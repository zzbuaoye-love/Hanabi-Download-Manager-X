import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../models/download_intent.dart';
import '../models/download_task.dart';
import '../models/plugin_manifest.dart';
import 'app_logger_service.dart';
import 'plugin_lifecycle_service.dart';
import 'plugin_process_runner.dart';

class PluginTaskRecord {
  const PluginTaskRecord({
    required this.id,
    required this.pluginId,
    required this.url,
    required this.fileName,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.saveDir,
    this.filePath,
    this.error,
    this.totalSize,
    this.downloadedSize,
    this.speed,
    this.progress = 0,
    this.pluginData = const <String, dynamic>{},
    this.statusDetail,
    this.peerCount,
    this.seederCount,
    this.uploadSpeed,
  });

  final String id;
  final String pluginId;
  final String url;
  final String fileName;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? saveDir;
  final String? filePath;
  final String? error;
  final int? totalSize;
  final int? downloadedSize;
  final double? speed;
  final double progress;
  final Map<String, dynamic> pluginData;
  final String? statusDetail;
  final int? peerCount;
  final int? seederCount;
  final double? uploadSpeed;

  factory PluginTaskRecord.fromJson(Map<String, dynamic> json) {
    final pluginDataRaw = json['pluginData'];
    return PluginTaskRecord(
      id: json['id']?.toString() ?? '',
      pluginId: json['pluginId']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      fileName: json['fileName']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
      saveDir: json['saveDir']?.toString(),
      filePath: json['filePath']?.toString(),
      error: json['error']?.toString(),
      totalSize: (json['totalSize'] as num?)?.toInt(),
      downloadedSize: (json['downloadedSize'] as num?)?.toInt(),
      speed: (json['speed'] as num?)?.toDouble(),
      progress: _normalizeProgress(json['progress']),
      pluginData: pluginDataRaw is Map
          ? pluginDataRaw.map((key, value) => MapEntry(key.toString(), value))
          : const <String, dynamic>{},
      statusDetail: json['statusDetail']?.toString(),
      peerCount: (json['peerCount'] as num?)?.toInt(),
      seederCount: (json['seederCount'] as num?)?.toInt(),
      uploadSpeed: (json['uploadSpeed'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'pluginId': pluginId,
        'url': url,
        'fileName': fileName,
        'status': status,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (saveDir != null && saveDir!.isNotEmpty) 'saveDir': saveDir,
        if (filePath != null && filePath!.isNotEmpty) 'filePath': filePath,
        if (error != null && error!.isNotEmpty) 'error': error,
        if (totalSize != null) 'totalSize': totalSize,
        if (downloadedSize != null) 'downloadedSize': downloadedSize,
        if (speed != null) 'speed': speed,
        'progress': progress,
        if (pluginData.isNotEmpty) 'pluginData': pluginData,
        if (statusDetail != null && statusDetail!.isNotEmpty)
          'statusDetail': statusDetail,
        if (peerCount != null) 'peerCount': peerCount,
        if (seederCount != null) 'seederCount': seederCount,
        if (uploadSpeed != null) 'uploadSpeed': uploadSpeed,
      };

  Map<String, dynamic> toPluginJson() => {
        'taskId': id,
        'pluginId': pluginId,
        'url': url,
        'fileName': fileName,
        if (saveDir != null && saveDir!.isNotEmpty) 'saveDir': saveDir,
        if (filePath != null && filePath!.isNotEmpty) 'filePath': filePath,
        'pluginData': pluginData,
      };

  PluginTaskRecord mergePluginResult(Map<String, dynamic> result) {
    final pluginDataRaw = result['pluginData'] ?? result['plugin_data'];
    final nextPluginData = <String, dynamic>{...pluginData};
    if (pluginDataRaw is Map) {
      nextPluginData.addAll(
        pluginDataRaw.map((key, value) => MapEntry(key.toString(), value)),
      );
    }

    final nextTotalSize = _firstInt(result, ['totalSize', 'total_size']);
    final nextDownloadedSize =
        _firstInt(result, ['downloadedSize', 'downloaded_size']);
    return copyWith(
      status: result['status']?.toString(),
      filePath:
          result['filePath']?.toString() ?? result['file_path']?.toString(),
      error: result['error']?.toString(),
      totalSize: nextTotalSize,
      downloadedSize: nextDownloadedSize,
      speed: _firstDouble(result, ['speed', 'downloadSpeed', 'download_speed']),
      progress: result.containsKey('progress')
          ? _normalizeProgress(result['progress'])
          : _progressFromSizes(nextDownloadedSize, nextTotalSize) ?? progress,
      pluginData: nextPluginData,
      updatedAt: DateTime.now(),
      statusDetail:
          result['statusDetail']?.toString() ?? result['detail']?.toString(),
      peerCount: _firstInt(result, ['peerCount', 'peer_count', 'peers']),
      seederCount: _firstInt(result, ['seeders', 'seederCount', 'sources']),
      uploadSpeed: _firstDouble(result, ['uploadSpeed', 'upload_speed']),
    );
  }

  PluginTaskRecord copyWith({
    String? status,
    DateTime? updatedAt,
    String? saveDir,
    String? filePath,
    String? error,
    int? totalSize,
    int? downloadedSize,
    double? speed,
    double? progress,
    Map<String, dynamic>? pluginData,
    String? statusDetail,
    int? peerCount,
    int? seederCount,
    double? uploadSpeed,
  }) {
    return PluginTaskRecord(
      id: id,
      pluginId: pluginId,
      url: url,
      fileName: fileName,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      saveDir: saveDir ?? this.saveDir,
      filePath: filePath ?? this.filePath,
      error: error ?? this.error,
      totalSize: totalSize ?? this.totalSize,
      downloadedSize: downloadedSize ?? this.downloadedSize,
      speed: speed ?? this.speed,
      progress: progress ?? this.progress,
      pluginData: Map.unmodifiable(pluginData ?? this.pluginData),
      statusDetail: statusDetail ?? this.statusDetail,
      peerCount: peerCount ?? this.peerCount,
      seederCount: seederCount ?? this.seederCount,
      uploadSpeed: uploadSpeed ?? this.uploadSpeed,
    );
  }

  DownloadTask toDownloadTask() {
    return DownloadTask(
      id: id,
      url: url,
      fileName: fileName,
      status: _downloadStatus(status),
      progress: progress.clamp(0.0, 1.0),
      filePath: filePath ?? saveDir,
      error: error,
      fileSize: totalSize,
      downloadedSize: downloadedSize,
      speed: speed,
      downloadCore: 'Plugin: $pluginId',
      createdAt: createdAt,
      statusDetail: statusDetail,
      peerCount: peerCount,
      seederCount: seederCount,
      uploadSpeed: uploadSpeed,
    );
  }

  bool get isActive {
    final normalized = status.toLowerCase();
    return normalized != 'completed' &&
        normalized != 'complete' &&
        normalized != 'failed' &&
        normalized != 'error' &&
        normalized != 'removed';
  }

  static DownloadStatus _downloadStatus(String status) {
    switch (status.toLowerCase()) {
      case 'active':
      case 'downloading':
      case 'seeding':
        return DownloadStatus.downloading;
      case 'paused':
      case 'stopped':
        return DownloadStatus.paused;
      case 'complete':
      case 'completed':
        return DownloadStatus.completed;
      case 'checking':
      case 'verifying':
      case 'merging':
        return DownloadStatus.merging;
      case 'failed':
      case 'error':
      case 'removed':
        return DownloadStatus.failed;
      case 'waiting':
      case 'pending':
      default:
        return DownloadStatus.pending;
    }
  }

  static double _normalizeProgress(Object? value) {
    final number = value is num ? value.toDouble() : double.tryParse('$value');
    if (number == null || number.isNaN || number.isInfinite) {
      return 0;
    }
    if (number > 1) {
      return (number / 100).clamp(0.0, 1.0);
    }
    return number.clamp(0.0, 1.0);
  }

  static int? _firstInt(Map<String, dynamic> result, List<String> keys) {
    for (final key in keys) {
      final value = result[key];
      if (value is num) {
        return value.toInt();
      }
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null) {
        return parsed;
      }
    }
    return null;
  }

  static double? _firstDouble(Map<String, dynamic> result, List<String> keys) {
    for (final key in keys) {
      final value = result[key];
      if (value is num) {
        return value.toDouble();
      }
      final parsed = double.tryParse(value?.toString() ?? '');
      if (parsed != null) {
        return parsed;
      }
    }
    return null;
  }

  static double? _progressFromSizes(int? downloaded, int? total) {
    if (downloaded == null || total == null || total <= 0) {
      return null;
    }
    return (downloaded / total).clamp(0.0, 1.0);
  }
}

class PluginTaskService extends ChangeNotifier {
  static final PluginTaskService _instance = PluginTaskService._internal();

  factory PluginTaskService() => _instance;

  PluginTaskService._internal();

  final PluginLifecycleService _pluginService = PluginLifecycleService();
  final PluginProcessRunner _runner = PluginProcessRunner();
  final AppLoggerService _logger = AppLoggerService();
  final Map<String, PluginTaskRecord> _records = <String, PluginTaskRecord>{};

  late String _tasksPath;
  bool _initialized = false;
  Future<List<PluginTaskRecord>>? _refreshInFlight;

  List<PluginTaskRecord> get records => List.unmodifiable(_records.values);

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    await _pluginService.ensureInitialized();
    _tasksPath = path.join(_pluginService.pluginsRootDir, 'plugin_tasks.json');
    await _load();
    _initialized = true;
  }

  Future<void> ensureInitialized() async {
    if (!_initialized) {
      await initialize();
    }
  }

  bool hasTask(String id) => _records.containsKey(id);

  Future<PluginTaskRecord> registerTask({
    required String pluginId,
    required String taskId,
    required DownloadIntent intent,
    required String fileName,
    String? saveDir,
    Map<String, dynamic> pluginResult = const <String, dynamic>{},
  }) async {
    await ensureInitialized();
    final now = DateTime.now();
    final initial = PluginTaskRecord(
      id: taskId,
      pluginId: pluginId,
      url: intent.normalizedValue,
      fileName: fileName,
      status: 'pending',
      createdAt: now,
      updatedAt: now,
      saveDir: saveDir,
    ).mergePluginResult(pluginResult);
    _records[taskId] = initial;
    _resetBackoff(taskId);
    await _save();
    notifyListeners();
    return initial;
  }

  /// 每次状态查询都要启动一个插件进程，串行执行时任务越多刷新越慢。
  static const int _statusConcurrency = 4;
  static const Duration _statusTimeout = Duration(seconds: 25);

  /// 没有进展的任务按指数退避降低查询频率。
  ///
  /// P2P 任务停在「等待中」是常态，可能持续几十分钟。按 2 秒的轮询节奏
  /// 一直启动 Python 进程，只会让 CPU 和磁盘持续忙碌而拿不到任何新信息。
  static const Duration _minIdleBackoff = Duration(seconds: 4);
  static const Duration _maxIdleBackoff = Duration(seconds: 30);

  final Map<String, DateTime> _nextPollAt = <String, DateTime>{};
  final Map<String, int> _idleRounds = <String, int>{};

  /// 用户操作或任务重建后立刻恢复正常轮询节奏。
  void _resetBackoff(String id) {
    _nextPollAt.remove(id);
    _idleRounds.remove(id);
  }

  void _backOff(String id) {
    final rounds = (_idleRounds[id] ?? 0) + 1;
    _idleRounds[id] = rounds;
    var delay = _minIdleBackoff * (1 << (rounds - 1).clamp(0, 8));
    if (delay > _maxIdleBackoff) {
      delay = _maxIdleBackoff;
    }
    _nextPollAt[id] = DateTime.now().add(delay);
  }

  static bool _hasMeaningfulChange(
    PluginTaskRecord before,
    PluginTaskRecord after,
  ) {
    return before.status != after.status ||
        before.downloadedSize != after.downloadedSize ||
        before.totalSize != after.totalSize ||
        (before.progress - after.progress).abs() > 0.0001 ||
        before.error != after.error ||
        before.statusDetail != after.statusDetail ||
        before.peerCount != after.peerCount ||
        before.seederCount != after.seederCount ||
        before.uploadSpeed != after.uploadSpeed ||
        !mapEquals(before.pluginData, after.pluginData);
  }

  Future<List<PluginTaskRecord>> refreshActiveTasks() {
    final existing = _refreshInFlight;
    if (existing != null) {
      return existing;
    }

    late final Future<List<PluginTaskRecord>> tracked;
    tracked = _refreshActiveTasksOnce().whenComplete(() {
      if (identical(_refreshInFlight, tracked)) {
        _refreshInFlight = null;
      }
    });
    _refreshInFlight = tracked;
    return tracked;
  }

  Future<List<PluginTaskRecord>> _refreshActiveTasksOnce() async {
    await ensureInitialized();
    var changed = false;
    final now = DateTime.now();
    final pending = <(PluginTaskRecord, InstalledPlugin)>[];

    for (final record in _records.values.toList(growable: false)) {
      if (!record.isActive) {
        _resetBackoff(record.id);
        continue;
      }
      final plugin = _pluginService.getPlugin(record.pluginId);
      if (plugin == null || !plugin.enabled) {
        _records[record.id] = record.copyWith(
          status: 'failed',
          error: 'Plugin ${record.pluginId} is not enabled',
          updatedAt: DateTime.now(),
        );
        changed = true;
        continue;
      }
      final nextPollAt = _nextPollAt[record.id];
      if (nextPollAt != null && now.isBefore(nextPollAt)) {
        continue;
      }
      pending.add((record, plugin));
    }

    for (var start = 0; start < pending.length; start += _statusConcurrency) {
      final batch = pending.skip(start).take(_statusConcurrency);
      final results = await Future.wait(
        batch.map((entry) async {
          final (record, plugin) = entry;
          return (
            record,
            await _runner.invoke(
              plugin,
              method: 'hanabi.download.status',
              params: record.toPluginJson(),
              timeout: _statusTimeout,
            ),
          );
        }),
      );

      for (final (record, result) in results) {
        if (!result.success) {
          _logger.warning(
            'PluginTask',
            'Plugin task status failed: ${record.id}: ${result.error}',
          );
          // 后端不可用时更要退避，否则每 2 秒重试一次失败的进程启动。
          _backOff(record.id);
          continue;
        }
        // 记录可能在等待期间被移除
        if (!_records.containsKey(record.id)) {
          continue;
        }
        if (result.result is Map) {
          final updated = record.mergePluginResult(
            (result.result as Map).map(
              (key, value) => MapEntry(key.toString(), value),
            ),
          );
          _records[record.id] = updated;
          changed = true;
          if (_hasMeaningfulChange(record, updated)) {
            _resetBackoff(record.id);
          } else {
            _backOff(record.id);
          }
        }
      }
    }

    if (changed) {
      _scheduleSave();
      notifyListeners();
    }
    return records;
  }

  Future<bool> pauseTask(String id) => _callTaskMethod(id, 'pause');

  Future<bool> resumeTask(String id) => _callTaskMethod(id, 'resume');

  Future<bool> removeTask(String id) async {
    final called = await _callTaskMethod(id, 'remove', keepRecord: false);
    _records.remove(id);
    _resetBackoff(id);
    await _save();
    notifyListeners();
    return called;
  }

  Future<bool> _callTaskMethod(
    String id,
    String action, {
    bool keepRecord = true,
  }) async {
    await ensureInitialized();
    final record = _records[id];
    if (record == null) {
      return false;
    }
    final plugin = _pluginService.getPlugin(record.pluginId);
    if (plugin == null || !plugin.enabled) {
      return false;
    }

    final result = await _runner.invoke(
      plugin,
      method: 'hanabi.download.$action',
      params: record.toPluginJson(),
      timeout: const Duration(seconds: 15),
    );
    if (!result.success) {
      _logger.warning(
        'PluginTask',
        'Plugin task $action failed: $id: ${result.error}',
      );
      return false;
    }
    if (keepRecord && result.result is Map) {
      _records[id] = record.mergePluginResult(
        (result.result as Map).map(
          (key, value) => MapEntry(key.toString(), value),
        ),
      );
      // 暂停/继续之后用户在等界面反馈，恢复正常轮询节奏。
      _resetBackoff(id);
      await _save();
      notifyListeners();
    }
    return true;
  }

  Future<void> _load() async {
    _records.clear();
    final file = File(_tasksPath);
    final backup = File('$_tasksPath.backup');
    try {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
        _logger.warning(
          'PluginTask',
          'Recovered plugin tasks after an interrupted save',
        );
      }
    } catch (e) {
      _logger.warning('PluginTask', 'Could not recover task backup: $e');
    }
    if (!await file.exists()) {
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      final tasks = decoded is Map ? decoded['tasks'] : null;
      if (tasks is List) {
        for (final task in tasks.whereType<Map>()) {
          final record = PluginTaskRecord.fromJson(
            task.map((key, value) => MapEntry(key.toString(), value)),
          );
          if (record.id.isNotEmpty) {
            _records[record.id] = record;
          }
        }
      }
    } catch (e) {
      _logger.warning('PluginTask', 'Failed to load plugin tasks: $e');
    }
  }

