import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

class NeoNsfLaunchSpec {
  const NeoNsfLaunchSpec({
    required this.executable,
    this.arguments = const <String>[],
    this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
}

/// Owns the native sidecar process and the JSONL control channel.
///
/// Beyond framing, this supervises the child: an unexpected exit is followed by a
/// backing-off restart, and a periodic ping detects a process that is alive but no
/// longer answering. Without that, a single sidecar crash left every task frozen
/// with no way back short of restarting the whole app.
class NeoNsfProcessBridge {
  NeoNsfProcessBridge({
    NeoNsfLaunchSpec? launchSpec,
    bool supervise = true,
    Duration heartbeatInterval = const Duration(seconds: 10),
  })  : _launchSpec = launchSpec,
        _supervise = supervise,
        _heartbeatInterval = heartbeatInterval;

  static const int _maxMissedHeartbeats = 3;
  static const Duration _maxRestartDelay = Duration(seconds: 30);

  final NeoNsfLaunchSpec? _launchSpec;
  final bool _supervise;
  final Duration _heartbeatInterval;
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Completer<Map<String, dynamic>>? _ready;
  Map<String, dynamic>? _lastHandshake;
  Timer? _restartTimer;
  Timer? _heartbeatTimer;
  int _requestSequence = 0;
  int _restartAttempts = 0;
  int _missedHeartbeats = 0;
  bool _stopping = false;
  bool _startedOnce = false;
  bool _disposed = false;

  Stream<Map<String, dynamic>> get events => _events.stream;

  bool get isRunning => _process != null;

  /// The handshake payload from the most recent successful start.
  Map<String, dynamic>? get handshake => _lastHandshake;

  Future<Map<String, dynamic>> start({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (_process != null) {
      final ready = _ready;
      return ready == null ? <String, dynamic>{} : await ready.future;
    }

    _stopping = false;
    _restartTimer?.cancel();
    _restartTimer = null;

    final launch = _launchSpec ?? resolveDefaultLaunchSpec();
    final ready = Completer<Map<String, dynamic>>();
    _ready = ready;
    final process = await Process.start(
      launch.executable,
      <String>[
        ...launch.arguments,
        // The sidecar exits on its own if this process disappears, so a hard kill
        // of the app cannot leave an invisible downloader running forever.
        '--parent-pid',
        '$pid',
      ],
      workingDirectory: launch.workingDirectory,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    _process = process;

    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine, onError: _handleProcessError);
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isNotEmpty) {
        _events.add(<String, dynamic>{
          'type': 'diagnostic',
          'level': 'error',
          'message': line,
        });
      }
    });
    unawaited(process.exitCode.then(_handleExit));

    try {
      final handshake = await ready.future.timeout(timeout);
      _lastHandshake = handshake;
      _startedOnce = true;
      _restartAttempts = 0;
      _missedHeartbeats = 0;
      _startHeartbeat();
      return handshake;
    } catch (_) {
      await stop(force: true);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> command(
    String command, {
    Map<String, dynamic>? payload,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final process = _process;
    if (process == null) {
      throw StateError('NeoNSF process is not running.');
    }

    final requestId = 'dart-${++_requestSequence}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    process.stdin.writeln(jsonEncode(<String, dynamic>{
      'requestId': requestId,
      'command': command,
      if (payload != null) 'payload': payload,
    }));
    await process.stdin.flush();

    try {
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(requestId);
    }
  }

  Future<bool> enqueue(Map<String, dynamic> payload) async {
    final response = await command('enqueue', payload: payload);
    if (response['ok'] != true) {
      throw StateError(response['error']?.toString() ?? 'Unknown NeoNSF error');
    }
    return true;
  }

  Future<bool> pause(String taskId) async {
    final response = await command('pause', payload: {'taskId': taskId});
    return response['ok'] == true;
  }

  Future<bool> resume(String taskId) async {
    final response = await command(
      'resume',
      payload: {'taskId': taskId},
      // Resuming waits for the previous run to unwind on the native side.
      timeout: const Duration(seconds: 20),
    );
    return response['ok'] == true;
  }

  Future<bool> cancel(String taskId, {bool deletePartial = true}) async {
    final response = await command('cancel', payload: {
      'taskId': taskId,
      'deletePartial': deletePartial,
    });
    return response['ok'] == true;
  }

  Future<bool> configure({
    int? maxConcurrentTransfers,
    int? maxBytesPerSecond,
  }) async {
    if (maxConcurrentTransfers == null && maxBytesPerSecond == null) {
      return true;
    }
    final response = await command('configure', payload: <String, dynamic>{
      if (maxConcurrentTransfers != null)
        'maxConcurrentTransfers': maxConcurrentTransfers,
      if (maxBytesPerSecond != null) 'maxBytesPerSecond': maxBytesPerSecond,
    });
    return response['ok'] == true;
  }

  Future<void> stop({bool force = false}) async {
    _stopping = true;
    _restartTimer?.cancel();
    _restartTimer = null;
    _stopHeartbeat();

    final process = _process;
    if (process == null) return;

    if (!force) {
      try {
        await command('shutdown', timeout: const Duration(seconds: 2));
      } catch (_) {}
    }

    try {
      await process.stdin.close();
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill();
    }
    await _clearProcess();
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _events.close();
  }

