import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../kernel_interface.dart';

class NeoNsfTaskStorage {
  NeoNsfTaskStorage({String? homePath}) : _homePath = homePath;

  final String? _homePath;
  Future<void> _writeQueue = Future<void>.value();
  Future<void>? _initialization;
  late final Directory directory;
  late final File _tasksFile;
  final Map<String, Map<String, String>> _requestHeaders =
      <String, Map<String, String>>{};
  final Map<String, Map<String, String>> _resumeValidators =
      <String, Map<String, String>>{};

  Map<String, String> requestHeadersFor(String taskId) =>
      Map<String, String>.unmodifiable(
        _requestHeaders[taskId] ?? const <String, String>{},
      );

  Map<String, String> resumeValidatorsFor(String taskId) =>
      Map<String, String>.unmodifiable(
        _resumeValidators[taskId] ?? const <String, String>{},
      );

  Future<void> init() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final home = _homePath ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    directory = Directory(path.join(home, '.hdmx', 'kernel', 'neo_nsf'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    _tasksFile = File(path.join(directory.path, 'tasks.json'));
  }

  Future<Map<String, DownloadTask>> loadTasks() async {
    await init();
    // A crash during a save can leave the payload only in the temporary file, so
    // fall back to it before concluding there is nothing to restore.
    for (final candidate in <File>[
      _tasksFile,
      File('${_tasksFile.path}.tmp'),
    ]) {
      if (!await candidate.exists()) continue;
      final tasks = await _readTasks(candidate);
      if (tasks != null) return tasks;
    }
    return <String, DownloadTask>{};
  }

  Future<Map<String, DownloadTask>?> _readTasks(File source) async {
    try {
      final decoded = jsonDecode(await source.readAsString());
      if (decoded is! Map) return null;
      final tasks = <String, DownloadTask>{};
      _requestHeaders.clear();
      _resumeValidators.clear();
      for (final entry in decoded.entries) {
        if (entry.value is! Map) continue;
        final stored = Map<String, dynamic>.from(entry.value as Map);
        final task = DownloadTask.fromJson(
          stored,
        );
        if (task.id.isEmpty) continue;
        final rawHeaders = stored['_requestHeaders'];
        if (rawHeaders is Map) {
          _requestHeaders[task.id] = <String, String>{
            for (final header in rawHeaders.entries)
              header.key.toString(): header.value.toString(),
          };
        }
        final rawValidators = stored['_resumeValidators'];
        if (rawValidators is Map) {
          _resumeValidators[task.id] = <String, String>{
            for (final validator in rawValidators.entries)
              validator.key.toString(): validator.value.toString(),
          };
        }
        if (task.status == DownloadStatus.downloading ||
            task.status == DownloadStatus.pending ||
            task.status == DownloadStatus.merging) {
          task.status = DownloadStatus.paused;
          task.speed = 0;
          task.eta = 0;
        }
        tasks[entry.key.toString()] = task;
      }
      return tasks;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveTasks(
    Map<String, DownloadTask> tasks, {
    Map<String, Map<String, String>> requestHeaders =
        const <String, Map<String, String>>{},
    Map<String, Map<String, String>> resumeValidators =
        const <String, Map<String, String>>{},
  }) {
    final snapshot = <String, dynamic>{
      for (final entry in tasks.entries)
        entry.key: <String, dynamic>{
          ...entry.value.toJson(),
          if (requestHeaders[entry.key]?.isNotEmpty ?? false)
            '_requestHeaders': requestHeaders[entry.key],
          if (resumeValidators[entry.key]?.isNotEmpty ?? false)
            '_resumeValidators': resumeValidators[entry.key],
        },
    };
    final operation = _writeQueue.then((_) async {
      await init();
      final temporary = File('${_tasksFile.path}.tmp');
      await temporary.writeAsString(jsonEncode(snapshot), flush: true);
      // File.rename maps to MoveFileEx with MOVEFILE_REPLACE_EXISTING on Windows and
      // to rename(2) elsewhere, so it replaces atomically. Deleting the target first
      // (as this used to) opened a window where a crash lost every task.
      await temporary.rename(_tasksFile.path);
    });
    _writeQueue = operation.catchError((_) {});
    return operation;
  }

  Future<void> clear() async {
    await init();
    if (await _tasksFile.exists()) {
      await _tasksFile.delete();
    }
    final temporary = File('${_tasksFile.path}.tmp');
    if (await temporary.exists()) {
      await temporary.delete();
    }
    _requestHeaders.clear();
    _resumeValidators.clear();
  }
}
