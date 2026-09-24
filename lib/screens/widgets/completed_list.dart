import 'dart:io';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../services/integrated_download_service.dart';
import '../../services/client_config_service.dart';
import '../../services/performance_monitor_service.dart';
import '../../models/download_task.dart';
import '../../theme/app_theme.dart';
import '../../widgets/file_icon_widget.dart';
import '../../widgets/animated_card.dart';
import '../../widgets/fluent_interactions.dart';
import '../../widgets/scroll_edge_fade.dart';
import '../../widgets/smooth_scroll_wrapper.dart';
import '../../utils/fluent_icons.dart' as CustomIcons;
import '../../widgets/animated_notifications.dart';
import '../../widgets/folder_picker_dialog.dart';

// 自定义分类
class CustomCategory {
  final String name;
  final List<String> extensions;

  CustomCategory({
    required this.name,
    required this.extensions,
  });

  bool matches(String fileName) {
    final ext = fileName.toLowerCase().substring(fileName.lastIndexOf('.'));
    return extensions.contains(ext);
  }
}

// 文件类型枚举
enum FileCategory {
  all,
  video,
  audio,
  archive,
  document,
  program,
  other;

  String label(AppLocalizations t) {
    switch (this) {
      case FileCategory.all:
        return t.completedCategoryAll;
      case FileCategory.video:
        return t.completedCategoryVideo;
      case FileCategory.audio:
        return t.completedCategoryAudio;
      case FileCategory.archive:
        return t.completedCategoryArchive;
      case FileCategory.document:
        return t.completedCategoryDocument;
      case FileCategory.program:
        return t.completedCategoryProgram;
      case FileCategory.other:
        return t.completedCategoryOther;
    }
  }

  IconData get icon {
    switch (this) {
      case FileCategory.all:
        return CustomIcons.FluentIcons.folder;
      case FileCategory.video:
        return CustomIcons.FluentIcons.video;
      case FileCategory.audio:
        return CustomIcons.FluentIcons.music_note;
      case FileCategory.archive:
        return CustomIcons.FluentIcons.archive;
      case FileCategory.document:
        return CustomIcons.FluentIcons.document;
      case FileCategory.program:
        return CustomIcons.FluentIcons.app_icon_default;
      case FileCategory.other:
        return CustomIcons.FluentIcons.more;
    }
  }

  List<String> get extensions {
    switch (this) {
      case FileCategory.all:
        return [];
      case FileCategory.video:
        return [
          '.mp4',
          '.avi',
          '.mkv',
          '.mov',
          '.wmv',
          '.flv',
          '.webm',
          '.m4v',
          '.mpg',
          '.mpeg'
        ];
      case FileCategory.audio:
        return [
          '.mp3',
          '.wav',
          '.flac',
          '.aac',
          '.ogg',
          '.wma',
          '.m4a',
          '.ape'
        ];
      case FileCategory.archive:
        return ['.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.iso'];
      case FileCategory.document:
        return [
          '.pdf',
          '.doc',
          '.docx',
          '.xls',
          '.xlsx',
          '.ppt',
          '.pptx',
          '.txt',
          '.md',
          '.rtf'
        ];
      case FileCategory.program:
        return ['.exe', '.msi', '.apk', '.dmg', '.deb', '.rpm', '.appimage'];
      case FileCategory.other:
        return [];
    }
  }

  static FileCategory fromFileName(String fileName) {
    final dotIndex = fileName.lastIndexOf('.');

    // 如果没有扩展名或扩展名在开头，返回 other
    if (dotIndex == -1 || dotIndex == 0 || dotIndex == fileName.length - 1) {
      return FileCategory.other;
    }

    final ext = fileName.toLowerCase().substring(dotIndex);

    for (final category in FileCategory.values) {
      if (category == FileCategory.all || category == FileCategory.other) {
        continue;
      }
      if (category.extensions.contains(ext)) {
        return category;
      }
    }

    return FileCategory.other;
  }
}

class CompletedList extends StatefulWidget {
  const CompletedList({super.key});

  @override
  State<CompletedList> createState() => _CompletedListState();
}

