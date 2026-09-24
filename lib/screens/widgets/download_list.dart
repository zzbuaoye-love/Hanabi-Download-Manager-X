import 'dart:ui';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/integrated_download_service.dart';
import '../../services/performance_monitor_service.dart';
import '../../services/download_failure_stats_service.dart';
import '../../services/client_config_service.dart';
import '../../services/geo_ip_service.dart';
import '../../models/download_task.dart'
    show DownloadTask, DownloadStatus, SegmentInfo;
import '../../theme/app_theme.dart';
import '../../widgets/file_icon_widget.dart';
import '../../widgets/animated_card.dart';
import '../../widgets/fluent_interactions.dart';
import '../../widgets/scroll_edge_fade.dart';
import '../../widgets/smooth_scroll_wrapper.dart';
import '../../utils/fluent_icons.dart' as CustomIcons;
import '../../utils/failure_reason_localizer.dart';
import '../../widgets/animated_notifications.dart';
import '../../widgets/speed_chart_widget.dart';
import '../../widgets/geo_route_badge.dart';
import '../../l10n/app_localizations.dart';

class DownloadList extends StatefulWidget {
  const DownloadList({super.key});

  @override
  State<DownloadList> createState() => _DownloadListState();
}

class _DownloadListState extends State<DownloadList> {
  bool _showSearch = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  DownloadStatus? _filterStatus;
  String? _filterTag;
  String _sortOrder = 'newest'; // 'newest' 或 'oldest'

