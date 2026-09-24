// Standalone end-to-end harness for the NeoNSF native sidecar.
//
// Drives a real HanabiNeoNSF.exe over the JSONL protocol against the local
// download test server, so the native engine can be exercised without booting
// Flutter. Usage:
//
//   dart run tool/neonsf_smoke.dart [path\to\HanabiNeoNSF.exe]
//
// The executable argument is optional; without it the normal bridge resolution
// order applies.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hanabi_download_manager_x/services/kernel/neonsf/neonsf_process_bridge.dart';
import 'package:path/path.dart' as path;

import 'download_test_server.dart';

late LocalDownloadTestServer server;
late NeoNsfProcessBridge bridge;
late Directory workDir;

final List<String> failures = <String>[];
int passed = 0;

Future<void> main(List<String> args) async {
  final executable = args.isNotEmpty ? args.first : null;
  if (executable != null && !File(executable).existsSync()) {
    stderr.writeln('Executable not found: $executable');
    exitCode = 2;
    return;
  }

  server = LocalDownloadTestServer(port: 0);
  await server.start();
  workDir = await Directory.systemTemp.createTemp('neonsf_smoke_');
  bridge = NeoNsfProcessBridge(
    launchSpec:
        executable == null ? null : NeoNsfLaunchSpec(executable: executable),
  );

  try {
    final ready = await bridge.start();
    stdout.writeln('ready: ${ready['name']} ${ready['version']} '
        'protocol=${ready['protocolVersion']}');
    final capabilities = ready['capabilities'] as Map?;
    stdout.writeln('capabilities: $capabilities');
    _expect(ready['protocolVersion'] == 2, 'protocolVersion is 2');

    await _testKnownSmallFile();
    await _testUnknownSizeSmallFile();
    await _testParallelLargeFile();
    await _testServerWithoutRangeSupport();
    await _testPauseAndResume();
    await _testTransientDisconnect();
    await _testFlakyServerErrors();
    await _testChecksumVerification();
    await _testRejectedChecksum();
    await _testConcurrencyGate();
  } catch (error, stackTrace) {
    failures.add('harness crashed: $error\n$stackTrace');
  } finally {
    await bridge.dispose();
    await server.close();
    if (await workDir.exists()) {
      await workDir.delete(recursive: true);
    }
  }

  stdout.writeln('');
  stdout.writeln('passed: $passed, failed: ${failures.length}');
  for (final failure in failures) {
    stdout.writeln('  FAIL  $failure');
  }
  exitCode = failures.isEmpty ? 0 : 1;
}

// ----------------------------------------------------------------- scenarios

Future<void> _testKnownSmallFile() async {
  const size = 512 * 1024;
  final result = await _run(
    label: 'known small file goes direct',
    taskId: 'small-known',
    url: _url('normal', '512k.bin', 'small-known'),
    expectedSize: size,
  );
  _expect(result.completed, 'small-known completed: ${result.error}');
  _expect(result.transferMode == 'direct',
      'small-known used direct, got ${result.transferMode}');
  await _expectBytes(result.filePath, size, 'small-known');
}

Future<void> _testUnknownSizeSmallFile() async {
  // The old engine issued a HEAD whenever expectedSize was absent, which is the
  // common case for manually added downloads.
  const size = 512 * 1024;
  final result = await _run(
    label: 'unknown size small file needs no preflight',
    taskId: 'small-unknown',
    url: _url('normal', '512k.bin', 'small-unknown'),
  );
  _expect(result.completed, 'small-unknown completed: ${result.error}');
  _expect(result.totalBytes == size,
      'small-unknown learned its size, got ${result.totalBytes}');
  await _expectBytes(result.filePath, size, 'small-unknown');
  _expect(result.requestCount == 1,
      'small-unknown used exactly 1 request, used ${result.requestCount}');
}