class _CompletedListState extends State<CompletedList> {
  int _currentTabIndex = 0;
  List<CustomCategory> _customCategories = [];
  bool _showSearch = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  AppLocalizations get t => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    _loadCustomCategories();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadCustomCategories() {
    final configService = context.read<ClientConfigService>();
    final categoriesData = configService.getCustomCategories();
    _customCategories = categoriesData.map((data) {
      return CustomCategory(
        name: data['name'] as String,
        extensions: (data['extensions'] as List).cast<String>(),
      );
    }).toList();
    // 只在 widget 已经构建过后才 setState
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    // 追踪重建
    PerformanceMonitorService().trackRebuild('CompletedList');

    return ColoredBox(
      color: Colors.transparent,
      // 优化：使用 Selector 只监听已完成任务，避免下载中任务进度更新触发重建
      child: Selector<IntegratedDownloadService,
          ({List<DownloadTask> completedTasks, bool hasLoaded})>(
        selector: (_, service) => (
          completedTasks: service.tasks
              .where((t) => t.status == DownloadStatus.completed)
              .toList(),
          hasLoaded: service.hasLoadedOnce,
        ),
        shouldRebuild: (previous, next) {
          if (previous.hasLoaded != next.hasLoaded) return true;
          final previousTasks = previous.completedTasks;
          final nextTasks = next.completedTasks;

          if (previousTasks.length != nextTasks.length) return true;
          for (int i = 0; i < previousTasks.length; i++) {
            if (previousTasks[i].id != nextTasks[i].id) return true;
          }
          return false;
        },
        builder: (context, snapshot, child) {
          final completedTasks = snapshot.completedTasks;
          final hasLoaded = snapshot.hasLoaded;

          // 按完成时间排序，最新的在前面
          completedTasks.sort((a, b) {
            if (a.endTime == null && b.endTime == null) return 0;
            if (a.endTime == null) return 1;
            if (b.endTime == null) return -1;
            return b.endTime!.compareTo(a.endTime!);
          });

          if (completedTasks.isEmpty) {
            if (!hasLoaded) {
              return _buildLoadingState(context);
            }
            return _buildEmptyState(context);
          }

          // 按预定义类型分组
          final tasksByCategory = <FileCategory, List<DownloadTask>>{};
          for (final task in completedTasks) {
            final category = FileCategory.fromFileName(task.fileName);
            tasksByCategory.putIfAbsent(category, () => []).add(task);
          }

          // 按自定义类型分组
          final customTasksByIndex = <int, List<DownloadTask>>{};
          for (var i = 0; i < _customCategories.length; i++) {
            final category = _customCategories[i];
            final tasks = completedTasks
                .where((task) => category.matches(task.fileName))
                .toList();
            if (tasks.isNotEmpty) {
              customTasksByIndex[i] = tasks;
            }
          }

          // 构建标签列表（只包含有文件的分类）
          final tabs = <FileCategory>[FileCategory.all];
          for (final category in FileCategory.values) {
            if (category != FileCategory.all &&
                tasksByCategory.containsKey(category)) {
              tabs.add(category);
            }
          }

          // 确保当前索引有效
          final totalTabs = tabs.length + _customCategories.length;
          if (_currentTabIndex >= totalTabs) {
            _currentTabIndex = 0;
          }

          // 获取当前显示的任务列表
          List<DownloadTask> currentTasks;
          if (_currentTabIndex < tabs.length) {
            // 预定义分类
            final currentCategory = tabs[_currentTabIndex];
            currentTasks = currentCategory == FileCategory.all
                ? completedTasks
                : (tasksByCategory[currentCategory] ?? []);
          } else {
            // 自定义分类
            final customIndex = _currentTabIndex - tabs.length;
            currentTasks = customTasksByIndex[customIndex] ?? [];
          }

          // 应用搜索过滤
          if (_searchQuery.isNotEmpty) {
            currentTasks = currentTasks
                .where((t) =>
                    t.fileName
                        .toLowerCase()
                        .contains(_searchQuery.toLowerCase()) ||
                    t.url.toLowerCase().contains(_searchQuery.toLowerCase()))
                .toList();
          }

          return Column(
            children: [
              _buildHeader(context, completedTasks.length),
              _buildTabBar(context, tabs, tasksByCategory, customTasksByIndex,
                  completedTasks.length),
              _buildBatchActionsBar(context, currentTasks),
              Expanded(
                child: currentTasks.isEmpty
                    ? _buildNoResultsState(context)
                    : ScrollEdgeFade(
                        topExtent: 20,
                        bottomExtent: 20,
                        child: SmoothListView.builder(
                          padding: const EdgeInsets.all(20),
                          itemCount: currentTasks.length,
                          // 性能优化：增加缓存区域
                          cacheExtent: 500,
                          addRepaintBoundaries: true,
                          addAutomaticKeepAlives: false,
                          // 平滑滚动配置 - 使用快速响应模式
                          config: SmoothScrollConfig.fast,
                          itemBuilder: (context, index) {
                            final task = currentTasks[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: RepaintBoundary(
                                child: _CompletedTaskCard(
                                  key: ValueKey(task.id),
                                  task: task,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    if (!_showSearch) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: AppTheme.borderDefault),
      ),
      child: Row(
        children: [
          Icon(
            CustomIcons.FluentIcons.searchIcon,
            size: 14,
            color: AppTheme.textTertiary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextBox(
              controller: _searchController,
              placeholder: t.completedSearchPlaceholder,
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: WidgetStateProperty.all(const BoxDecoration()),
              style: FluentTheme.of(context)
                  .typography
                  .body
                  ?.copyWith(fontSize: 13),
              autofocus: true,
            ),
          ),
          if (_searchQuery.isNotEmpty)
            FluentIconButton(
              icon: CustomIcons.FluentIcons.clear,
              size: 28,
              iconSize: 12,
              onPressed: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            ),
          const SizedBox(width: 2),
          FluentIconButton(
            icon: CustomIcons.FluentIcons.chrome_close,
            size: 28,
            iconSize: 13,
            onPressed: () {
              _searchController.clear();
              setState(() {
                _showSearch = false;
                _searchQuery = '';
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildNoResultsState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CustomIcons.FluentIcons.search_issue,
            size: 64,
            color: AppTheme.textTertiary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            t.completedNoResultsTitle,
            style: FluentTheme.of(context).typography.subtitle?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            t.completedNoResultsSubtitle,
            style: FluentTheme.of(context).typography.caption?.copyWith(
                  color: AppTheme.textTertiary,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(
    BuildContext context,
    List<FileCategory> tabs,
    Map<FileCategory, List<DownloadTask>> tasksByCategory,
    Map<int, List<DownloadTask>> customTasksByIndex,
    int totalCount,
  ) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: AppTheme.borderSubtle),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: SmoothSingleChildScrollView(
                  config: SmoothScrollConfig.fast,
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      // 预定义分类
                      ...tabs.asMap().entries.map((entry) {
                        final index = entry.key;
                        final category = entry.value;
                        final count = category == FileCategory.all
                            ? totalCount
                            : (tasksByCategory[category]?.length ?? 0);
                        final isSelected = _currentTabIndex == index;

                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _TabButton(
                            icon: category.icon,
                            label: category.label(t),
                            count: count,
                            isSelected: isSelected,
                            onTap: () =>
                                setState(() => _currentTabIndex = index),
                          ),
                        );
                      }),
                      // 自定义分类
                      ..._customCategories.asMap().entries.map((entry) {
                        final customIndex = entry.key;
                        final category = entry.value;
                        final tabIndex = tabs.length + customIndex;
                        final count =
                            customTasksByIndex[customIndex]?.length ?? 0;
                        final isSelected = _currentTabIndex == tabIndex;

                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _CustomTabButton(
                            icon: CustomIcons.FluentIcons.tag,
                            label: category.name,
                            count: count,
                            isSelected: isSelected,
                            onTap: () =>
                                setState(() => _currentTabIndex = tabIndex),
                            onDelete: () => _deleteCustomCategory(customIndex),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 搜索按钮
              FluentIconButton(
                icon: CustomIcons.FluentIcons.searchIcon,
                tooltip: t.completedSearchPlaceholder,
                selected: _showSearch,
                onPressed: () => setState(() => _showSearch = !_showSearch),
              ),
              const SizedBox(width: 4),
              // 新建自定义分类按钮
              FluentIconButton(
                icon: CustomIcons.FluentIcons.add,
                tooltip: t.completedCreateCategoryTitle,
                onPressed: _showCreateCategoryDialog,
              ),
            ],
          ),
        ),
        // 搜索栏（展开时显示）
        if (_showSearch) _buildSearchBar(context),
      ],
    );
  }

  void _showCreateCategoryDialog() {
    final nameController = TextEditingController();
    final extensionsController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(t.completedCreateCategoryTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.completedCreateCategoryNameLabel),
            const SizedBox(height: 8),
            TextBox(
              controller: nameController,
              placeholder: t.completedCreateCategoryNamePlaceholder,
            ),
            const SizedBox(height: 16),
            Text(t.completedCreateCategoryExtensionsLabel),
            const SizedBox(height: 8),
            TextBox(
              controller: extensionsController,
              placeholder: t.completedCreateCategoryExtensionsPlaceholder,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.accentPrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
              child: Text(
                t.completedCreateCategoryHint,
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textTertiary,
                ),
              ),
            ),
          ],
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context),
            child: Text(t.completedCancelButton),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameController.text.trim();
              final extensionsText = extensionsController.text.trim();

              if (name.isEmpty || extensionsText.isEmpty) {
                NotificationManager.of(context)?.showWarning(
                  t.completedCreateCategoryInputErrorTitle,
                  message: t.completedCreateCategoryInputErrorMessage,
                );
                return;
              }

              final extensions = extensionsText
                  .split(',')
                  .map((e) => e.trim().toLowerCase())
                  .where((e) => e.isNotEmpty)
                  .toList();

              if (extensions.isEmpty) {
                NotificationManager.of(context)?.showWarning(
                  t.completedCreateCategoryInputErrorTitle,
                  message: t.completedCreateCategoryInvalidExtMessage,
                );
                return;
              }

              // 保存自定义分类到配置
              final configService = context.read<ClientConfigService>();
              await configService.addCustomCategory(name, extensions);

              // 重新加载分类
              _loadCustomCategories();

              if (!context.mounted) return;
              Navigator.pop(context);

              NotificationManager.of(context)?.showSuccess(
                t.completedCreateCategorySuccessTitle,
                message: t.completedCreateCategorySuccessMessage(name),
              );
            },
            child: Text(t.completedCreateButton),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchActionsBar(BuildContext context, List<DownloadTask> tasks) {
    if (tasks.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: AppTheme.borderDefault),
      ),
      child: Row(
        children: [
          Icon(
            CustomIcons.FluentIcons.list,
            size: 14,
            color: AppTheme.textTertiary,
          ),
          const SizedBox(width: 8),
          Text(
            t.completedBatchActionsLabel(tasks.length),
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
            ),
          ),
          const Spacer(),
          Button(
            onPressed: () => _batchRenameTasks(tasks),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CustomIcons.FluentIcons.getIcon('edit_20'), size: 12),
                const SizedBox(width: 6),
                Text(t.completedBatchRenameButton,
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Button(
            onPressed: () => _batchMoveTasks(tasks),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CustomIcons.FluentIcons.folder_open, size: 12),
                const SizedBox(width: 6),
                Text(t.completedBatchMoveButton,
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _batchMoveTasks(List<DownloadTask> tasks) async {
    if (tasks.isEmpty) return;

    String initialPath = 'C:\\';
    try {
      initialPath = Directory.current.path;
    } catch (_) {}

    final selectedPath = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (context) => FolderPickerDialog(
        initialPath: initialPath,
      ),
    );

    if (selectedPath == null || !mounted) return;

    final service = context.read<IntegratedDownloadService>();
    int success = 0;
    int failed = 0;

    for (final task in tasks) {
      final ok = await service.moveTaskFile(task.id, selectedPath);
      if (ok) {
        success++;
      } else {
        failed++;
      }
    }

    if (!mounted) return;

    if (failed == 0) {
      NotificationManager.of(context)?.showSuccess(
        t.completedBatchMoveSuccessTitle,
        message: t.completedBatchMoveSuccessMessage(success),
      );
    } else {
      NotificationManager.of(context)?.showWarning(
        t.completedBatchMoveSuccessTitle,
        message: t.completedBatchMovePartialMessage(success, failed),
      );
    }
  }

  Future<void> _batchRenameTasks(List<DownloadTask> tasks) async {
    if (tasks.isEmpty) return;

    final prefixController = TextEditingController();
    final suffixController = TextEditingController();
    final service = context.read<IntegratedDownloadService>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(t.completedBatchRenameTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.completedBatchRenameHint),
            const SizedBox(height: 12),
            Text(t.completedBatchRenamePrefixLabel),
            const SizedBox(height: 6),
            TextBox(
              controller: prefixController,
              placeholder: t.completedBatchRenamePrefixPlaceholder,
            ),
            const SizedBox(height: 12),
            Text(t.completedBatchRenameSuffixLabel),
            const SizedBox(height: 6),
            TextBox(
              controller: suffixController,
              placeholder: t.completedBatchRenameSuffixPlaceholder,
            ),
          ],
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.folderPickerCancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.folderPickerConfirmButton),
          ),
        ],
      ),
    );

    final prefix = prefixController.text.trim();
    final suffix = suffixController.text.trim();
    prefixController.dispose();
    suffixController.dispose();

    if (confirmed != true) return;
    if (prefix.isEmpty && suffix.isEmpty) {
      if (mounted) {
        NotificationManager.of(context)?.showWarning(
          t.completedBatchRenameTitle,
          message: t.completedBatchRenameEmptyWarningMessage,
        );
      }
      return;
    }

    int success = 0;
    int failed = 0;

    for (final task in tasks) {
      final newName = _applyPrefixSuffix(task.fileName, prefix, suffix);
      final ok = await service.renameTaskFile(task.id, newName);
      if (ok) {
        success++;
      } else {
        failed++;
      }
    }

    if (!mounted) return;

    if (failed == 0) {
      NotificationManager.of(context)?.showSuccess(
        t.completedBatchRenameSuccessTitle,
        message: t.completedBatchRenameSuccessMessage(success),
      );
    } else {
      NotificationManager.of(context)?.showWarning(
        t.completedBatchRenameSuccessTitle,
        message: t.completedBatchRenamePartialMessage(success, failed),
      );
    }
  }

  String _applyPrefixSuffix(String fileName, String prefix, String suffix) {
    final dotIndex = fileName.lastIndexOf('.');
    final hasExt = dotIndex > 0 && dotIndex < fileName.length - 1;
    final base = hasExt ? fileName.substring(0, dotIndex) : fileName;
    final ext = hasExt ? fileName.substring(dotIndex) : '';
    return '$prefix$base$suffix$ext';
  }

  void _deleteCustomCategory(int index) {
    final category = _customCategories[index];
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(t.completedConfirmDeleteTitle),
        content: Text(t.completedDeleteCategoryMessage(category.name)),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context),
            child: Text(t.completedCancelButton),
          ),
          FilledButton(
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.all(AppTheme.statusError),
            ),
            onPressed: () async {
              final configService = context.read<ClientConfigService>();
              await configService.removeCustomCategory(index);

              // 重新加载分类
              _loadCustomCategories();

              // 如果当前选中的是被删除的分类，切换到"所有下载"
              final totalPredefinedTabs = FileCategory.values.length;
              if (_currentTabIndex >= totalPredefinedTabs) {
                final customIndex = _currentTabIndex - totalPredefinedTabs;
                if (customIndex >= index) {
                  setState(() => _currentTabIndex = 0);
                }
              }

              if (!context.mounted) return;
              Navigator.pop(context);

              NotificationManager.of(context)?.showSuccess(
                t.completedDeleteCategorySuccessTitle,
                message: t.completedDeleteCategorySuccessMessage(category.name),
              );
            },
            child: Text(t.completedDeleteButton),
          ),
        ],
      ),
    );
  }

  /// WinUI 3 页头：扁平图标磁贴 + Subtitle 标题 + 中性计数徽标 + 右侧命令
  Widget _buildHeader(BuildContext context, int count) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppTheme.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.statusSuccess.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: Icon(
              CustomIcons.FluentIcons.completed,
              size: 16,
              color: AppTheme.statusSuccess,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            t.completedHeaderTitle,
            style: FluentTheme.of(context).typography.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
          ),
          const SizedBox(width: 10),
          FluentChip(label: '$count', fontSize: 12),
          const Spacer(),
          FluentSubtleButton(
            icon: CustomIcons.FluentIcons.folder_open,
            label: t.completedOpenFolderButton,
            filled: true,
            onPressed: () async {
              final folder =
                  Directory("${Platform.environment['USERPROFILE']}\\Downloads")
                      .path;
              final target = folder.replaceAll('/', '\\');
              await Process.run('explorer', [target]);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: ProgressRing(
              strokeWidth: 3,
              activeColor: AppTheme.accentPrimary,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            t.loadingTasks,
            style: FluentTheme.of(context).typography.body?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            t.loadingTasksHint,
            style: FluentTheme.of(context).typography.caption?.copyWith(
                  color: AppTheme.textTertiary,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    // 与下载页一致的 WinUI 入场：淡入 + 8px 上移，无弹跳/发光
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: AppTheme.motionNormal,
        curve: AppTheme.motionStandard,
        builder: (context, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - value)),
            child: child,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CustomIcons.FluentIcons.completed,
              size: 40,
              color: AppTheme.textDisabled,
            ),
            const SizedBox(height: 16),
            Text(
              t.completedEmptyTitle,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              t.completedEmptySubtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: AppTheme.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompletedTaskCard extends StatefulWidget {
  final DownloadTask task;

  const _CompletedTaskCard({super.key, required this.task});

  @override
  State<_CompletedTaskCard> createState() => _CompletedTaskCardState();
}

class _CompletedTaskCardState extends State<_CompletedTaskCard> {
  bool _isExpanded = false;
  AppLocalizations get t => AppLocalizations.of(context)!;

  @override
  Widget build(BuildContext context) {
    final downloadService = context.read<IntegratedDownloadService>();

    // 与下载任务卡片统一：WinUI 卡面令牌 + 中性描边，hover 仅做 subtle 填充变化
    return AnimatedCard(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      backgroundColor: AppTheme.surfaceCard,
      hoverColor: AppTheme.surfaceCardHover,
      borderColor: AppTheme.borderDefault,
      hoverBorderColor: AppTheme.borderStrong,
      borderRadius: AppTheme.radiusSm,
      enableScaleAnimation: false,
      enableGlowAnimation: false,
      child: Column(
        children: [
          Row(
            children: [
              _buildStatusIcon(),
              const SizedBox(width: 14),
              Expanded(child: _buildTaskInfo()),
              const SizedBox(width: 12),
              _buildActions(downloadService),
            ],
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: _buildStatistics(),
            ),
            crossFadeState: _isExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: AppTheme.motionNormal,
            sizeCurve: AppTheme.motionStandard,
            firstCurve: AppTheme.motionAccelerate,
            secondCurve: AppTheme.motionStandard,
          ),
        ],
      ),
    );
  }

  Widget _buildStatistics() {
    // WinUI Expander 展开区：独立的 subtle 底色 + 描边，与卡面区分层级
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.subtleFillHover,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CustomIcons.FluentIcons.chart,
                size: 14,
                color: AppTheme.accentPrimary,
              ),
              const SizedBox(width: 6),
              Text(
                t.completedStatsTitle,
                style: FluentTheme.of(context).typography.body?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildStatsGrid(),
        ],
      ),
    );
  }

  Widget _buildStatsGrid() {
    final stats = [
      // 第一行：重要统计
      _StatItem(
        icon: CustomIcons.FluentIcons.speed_high,
        label: t.completedStatsPeakSpeed,
        value: widget.task.formattedPeakSpeed,
        color: AppTheme.statusSuccess,
      ),
      _StatItem(
        icon: CustomIcons.FluentIcons.timeline_progress,
        label: t.completedStatsAverageSpeed,
        value: widget.task.formattedAverageSpeed,
        color: AppTheme.accentPrimary,
      ),
      _StatItem(
        icon: CustomIcons.FluentIcons.clock,
        label: t.completedStatsDuration,
        value: widget.task.formattedDuration,
        color: AppTheme.statusWarning,
      ),
      // 第二行：详细信息
      _StatItem(
        icon: CustomIcons.FluentIcons.split,
        label: t.completedStatsSegments,
        value: '${widget.task.segmentCount ?? 0}',
        color: AppTheme.textSecondary,
      ),
      _StatItem(
        icon: CustomIcons.FluentIcons.processing,
        label: t.completedStatsThreads,
        value: '${widget.task.threadCount ?? 0}',
        color: AppTheme.textSecondary,
      ),
      _StatItem(
        icon: CustomIcons.FluentIcons.server,
        label: t.completedStatsCore,
        value: widget.task.downloadCore ?? 'NSF-X',
        color: AppTheme.textSecondary,
      ),
    ];

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: stats,
    );
  }

