// Real-network A/B harness for the NeoNSF sidecar.
//
// Runs the same URL through one or more engine builds at one or more connection
// counts, then compares wall time, throughput and SHA-256. Identical digests
// across every run are the proof that chunk assembly is byte-correct; the time
// column is the proof that per-lane connections actually buy something.
//
//   dart run tool/neonsf_live_check.dart \
//     --url https://example.com/file.zip \
//     --engine new=path\to\HanabiNeoNSF.exe \
//     --engine old=path\to\old\HanabiNeoNSF.exe \
//     --connections 1,8
//
// Without --engine the normal bridge resolution order applies.

import 'dart:async';
import 'dart:io';

import 'package:hanabi_download_manager_x/services/kernel/neonsf/neonsf_process_bridge.dart';
import 'package:path/path.dart' as path;

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options == null) {
    stderr.writeln(
      'usage: dart run tool/neonsf_live_check.dart --url <url> '
      '[--engine label=exe]... [--connections 1,8] [--expect-sha256 hex] [--keep]',
    );
    exitCode = 2;
    return;
  }

  final workDir = await Directory.systemTemp.createTemp('neonsf_live_');
  final results = <_Result>[];

  try {
    for (final engine in options.engines.entries) {
      for (final connections in options.connections) {
        final result = await _runOnce(
          engineLabel: engine.key,
          executable: engine.value,
          url: options.url,
          connections: connections,
          workDir: workDir,
          keep: options.keep,
        );
        results.add(result);
        stdout.writeln('');
      }
    }
  } finally {
    if (!options.keep && await workDir.exists()) {
      await workDir.delete(recursive: true);
    }
  }

  _report(results, options.expectSha256);
  final ok = results.every((r) => r.error == null) && _digestsAgree(results);
  exitCode = ok ? 0 : 1;
}

Future<_Result> _runOnce({
  required String engineLabel,
  required String? executable,
  required String url,
  required int connections,
  required Directory workDir,
  required bool keep,
}) async {
  final label = '$engineLabel/${connections}c';
  stdout.writeln('▶ $label  $url');

  final bridge = NeoNsfProcessBridge(
    launchSpec:
        executable == null ? null : NeoNsfLaunchSpec(executable: executable),
    // A restart mid-measurement would silently corrupt the timing.
    supervise: false,
  );
  final filePath = path.join(
    workDir.path,
    '${engineLabel}_${connections}c_${DateTime.now().microsecondsSinceEpoch}.bin',
  );
  final taskId = 'live-$engineLabel-$connections';

  var totalBytes = 0;
  var lanes = 0;
  var peakLanes = 0;
  String? mode;
  String? httpVersion;
  var supportsRanges = false;
  var retries = 0;
  var segmentRetries = 0;
  var lastPrinted = 0;

  try {
    final ready = await bridge.start();
    stdout.writeln(
      '  engine ${ready['name']} ${ready['version']} '
      '(protocol ${ready['protocolVersion']})',
    );

    final done = Completer<Map<String, dynamic>>();
    final subscription = bridge.events.listen((event) {
      if (event['taskId'] != taskId) return;
      switch (event['type']) {
        case 'headers':
          totalBytes = (event['totalBytes'] as num?)?.toInt() ?? 0;
          lanes = (event['maxConnectionCount'] as num?)?.toInt() ??
              (event['connectionCount'] as num?)?.toInt() ??
              0;
          mode = event['transferMode']?.toString();
          httpVersion = event['httpVersion']?.toString();
          supportsRanges = event['supportsRanges'] == true;
          stdout.writeln(
            '  headers: ${_bytes(totalBytes)} http/$httpVersion '
            'ranges=$supportsRanges mode=$mode lanes=$lanes',
          );
        case 'progress':
          final downloaded = (event['downloadedBytes'] as num?)?.toInt() ?? 0;
          final bps = (event['instantBps'] as num?)?.toDouble() ?? 0;
          // Where the lane governor actually settled, which is the interesting
          // number now that the count is adaptive.
          final live = (event['connectionCount'] as num?)?.toInt() ?? 0;
          if (live > peakLanes) peakLanes = live;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastPrinted >= 2000) {
            lastPrinted = now;
            final percent =
                totalBytes > 0 ? (downloaded * 100 / totalBytes) : 0.0;
            stdout.writeln(
              '  ${percent.toStringAsFixed(1).padLeft(5)}%  '
              '${_bytes(downloaded)}  ${_bytes(bps.round())}/s  ${live}L',
            );
          }
        case 'retrying':
          retries++;
          stdout.writeln('  retry #$retries: ${event['error']}');
        case 'segmentRetrying':
          segmentRetries++;
          if (segmentRetries <= 5) {
            stdout.writeln(
              '  lane ${event['lane']} retry: ${event['error']}',
            );
          }
        case 'completed':
        case 'failed':
          if (!done.isCompleted) done.complete(event);
      }
    });

    final stopwatch = Stopwatch()..start();
    await bridge.enqueue(<String, dynamic>{
      'taskId': taskId,
      'url': url,
      'filePath': filePath,
      // Mirror the real app: NeoNsfKernel always sends a User-Agent, and mirrors
      // like Aliyun's answer 403 to UA-less requests.
      'headers': const <String, String>{
        'User-Agent': 'NSFX/2.0 (Next Speed Force X)',
      },
      'maxConnections': connections,
      'maxRetries': 3,
      'httpVersionPolicy': 'auto',
    });

    final event = await done.future.timeout(const Duration(minutes: 20));
    stopwatch.stop();
    await subscription.cancel();

    if (event['type'] != 'completed') {
      return _Result(
        label: label,
        error: event['error']?.toString() ?? 'failed',
        elapsed: stopwatch.elapsed,
      );
    }

    final downloaded = (event['downloadedBytes'] as num?)?.toInt() ?? 0;
    final digest = await _sha256(filePath);
    stdout.writeln(
      '  done in ${_seconds(stopwatch.elapsed)} '
      '(${_bytes((downloaded / stopwatch.elapsed.inMilliseconds * 1000).round())}/s)',
    );

    if (!keep) {
      await File(filePath).delete();
    }

    return _Result(
      label: label,
      elapsed: stopwatch.elapsed,
      bytes: downloaded,
      digest: digest,
      lanes: lanes,
      peakLanes: peakLanes,
      mode: mode,
      httpVersion: httpVersion,
      retries: retries,
      segmentRetries: segmentRetries,
    );
  } catch (error) {
    return _Result(label: label, error: error.toString());
  } finally {
    await bridge.dispose();
  }
}