  /// 轮询期间速度和来源数每次都在变，逐次落盘意味着每 2 秒重写一次
  /// 整个任务文件。这里合并成固定节奏的一次写入。
  static const Duration _saveDebounce = Duration(seconds: 5);
  Timer? _saveTimer;
  Future<void> _saveTail = Future<void>.value();

  void _scheduleSave() {
    _saveTimer ??= Timer(_saveDebounce, () {
      _saveTimer = null;
      unawaited(
        _save().catchError((Object error, StackTrace stackTrace) {
          _logger.error(
            'PluginTask',
            'Debounced plugin task save failed: $error',
          );
        }),
      );
    });
  }

  Future<void> _save() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final snapshot = const JsonEncoder.withIndent('  ').convert({
      'updatedAt': DateTime.now().toIso8601String(),
      'tasks': _records.values.map((record) => record.toJson()).toList(),
    });

    // Every writer joins one chain. This prevents a slow older snapshot from
    // truncating or overwriting a newer one.
    final write = _saveTail.then((_) => _writeSnapshot(snapshot));
    _saveTail = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _logger.error('PluginTask', 'Plugin task save failed: $error');
      },
    );
    return write;
  }

  Future<void> _writeSnapshot(String snapshot) async {
    final target = File(_tasksPath);
    final staged = File('$_tasksPath.tmp');
    final backup = File('$_tasksPath.backup');
    await target.parent.create(recursive: true);

    if (await staged.exists()) {
      await staged.delete();
    }
    await staged.writeAsString(snapshot, flush: true);

    var previousMoved = false;
    try {
      if (await backup.exists()) {
        await backup.delete();
      }
      if (await target.exists()) {
        await target.rename(backup.path);
        previousMoved = true;
      }
      await staged.rename(target.path);
      if (previousMoved && await backup.exists()) {
        try {
          await backup.delete();
        } catch (e) {
          _logger.warning(
            'PluginTask',
            'Could not remove old task backup: $e',
          );
        }
      }
    } catch (_) {
      if (previousMoved && await backup.exists()) {
        try {
          if (await target.exists()) {
            await target.delete();
          }
          await backup.rename(target.path);
        } catch (rollbackError) {
          _logger.error(
            'PluginTask',
            'Plugin task rollback failed: $rollbackError',
          );
        }
      }
      rethrow;
    } finally {
      try {
        if (await staged.exists()) {
          await staged.delete();
        }
      } catch (_) {
        // A stale temp file is harmless and will be replaced by the next save.
      }
    }
  }

  /// Persists a pending debounced update and waits for earlier writes.
  Future<void> flush() async {
    final hasPendingDebounce = _saveTimer != null;
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_initialized) {
      return;
    }
    if (hasPendingDebounce) {
      await _save();
    } else {
      await _saveTail;
    }
  }

  @override
  void dispose() {
    unawaited(flush());
    super.dispose();
  }
}