Future<void> _testParallelLargeFile() async {
  const size = 64 * 1024 * 1024;
  final result = await _run(
    label: 'large file is chunked across lanes',
    taskId: 'large-parallel',
    url: _url('normal', '64m.bin', 'large-parallel'),
    expectedSize: size,
    maxConnections: 8,
    timeout: const Duration(seconds: 120),
  );
  _expect(result.completed, 'large-parallel completed: ${result.error}');
  _expect(result.transferMode == 'parallel_range',
      'large-parallel used ranges, got ${result.transferMode}');
  _expect(result.connectionCount > 1,
      'large-parallel opened >1 lane, got ${result.connectionCount}');
  await _expectBytes(result.filePath, size, 'large-parallel');
}

Future<void> _testServerWithoutRangeSupport() async {
  const size = 16 * 1024 * 1024;
  final result = await _run(
    label: 'range-less server falls back to a single stream',
    taskId: 'no-range',
    url: _url('no-range', '16m.bin', 'no-range'),
    expectedSize: size,
    maxConnections: 8,
    timeout: const Duration(seconds: 90),
  );
  _expect(result.completed, 'no-range completed: ${result.error}');
  _expect(result.transferMode == 'direct',
      'no-range collapsed to direct, got ${result.transferMode}');
  await _expectBytes(result.filePath, size, 'no-range');
}

Future<void> _testPauseAndResume() async {
  const size = 48 * 1024 * 1024;
  const taskId = 'pause-resume';
  final filePath = path.join(workDir.path, '$taskId.bin');
  final terminal = _terminalEvent(taskId, const Duration(seconds: 120));

  await bridge.enqueue(_payload(
    taskId: taskId,
    url: _url('slow', '48m.bin', taskId, extra: 'delayMs=8'),
    filePath: filePath,
    expectedSize: size,
    maxConnections: 4,
  ));

  await _firstEvent(taskId, 'progress', const Duration(seconds: 20));
  final paused = _firstEvent(taskId, 'paused', const Duration(seconds: 20));
  _expect(await bridge.pause(taskId), 'pause accepted');
  await paused;

  final checkpoint = File('$filePath.neonsf.state');
  _expect(await checkpoint.exists(), 'checkpoint written on pause');

  _expect(await bridge.resume(taskId), 'resume accepted');
  final event = await terminal;
  _expect(event['type'] == 'completed',
      'pause-resume completed: ${event['error']}');
  await _expectBytes(filePath, size, 'pause-resume');
  _expect(!await checkpoint.exists(), 'checkpoint cleaned up after completion');
  _expect(!await File('$filePath.neonsf.partial').exists(),
      'partial cleaned up after completion');
}

Future<void> _testTransientDisconnect() async {
  const size = 16 * 1024 * 1024;
  final result = await _run(
    label: 'mid-transfer disconnect is retried per segment',
    taskId: 'disconnect',
    url: _url('disconnect-once', '16m.bin', 'disconnect'),
    expectedSize: size,
    maxConnections: 4,
    timeout: const Duration(seconds: 90),
  );
  _expect(result.completed, 'disconnect completed: ${result.error}');
  await _expectBytes(result.filePath, size, 'disconnect');
}

Future<void> _testFlakyServerErrors() async {
  const size = 4 * 1024 * 1024;
  final result = await _run(
    label: 'transient 503 is retried',
    taskId: 'flaky',
    url: _url('flaky-503', '4m.bin', 'flaky'),
    expectedSize: size,
    timeout: const Duration(seconds: 90),
  );
  _expect(result.completed, 'flaky completed: ${result.error}');
  await _expectBytes(result.filePath, size, 'flaky');
}

Future<void> _testChecksumVerification() async {
  const size = 1024 * 1024;
  final digest = await _patternDigest(size);
  final result = await _run(
    label: 'matching sha256 is accepted',
    taskId: 'sha-ok',
    url: _url('normal', '1m.bin', 'sha-ok'),
    expectedSize: size,
    expectedSha256: digest,
  );
  _expect(result.completed, 'sha-ok completed: ${result.error}');
}