  AppLocalizations get t => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    // 延迟加载排序设置，避免在 initState 中触发 setState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSortOrder();
    });
  }

  Future<void> _loadSortOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final sortOrder = prefs.getString('task_sort_order') ?? 'newest';
    if (mounted) {
      setState(() => _sortOrder = sortOrder);
    }
  }

  Future<void> _saveSortOrder(String order) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('task_sort_order', order);
    setState(() => _sortOrder = order);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 追踪重建
    PerformanceMonitorService().trackRebuild('DownloadList');

    return ColoredBox(
      color: Colors.transparent,
      // 优化：使用 Selector 监听任务列表变化
      child: Selector<IntegratedDownloadService,
          ({bool hasLoaded, List<DownloadTask> tasks})>(
        selector: (_, service) => (
          hasLoaded: service.hasLoadedOnce,
          tasks: service.tasks,
        ),
        shouldRebuild: (previous, next) {
          if (previous.hasLoaded != next.hasLoaded) return true;
          final previousTasks = previous.tasks;
          final nextTasks = next.tasks;

          // 任务数量变化
          if (previousTasks.length != nextTasks.length) return true;

          for (int i = 0; i < previousTasks.length; i++) {
            // 任务 ID 变化
            if (previousTasks[i].id != nextTasks[i].id) return true;
            // 状态变化（如从下载中变为完成）
            if (previousTasks[i].status != nextTasks[i].status) return true;
            // 如果文件大小发生变化（对于未知大小的下载任务转为已知），也需要重建结构
            if (previousTasks[i].fileSize != nextTasks[i].fileSize) return true;
          }
          return false;
        },
        builder: (context, snapshot, child) {
          final downloadService = context.read<IntegratedDownloadService>();
          final tasks = snapshot.tasks;
          final hasLoaded = snapshot.hasLoaded;
          final tagMap = context.watch<ClientConfigService>().getTaskTagsMap();

          var activeTasks =
              tasks.where((t) => t.status != DownloadStatus.completed).toList();

          // 应用搜索过滤
          if (_searchQuery.isNotEmpty) {
            activeTasks = activeTasks
                .where((t) =>
                    t.fileName
                        .toLowerCase()
                        .contains(_searchQuery.toLowerCase()) ||
                    t.url.toLowerCase().contains(_searchQuery.toLowerCase()))
                .toList();
          }

          // 应用状态过滤
          if (_filterStatus != null) {
            activeTasks =
                activeTasks.where((t) => t.status == _filterStatus).toList();
          }

          // 应用标签过滤
          if (_filterTag != null && _filterTag!.isNotEmpty) {
            activeTasks = activeTasks.where((t) {
              final tags = tagMap[t.id] ?? const [];
              return tags.contains(_filterTag);
            }).toList();
          }

          // 应用排序 - 直接使用 createdAt 字段
          activeTasks.sort((a, b) {
            if (_sortOrder == 'newest') {
              return b.createdAt.compareTo(a.createdAt); // 最新的在最上面
            } else {
              return a.createdAt.compareTo(b.createdAt); // 最旧的在最上面
            }
          });

          if (activeTasks.isEmpty &&
              (_searchQuery.isNotEmpty ||
                  _filterStatus != null ||
                  _filterTag != null)) {
            return _buildNoResultsState(context);
          }

          if (activeTasks.isEmpty) {
            if (!hasLoaded) {
              return _buildLoadingState(context);
            }
            return _buildEmptyState(context);
          }

          return Column(
            children: [
              // 顶部工具栏：搜索和筛选按钮
              _buildToolbar(context),
              // 搜索和筛选栏（展开时显示）
              _buildSearchBar(context, downloadService),
              // 下载统计栏
              Selector<IntegratedDownloadService,
                  ({int count, double speed, int segments})>(
                selector: (_, service) {
                  final downloadingTasks = service.tasks
                      .where((t) => t.status == DownloadStatus.downloading)
                      .toList();
                  return (
                    count: downloadingTasks.length,
                    speed: downloadingTasks.fold<double>(
                        0, (sum, t) => sum + (t.speed ?? 0)),
                    segments: downloadingTasks.fold<int>(
                        0, (sum, t) => sum + (t.segments?.length ?? 0)),
                  );
                },
                builder: (context, stats, child) {
                  if (stats.count == 0) return const SizedBox.shrink();
                  return _buildStatsBar(
                      context, stats.count, stats.speed, stats.segments);
                },
              ),
              // 任务列表
              Expanded(
                child: ScrollEdgeFade(
                  topExtent: 20,
                  bottomExtent: 20,
                  child: SmoothListView.builder(
                    padding: const EdgeInsets.all(20),
                    itemCount: activeTasks.length,
                    // 性能优化：增加缓存区域，预加载更多项目减少滚动时的创建销毁
                    cacheExtent: 500,
                    // 添加 addRepaintBoundaries 优化重绘
                    addRepaintBoundaries: true,
                    // 添加 addAutomaticKeepAlives 保持状态
                    addAutomaticKeepAlives: false,
                    // 平滑滚动配置 - 使用快速响应模式
                    config: SmoothScrollConfig.fast,
                    itemBuilder: (context, index) {
                      final taskId = activeTasks[index].id;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        // 使用 RepaintBoundary 隔离每个卡片的重绘
                        child: RepaintBoundary(
                          child: Selector<IntegratedDownloadService,
                              DownloadTask?>(
                            key: ValueKey(taskId),
                            selector: (_, service) {
                              try {
                                return service.tasks
                                    .firstWhere((t) => t.id == taskId);
                              } catch (_) {
                                return null;
                              }
                            },
                            builder: (context, task, child) {
                              if (task == null) return const SizedBox.shrink();
                              return _DownloadTaskCard(
                                task: task,
                              );
                            },
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

  Widget _buildToolbar(BuildContext context) {
    // WinUI 3 CommandBar：subtle 图标按钮 32×32，按钮间距 4，
    // 生效中的筛选用 accent 填充表达“已激活”，而不是把图标染色了事。
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Row(
        children: [
          FluentIconButton(
            icon: CustomIcons.FluentIcons.searchIcon,
            tooltip: t.downloadSearchPlaceholder,
            selected: _showSearch,
            onPressed: () => setState(() => _showSearch = !_showSearch),
          ),
          const SizedBox(width: 4),
          FluentIconButton(
            icon: CustomIcons.FluentIcons.filter,
            tooltip: t.downloadFilterTitle,
            selected: _filterStatus != null,
            onPressed: () => _showFilterDialog(context),
          ),
          const SizedBox(width: 4),
          FluentIconButton(
            icon: CustomIcons.FluentIcons.tag,
            tooltip: t.tagFilterTitle,
            selected: _filterTag != null,
            onPressed: () => _showTagFilterDialog(context),
          ),
          const SizedBox(width: 4),
          FluentIconButton(
            icon: _sortOrder == 'newest'
                ? CustomIcons.FluentIcons.sort_down
                : CustomIcons.FluentIcons.sort_up,
            tooltip: t.downloadSortTitle,
            onPressed: () => _showSortDialog(context),
          ),
          const Spacer(),
          // 生效中的筛选条件：WinUI 可移除标签
          AnimatedSize(
            duration: AppTheme.motionNormal,
            curve: AppTheme.motionStandard,
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_filterStatus != null)
                  _RemovableFilterChip(
                    label: _getStatusFilterText(_filterStatus!),
                    onRemove: () => setState(() => _filterStatus = null),
                  ),
                if (_filterTag != null) ...[
                  if (_filterStatus != null) const SizedBox(width: 8),
                  _RemovableFilterChip(
                    icon: CustomIcons.FluentIcons.tag,
                    label: _filterTag!,
                    onRemove: () => setState(() => _filterTag = null),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getStatusFilterText(DownloadStatus status) {
    final t = AppLocalizations.of(context)!;
    switch (status) {
      case DownloadStatus.downloading:
        return t.downloadStatusDownloading;
      case DownloadStatus.paused:
        return t.downloadStatusPaused;
      case DownloadStatus.pending:
        return t.downloadStatusPending;
      case DownloadStatus.failed:
        return t.downloadStatusFailed;
      case DownloadStatus.merging:
        return t.downloadStatusMerging;
      default:
        return t.downloadFilterAll;
    }
  }

  void _showFilterDialog(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(t.downloadFilterTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.downloadFilterSubtitle),
            const SizedBox(height: 16),
            _buildFilterOption(context, null, t.downloadFilterAll,
                CustomIcons.FluentIcons.list),
            _buildFilterOption(context, DownloadStatus.downloading,
                t.downloadStatusDownloading, CustomIcons.FluentIcons.download),
            _buildFilterOption(context, DownloadStatus.paused,
                t.downloadStatusPaused, CustomIcons.FluentIcons.pause),
            _buildFilterOption(context, DownloadStatus.pending,
                t.downloadStatusPending, CustomIcons.FluentIcons.clock),
            _buildFilterOption(context, DownloadStatus.failed,
                t.downloadStatusFailed, CustomIcons.FluentIcons.error_badge),
            _buildFilterOption(context, DownloadStatus.merging,
                t.downloadStatusMerging, CustomIcons.FluentIcons.processing),
          ],
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context),
            child: Text(t.downloadDialogCloseButton),
          ),
        ],
      ),
    );
  }

  void _showTagFilterDialog(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final config = context.read<ClientConfigService>();
    final tags = config.getAllTaskTags();

    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(t.tagFilterTitle),
        content: tags.isEmpty
            ? Text(t.tagFilterEmpty)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.tagFilterSubtitle),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: tags.map((tag) {
                      final isSelected = _filterTag == tag;
                      return FluentInteractiveSurface(
                        onPressed: () {
                          setState(() => _filterTag = tag);
                          Navigator.pop(context);
                        },
                        pressedScale: 0.97,
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusRound),
                        border: Border.all(
                          color: isSelected
                              ? AppTheme.accentPrimary.withValues(alpha: 0.45)
                              : AppTheme.borderDefault,
                        ),
                        colors: isSelected
                            ? FluentInteractionColors.accent()
                            : FluentInteractionColors.card(),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: Text(
                          tag,
                          style: TextStyle(
                            color: isSelected
                                ? (AppTheme.isDarkContext(context)
                                    ? AppTheme.accentLight
                                    : AppTheme.accentPrimary)
                                : AppTheme.textSecondary,
                            fontSize: 12,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
        actions: [
          if (_filterTag != null)
            Button(
              onPressed: () {
                setState(() => _filterTag = null);
                Navigator.pop(context);
              },
              child: Text(t.tagFilterClearButton),
            ),
          Button(
            onPressed: () => Navigator.pop(context),
            child: Text(t.downloadDialogCloseButton),
          ),
        ],
      ),
    );
  }

  void _showSortDialog(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(t.downloadSortTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.downloadSortSubtitle),
            const SizedBox(height: 16),
            _buildSortOption(context, 'newest', t.downloadSortNewest,
                CustomIcons.FluentIcons.sort_down, t.downloadSortNewestDesc),
            _buildSortOption(context, 'oldest', t.downloadSortOldest,
                CustomIcons.FluentIcons.sort_up, t.downloadSortOldestDesc),
          ],
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context),
            child: Text(t.downloadDialogCloseButton),
          ),
        ],
      ),
    );
  }

  Widget _buildSortOption(BuildContext context, String value, String label,
      IconData icon, String description) {
    return _OptionRow(
      icon: icon,
      label: label,
      description: description,
      isSelected: _sortOrder == value,
      onTap: () {
        _saveSortOrder(value);
        Navigator.pop(context);
      },
    );
  }

  Widget _buildFilterOption(BuildContext context, DownloadStatus? status,
      String label, IconData icon) {
    return _OptionRow(
      icon: icon,
      label: label,
      isSelected: _filterStatus == status,
      onTap: () {
        setState(() => _filterStatus = status);
        Navigator.pop(context);
      },
    );
  }

  Widget _buildSearchBar(
      BuildContext context, IntegratedDownloadService downloadService) {
    // 只在搜索展开时显示
    if (!_showSearch) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.bgLayer2.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: AppTheme.borderSubtle.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(CustomIcons.FluentIcons.searchIcon,
              size: 14, color: AppTheme.accentLight),
          const SizedBox(width: 8),
          Expanded(
            child: TextBox(
              controller: _searchController,
              placeholder: t.downloadSearchPlaceholder,
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
            IconButton(
              icon: Icon(CustomIcons.FluentIcons.clear, size: 12),
              onPressed: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
              style: ButtonStyle(
                padding: WidgetStateProperty.all(const EdgeInsets.all(6)),
              ),
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
            t.downloadNoResultsTitle,
            style: FluentTheme.of(context).typography.subtitle?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            t.downloadNoResultsSubtitle,
            style: FluentTheme.of(context).typography.caption?.copyWith(
                  color: AppTheme.textTertiary,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsBar(BuildContext context, int activeCount,
      double totalSpeed, int totalSegments) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: AppTheme.borderDefault),
      ),
      child: Row(
        children: [
          // 活跃任务数
          _buildStatItem(
            context,
            icon: CustomIcons.FluentIcons.download,
            label: t.downloadStatsActiveLabel,
            value: '$activeCount',
            color: AppTheme.accentPrimary,
          ),
          _buildDivider(),
          // 总速度
          _buildStatItem(
            context,
            icon: CustomIcons.FluentIcons.speed_high,
            label: t.downloadStatsSpeedLabel,
            value: _formatSpeed(totalSpeed),
            color: AppTheme.accentLight,
          ),
          _buildDivider(),
          // 活跃分段
          _buildStatItem(
            context,
            icon: CustomIcons.FluentIcons.split_object,
            label: t.downloadStatsSegmentsLabel,
            value: '$totalSegments',
            color: AppTheme.statusSuccess,
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Expanded(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      width: 1,
      height: 26,
      color: AppTheme.borderDefault,
    );
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    }
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    if (bytesPerSecond < 1024 * 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB/s';
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
    // WinUI 3 的入场动效是“淡入 + 轻微上移”，不做弹跳/发光 —— 这里统一到标准曲线
    return Center(
      child: _FadeUpEntrance(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CustomIcons.FluentIcons.download,
              size: 40,
              color: AppTheme.textDisabled,
            ),
            const SizedBox(height: 16),
            Text(
              t.downloadEmptyTitle,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              t.downloadEmptySubtitle,
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

/// WinUI 标准入场：150ms 淡入 + 8px 上移，无弹跳。
class _FadeUpEntrance extends StatelessWidget {
  final Widget child;

  const _FadeUpEntrance({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: AppTheme.motionNormal,
      curve: AppTheme.motionStandard,
      builder: (context, value, inner) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - value)),
            child: inner,
          ),
        );
      },
      child: child,
    );
  }
}

class _DownloadTaskCard extends StatefulWidget {
  final DownloadTask task;

  const _DownloadTaskCard({required this.task});

  @override
  State<_DownloadTaskCard> createState() => _DownloadTaskCardState();
}

class _DownloadTaskCardState extends State<_DownloadTaskCard> {
  bool _isSegmentsExpanded = false;
  bool _showAllSegments = false;
  int _maxVisibleSegments = 5;
  String _segmentsDisplayMode = 'merged'; // 'merged' (合并) 或 'list' (列表)
  bool _showSpeedChart = true;
  bool _showChartFrost = true;
  String _chartPosition = 'mid'; // 'low' | 'mid' | 'high'
  String _chartColor = 'blue';

  AppLocalizations get t => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    _loadSegmentsExpandedSetting();
  }

  Future<void> _loadSegmentsExpandedSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final defaultExpanded = prefs.getBool('segments_default_expanded') ?? false;
    final maxVisible = prefs.getInt('segments_max_visible') ?? 5;
    final displayMode = prefs.getString('segments_display_mode') ?? 'merged';
    final showChart = prefs.getBool('show_speed_chart') ?? true;
    final showFrost = prefs.getBool('show_chart_frost') ?? true;
    final chartPos = prefs.getString('chart_position') ?? 'mid';
    final chartCol = prefs.getString('chart_color') ?? 'blue';
    if (mounted) {
      setState(() {
        _isSegmentsExpanded = defaultExpanded;
        _maxVisibleSegments = maxVisible;
        _segmentsDisplayMode = displayMode;
        _showSpeedChart = showChart;
        _showChartFrost = showFrost;
        _chartPosition = chartPos;
        _chartColor = chartCol;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 追踪重建
    PerformanceMonitorService().trackRebuild('DownloadTaskCard');

    final downloadService = context.read<IntegratedDownloadService>();
    final showHttpConnectivityBadges =
        context.select<ClientConfigService, bool>(
      (config) => config.getBool(
        'download.show_http_connectivity_badges',
        defaultValue: false,
      ),
    );
    // IP 归属地徽标有独立开关，与 show_http_connectivity_badges 无关。
    // 这里只 select 一个 bool：GeoIpService 每次解析完成后的 notifyListeners()
    // 不会因此重建整张卡片；真正的路由数据由 GeoRouteBadge 内部自行 watch。
    // 外层的 Selector<IntegratedDownloadService, DownloadTask?> 只过滤它自身
    // Provider 的通知，不会阻断 GeoIpService 对徽标 Element 的定向重建，
    // RepaintBoundary 同样只影响绘制分层、不影响重建传播——无需额外处理。
    final showGeoRouteBadge =
        context.select<GeoIpService, bool>((geo) => geo.enabled);
    final isActive = widget.task.status == DownloadStatus.downloading;

    // WinUI 3 卡片：surfaceCard + 中性描边，hover 仅 subtle 填充变化；
    // 活跃任务保留 subtle accent 描边作为功能提示
    return AnimatedCard(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      backgroundColor: AppTheme.surfaceCard,
      hoverColor: AppTheme.surfaceCardHover,
      borderColor: isActive
          ? AppTheme.accentPrimary.withValues(alpha: 0.32)
          : AppTheme.borderDefault,
      hoverBorderColor: isActive
          ? AppTheme.accentPrimary.withValues(alpha: 0.32)
          : AppTheme.borderStrong,
      borderRadius: AppTheme.radiusSm,
      enableScaleAnimation: false,
      enableGlowAnimation: isActive,
      child: Stack(
        children: [
          // 背景速度折线图（下载中/暂停/失败时显示）
          if (_showSpeedChart &&
              (widget.task.status == DownloadStatus.downloading ||
                  widget.task.status == DownloadStatus.paused ||
                  widget.task.status == DownloadStatus.failed))
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                child: SpeedChartWidget(
                  taskId: widget.task.id,
                  currentSpeed: widget.task.speed ?? 0,
                  status: widget.task.status == DownloadStatus.paused
                      ? 'paused'
                      : widget.task.status == DownloadStatus.failed
                          ? 'failed'
                          : 'downloading',
                  colorName: _chartColor,
                  position: _chartPosition == 'low'
                      ? ChartPosition.low
                      : _chartPosition == 'high'
                          ? ChartPosition.high
                          : ChartPosition.mid,
                  progress: widget.task.progress.clamp(0.0, 1.0),
                ),
              ),
            ),
          // 毛玻璃层（在曲线之上、内容之下）
          if (_showSpeedChart &&
              _showChartFrost &&
              (widget.task.status == DownloadStatus.downloading ||
                  widget.task.status == DownloadStatus.paused ||
                  widget.task.status == DownloadStatus.failed))
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
                  child: Container(color: Colors.transparent),
                ),
              ),
            ),
          // 卡片内容
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(
                  downloadService,
                  showHttpConnectivityBadges,
                  showGeoRouteBadge,
                ),
                const SizedBox(height: 16),
                _buildTagsRow(),
                _buildProgressSection(),
                if (widget.task.status == DownloadStatus.downloading) ...[
                  const SizedBox(height: 14),
                  _buildSpeedInfo(),
                ],
                if (widget.task.status == DownloadStatus.failed &&
                    widget.task.error != null) ...[
                  const SizedBox(height: 14),
                  _buildErrorInfo(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// BT / ED2K 等插件任务没有 HTTP 协商，也没有可解析的主机名，
  /// 这些徽标只会显示成「HTTP --」「未知」这类噪音。
  bool get _isHttpTask {
    final url = widget.task.url.trim().toLowerCase();
    return url.startsWith('http://') || url.startsWith('https://');
  }

  Widget _buildHeader(
    IntegratedDownloadService service,
    bool showHttpConnectivityBadgesSetting,
    bool showGeoRouteBadgeSetting,
  ) {
    final showHttpConnectivityBadges =
        showHttpConnectivityBadgesSetting && _isHttpTask;
    final showGeoRouteBadge = showGeoRouteBadgeSetting && _isHttpTask;
    final showResumeDecisionBadge =
        (widget.task.resumeDecisionLabel ?? '').trim().isNotEmpty;
    final showHttpDecisionBadge =
        (widget.task.httpPolicyDecisionReason ?? '').trim().isNotEmpty;
    final showConcurrencyBadge = widget.task.hostConcurrencyCap != null &&
        widget.task.hostConcurrencyCap! > 0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 文件图标
        FileIconWidget(
          fileName: widget.task.fileName,
          filePath: widget.task.filePath,
          size: 44,
        ),
        const SizedBox(width: 14),
        // 文件信息
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 文件名 + 状态指示器
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.task.fileName,
                      style: FluentTheme.of(context).typography.body?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary,
                            fontSize: 14,
                            height: 1.3,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildStatusIndicator(),
                ],
              ),
              const SizedBox(height: 6),
              // URL + 文件大小
              Row(
                children: [
                  Expanded(child: _buildUrlWithCopy()),
                  if (widget.task.fileSize != null &&
                      widget.task.fileSize! > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.bgLayer2.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _formatBytes(widget.task.fileSize!),
                        style: FluentTheme.of(context)
                            .typography
                            .caption
                            ?.copyWith(
                              color: AppTheme.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                            ),
                      ),
                    ),
                  ],
                ],
              ),
              // 归属地徽标是独立开关，必须一并参与 Wrap 的显示判定，
              // 否则在 HTTP 连通性徽标关闭（默认）时整个 Wrap 都不会渲染。
              if (showHttpConnectivityBadges ||
                  showResumeDecisionBadge ||
                  showGeoRouteBadge) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (showHttpConnectivityBadges) _buildHttpVersionBadge(),
                    if (showHttpConnectivityBadges && showHttpDecisionBadge)
                      _buildHttpDecisionBadge(),
                    if (showHttpConnectivityBadges && showConcurrencyBadge)
                      _buildConcurrencyCapBadge(),
                    if (showHttpConnectivityBadges) _buildConnectivityBadge(),
                    if (showResumeDecisionBadge) _buildResumeDecisionBadge(),
                    if (showGeoRouteBadge)
                      GeoRouteBadge(
                        url: widget.task.url,
                        downloadSpeed: widget.task.speed ?? 0,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        // 操作按钮
        _buildActionButtons(service),
      ],
    );
  }

  Widget _buildHttpVersionBadge() {
    final policy = widget.task.effectiveHttpVersionPolicy;
    final negotiated =
        _formatNegotiatedHttpVersion(widget.task.negotiatedHttpVersion);
    final display = negotiated ??
        switch (policy) {
          'http3_only' => 'HTTP/3',
          'http2_only' => 'HTTP/2',
          'http1_only' => 'HTTP/1.1',
          'auto' => 'HTTP Auto',
          _ => 'HTTP --',
        };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.accentPrimary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: AppTheme.accentPrimary.withValues(alpha: 0.28),
          width: 1,
        ),
      ),
      child: Text(
        display,
        style: FluentTheme.of(context).typography.caption?.copyWith(
              color: AppTheme.accentLight,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
      ),
    );
  }

  Widget _buildHttpDecisionBadge() {
    final reason = widget.task.httpPolicyDecisionReason?.trim() ?? '';
    final lowered = reason.toLowerCase();
    final usesHostHint =
        lowered.contains('cached host policy') || lowered.contains('host');
    final label =
        usesHostHint ? t.downloadBadgeHostHint : t.downloadBadgePolicyFallback;
    final color = usesHostHint ? AppTheme.accentLight : AppTheme.statusWarning;
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: color.withValues(alpha: 0.28),
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: FluentTheme.of(context).typography.caption?.copyWith(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
      ),
    );

    return Tooltip(
      message: reason,
      child: badge,
    );
  }

  String? _formatNegotiatedHttpVersion(String? rawVersion) {
    final raw = (rawVersion ?? '').trim().toLowerCase();
    if (raw.isEmpty) return null;

    final normalized = raw.startsWith('http/') ? raw.substring(5) : raw;
    if (normalized == 'http3' ||
        normalized.startsWith('3') ||
        normalized.contains('/3')) {
      return 'HTTP/3';
    }
    if (normalized == 'http2' ||
        normalized.startsWith('2') ||
        normalized == 'h2' ||
        normalized.contains('/2')) {
      return 'HTTP/2';
    }
    if (normalized == 'http1_1' ||
        normalized == 'http1' ||
        normalized.startsWith('1')) {
      return 'HTTP/1.1';
    }
    return null;
  }

  Widget _buildConnectivityBadge() {
    final reachable = widget.task.targetReachable;
    final (text, color) = switch (reachable) {
      true => (t.statusValueReachable, AppTheme.statusSuccess),
      false => (t.statusValueUnreachable, AppTheme.statusError),
      null => (t.statusValueUnknown, AppTheme.statusWarning),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: color.withValues(alpha: 0.28),
          width: 1,
        ),
      ),
      child: Text(
        text,
        style: FluentTheme.of(context).typography.caption?.copyWith(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
      ),
    );
  }

  Widget _buildConcurrencyCapBadge() {
    final cap = widget.task.hostConcurrencyCap;
    final reason = widget.task.hostConcurrencyReason?.trim() ?? '';
    if (cap == null || cap <= 0) {
      return const SizedBox.shrink();
    }

    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.statusWarning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: AppTheme.statusWarning.withValues(alpha: 0.28),
          width: 1,
        ),
      ),
      child: Text(
        t.downloadBadgeConcurrencyCap(cap),
        style: FluentTheme.of(context).typography.caption?.copyWith(
              color: AppTheme.statusWarning,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
      ),
    );

    if (reason.isEmpty) {
      return badge;
    }

    return Tooltip(
      message: reason,
      child: badge,
    );
  }

  Widget _buildResumeDecisionBadge() {
    final label = widget.task.resumeDecisionLabel?.trim() ?? '';
    final reason = widget.task.resumeDecisionReason?.trim() ?? '';
    final lowered = label.toLowerCase();
    final Color color;

    if (lowered.contains('blocked')) {
      color = AppTheme.statusError;
    } else if (lowered.contains('single')) {
      color = AppTheme.statusWarning;
    } else if (lowered.contains('verified')) {
      color = AppTheme.statusSuccess;
    } else {
      color = AppTheme.accentLight;
    }

    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: color.withValues(alpha: 0.28),
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: FluentTheme.of(context).typography.caption?.copyWith(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
      ),
    );

    if (reason.isEmpty) {
      return badge;
    }

    return Tooltip(
      message: reason,
      child: badge,
    );
  }

  Widget _buildTagsRow() {
    final tags =
        context.watch<ClientConfigService>().getTaskTags(widget.task.id);
    if (tags.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
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
    );
  }

  // 状态指示：WinUI InfoBadge 风格胶囊（圆点 + 文案），比裸圆点更易读
  Widget _buildStatusIndicator() {
    return _StatusPill(
      status: widget.task.status,
      color: _getStatusColor(),
      label: _getStatusLabel(),
    );
  }

  String _getStatusLabel() {
    switch (widget.task.status) {
      case DownloadStatus.pending:
        return t.downloadStatusPending;
      case DownloadStatus.downloading:
        return t.downloadStatusDownloading;
      case DownloadStatus.paused:
        return t.downloadStatusPaused;
      case DownloadStatus.completed:
        return t.downloadStatusCompleted;
      case DownloadStatus.failed:
        return t.downloadStatusFailed;
      case DownloadStatus.merging:
        return t.downloadStatusMerging;
    }
  }

  Widget _buildUrlWithCopy() {
    return _HoverableUrl(
      url: widget.task.url,
      onTap: _copyUrlToClipboard,
    );
  }

  Future<void> _copyUrlToClipboard() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.task.url));
      if (mounted) {
        // 显示复制成功的提示
        NotificationManager.of(context)?.showSuccess(
          t.downloadCopySuccessTitle,
          message: t.downloadCopySuccessMessage,
        );
      }
    } catch (e) {
      if (mounted) {
        NotificationManager.of(context)?.showError(
          t.downloadCopyFailedTitle,
          message: t.downloadCopyFailedMessage(e.toString()),
        );
      }
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

  /// WinUI 3 命令区：subtle 图标按钮 32×32、间距 4。
  /// 按钮集合随任务状态变化，用 [AnimatedSize] 让宽度变化平滑过渡。
  Widget _buildActionButtons(IntegratedDownloadService service) {
    final isMerging = widget.task.status == DownloadStatus.merging;
    final hasRetryableSegments = widget.task.hasRetryableSegments;
    final isFailed = widget.task.status == DownloadStatus.failed;
    final canStart = widget.task.status == DownloadStatus.pending ||
        widget.task.status == DownloadStatus.paused;

    final buttons = <Widget>[];
    void add(Widget button) {
      if (buttons.isNotEmpty) buttons.add(const SizedBox(width: 4));
      buttons.add(button);
    }

    if (!isMerging) {
      if (canStart) {
        add(FluentIconButton(
          key: const ValueKey('start'),
          icon: CustomIcons.FluentIcons.play,
          accentColor: AppTheme.statusSuccess,
          tooltip: t.downloadActionStart,
          onPressed: () => service.startTask(widget.task.id),
        ));
      } else if (widget.task.status == DownloadStatus.downloading) {
        add(FluentIconButton(
          key: const ValueKey('pause'),
          icon: CustomIcons.FluentIcons.pause,
          accentColor: AppTheme.statusWarning,
          tooltip: t.downloadActionPause,
          onPressed: () => service.pauseTask(widget.task.id),
        ));
      }

      if (hasRetryableSegments || isFailed) {
        add(FluentIconButton(
          key: const ValueKey('retry'),
          icon: CustomIcons.FluentIcons.refresh,
          accentColor: AppTheme.accentLight,
          tooltip: hasRetryableSegments
              ? t.downloadActionRetrySegments
              : t.downloadActionRetryAll,
          onPressed: () => service.retryFailedSegments(widget.task.id),
        ));
      }

      add(FluentIconButton(
        key: const ValueKey('tags'),
        icon: CustomIcons.FluentIcons.tag,
        accentColor: AppTheme.accentLight,
        tooltip: t.tagActionLabel,
        onPressed: _editTags,
      ));

      add(FluentIconButton(
        key: const ValueKey('delete'),
        icon: CustomIcons.FluentIcons.delete,
        accentColor: AppTheme.statusError,
        tinted: true,
        tooltip: t.downloadActionDelete,
        onPressed: () => _confirmDelete(service),
      ));
    }

    return AnimatedSize(
      duration: AppTheme.motionNormal,
      curve: AppTheme.motionStandard,
      alignment: Alignment.centerRight,
      child: Row(mainAxisSize: MainAxisSize.min, children: buttons),
    );
  }

  Widget _buildProgressSection() {
    final isUnknownSize =
        (widget.task.fileSize == null || widget.task.fileSize == 0) &&
            widget.task.status == DownloadStatus.downloading;
    final isMerging = widget.task.status == DownloadStatus.merging;
    final progress = widget.task.progress.clamp(0.0, 1.0);
    final isMatchingHttpProtocol =
        widget.task.startupStatusKey == 'matching_http_protocol';
    final isDark = AppTheme.isDarkContext(context);

    final accent = isDark ? AppTheme.accentLight : AppTheme.accentPrimary;
    // 进度条颜色随状态走：暂停用中性灰、失败用错误色，和状态胶囊保持一致
    final barColor = switch (widget.task.status) {
      DownloadStatus.paused => AppTheme.textTertiary,
      DownloadStatus.failed => AppTheme.statusError,
      _ => AppTheme.accentPrimary,
    };

    // 合并状态：特殊布局
    if (isMerging) {
      return Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: ProgressRing(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            t.downloadMergingStatus,
            style: FluentTheme.of(context).typography.caption?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: accent,
                  fontSize: 12,
                ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FluentProgressTrack(
              value: progress,
              height: 6,
              color: AppTheme.accentPrimary,
            ),
          ),
          const SizedBox(width: 12),
          _AnimatedPercentage(value: progress, color: accent),
        ],
      );
    }

    // 正常下载状态
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 进度信息行
        Row(
          children: [
            Expanded(
              child: Text(
                (!isUnknownSize &&
                        widget.task.fileSize != null &&
                        widget.task.fileSize! > 0)
                    ? '${_formatBytes((widget.task.fileSize! * progress).round())} / ${_formatBytes(widget.task.fileSize!)}'
                    : isMatchingHttpProtocol
                        ? t.downloadMatchingHttpProtocol
                        : t.downloadCalculatingSize,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FluentTheme.of(context).typography.caption?.copyWith(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                    ),
              ),
            ),
            const SizedBox(width: 12),
            // WinUI 3：百分比是正文强调文本，而不是一个彩色药丸
            if (isUnknownSize)
              Text(
                isMatchingHttpProtocol
                    ? t.downloadMatchingHttpProtocolShort
                    : t.downloadCalculating,
                style: FluentTheme.of(context).typography.caption?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textTertiary,
                      fontSize: 12,
                    ),
              )
            else
              _AnimatedPercentage(
                value: progress,
                color: widget.task.status == DownloadStatus.failed
                    ? AppTheme.statusError
                    : widget.task.status == DownloadStatus.paused
                        ? AppTheme.textSecondary
                        : accent,
                fontSize: 13,
              ),
          ],
        ),

        const SizedBox(height: 8),

        // WinUI 3 ProgressBar：6px 轨道 + 补间动画（进度不再逐帧跳变）
        FluentProgressTrack(
          value: progress,
          height: 6,
          color: barColor,
          indeterminate: isUnknownSize,
        ),

        // 插件任务（BT / ED2K）的连接细节：没有它时「等待中」看不出原因
        if ((widget.task.statusDetail ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            widget.task.statusDetail!.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: FluentTheme.of(context).typography.caption?.copyWith(
                  color: AppTheme.textTertiary,
                  fontSize: 11,
                ),
          ),
        ],

        // 分段进度（如果有）
        if (widget.task.segments != null &&
            widget.task.segments!.isNotEmpty) ...[
          const SizedBox(height: 10),
          _buildSegmentsProgress(),
        ],
      ],
    );
  }

  Widget _buildSegmentsProgress() {
    final segments = widget.task.segments!;

    // 简洁模式：不显示分段信息
    if (_segmentsDisplayMode == 'none') {
      return const SizedBox.shrink();
    }

    // 合并进度条模式
    if (_segmentsDisplayMode == 'merged') {
      return _buildMergedSegmentsBar(segments);
    }

    // 列表模式
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // WinUI Expander header：整块可点，hover/press 高亮与命中区域等大
        FluentInteractiveSurface(
          onPressed: () =>
              setState(() => _isSegmentsExpanded = !_isSegmentsExpanded),
          colors: FluentInteractionColors(
            rest: AppTheme.subtleFillHover,
            hovered: AppTheme.surfaceCardHover,
            pressed: AppTheme.subtleFillPressed,
          ),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CustomIcons.FluentIcons.split_object,
                size: 12,
                color: AppTheme.textTertiary,
              ),
              const SizedBox(width: 6),
              Text(
                t.downloadSegmentsTitleWithCount(segments.length),
                style: FluentTheme.of(context).typography.caption?.copyWith(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
              ),
              const SizedBox(width: 6),
              AnimatedRotation(
                turns: _isSegmentsExpanded ? 0.5 : 0,
                duration: AppTheme.motionNormal,
                curve: AppTheme.motionStandard,
                child: Icon(
                  CustomIcons.FluentIcons.chevron_down,
                  size: 10,
                  color: AppTheme.textTertiary,
                ),
              ),
            ],
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: _buildSegmentsList(segments),
          crossFadeState: _isSegmentsExpanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: AppTheme.motionNormal,
          sizeCurve: AppTheme.motionStandard,
        ),
      ],
    );
  }

  /// 合并分段进度条
  Widget _buildMergedSegmentsBar(List<SegmentInfo> segments) {
    final totalSize = widget.task.fileSize ?? 0;
    if (totalSize == 0) return const SizedBox.shrink();

    // 统计分段状态
    final completedCount =
        segments.where((s) => s.status == 'completed').length;
    final downloadingCount =
        segments.where((s) => s.status == 'downloading').length;
    final failedCount = segments.where((s) => s.status == 'failed').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分段信息标题
        Row(
          children: [
            Icon(
              CustomIcons.FluentIcons.split_object,
              size: 12,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(width: 6),
            Text(
              t.downloadSegmentsTitle,
              style: FluentTheme.of(context).typography.caption?.copyWith(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                  ),
            ),
            const SizedBox(width: 8),
            // 分段状态统计
            _buildSegmentStatusBadge(completedCount, AppTheme.statusSuccess,
                t.downloadSegmentsStatusCompleted),
            const SizedBox(width: 4),
            _buildSegmentStatusBadge(downloadingCount, AppTheme.accentPrimary,
                t.downloadSegmentsStatusDownloading),
            if (failedCount > 0) ...[
              const SizedBox(width: 4),
              _buildSegmentStatusBadge(failedCount, AppTheme.statusError,
                  t.downloadSegmentsStatusFailed),
            ],
          ],
        ),
        const SizedBox(height: 8),
        // 简约现代的进度条
        Container(
          height: 18,
          decoration: BoxDecoration(
            color: AppTheme.bgLayer1.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(4),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: CustomPaint(
              painter: _FlatSegmentProgressPainter(
                segments: segments,
                totalSize: totalSize,
              ),
              size: Size.infinite,
            ),
          ),
        ),
        const SizedBox(height: 4),
        // 分段数量提示
        Row(
          children: [
            Expanded(
              child: Text(
                failedCount > 0
                    ? t.downloadSegmentsSummaryWithFailed(segments.length,
                        completedCount, downloadingCount, failedCount)
                    : t.downloadSegmentsSummary(
                        segments.length, completedCount, downloadingCount),
                style: FluentTheme.of(context).typography.caption?.copyWith(
                      color: AppTheme.textTertiary,
                      fontSize: 10,
                    ),
              ),
            ),
            // 快速重试按钮
            if (failedCount > 0) ...[
              const SizedBox(width: 8),
              FluentInteractiveSurface(
                onPressed: () => context
                    .read<IntegratedDownloadService>()
                    .retryFailedSegments(widget.task.id),
                colors: FluentInteractionColors.tinted(AppTheme.accentPrimary),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                pressedScale: 0.96,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      CustomIcons.FluentIcons.refresh,
                      size: 9,
                      color: AppTheme.accentLight,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      t.downloadRetryButton,
                      style: TextStyle(
                        color: AppTheme.accentLight,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildSegmentStatusBadge(int count, Color color, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$count $label',
        style: FluentTheme.of(context).typography.caption?.copyWith(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w400,
            ),
      ),
    );
  }

  Widget _buildSegmentsList(List<SegmentInfo> segments) {
    final visibleSegments = _showAllSegments
        ? segments
        : segments.take(_maxVisibleSegments).toList();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          ...visibleSegments.map((segment) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _buildSegmentRow(segment),
              )),
          if (segments.length > _maxVisibleSegments)
            _buildShowMoreButton(segments.length),
        ],
      ),
    );
  }

  Widget _buildSegmentRow(SegmentInfo segment) {
    final downloadService = context.read<IntegratedDownloadService>();

    // 根据分段状态选择颜色
    Color statusColor;
    switch (segment.status) {
      case 'downloading':
        statusColor = AppTheme.accentPrimary;
        break;
      case 'completed':
        statusColor = AppTheme.statusSuccess;
        break;
      case 'failed':
        statusColor = AppTheme.statusError;
        break;
      case 'paused':
        statusColor = AppTheme.statusWarning;
        break;
      default:
        statusColor = AppTheme.textTertiary;
    }

    return Row(
      children: [
        // 分段编号和状态指示器
        SizedBox(
          width: 60,
          child: Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                t.downloadSegmentLabel(segment.index + 1),
                style: FluentTheme.of(context).typography.caption?.copyWith(
                      color: AppTheme.textTertiary,
                      fontSize: 11,
                    ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ProgressBar(
            value: segment.progress,
            strokeWidth: 3,
          ),
        ),
        const SizedBox(width: 8),
        // 状态文本
        SizedBox(
          width: 35,
          child: Text(
            segment.statusText,
            style: FluentTheme.of(context).typography.caption?.copyWith(
                  color: statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w400,
                ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 70,
          child: Text(
            '${_formatBytes(segment.downloadedBytes)}/${_formatBytes(segment.endByte - segment.startByte)}',
            style: FluentTheme.of(context).typography.caption?.copyWith(
                  color: AppTheme.textTertiary,
                  fontSize: 9,
                ),
            textAlign: TextAlign.right,
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 55,
          child: Text(
            _formatSpeed(segment.speed),
            style: FluentTheme.of(context).typography.caption?.copyWith(
                  color: segment.speed > 0
                      ? AppTheme.accentLight
                      : AppTheme.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w400,
                ),
            textAlign: TextAlign.right,
          ),
        ),
        // 重试次数显示
        if (segment.retryCount > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: AppTheme.statusWarning.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              t.downloadSegmentRetryCount(segment.retryCount),
              style: FluentTheme.of(context).typography.caption?.copyWith(
                    color: AppTheme.statusWarning,
                    fontSize: 9,
                    fontWeight: FontWeight.w400,
                  ),
            ),
          ),
        ],
        // 单个分段重试按钮
        if (segment.canRetry) ...[
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () =>
                downloadService.retrySegment(widget.task.id, segment.index),
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: AppTheme.accentLight.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                  color: AppTheme.accentLight.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
              child: Icon(
                CustomIcons.FluentIcons.refresh,
                size: 8,
                color: AppTheme.accentLight,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildShowMoreButton(int totalCount) {
    final accent = AppTheme.isDarkContext(context)
        ? AppTheme.accentLight
        : AppTheme.accentPrimary;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FluentInteractiveSurface(
          onPressed: () => setState(() => _showAllSegments = !_showAllSegments),
          colors: FluentInteractionColors.tinted(AppTheme.accentPrimary),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
          pressedScale: 0.98,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedRotation(
                turns: _showAllSegments ? 0.5 : 0,
                duration: AppTheme.motionNormal,
                curve: AppTheme.motionStandard,
                child: Icon(
                  CustomIcons.FluentIcons.chevron_down_small,
                  size: 12,
                  color: accent,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _showAllSegments
                    ? t.downloadSegmentsCollapse
                    : t.downloadSegmentsShowAll(
                        totalCount - _maxVisibleSegments),
                style: FluentTheme.of(context).typography.caption?.copyWith(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    }
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    if (bytesPerSecond < 1024 * 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB/s';
  }

  Widget _buildSpeedInfo() {
    final isUnknownSize =
        widget.task.fileSize == null || widget.task.fileSize == 0;
    final segmentCount = widget.task.segments?.length ?? 0;
    final activeSegments =
        widget.task.segments?.where((s) => s.isDownloading).length ?? 0;
    final speed = widget.task.speed ?? 0;

    final accent = AppTheme.isDarkContext(context)
        ? AppTheme.accentLight
        : AppTheme.accentPrimary;
    final showRemaining = !isUnknownSize &&
        widget.task.remainingTime != null &&
        widget.task.remainingTime!.inSeconds > 0;

    // WinUI 3：单层 subtle 底色的信息条，内部只用图标 + 文本，不再层层套彩色方块
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppTheme.subtleFillHover,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Row(
        children: [
          Icon(CustomIcons.FluentIcons.speed_high, size: 14, color: accent),
          const SizedBox(width: 6),
          Text(
            _formatSpeed(speed),
            style: TextStyle(
              color: accent,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (segmentCount > 1) ...[
            _buildSpeedInfoDivider(),
            Icon(
              CustomIcons.FluentIcons.split_object,
              size: 11,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(width: 5),
            Text(
              '$activeSegments/$segmentCount',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (showRemaining) ...[
            _buildSpeedInfoDivider(),
            Icon(
              CustomIcons.FluentIcons.clock,
              size: 11,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(width: 5),
            Text(
              widget.task.formattedRemainingTime,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isUnknownSize
                  ? t.downloadSizeUnknown(widget.task.formattedDownloadedSize)
                  : '${widget.task.formattedDownloadedSize} / ${widget.task.formattedFileSize}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedInfoDivider() {
    return Container(
      width: 1,
      height: 12,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: AppTheme.borderDefault,
    );
  }

  Widget _buildErrorInfo() {
    final downloadService = context.read<IntegratedDownloadService>();
    final failureStats = context.read<DownloadFailureStatsService>();
    final hasRetryableSegments = widget.task.hasRetryableSegments;
    final failedCount = widget.task.failedSegments.length;
    final reasonKey = failureStats.classifyReasonKey(widget.task.error);
    final reasonLabel = FailureReasonLocalizer.localized(t, reasonKey);
    final suggestion = FailureReasonLocalizer.suggestion(t, reasonKey);
    final rawError = widget.task.error ?? '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.statusError.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: AppTheme.statusError.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CustomIcons.FluentIcons.error_badge,
                size: 16,
                color: AppTheme.statusError,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.downloadFailedTitle,
                      style:
                          FluentTheme.of(context).typography.caption?.copyWith(
                                color: AppTheme.statusError,
                                fontWeight: FontWeight.w500,
                              ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      reasonLabel,
                      style: FluentTheme.of(context)
                          .typography
                          .caption
                          ?.copyWith(
                            color: AppTheme.statusError.withValues(alpha: 0.8),
                            fontSize: 12,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (rawError.isNotEmpty && rawError != reasonLabel) ...[
                      const SizedBox(height: 2),
                      Text(
                        rawError,
                        style: FluentTheme.of(context)
                            .typography
                            .caption
                            ?.copyWith(
                              color: AppTheme.textTertiary,
                              fontSize: 11,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (suggestion != null && suggestion.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        suggestion,
                        style: FluentTheme.of(context)
                            .typography
                            .caption
                            ?.copyWith(
                              color: AppTheme.textSecondary,
                              fontSize: 11,
                            ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          // 分段失败信息和重试按钮
          if (hasRetryableSegments) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.accentLight.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: AppTheme.accentLight.withValues(alpha: 0.2),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    CustomIcons.FluentIcons.info,
                    size: 12,
                    color: AppTheme.accentLight,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      t.downloadFailedSegmentsHint(failedCount),
                      style:
                          FluentTheme.of(context).typography.caption?.copyWith(
                                color: AppTheme.accentLight,
                                fontSize: 11,
                              ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FluentInteractiveSurface(
                    onPressed: () =>
                        downloadService.retryFailedSegments(widget.task.id),
                    colors:
                        FluentInteractionColors.tinted(AppTheme.accentPrimary),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    pressedScale: 0.97,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CustomIcons.FluentIcons.refresh,
                          size: 11,
                          color: AppTheme.accentLight,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          t.downloadRetryButton,
                          style: TextStyle(
                            color: AppTheme.accentLight,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _confirmDelete(IntegratedDownloadService service) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogContext) {
        final t = AppLocalizations.of(dialogContext)!;
        return ContentDialog(
          title: Text(t.downloadConfirmDeleteTitle),
          content: Text(t.downloadConfirmDeleteMessage(widget.task.fileName)),
          actions: [
            Button(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(t.settingsCancelButton),
            ),
            FilledButton(
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.all(AppTheme.statusError),
              ),
              onPressed: () {
                service.removeTask(widget.task.id);
                Navigator.pop(dialogContext);
              },
              child: Text(t.downloadDeleteButton),
            ),
          ],
        );
      },
    );
  }

  Color _getStatusColor() {
    switch (widget.task.status) {
      case DownloadStatus.pending:
        return AppTheme.statusWarning;
      case DownloadStatus.downloading:
        return AppTheme.accentPrimary;
      case DownloadStatus.paused:
        return AppTheme.textTertiary;
      case DownloadStatus.completed:
        return AppTheme.statusSuccess;
      case DownloadStatus.failed:
        return AppTheme.statusError;
      case DownloadStatus.merging:
        return AppTheme.accentLight;
    }
  }
}

/// 现代简约风格分段进度条绘制器
class _FlatSegmentProgressPainter extends CustomPainter {
  final List<SegmentInfo> segments;
  final int totalSize;

  _FlatSegmentProgressPainter({
    required this.segments,
    required this.totalSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (totalSize == 0 || segments.isEmpty) return;

    final width = size.width;
    final height = size.height;

    // 绘制每个分段
    for (int i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final startRatio = segment.startByte / totalSize;
      final endRatio = segment.endByte / totalSize;
      final segmentWidth = (endRatio - startRatio) * width;
      final startX = startRatio * width;

      // 计算分段内的进度
      final segmentSize = segment.endByte - segment.startByte;
      double progressRatio = 0.0;
      if (segmentSize > 0) {
        progressRatio = (segment.downloadedBytes / segmentSize).clamp(0.0, 1.0);
      }
      final progressWidth =
          (segmentWidth * progressRatio).clamp(0.0, segmentWidth);

      // 选择颜色
      Color color;
      switch (segment.status) {
        case 'completed':
          color = AppTheme.statusSuccess;
          break;
        case 'downloading':
          color = AppTheme.accentPrimary;
          break;
        case 'failed':
          color = AppTheme.statusError;
          break;
        case 'paused':
          color = AppTheme.statusWarning;
          break;
        default:
          color = AppTheme.textTertiary.withValues(alpha: 0.15);
      }

      // 绘制已下载部分 - 使用精确的像素对齐
      if (progressWidth > 0) {
        final progressPaint = Paint()
          ..color = color
          ..style = PaintingStyle.fill
          ..isAntiAlias = false; // 禁用抗锯齿，确保像素完美对齐

        canvas.drawRect(
          Rect.fromLTWH(startX, 0, progressWidth, height),
          progressPaint,
        );
      }

      // 只在非完成分段之间绘制分割线
      if (i < segments.length - 1) {
        final nextSegment = segments[i + 1];

        // 两个分段都是完成状态时，不显示分割线
        if (segment.status == 'completed' &&
            nextSegment.status == 'completed') {
          continue;
        }

        // 其他情况显示分割线
        final gapX = startX + segmentWidth;
        final gapPaint = Paint()
          ..color = AppTheme.bgLayer2.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..isAntiAlias = false; // 禁用抗锯齿

        canvas.drawLine(
          Offset(gapX, 0),
          Offset(gapX, height),
          gapPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FlatSegmentProgressPainter oldDelegate) {
    if (oldDelegate.segments.length != segments.length) return true;
    if (oldDelegate.totalSize != totalSize) return true;

    for (int i = 0; i < segments.length; i++) {
      final oldSeg = oldDelegate.segments[i];
      final newSeg = segments[i];

      if (oldSeg.status != newSeg.status) return true;

      final segmentSize = newSeg.endByte - newSeg.startByte;
      if (segmentSize > 0) {
        final oldProgress = oldSeg.downloadedBytes / segmentSize;
        final newProgress = newSeg.downloadedBytes / segmentSize;
        if ((newProgress - oldProgress).abs() > 0.001) return true;
      }
    }

    return false;
  }
}

/// WinUI 3 可移除筛选标签：文字与关闭按钮各自拥有完整命中区域，
/// 关闭按钮的高亮与它的 20×20 命中区域等大。
class _RemovableFilterChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onRemove;

  const _RemovableFilterChip({
    required this.label,
    required this.onRemove,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.isDarkContext(context)
        ? AppTheme.accentLight
        : AppTheme.accentPrimary;

    return Container(
      height: 26,
      constraints: const BoxConstraints(maxWidth: 220),
      padding: EdgeInsets.only(left: icon == null ? 10 : 8, right: 3),
      decoration: BoxDecoration(
        color: AppTheme.accentPrimary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusRound),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: accent),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: accent,
              ),
            ),
          ),
          const SizedBox(width: 4),
          FluentIconButton(
            icon: CustomIcons.FluentIcons.chrome_close,
            tooltip: AppLocalizations.of(context)!.downloadFilterAll,
            size: 20,
            iconSize: 9,
            restColor: accent,
            accentColor: accent,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// WinUI 3 单选列表行（排序 / 筛选对话框）：
/// 整行可点，hover/press 高亮铺满整行，选中态用 subtle 填充 + 左侧 accent 指示条。
class _OptionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? description;
  final bool isSelected;
  final VoidCallback onTap;

  const _OptionRow({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.isDarkContext(context)
        ? AppTheme.accentLight
        : AppTheme.accentPrimary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: FluentInteractiveSurface(
        onPressed: onTap,
        colors: isSelected
            ? FluentInteractionColors(
                rest: AppTheme.subtleFillHover,
                hovered: AppTheme.surfaceCardHover,
                pressed: AppTheme.subtleFillPressed,
              )
            : FluentInteractionColors.subtle(),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            // WinUI 选中指示：左侧 3×16 accent pill
            AnimatedContainer(
              duration: AppTheme.motionFast,
              curve: AppTheme.motionStandard,
              width: 3,
              height: isSelected ? 16 : 0,
              margin: const EdgeInsets.only(right: 9),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Icon(
              icon,
              size: 15,
              color: isSelected ? accent : AppTheme.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.textPrimary,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      description!,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.25,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (isSelected)
              Icon(
                CustomIcons.FluentIcons.check_mark,
                size: 14,
                color: accent,
              ),
          ],
        ),
      ),
    );
  }
}

/// 百分比数字：数值变化时做补间，避免下载过程中数字生硬跳动。
class _AnimatedPercentage extends StatelessWidget {
  final double value;
  final Color color;
  final double fontSize;

  const _AnimatedPercentage({
    required this.value,
    required this.color,
    this.fontSize = 12,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0)),
      duration: AppTheme.motionNormal,
      curve: AppTheme.motionStandard,
      builder: (context, animated, _) {
        return Text(
          '${(animated * 100).toStringAsFixed(1)}%',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }
}

/// 下载状态胶囊：WinUI `InfoBadge` 风格；下载/合并时圆点做轻微呼吸动画。
class _StatusPill extends StatefulWidget {
  final DownloadStatus status;
  final Color color;
  final String label;

  const _StatusPill({
    required this.status,
    required this.color,
    required this.label,
  });

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  bool get _shouldPulse =>
      widget.status == DownloadStatus.downloading ||
      widget.status == DownloadStatus.merging;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (_shouldPulse) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_StatusPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!_shouldPulse && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = RepaintBoundary(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final t = _shouldPulse ? _pulse.value : 0.0;
          return Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: 1.0 - 0.45 * t),
              shape: BoxShape.circle,
            ),
          );
        },
      ),
    );

    return AnimatedContainer(
      duration: AppTheme.motionFast,
      curve: AppTheme.motionStandard,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: widget.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusRound),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot,
          const SizedBox(width: 6),
          Text(
            widget.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: widget.color,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// 可悬停的 URL：hover 时提亮并露出复制图标，点击复制。
class _HoverableUrl extends StatefulWidget {
  final String url;
  final VoidCallback onTap;

  const _HoverableUrl({
    required this.url,
    required this.onTap,
  });

  @override
  State<_HoverableUrl> createState() => _HoverableUrlState();
}

class _HoverableUrlState extends State<_HoverableUrl> {
  bool _isHovered = false;

  void _setHovered(bool value) {
    if (_isHovered == value) return;
    setState(() => _isHovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final color = _isHovered ? AppTheme.textSecondary : AppTheme.textTertiary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          message: AppLocalizations.of(context)!.downloadCopyTooltip,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: AnimatedDefaultTextStyle(
                  duration: AppTheme.motionFast,
                  curve: AppTheme.motionStandard,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    decoration: _isHovered
                        ? TextDecoration.underline
                        : TextDecoration.none,
                    decorationColor: color.withValues(alpha: 0.7),
                  ),
                  child: Text(
                    widget.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              AnimatedOpacity(
                opacity: _isHovered ? 1 : 0,
                duration: AppTheme.motionFast,
                curve: AppTheme.motionStandard,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    CustomIcons.FluentIcons.copy,
                    size: 11,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
