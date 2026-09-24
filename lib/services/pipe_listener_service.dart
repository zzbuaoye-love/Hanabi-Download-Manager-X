import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

int? _readPositiveInt(Object? raw) {
  final value = raw is num ? raw.toInt() : int.tryParse('$raw');
  return value != null && value > 0 ? value : null;
}

/// Download request received from the popup application
class PopupDownloadRequest {
  final String url;
  final String filename;
  final String savePath;
  final String? referer;
  final String? userAgent;
  final String? cookies;
  final Map<String, dynamic>? headers;
  final int? expectedSizeHint;

  PopupDownloadRequest({
    required this.url,
    required this.filename,
    required this.savePath,
    this.referer,
    this.userAgent,
    this.cookies,
    this.headers,
    this.expectedSizeHint,
  });

  factory PopupDownloadRequest.fromJson(Map<String, dynamic> json) {
    final headersRaw = json['headers'];
    return PopupDownloadRequest(
      url: json['url']?.toString() ?? '',
      filename: json['filename']?.toString() ?? '',
      savePath: json['save_path']?.toString() ?? '',
      referer: json['referer']?.toString(),
      userAgent: (json['user_agent'] ?? json['userAgent'])?.toString(),
      cookies: json['cookies']?.toString(),
      headers: headersRaw is Map
          ? headersRaw.map(
              (key, value) => MapEntry(key.toString(), value),
            )
          : null,
      expectedSizeHint: _readPositiveInt(
        json['file_size'] ?? json['fileSize'] ?? json['total_bytes'],
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'filename': filename,
        'save_path': savePath,
        'referer': referer,
        'user_agent': userAgent,
        'cookies': cookies,
        'headers': headers,
        if (expectedSizeHint != null) 'file_size': expectedSizeHint,
      };

  @override
  String toString() =>
      'PopupDownloadRequest(url: $url, filename: $filename, savePath: $savePath)';
}

/// Service to listen for download requests from the Hanabi Popup application
/// via Windows Named Pipes.
///
/// Implementation notes (important for hot restart):
/// The previous implementation parked a `compute` isolate inside a blocking
/// `ConnectNamedPipe` call. An isolate stuck in a synchronous native call can
/// never reach a safepoint, so `flutter run` hot restart (R/r) waited on it
/// forever. This version uses overlapped (asynchronous) pipe I/O and only ever
/// waits on native events in short slices inside a Dart loop, so the worker
/// isolate stays interruptible at loop back-edges and can always be shut down
/// (hot restart, `Isolate.kill`, or the manual-reset stop event below).
class PipeListenerService with ChangeNotifier {
  static const String pipeName = r'\\.\pipe\hanabi-download';
  static const int bufferSize = 4096;

  bool _isRunning = false;
  bool _stopRequested = false;
  bool _disposed = false;
  Isolate? _workerIsolate;
  ReceivePort? _workerMessages;
  ReceivePort? _workerErrors;
  ReceivePort? _workerExit;
  StreamSubscription<dynamic>? _workerMessagesSub;
  StreamSubscription<dynamic>? _workerErrorsSub;
  StreamSubscription<dynamic>? _workerExitSub;
  Completer<void>? _stoppedCompleter;
  Timer? _restartTimer;
  Future<void>? _spawnInFlight;
  Future<void>? _stopInFlight;
  int _workerGeneration = 0;

  /// Address of the manual-reset win32 event used to ask the worker isolate to
  /// stop. Owned by the main isolate.
  int _stopEventAddress = 0;

  /// Callback when a download request is received
  FutureOr<void> Function(PopupDownloadRequest)? onDownloadRequest;

  /// Whether the pipe listener is currently running
  bool get isRunning => _isRunning;

  /// Start listening for download requests
  Future<void> start() async {
    final stopping = _stopInFlight;
    if (stopping != null) {
      await stopping;
    }
    if (_disposed) {
      return;
    }
    if (_isRunning) {
      debugPrint('[PipeListener] Already running');
      return;
    }

    debugPrint('[PipeListener] Starting pipe listener...');

    // A previous hot restart may have killed the worker isolate without
    // running its cleanup, leaking a pipe instance with a pending listen.
    // Neutralize such zombies so they cannot steal client connections.
    _neutralizeStaleServerInstances();

    final stopEventResult = CreateEvent(null, true, false, null);
    final stopEvent = stopEventResult.value;
    if (stopEvent.address == 0) {
      debugPrint(
        '[PipeListener] Failed to create stop event '
        '(error ${stopEventResult.error})',
      );
      return;
    }
    _stopEventAddress = stopEvent.address;

    _isRunning = true;
    _stopRequested = false;
    final generation = ++_workerGeneration;
    _safeNotify();

    final spawn = _spawnWorker(generation);
    _spawnInFlight = spawn;
    try {
      await spawn;
    } finally {
      if (identical(_spawnInFlight, spawn)) {
        _spawnInFlight = null;
      }
    }
  }

  /// Stop listening for download requests
  Future<void> stop() {
    final existing = _stopInFlight;
    if (existing != null) {
      return existing;
    }

    late final Future<void> tracked;
    tracked = _stopOnce().whenComplete(() {
      if (identical(_stopInFlight, tracked)) {
        _stopInFlight = null;
      }
    });
    _stopInFlight = tracked;
    return tracked;
  }

  Future<void> _stopOnce() async {
    debugPrint('[PipeListener] Stopping pipe listener...');
    _stopRequested = true;
    _isRunning = false;
    _workerGeneration++;
    _restartTimer?.cancel();
    _restartTimer = null;

    final completer = _stoppedCompleter;
    if (_workerIsolate != null && _stopEventAddress != 0) {
      // Signal the manual-reset stop event; the worker notices it within one
      // wait slice and exits its loop cleanly.
      SetEvent(HANDLE(Pointer.fromAddress(_stopEventAddress)));
    }

    // Isolate.spawn itself is asynchronous. Do not close the shared stop event
    // until an in-flight spawn has either failed or produced an isolate that we
    // can stop.
    final spawning = _spawnInFlight;
    if (spawning != null) {
      await spawning;
    }

    if (completer != null && _workerIsolate != null) {
      try {
        await completer.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        debugPrint(
          '[PipeListener] Worker did not stop in time, killing isolate',
        );
        _workerIsolate?.kill(priority: Isolate.immediate);
        try {
          await completer.future.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          debugPrint('[PipeListener] Worker exit was not observed after kill');
        }
      }
    }

    _teardownWorkerState();

    _closeStopEvent();

    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _spawnWorker(int generation) async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    final exit = ReceivePort();

    _workerMessages = messages;
    _workerErrors = errors;
    _workerExit = exit;
    _stoppedCompleter = Completer<void>();

    _workerMessagesSub = messages.listen(_onWorkerMessage);
    _workerErrorsSub = errors.listen((error) {
      debugPrint('[PipeListener] Worker error: $error');
    });
    _workerExitSub = exit.listen((_) => _onWorkerExit(generation));

    try {
      final isolate = await Isolate.spawn(
        _pipeWorkerMain,
        <Object?>[messages.sendPort, _stopEventAddress],
        onError: errors.sendPort,
        onExit: exit.sendPort,
        errorsAreFatal: true,
        debugName: 'hanabi-pipe-listener',
      );
      _workerIsolate = isolate;
      if (generation != _workerGeneration || _stopRequested || !_isRunning) {
        isolate.kill(priority: Isolate.immediate);
        final stopped = _stoppedCompleter;
        if (stopped != null) {
          try {
            await stopped.future.timeout(const Duration(seconds: 1));
          } on TimeoutException {
            debugPrint(
              '[PipeListener] Spawned worker exit was not observed after kill',
            );
          }
        }
        return;
      }
      debugPrint('[PipeListener] Worker isolate started');
    } catch (e) {
      debugPrint('[PipeListener] Failed to start worker isolate: $e');
      _teardownWorkerState();
      if (generation == _workerGeneration) {
        _isRunning = false;
        _stopRequested = true;
        _workerGeneration++;
        _closeStopEvent();
        _safeNotify();
      }
    }
  }

  void _onWorkerMessage(dynamic message) {
    if (message is! List<Object?> || message.isEmpty) return;

    switch (message.first) {
      case 'data':
        final payload = message.length > 1 ? message[1] : null;
        if (payload is String && _isRunning) {
          _handleMessage(payload);
        }
      case 'log':
        final text = message.length > 1 ? message[1] : null;
        if (text != null) {
          debugPrint('[PipeListener] $text');
        }
      case 'stopped':
        _completeStopped();
    }
  }

  void _onWorkerExit(int generation) {
    _completeStopped();

    if (generation != _workerGeneration || _stopRequested || !_isRunning) {
      return;
    }

    // Unexpected worker death (e.g. an uncaught error): restart shortly.
    debugPrint('[PipeListener] Worker exited unexpectedly, restarting in 2s');
    _teardownWorkerState();
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(seconds: 2), () {
      if (_isRunning && !_stopRequested && _stopEventAddress != 0) {
        final spawn = _spawnWorker(generation);
        _spawnInFlight = spawn;
        unawaited(
          spawn.whenComplete(() {
            if (identical(_spawnInFlight, spawn)) {
              _spawnInFlight = null;
            }
          }),
        );
      }
    });
  }

  void _completeStopped() {
    final completer = _stoppedCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _teardownWorkerState() {
    _workerMessagesSub?.cancel();
    _workerErrorsSub?.cancel();
    _workerExitSub?.cancel();
    _workerMessages?.close();
    _workerErrors?.close();
    _workerExit?.close();
    _workerMessagesSub = null;
    _workerErrorsSub = null;
    _workerExitSub = null;
    _workerMessages = null;
    _workerErrors = null;
    _workerExit = null;
    _workerIsolate = null;
    _stoppedCompleter = null;
  }

  void _closeStopEvent() {
    if (_stopEventAddress == 0) {
      return;
    }
    CloseHandle(HANDLE(Pointer.fromAddress(_stopEventAddress)));
    _stopEventAddress = 0;
  }

  /// Connects (as a client) to any pipe instance that is currently waiting for
  /// a connection and immediately closes it. Live servers do not exist yet at
  /// this point in `start()`, so any instance we can open belongs to a worker
  /// isolate that was killed without cleanup (hot restart) - connecting to it
  /// takes it out of the listening pool for good.
  void _neutralizeStaleServerInstances() {
    final namePtr = pipeName.toNativeUtf16();
    try {
      for (var i = 0; i < 4; i++) {
        final result = CreateFile(
          PCWSTR(namePtr),
          GENERIC_WRITE,
          FILE_SHARE_NONE,
          null,
          OPEN_EXISTING,
          FILE_ATTRIBUTE_NORMAL,
          null,
        );
        final handle = result.value;
        if (handle.address == 0 ||
            handle.address == INVALID_HANDLE_VALUE.address) {
          break; // No (more) listening instances.
        }
        CloseHandle(handle);
        debugPrint('[PipeListener] Neutralized stale pipe instance');
      }
    } finally {
      free(namePtr);
    }
  }

  void _handleMessage(String message) {
    debugPrint('[PipeListener] Received message: $message');

    try {
      final json = jsonDecode(message) as Map<String, dynamic>;
      final request = PopupDownloadRequest.fromJson(json);

      debugPrint('[PipeListener] Parsed request: $request');

      // Notify callback
      if (onDownloadRequest != null) {
        unawaited(Future.sync(() => onDownloadRequest!(request)));
      }
    } catch (e) {
      debugPrint('[PipeListener] Failed to parse message: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Worker isolate
// ---------------------------------------------------------------------------

/// Maximum duration of a single native wait. Every slice returns control to
/// Dart code, whose loop back-edge is a VM interrupt point - this is what
/// keeps the isolate killable during hot restart.
const int _waitSliceMs = 250;

/// How long to wait for a connected client to actually send its message.
const int _readDeadlineMs = 15000;

/// Backoff before retrying after a pipe creation/connection failure.
const int _retryDelayMs = 2000;

enum _WorkerOutcome { continueLoop, retryAfterDelay, stop }

enum _DualWait { stop, signaled, timeout, failure }

void _pipeWorkerMain(List<Object?> args) {
  final sendPort = args[0] as SendPort;
  final stopEventAddress = args[1] as int;
  final stopEvent = HANDLE(Pointer.fromAddress(stopEventAddress));

  void log(String message) => sendPort.send(<Object?>['log', message]);

  try {
    while (true) {
      final outcome = _serveOneConnection(sendPort, stopEvent, log);
      if (outcome == _WorkerOutcome.stop) break;
      if (outcome == _WorkerOutcome.retryAfterDelay) {
        if (_waitForStop(stopEvent, _retryDelayMs)) break;
      }
    }
  } finally {
    sendPort.send(const <Object?>['stopped']);
  }
}

/// Creates one pipe instance, waits (interruptibly) for a client, reads a
/// single message and tears the instance down again.
_WorkerOutcome _serveOneConnection(
  SendPort sendPort,
  HANDLE stopEvent,
  void Function(String) log,
) {
  final pipeNamePtr = PipeListenerService.pipeName.toNativeUtf16();
  var pipe = HANDLE(Pointer.fromAddress(0));
  var ioEvent = HANDLE(Pointer.fromAddress(0));
  Pointer<OVERLAPPED> overlapped = nullptr;
  Pointer<Uint8> buffer = nullptr;
  Pointer<Uint32> transferred = nullptr;
  var connected = false;

  try {
    pipe = CreateNamedPipe(
      PCWSTR(pipeNamePtr),
      PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED,
      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
      PIPE_UNLIMITED_INSTANCES,
      PipeListenerService.bufferSize,
      PipeListenerService.bufferSize,
      0,
      null,
    );

    if (pipe.address == 0 || pipe.address == INVALID_HANDLE_VALUE.address) {
      log('Failed to create pipe (error ${GetLastError()})');
      return _WorkerOutcome.retryAfterDelay;
    }

    final eventResult = CreateEvent(null, true, false, null);
    ioEvent = eventResult.value;
    if (ioEvent.address == 0) {
      log('Failed to create I/O event (error ${eventResult.error})');
      return _WorkerOutcome.retryAfterDelay;
    }

    transferred = calloc<Uint32>();
    overlapped = calloc<OVERLAPPED>();
    overlapped.ref.hEvent = ioEvent;

    // --- Wait for a client (asynchronous connect) ---
    final connect = ConnectNamedPipe(pipe, overlapped);
    if (connect.value || connect.error == ERROR_PIPE_CONNECTED) {
      connected = true;
    } else if (connect.error == ERROR_IO_PENDING) {
      switch (_waitDual(stopEvent, ioEvent)) {
        case _DualWait.stop:
          _reapPendingIo(pipe, overlapped, transferred);
          return _WorkerOutcome.stop;
        case _DualWait.failure:
          _reapPendingIo(pipe, overlapped, transferred);
          log('Waiting for pipe connection failed');
          return _WorkerOutcome.retryAfterDelay;
        case _DualWait.timeout:
        case _DualWait.signaled:
          final done =
              GetOverlappedResult(pipe, overlapped, transferred, false);
          if (!done.value && done.error != ERROR_PIPE_CONNECTED) {
            log('Pipe connection failed (error ${done.error})');
            return _WorkerOutcome.continueLoop;
          }
          connected = true;
      }
    } else {
      log('ConnectNamedPipe failed (error ${connect.error})');
      return _WorkerOutcome.retryAfterDelay;
    }

    // --- Read a single message (asynchronous read with deadline) ---
    buffer = calloc<Uint8>(PipeListenerService.bufferSize);
    ResetEvent(ioEvent);

    var truncated = false;
    final read = ReadFile(
      pipe,
      buffer,
      PipeListenerService.bufferSize,
      null,
      overlapped,
    );
    if (!read.value) {
      if (read.error == ERROR_MORE_DATA) {
        truncated = true;
      } else if (read.error == ERROR_IO_PENDING) {
        switch (_waitDual(stopEvent, ioEvent, deadlineMs: _readDeadlineMs)) {
          case _DualWait.stop:
            _reapPendingIo(pipe, overlapped, transferred);
            return _WorkerOutcome.stop;
          case _DualWait.timeout:
            _reapPendingIo(pipe, overlapped, transferred);
            log('Client connected but sent no data within '
                '${_readDeadlineMs}ms, dropping connection');
            return _WorkerOutcome.continueLoop;
          case _DualWait.failure:
            _reapPendingIo(pipe, overlapped, transferred);
            log('Waiting for pipe read failed');
            return _WorkerOutcome.continueLoop;
          case _DualWait.signaled:
            break;
        }
      } else {
        log('ReadFile failed (error ${read.error})');
        return _WorkerOutcome.continueLoop;
      }
    }

    final readResult =
        GetOverlappedResult(pipe, overlapped, transferred, false);
    if (!readResult.value && readResult.error == ERROR_MORE_DATA) {
      truncated = true;
    }
    final count = transferred.value;
    if ((readResult.value || truncated) && count > 0) {
      final bytes = Uint8List.fromList(buffer.asTypedList(count));
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      if (truncated) {
        log('Warning: message exceeded ${PipeListenerService.bufferSize} '
            'bytes and was truncated');
      }
      if (text.isNotEmpty) {
        sendPort.send(<Object?>['data', text]);
      }
    }

    return _WorkerOutcome.continueLoop;
  } finally {
    if (connected && pipe.address != 0) {
      DisconnectNamedPipe(pipe);
    }
    if (pipe.address != 0 && pipe.address != INVALID_HANDLE_VALUE.address) {
      CloseHandle(pipe);
    }
    if (ioEvent.address != 0) {
      CloseHandle(ioEvent);
    }
    if (overlapped != nullptr) calloc.free(overlapped);
    if (buffer != nullptr) calloc.free(buffer);
    if (transferred != nullptr) calloc.free(transferred);
    free(pipeNamePtr);
  }
}

/// Cancels an in-flight overlapped operation and waits for it to be reaped so
/// the OVERLAPPED struct can be freed safely.
void _reapPendingIo(
  HANDLE pipe,
  Pointer<OVERLAPPED> overlapped,
  Pointer<Uint32> transferred,
) {
  CancelIoEx(pipe, overlapped);
  GetOverlappedResult(pipe, overlapped, transferred, true);
}

/// Waits for either the stop event (index 0) or the I/O event (index 1) in
/// short slices so the isolate remains interruptible.
_DualWait _waitDual(
  HANDLE stopEvent,
  HANDLE ioEvent, {
  int? deadlineMs,
}) {
  final handles = calloc<Pointer>(2);
  try {
    handles[0] = stopEvent;
    handles[1] = ioEvent;
    var elapsed = 0;
    while (true) {
      final wait = WaitForMultipleObjects(2, handles, false, _waitSliceMs);
      final signal = wait.value;
      if (signal == WAIT_OBJECT_0) return _DualWait.stop;
      if (signal == WAIT_OBJECT_0 + 1) return _DualWait.signaled;
      if (signal != WAIT_TIMEOUT) return _DualWait.failure;
      // Slice timed out: this loop back-edge is where the VM can interrupt
      // the isolate (hot restart / Isolate.kill).
      if (deadlineMs != null) {
        elapsed += _waitSliceMs;
        if (elapsed >= deadlineMs) return _DualWait.timeout;
      }
    }
  } finally {
    calloc.free(handles);
  }
}

/// Sleeps up to [totalMs] but wakes immediately when the stop event fires.
/// Returns true if stop was signaled.
bool _waitForStop(HANDLE stopEvent, int totalMs) {
  var remaining = totalMs;
  while (remaining > 0) {
    final slice = remaining < _waitSliceMs ? remaining : _waitSliceMs;
    final wait = WaitForSingleObject(stopEvent, slice);
    if (wait.value == WAIT_OBJECT_0) return true;
    if (wait.value != WAIT_TIMEOUT) return false;
    remaining -= slice;
  }
  return false;
}