Future<void> _testRejectedChecksum() async {
  const size = 1024 * 1024;
  final result = await _run(
    label: 'mismatched sha256 fails without publishing the file',
    taskId: 'sha-bad',
    url: _url('normal', '1m.bin', 'sha-bad'),
    expectedSize: size,
    expectedSha256: '0' * 64,
    timeout: const Duration(seconds: 60),
  );
  _expect(!result.completed, 'sha-bad refused to complete');
  _expect((result.error ?? '').contains('CHECKSUM_MISMATCH'),
      'sha-bad reported a checksum mismatch, got ${result.error}');
  _expect(!await File(result.filePath).exists(),
      'sha-bad left no output file behind');
}

Future<void> _testConcurrencyGate() async {
  await bridge.command('configure', payload: <String, dynamic>{
    'maxConcurrentTransfers': 1,
  });

  final ids = <String>['gate-a', 'gate-b'];
  final queued = _firstEvent(ids[1], 'queued', const Duration(seconds: 20));
  final terminals = ids
      .map((id) => _terminalEvent(id, const Duration(seconds: 90)))
      .toList(growable: false);

  for (final id in ids) {
    await bridge.enqueue(_payload(
      taskId: id,
      url: _url('slow', '8m.bin', id, extra: 'delayMs=4'),
      filePath: path.join(workDir.path, '$id.bin'),
      expectedSize: 8 * 1024 * 1024,
      maxConnections: 2,
    ));
  }

  try {
    await queued;
    _expect(true, 'second task was queued behind the concurrency limit');
  } on TimeoutException {
    _expect(false, 'second task was queued behind the concurrency limit');
  }

  for (var index = 0; index < ids.length; index++) {
    final event = await terminals[index];
    _expect(event['type'] == 'completed',
        '${ids[index]} completed: ${event['error']}');
  }

  await bridge.command('configure', payload: <String, dynamic>{
    'maxConcurrentTransfers': 5,
  });
}

// ------------------------------------------------------------------ plumbing

class _Outcome {
  _Outcome({
    required this.completed,
    required this.filePath,
    this.error,
    this.transferMode,
    this.connectionCount = 0,
    this.totalBytes = 0,
    this.requestCount = 0,
  });

  final bool completed;
  final String filePath;
  final String? error;
  final String? transferMode;
  final int connectionCount;
  final int totalBytes;
  final int requestCount;
}

Future<_Outcome> _run({
  required String label,
  required String taskId,
  required String url,
  int? expectedSize,
  int maxConnections = 8,
  String? expectedSha256,
  Duration timeout = const Duration(seconds: 45),
}) async {
  stdout.writeln('· $label');
  final filePath = path.join(workDir.path, '$taskId.bin');

  String? transferMode;
  var connectionCount = 0;
  var totalBytes = 0;
  var requestCount = 0;

  final subscription = bridge.events.listen((event) {
    if (event['taskId'] != taskId) return;
    if (event['type'] == 'headers') {
      transferMode = event['transferMode']?.toString();
      connectionCount = (event['maxConnectionCount'] as num?)?.toInt() ??
          (event['connectionCount'] as num?)?.toInt() ??
          0;
      totalBytes = (event['totalBytes'] as num?)?.toInt() ?? 0;
    }
  });

  final before = await _serverRequestCount();
  final terminal = _terminalEvent(taskId, timeout);
  await bridge.enqueue(_payload(
    taskId: taskId,
    url: url,
    filePath: filePath,
    expectedSize: expectedSize,
    maxConnections: maxConnections,
    expectedSha256: expectedSha256,
  ));

  Map<String, dynamic> event;
  try {
    event = await terminal;
  } on TimeoutException {
    event = <String, dynamic>{'type': 'failed', 'error': 'timed out'};
  } finally {
    // The stats endpoint counts itself, so the closing sample inflates the delta by one.
    requestCount = await _serverRequestCount() - before - 1;
    await subscription.cancel();
  }

  return _Outcome(
    completed: event['type'] == 'completed',
    filePath: filePath,
    error: event['error']?.toString(),
    transferMode: transferMode,
    connectionCount: connectionCount,
    totalBytes: totalBytes,
    requestCount: requestCount,
  );
}