  Widget _buildStatusIcon() {
    // 使用系统文件图标组件
    return FileIconWidget(
      fileName: widget.task.fileName,
      filePath: widget.task.filePath,
      size: 32,
    );
  }

  Widget _buildTaskInfo() {
    final tags =
        context.watch<ClientConfigService>().getTaskTags(widget.task.id);
    final url = widget.task.url.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.task.fileName,
          style: FluentTheme.of(context).typography.body?.copyWith(
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(
              CustomIcons.FluentIcons.check_mark,
              size: 10,
              color: AppTheme.statusSuccess,
            ),
            const SizedBox(width: 4),
            Text(
              widget.task.formattedFileSize,
              style: FluentTheme.of(context).typography.caption?.copyWith(
                    color: AppTheme.textTertiary,
                    fontSize: 12,
                  ),
            ),
            if (widget.task.endTime != null) ...[
              Container(
                width: 1,
                height: 10,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: AppTheme.borderSubtle,
              ),
              Text(
                _formatDate(widget.task.endTime!),
                style: FluentTheme.of(context).typography.caption?.copyWith(
                      color: AppTheme.textTertiary,
                      fontSize: 12,
                    ),
              ),
            ],
          ],
        ),
        if (url.isNotEmpty) ...[
          const SizedBox(height: 8),
          _buildCompactUrlRow(url),
        ],
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: tags.map((tag) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.accentPrimary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTheme.radiusRound),
                  border: Border.all(
                    color: AppTheme.accentPrimary.withValues(alpha: 0.25),
                  ),
                ),
                child: Text(
                  tag,
                  style: FluentTheme.of(context).typography.caption?.copyWith(
                        color: AppTheme.accentLight,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildCompactUrlRow(String url) {
    final displayUrl = url.length > 60 ? '${url.substring(0, 60)}...' : url;

    // hover/press 高亮铺满这一整块，点击复制链接
    return Align(
      alignment: Alignment.centerLeft,
      child: FluentInteractiveSurface(
        onPressed: _copyUrlToClipboard,
        tooltip: t.downloadCopyTooltip,
        colors: FluentInteractionColors(
          rest: AppTheme.subtleFillHover,
          hovered: AppTheme.surfaceCardHover,
          pressed: AppTheme.subtleFillPressed,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        builder: (context, states) {
          final color = states.isHovered || states.isPressed
              ? AppTheme.textSecondary
              : AppTheme.textTertiary;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CustomIcons.FluentIcons.link, size: 10, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  displayUrl,
                  style: TextStyle(color: color, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// WinUI 3 命令区：主操作用带文字的按钮，其余用 32×32 subtle 图标按钮，间距 4。
  Widget _buildActions(IntegratedDownloadService service) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FluentSubtleButton(
          icon: CustomIcons.FluentIcons.play,
          label: t.completedActionRun,
          accentColor: AppTheme.accentPrimary,
          filled: true,
          onPressed: () => _runFile(widget.task.filePath),
        ),
        const SizedBox(width: 6),
        FluentSubtleButton(
          icon: CustomIcons.FluentIcons.folder_open,
          label: t.completedActionLocation,
          onPressed: () => _openFileLocation(widget.task.filePath),
        ),
        const SizedBox(width: 4),
        FluentIconButton(
          icon: CustomIcons.FluentIcons.tag,
          tooltip: t.tagActionLabel,
          accentColor: AppTheme.accentLight,
          onPressed: _editTags,
        ),
        const SizedBox(width: 4),
        FluentExpanderChevron(
          expanded: _isExpanded,
          onPressed: () => setState(() => _isExpanded = !_isExpanded),
        ),
        const SizedBox(width: 4),
        FluentIconButton(
          icon: CustomIcons.FluentIcons.delete,
          tooltip: t.downloadActionDelete,
          accentColor: AppTheme.statusError,
          tinted: true,
          onPressed: () => _confirmDelete(service),
        ),
      ],
    );
  }

  Future<void> _copyUrlToClipboard() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.task.url));
      if (!mounted) return;
      NotificationManager.of(context)?.showSuccess(
        t.downloadCopySuccessTitle,
        message: t.downloadCopySuccessMessage,
      );
    } catch (e) {
      if (!mounted) return;
      NotificationManager.of(context)?.showError(
        t.downloadCopyFailedTitle,
        message: t.downloadCopyFailedMessage(e.toString()),
      );
    }
  }

  Future<void> _editTags() async {
    final config = context.read<ClientConfigService>();
    final existing = config.getTaskTags(widget.task.id);
    final controller = TextEditingController(text: existing.join(', '));

    final result = await showDialog<String>(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(t.tagEditTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.tagEditSubtitle),
            const SizedBox(height: 8),
            TextBox(
              controller: controller,
              placeholder: t.tagEditPlaceholder,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context),
            child: Text(t.folderPickerCancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(t.folderPickerConfirmButton),
          ),
        ],
      ),
    );

    controller.dispose();

    if (result != null) {
      final tags = result
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      await config.setTaskTags(widget.task.id, tags);
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) return t.completedTimeJustNow;
    if (diff.inHours < 1) return t.completedTimeMinutesAgo(diff.inMinutes);
    if (diff.inDays < 1) return t.completedTimeHoursAgo(diff.inHours);
    if (diff.inDays < 7) return t.completedTimeDaysAgo(diff.inDays);

    return t.completedTimeMonthDay(date.month, date.day);
  }

  void _runFile(String? filePath) async {
    if (filePath == null) {
      _showMessage(t.completedFilePathMissingMessage);
      return;
    }

    try {
      final file = File(filePath);
      if (!await file.exists()) {
        _showMessage(t.completedFileNotFoundMessage);
        return;
      }

      final safePath = filePath.replaceAll('/', '\\');
      await Process.start('cmd', ['/c', 'start', '', safePath],
          runInShell: true);
    } catch (e) {
      _showMessage(t.completedRunFileFailedMessage(e));
    }
  }

  void _openFileLocation(String? filePath) async {
    if (filePath == null) {
      _showMessage(t.completedFilePathMissingMessage);
      return;
    }

    try {
      final file = File(filePath);
      if (!await file.exists()) {
        _showMessage(t.completedFileNotFoundMessage);
        return;
      }

      final safePath = filePath.replaceAll('/', '\\');
      await Process.run('explorer', ['/select,', safePath]);
    } catch (e) {
      _showMessage(t.completedOpenFileLocationFailedMessage(e));
    }
  }

  void _showMessage(String message) {
    NotificationManager.of(context)?.showWarning(
      t.completedHintTitle,
      message: message,
    );
  }

  void _confirmDelete(IntegratedDownloadService service) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogContext) {
        final t = AppLocalizations.of(dialogContext)!;
        return ContentDialog(
          title: Row(
            children: [
              Icon(CustomIcons.FluentIcons.delete,
                  size: 18, color: AppTheme.statusError),
              const SizedBox(width: 8),
              Text(t.completedConfirmDeleteTitle),
            ],
          ),
          content: Text(t.completedDeleteTaskMessage(widget.task.fileName)),
          actions: [
            Button(
              onPressed: () => Navigator.pop(dialogContext),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CustomIcons.FluentIcons.chrome_close, size: 12),
                  const SizedBox(width: 6),
                  Text(t.completedCancelButton),
                ],
              ),
            ),
            Button(
              onPressed: () {
                service.removeTask(widget.task.id);
                Navigator.pop(dialogContext);
                if (!mounted) return;
                NotificationManager.of(context)?.showSuccess(
                  t.completedRemoveSuccessTitle,
                  message: t.completedRemoveSuccessMessage,
                );
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CustomIcons.FluentIcons.list, size: 12),
                  const SizedBox(width: 6),
                  Text(t.completedRemoveButton),
                ],
              ),
            ),
            FilledButton(
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.all(AppTheme.statusError),
              ),
              onPressed: () async {
                Navigator.pop(dialogContext);
                if (!mounted) return;
                await _deleteWithFile(service);
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CustomIcons.FluentIcons.delete,
                      size: 12, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(t.completedDeleteButton),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteWithFile(IntegratedDownloadService service) async {
    final filePath = widget.task.filePath;
    if (filePath != null) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
          if (mounted) {
            NotificationManager.of(context)?.showSuccess(
              t.completedDeleteSuccessTitle,
              message:
                  t.completedDeleteFileSuccessMessage(widget.task.fileName),
            );
          }
        } else {
          if (mounted) {
            NotificationManager.of(context)?.showWarning(
              t.completedFileNotFoundTitle,
              message: t.completedFileNotFoundMessage,
            );
          }
        }
      } catch (e) {
        if (mounted) {
          NotificationManager.of(context)?.showError(
            t.completedDeleteFailedTitle,
            message: t.completedDeleteFailedMessage(e),
          );
        }
      }
    }
    service.removeTask(widget.task.id);
  }
}