  // --------------------------------------------------------------- supervision

  void _startHeartbeat() {
    _stopHeartbeat();
    if (!_supervise || _heartbeatInterval <= Duration.zero) return;
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _beat());
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _beat() async {
    if (_process == null || _stopping) return;
    try {
      final response = await command(
        'ping',
        timeout: const Duration(seconds: 5),
      );
      if (response['ok'] == true) {
        _missedHeartbeats = 0;
        return;
      }
      _missedHeartbeats++;
    } catch (_) {
      _missedHeartbeats++;
    }

    if (_missedHeartbeats < _maxMissedHeartbeats) return;

    // Alive but wedged. Killing it routes through the normal exit handler, which
    // restarts it and lets the kernel re-enqueue from the native checkpoints.
    _events.add(<String, dynamic>{
      'type': 'diagnostic',
      'level': 'error',
      'message':
          'NeoNSF missed $_missedHeartbeats heartbeats; recycling the sidecar.',
    });
    _missedHeartbeats = 0;
    _process?.kill();
  }

  Future<void> _handleExit(int exitCode) async {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        StateError('NeoNSF exited before handshake with code $exitCode.'),
      );
    }
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          StateError('NeoNSF exited with code $exitCode.'),
        );
      }
    }
    _pending.clear();
    _stopHeartbeat();

    final willRestart = _supervise && !_stopping && !_disposed && _startedOnce;
    if (!_events.isClosed) {
      _events.add(<String, dynamic>{
        'type': 'processExited',
        'exitCode': exitCode,
        'willRestart': willRestart,
      });
    }
    await _clearProcess();

    if (willRestart) {
      _scheduleRestart();
    }
  }

  void _scheduleRestart() {
    _restartTimer?.cancel();
    final delay = Duration(
      milliseconds: min(
        _maxRestartDelay.inMilliseconds,
        500 * (1 << min(_restartAttempts, 6)),
      ),
    );
    _restartAttempts++;
    _restartTimer = Timer(delay, () async {
      if (_stopping || _disposed || _process != null) return;
      try {
        await start();
        if (!_events.isClosed) {
          _events.add(<String, dynamic>{
            'type': 'processRestarted',
            'attempts': _restartAttempts,
          });
        }
      } catch (error) {
        if (!_events.isClosed) {
          _events.add(<String, dynamic>{
            'type': 'diagnostic',
            'level': 'error',
            'message': 'NeoNSF restart failed: $error',
          });
        }
        if (!_stopping && !_disposed) {
          _scheduleRestart();
        }
      }
    });
  }

  // ------------------------------------------------------------------ framing

  void _handleLine(String line) {
    if (line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      final event = decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final type = event['type']?.toString();
      if (type == 'ready') {
        final ready = _ready;
        if (ready != null && !ready.isCompleted) {
          ready.complete(event);
        }
        return;
      }
      if (type == 'response') {
        final requestId = event['requestId']?.toString();
        final pending = requestId == null ? null : _pending[requestId];
        if (pending != null && !pending.isCompleted) {
          pending.complete(event);
        }
        return;
      }
      if (!_events.isClosed) {
        _events.add(event);
      }
    } catch (error) {
      if (!_events.isClosed) {
        _events.add(<String, dynamic>{
          'type': 'diagnostic',
          'level': 'error',
          'message': 'Invalid NeoNSF protocol line: $error',
          'line': line,
        });
      }
    }
  }

  void _handleProcessError(Object error, StackTrace stackTrace) {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(error, stackTrace);
    }
  }

  Future<void> _clearProcess() async {
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _process = null;
    _ready = null;
  }

  static NeoNsfLaunchSpec resolveDefaultLaunchSpec() {
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = path.join(
      executableDir,
      'data',
      'zzbuaoye_assets',
      'neonsf',
      'HanabiNeoNSF.exe',
    );
    if (File(bundled).existsSync()) {
      return NeoNsfLaunchSpec(executable: bundled);
    }

    final localBuild = path.join(
      Directory.current.path,
      'build',
      'neonsf',
      'win-x64',
      'HanabiNeoNSF.exe',
    );
    if (File(localBuild).existsSync()) {
      return NeoNsfLaunchSpec(executable: localBuild);
    }

    final legacyLocalDist = path.join(
      Directory.current.path,
      'neonsf',
      'dist',
      'HanabiNeoNSF.exe',
    );
    if (File(legacyLocalDist).existsSync()) {
      return NeoNsfLaunchSpec(executable: legacyLocalDist);
    }

    final debugDll = path.join(
      Directory.current.path,
      'neonsf',
      'dotnet',
      'Hanabi.NeoNSF',
      'bin',
      'Debug',
      'net8.0',
      'win-x64',
      'HanabiNeoNSF.dll',
    );
    if (File(debugDll).existsSync()) {
      return NeoNsfLaunchSpec(
        executable: 'dotnet',
        arguments: <String>[debugDll],
        workingDirectory: Directory.current.path,
      );
    }

    throw StateError(
      'NeoNSF executable was not found. Build neonsf/build_dotnet.ps1 first.',
    );
  }
}