void _report(List<_Result> results, String? expected) {
  stdout.writeln('=' * 78);
  stdout.writeln('${'run'.padRight(14)}${'time'.padLeft(9)}'
      '${'throughput'.padLeft(14)}${'lanes'.padLeft(7)}'
      '${'mode'.padLeft(16)}  sha256');
  stdout.writeln('-' * 78);
  for (final result in results) {
    if (result.error != null) {
      stdout.writeln('${result.label.padRight(14)}  FAILED: ${result.error}');
      continue;
    }
    final bps = result.bytes / result.elapsed.inMilliseconds * 1000;
    stdout.writeln('${result.label.padRight(14)}'
        '${_seconds(result.elapsed).padLeft(9)}'
        '${'${_bytes(bps.round())}/s'.padLeft(14)}'
        '${'${result.peakLanes}/${result.lanes}'.padLeft(7)}'
        '${(result.mode ?? '-').padLeft(16)}'
        '  ${result.digest?.substring(0, 16)}…');
  }
  stdout.writeln('=' * 78);

  final digests =
      results.where((r) => r.digest != null).map((r) => r.digest!).toSet();
  if (digests.length <= 1) {
    stdout.writeln('✓ every run produced an identical file');
  } else {
    stdout.writeln('✗ DIGEST MISMATCH across runs: $digests');
  }
  if (expected != null && digests.isNotEmpty) {
    final match =
        digests.length == 1 && digests.first == expected.toLowerCase();
    stdout.writeln(
      match
          ? '✓ digest matches the published checksum'
          : '✗ digest does NOT match the published checksum ($expected)',
    );
  }

  final fastest = results.where((r) => r.error == null).toList()
    ..sort((a, b) => a.elapsed.compareTo(b.elapsed));
  if (fastest.length >= 2) {
    final best = fastest.first;
    final worst = fastest.last;
    final speedup = worst.elapsed.inMilliseconds / best.elapsed.inMilliseconds;
    stdout.writeln(
      'fastest ${best.label} is ${speedup.toStringAsFixed(2)}x '
      'the slowest (${worst.label})',
    );
  }
}

bool _digestsAgree(List<_Result> results) =>
    results
        .where((r) => r.digest != null)
        .map((r) => r.digest!)
        .toSet()
        .length <=
    1;

class _Result {
  _Result({
    required this.label,
    this.elapsed = Duration.zero,
    this.bytes = 0,
    this.digest,
    this.lanes = 0,
    this.peakLanes = 0,
    this.mode,
    this.httpVersion,
    this.retries = 0,
    this.segmentRetries = 0,
    this.error,
  });

  final String label;
  final Duration elapsed;
  final int bytes;
  final String? digest;
  final int lanes;
  final int peakLanes;
  final String? mode;
  final String? httpVersion;
  final int retries;
  final int segmentRetries;
  final String? error;
}

class _Options {
  _Options({
    required this.url,
    required this.engines,
    required this.connections,
    required this.keep,
    this.expectSha256,
  });

  final String url;
  final Map<String, String?> engines;
  final List<int> connections;
  final bool keep;
  final String? expectSha256;

  static _Options? parse(List<String> args) {
    String? url;
    final engines = <String, String?>{};
    var connections = <int>[8];
    var keep = false;
    String? expectSha256;

    for (var index = 0; index < args.length; index++) {
      switch (args[index]) {
        case '--url':
          url = args[++index];
        case '--engine':
          final spec = args[++index];
          final separator = spec.indexOf('=');
          if (separator < 0) {
            engines['engine${engines.length}'] = spec;
          } else {
            engines[spec.substring(0, separator)] =
                spec.substring(separator + 1);
          }
        case '--connections':
          connections = args[++index]
              .split(',')
              .map((value) => int.parse(value.trim()))
              .toList();
        case '--expect-sha256':
          expectSha256 = args[++index].trim().toLowerCase();
        case '--keep':
          keep = true;
      }
    }

    if (url == null) return null;
    if (engines.isEmpty) engines['default'] = null;
    return _Options(
      url: url,
      engines: engines,
      connections: connections,
      keep: keep,
      expectSha256: expectSha256,
    );
  }
}

Future<String> _sha256(String filePath) async {
  final result = await Process.run(
    'certutil',
    <String>['-hashfile', filePath, 'SHA256'],
  );
  final line = result.stdout
      .toString()
      .split('\n')
      .map((value) => value.trim())
      .firstWhere(
        (value) => RegExp(r'^[0-9a-fA-F ]{64,}$').hasMatch(value),
        orElse: () => '',
      );
  return line.replaceAll(' ', '').toLowerCase();
}

String _bytes(int value) {
  const units = <String>['B', 'KiB', 'MiB', 'GiB'];
  var size = value.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String _seconds(Duration duration) =>
    '${(duration.inMilliseconds / 1000).toStringAsFixed(2)}s';