/// 带文字的操作按钮
/// 统计项组件：WinUI 3 subtle 信息磁贴。
/// 去掉了固定 110px 宽度，改为按内容自适应并设最小宽度，窄窗口下不会硬撑换行。
class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 104, maxWidth: 180),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.subtleFillHover,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 11, color: color),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// WinUI 3 `SelectorBar` 条目内容：图标 + 文案 + 计数徽标 + 底部 accent 指示条。
///
/// 选中态不再用彩色描边方框（那是 WinUI 之前的 Pivot 观感），而是：
/// subtle 填充 + BodyStrong 文本 + 底部 3px accent 指示条，指示条宽度带动画。
class _SelectorBarContent extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final bool isSelected;
  final Set<WidgetState> states;
  final Widget? trailing;

  const _SelectorBarContent({
    required this.icon,
    required this.label,
    required this.count,
    required this.isSelected,
    required this.states,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.isDarkContext(context)
        ? AppTheme.accentLight
        : AppTheme.accentPrimary;
    final foreground = isSelected
        ? AppTheme.textPrimary
        : (states.isHovered || states.isPressed)
            ? AppTheme.textPrimary
            : AppTheme.textSecondary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: isSelected ? accent : foreground),
            const SizedBox(width: 7),
            AnimatedDefaultTextStyle(
              duration: AppTheme.motionFast,
              curve: AppTheme.motionStandard,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: foreground,
              ),
              child: Text(label),
            ),
            const SizedBox(width: 6),
            AnimatedContainer(
              duration: AppTheme.motionFast,
              curve: AppTheme.motionStandard,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.accentPrimary.withValues(alpha: 0.18)
                    : AppTheme.subtleFillHover,
                borderRadius: BorderRadius.circular(AppTheme.radiusRound),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isSelected ? accent : AppTheme.textTertiary,
                ),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
        const SizedBox(height: 5),
        // WinUI SelectorBar 指示条
        AnimatedContainer(
          duration: AppTheme.motionNormal,
          curve: AppTheme.motionStandard,
          height: 3,
          width: isSelected ? 18 : 0,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }
}