Map<String, dynamic> _payload({
  required String taskId,
  required String url,
  required String filePath,
  int? expectedSize,
  int maxConnections = 8,
  String? expectedSha256,
}) =>
    <String, dynamic>{
      'taskId': taskId,
      'url': url,
      'filePath': filePath,
      if (expectedSize != null) 'expectedSize': expectedSize,
      if (expectedSha256 != null) 'expectedSha256': expectedSha256,
      'headers': const <String, String>{},
      'maxConnections': maxConnections,
      'maxRetries': 3,
      'httpVersionPolicy': 'auto',
    };

String _url(String scenario, String sizeToken, String resource,
    {String? extra}) {
  final query =
      extra == null ? 'resource=$resource' : 'resource=$resource&$extra';
  return server.baseUri
      .resolve('download/$scenario/$sizeToken?$query')
      .toString();
}

Future<Map<String, dynamic>> _terminalEvent(String taskId, Duration timeout) =>
    bridge.events
        .firstWhere((event) =>
            event['taskId'] == taskId &&
            (event['type'] == 'completed' || event['type'] == 'failed'))
        .timeout(timeout);

Future<Map<String, dynamic>> _firstEvent(
  String taskId,
  String type,
  Duration timeout,
) =>
    bridge.events
        .firstWhere(
            (event) => event['taskId'] == taskId && event['type'] == type)
        .timeout(timeout);

Future<int> _serverRequestCount() async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(server.baseUri.resolve('api/v1/stats'));
    final response = await request.close();
    final body = await response.transform(const Utf8Decoder()).join();
    final match = RegExp(r'"totalRequests"\s*:\s*(\d+)').firstMatch(body);
    return match == null ? 0 : int.parse(match.group(1)!);
  } catch (_) {
    return 0;
  } finally {
    client.close(force: true);
  }
}

Future<void> _expectBytes(String filePath, int size, String label) async {
  final file = File(filePath);
  if (!await file.exists()) {
    _expect(false, '$label produced an output file');
    return;
  }
  final actual = await file.readAsBytes();
  if (actual.length != size) {
    _expect(false, '$label is $size bytes, got ${actual.length}');
    return;
  }
  final expected = DownloadTestPattern.bytes(0, size);
  for (var index = 0; index < size; index++) {
    if (actual[index] != expected[index]) {
      _expect(false, '$label matches the source at byte $index');
      return;
    }
  }
  _expect(true, '$label is byte-exact');
}

Future<String> _patternDigest(int size) async {
  final bytes = DownloadTestPattern.bytes(0, size);
  final digest = await _sha256(bytes);
  return digest;
}

Future<String> _sha256(List<int> bytes) async {
  final temp = File(path.join(workDir.path, '.digest.tmp'));
  await temp.writeAsBytes(bytes, flush: true);
  final result = await Process.run(
    'certutil',
    <String>['-hashfile', temp.path, 'SHA256'],
  );
  await temp.delete();
  final lines = result.stdout
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => RegExp(r'^[0-9a-fA-F ]{64,}$').hasMatch(line))
      .toList();
  if (lines.isEmpty) {
    throw StateError('certutil produced no digest: ${result.stdout}');
  }
  return lines.first.replaceAll(' ', '').toLowerCase();
}

void _expect(bool condition, String description) {
  if (condition) {
    passed++;
    stdout.writeln('  ok    $description');
  } else {
    failures.add(description);
    stdout.writeln('  FAIL  $description');
  }
}
