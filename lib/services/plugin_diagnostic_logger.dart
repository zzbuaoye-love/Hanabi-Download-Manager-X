import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 插件诊断日志。
///
/// 这里的写入发生在 UI isolate 上：早期实现每条事件都做两次
/// `writeAsStringSync(flush: true)`，而每次插件调用会产生 5 条事件，
/// 也就是每 2 秒轮询一次就有 10 次同步刷盘。BT / ED2K 任务停在「等待中」
/// 时会一直轮询，界面因此持续掉帧。现在改为内存缓冲 + 异步批量落盘，
/// 并把高频的单次调用事件降级为 trace（默认不记录）。
class PluginDiagnosticLogger {
  static final PluginDiagnosticLogger _instance =
      PluginDiagnosticLogger._internal();

  factory PluginDiagnosticLogger() => _instance;

  PluginDiagnosticLogger._internal();

  static const int _maxStringLength = 600;

  /// 缓冲到这个条数就立即落盘，避免长时间批量堆积内存。
  static const int _maxBufferedLines = 256;
  static const Duration _flushInterval = Duration(milliseconds: 500);
  static const int _maxLogBytes = 4 * 1024 * 1024;

  final List<String> _buffer = <String>[];
  Map<String, Object?>? _pendingLastEvent;
  Timer? _flushTimer;
  Future<void>? _flushing;
  bool _verbose = false;
  File? _logFile;
  File? _lastEventFile;

  /// 高频事件（单次插件调用的生命周期）只在开发者模式下记录。
  bool get verbose => _verbose;

  set verbose(bool value) {
    if (_verbose == value) {
      return;
    }
    _verbose = value;
    mark('diagnostics.verbose', data: <String, Object?>{'enabled': value});
  }

  /// 低频事件：安装、扫描、设置、失败。始终记录。
  void mark(
    String event, {
    String? pluginId,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    final payload = <String, Object?>{
      'time': DateTime.now().toIso8601String(),
      'pid': pid,
      'event': event,
      if (pluginId != null) 'pluginId': pluginId,
      if (data.isNotEmpty) 'data': _sanitize(data),
    };

    _buffer.add(_formatLine(payload));
    _pendingLastEvent = payload;
    if (_buffer.length >= _maxBufferedLines) {
      unawaited(flush());
      return;
    }
    _flushTimer ??= Timer(_flushInterval, () => unawaited(flush()));
  }

  /// 高频事件：轮询期间每次插件调用都会产生若干条，默认丢弃。
  void trace(
    String event, {
    String? pluginId,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    if (!_verbose) {
      return;
    }
    mark(event, pluginId: pluginId, data: data);
  }

  void error(
    String event,
    Object error, {
    String? pluginId,
    StackTrace? stackTrace,
    Map<String, Object?> data = const <String, Object?>{},
  }) {
    mark(
      event,
      pluginId: pluginId,
      data: <String, Object?>{
        ...data,
        'error': error.toString(),
        if (stackTrace != null) 'stackTrace': stackTrace.toString(),
      },
    );
    // 失败信息值得立刻落盘，崩溃时才不会丢。
    unawaited(flush());
  }

  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    // 串行化：并发 flush 会让追加写交错。
    final previous = _flushing;
    final next = previous == null
        ? _flushInternal()
        : previous.then((_) => _flushInternal());
    _flushing = next;
    return next;
  }

  Future<void> _flushInternal() async {
    if (_buffer.isEmpty) {
      return;
    }
    final chunk = _buffer.join('\n');
    final lastEvent = _pendingLastEvent;
    _buffer.clear();
    _pendingLastEvent = null;

    try {
      final logFile = await _ensureLogFile();
      await _rotateIfOversized(logFile);
      await logFile.writeAsString('$chunk\n', mode: FileMode.append);
      if (lastEvent != null) {
        await (await _ensureLastEventFile()).writeAsString(
          const JsonEncoder.withIndent('  ').convert(lastEvent),
        );
      }
    } catch (_) {
      // Diagnostics must never crash the app.
    }
  }

  Future<void> _rotateIfOversized(File file) async {
    try {
      if (await file.length() < _maxLogBytes) {
        return;
      }
      final rotated = File('${file.path}.1');
      if (await rotated.exists()) {
        await rotated.delete();
      }
      await file.rename(rotated.path);
      _logFile = null;
      await _ensureLogFile();
    } catch (_) {
      // 轮转失败时继续追加，总比丢日志好。
    }
  }

  Future<File> _ensureLogFile() async {
    final existing = _logFile;
    if (existing != null) {
      return existing;
    }
    final file =
        File('${(await _ensureLogDirectory()).path}\\plugin_diagnostics.log');
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    _logFile = file;
    return file;
  }

  Future<File> _ensureLastEventFile() async {
    final existing = _lastEventFile;
    if (existing != null) {
      return existing;
    }
    final file =
        File('${(await _ensureLogDirectory()).path}\\plugin_last_event.json');
    _lastEventFile = file;
    return file;
  }

  Future<Directory> _ensureLogDirectory() async {
    final userProfile = Platform.environment['USERPROFILE'];
    final basePath = userProfile == null || userProfile.trim().isEmpty
        ? Directory.systemTemp.path
        : '$userProfile\\Documents';
    final directory = Directory('$basePath\\HanabiDownloadManagerX\\logs');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  String _formatLine(Map<String, Object?> payload) {
    final data = payload['data'];
    final buffer = StringBuffer()
      ..write('[')
      ..write(payload['time'])
      ..write('] [pid=')
      ..write(payload['pid'])
      ..write('] ')
      ..write(payload['event']);
    final pluginId = payload['pluginId'];
    if (pluginId != null) {
      buffer
        ..write(' plugin=')
        ..write(pluginId);
    }
    if (data != null) {
      buffer
        ..write(' data=')
        ..write(jsonEncode(data));
    }
    return buffer.toString();
  }

  Object? _sanitize(Object? value) {
    if (value == null || value is num || value is bool || value is DateTime) {
      return value is DateTime ? value.toIso8601String() : value;
    }
    if (value is FileSystemEntity) {
      return value.path;
    }
    if (value is String) {
      if (value.length <= _maxStringLength) {
        return value;
      }
      return '${value.substring(0, _maxStringLength)}...';
    }
    if (value is Iterable) {
      return value.map(_sanitize).toList(growable: false);
    }
    if (value is Map) {
      return value.map<String, Object?>(
        (key, mapValue) => MapEntry(key.toString(), _sanitize(mapValue)),
      );
    }
    return value.toString();
  }
}