/// Tab 按钮组件（WinUI 3 SelectorBar 风格）
class _TabButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final bool isSelected;
  final VoidCallback onTap;

  const _TabButton({
    required this.icon,
    required this.label,
    required this.count,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FluentInteractiveSurface(
      onPressed: onTap,
      colors: FluentInteractionColors.subtle(),
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 3),
      builder: (context, states) => _SelectorBarContent(
        icon: icon,
        label: label,
        count: count,
        isSelected: isSelected,
        states: states,
      ),
    );
  }
}

/// 自定义分类 Tab 按钮组件（带删除功能）
class _CustomTabButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final int count;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _CustomTabButton({
    required this.icon,
    required this.label,
    required this.count,
    required this.isSelected,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_CustomTabButton> createState() => _CustomTabButtonState();
}

class _CustomTabButtonState extends State<_CustomTabButton> {
  @override
  Widget build(BuildContext context) {
    return FluentInteractiveSurface(
      onPressed: widget.onTap,
      colors: FluentInteractionColors.subtle(),
      padding: const EdgeInsets.fromLTRB(10, 7, 6, 3),
      builder: (context, states) => _SelectorBarContent(
        icon: widget.icon,
        label: widget.label,
        count: widget.count,
        isSelected: widget.isSelected,
        states: states,
        // 删除按钮只在悬停时淡入，但始终占位，避免整条 Tab 抖动
        trailing: AnimatedOpacity(
          opacity: states.isHovered ? 1 : 0,
          duration: AppTheme.motionFast,
          curve: AppTheme.motionStandard,
          child: IgnorePointer(
            ignoring: !states.isHovered,
            child: FluentIconButton(
              icon: CustomIcons.FluentIcons.chrome_close,
              size: 20,
              iconSize: 9,
              restColor: AppTheme.textTertiary,
              accentColor: AppTheme.statusError,
              tinted: true,
              onPressed: widget.onDelete,
            ),
          ),
        ),
      ),
    );
  }
}
