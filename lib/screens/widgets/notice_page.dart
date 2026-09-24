import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/app_localizations.dart';
import '../../models/notice_model.dart';
import '../../services/client_config_service.dart';
import '../../services/notice_service.dart';
import '../../services/performance_monitor_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/fluent_icons.dart' as CustomIcons;
import '../../widgets/animated_notifications.dart';
import '../../widgets/fluent_interactions.dart';
import '../../widgets/scroll_edge_fade.dart';
import '../../widgets/settings_components.dart';
import '../../widgets/smooth_scroll_wrapper.dart';

// ============================================================================
// 通知等级
// ============================================================================

String _normalizeNoticeMarkdown(String source) {
  return source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAllMapped(
        RegExp(r'(\*\*[^*\n]*?)\s*[:：]\s+\*\*\s+\*\s+'),
        (match) => '${match.group(1)}：** ',
      );
}

Color _noticeLevelColor(NoticeLevel level) {
  switch (level) {
    case NoticeLevel.info:
      return AppTheme.statusInfo;
    case NoticeLevel.success:
      return AppTheme.statusSuccess;
    case NoticeLevel.warning:
      return AppTheme.statusWarning;
    case NoticeLevel.critical:
      return AppTheme.statusError;
  }
}

IconData _noticeLevelIcon(NoticeLevel level) {
  switch (level) {
    case NoticeLevel.info:
      return FluentIcons.info;
    case NoticeLevel.success:
      return FluentIcons.completed;
    case NoticeLevel.warning:
      return FluentIcons.warning;
    case NoticeLevel.critical:
      return FluentIcons.error_badge;
  }
}

String _noticeLevelLabel(AppLocalizations t, NoticeLevel level) {
  switch (level) {
    case NoticeLevel.info:
      return t.noticeLevelInfo;
    case NoticeLevel.success:
      return t.noticeLevelSuccess;
    case NoticeLevel.warning:
      return t.noticeLevelWarning;
    case NoticeLevel.critical:
      return t.noticeLevelCritical;
  }
}

String _noticeFormatDate(DateTime dt) {
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}

String _noticeFormatDateTime(DateTime dt) {
  return '${_noticeFormatDate(dt)} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

// ============================================================================
// Markdown 样式
// ============================================================================

MarkdownStyleSheet _noticeMarkdownStyleSheet(
  BuildContext context, {
  required bool compact,
}) {
  final isDark = AppTheme.isDarkContext(context);
  final accentColor = isDark ? AppTheme.accentLight : AppTheme.accentPrimary;
  final baseTextStyle = FluentTheme.of(context).typography.body?.copyWith(
        fontSize: compact ? 13 : 14,
        height: compact ? 1.6 : 1.7,
        color: compact ? AppTheme.textSecondary : AppTheme.textPrimary,
      );
  final secondaryColor =
      compact ? AppTheme.textTertiary : AppTheme.textSecondary;

  return MarkdownStyleSheet(
    p: baseTextStyle,
    pPadding: EdgeInsets.only(bottom: compact ? 8 : 10),
    strong: baseTextStyle?.copyWith(
      color: AppTheme.textPrimary,
      fontWeight: FontWeight.w600,
    ),
    em: baseTextStyle?.copyWith(
      color: secondaryColor,
      fontStyle: FontStyle.italic,
    ),
    // WinUI 排版层级：Subtitle / BodyLarge / BodyStrong
    h1: FluentTheme.of(context).typography.subtitle?.copyWith(
          fontSize: compact ? 18 : 20,
          fontWeight: FontWeight.w600,
          color: AppTheme.textPrimary,
          height: 1.3,
        ),
    h1Padding: const EdgeInsets.only(top: 4, bottom: 12),
    h2: FluentTheme.of(context).typography.bodyLarge?.copyWith(
          fontSize: compact ? 16 : 17,
          fontWeight: FontWeight.w600,
          color: AppTheme.textPrimary,
          height: 1.35,
        ),
    h2Padding: const EdgeInsets.only(top: 8, bottom: 10),
    h3: FluentTheme.of(context).typography.body?.copyWith(
          fontSize: compact ? 14 : 15,
          fontWeight: FontWeight.w600,
          color: AppTheme.textPrimary,
          height: 1.4,
        ),
    h3Padding: const EdgeInsets.only(top: 8, bottom: 6),
    a: baseTextStyle?.copyWith(
      color: accentColor,
      decoration: TextDecoration.underline,
      decorationColor: accentColor.withValues(alpha: 0.55),
    ),
    listIndent: compact ? 22 : 26,
    listBullet: baseTextStyle?.copyWith(color: accentColor),
    listBulletPadding: const EdgeInsets.only(right: 8),
    blockSpacing: compact ? 8 : 10,
    blockquote: baseTextStyle?.copyWith(color: secondaryColor),
    blockquotePadding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
    blockquoteDecoration: BoxDecoration(
      color: AppTheme.subtleFillHover,
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      border: Border(
        left: BorderSide(color: accentColor.withValues(alpha: 0.85), width: 3),
      ),
    ),
    code: baseTextStyle?.copyWith(
      fontSize: compact ? 12 : 13,
      fontFamily: 'Consolas',
      backgroundColor: AppTheme.subtleFillHover,
      color: accentColor,
    ),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: AppTheme.subtleFillHover,
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      border: Border.all(color: AppTheme.borderSubtle),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
    ),
  );
}

Widget _buildNoticeMarkdown(
  BuildContext context, {
  required String content,
  required bool compact,
  required Future<void> Function(String url) onLinkTap,
}) {
  return material.Material(
    color: material.Colors.transparent,
    child: MarkdownBody(
      data: _normalizeNoticeMarkdown(content),
      selectable: true,
      styleSheet: _noticeMarkdownStyleSheet(context, compact: compact),
      onTapLink: (text, href, title) {
        if (href != null) onLinkTap(href);
      },
    ),
  );
}

// ============================================================================
// 通用小组件
// ============================================================================

/// 等级图标磁贴：WinUI 用“语义色 + 淡色底”的圆角方块表达严重程度。
class _NoticeLevelTile extends StatelessWidget {
  final NoticeLevel level;
  final double size;

  const _NoticeLevelTile({required this.level, this.size = 28});

  @override
  Widget build(BuildContext context) {
    final color = _noticeLevelColor(level);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Icon(_noticeLevelIcon(level), size: size * 0.5, color: color),
    );
  }
}

/// WinUI 3 置顶徽标（subtle accent pill）
class _NoticePinnedBadge extends StatelessWidget {
  final double fontSize;

  const _NoticePinnedBadge({this.fontSize = 10});

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.isDarkContext(context)
        ? AppTheme.accentLight
        : AppTheme.accentPrimary;

    return FluentChip(
      icon: FluentIcons.pin,
      label: AppLocalizations.of(context)!.noticePinned,
      color: accent,
      fontSize: fontSize,
      iconSize: fontSize - 1,
    );
  }
}

/// WinUI 3 空/错误占位块：图标 + 标题 + 说明 + 操作，层级克制，不用彩色圆形色块。
class _NoticePlaceholder extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? description;
  final Widget? action;

  const _NoticePlaceholder({
    required this.icon,
    required this.title,
    this.iconColor,
    this.description,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: iconColor ?? AppTheme.textDisabled),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            if (description != null && description!.isNotEmpty) ...[
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  description!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 页面
// ============================================================================

class NoticePage extends StatefulWidget {
  const NoticePage({super.key});

  @override
  State<NoticePage> createState() => _NoticePageState();
}

class _NoticePageState extends State<NoticePage> {
  /// 只记录 id：列表刷新后仍能定位到同一条通知（记对象会拿到旧快照）
  String? _selectedNoticeId;
  bool _useSplitView = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final service = context.read<NoticeService>();
      if (service.notices.isEmpty) {
        service.fetchNotices();
      }
      if (mounted) {
        setState(() {
          _useSplitView =
              context.read<ClientConfigService>().getNoticeUseSplitView();
        });
      }
    });
  }

  AppLocalizations get t => AppLocalizations.of(context)!;

  Notice? _selectedNotice(List<Notice> notices) {
    if (_selectedNoticeId == null) return null;
    for (final notice in notices) {
      if (notice.id == _selectedNoticeId) return notice;
    }
    return null;
  }

  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.tryParse(url.trim());
      if (uri == null || !uri.hasScheme) {
        throw ArgumentError('Invalid URL: $url');
      }
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw StateError('No application is registered to open: $url');
      }
    } catch (e) {
      if (mounted) {
        NotificationManager.of(context)?.showError(
          t.aboutOpenLinkErrorTitle,
          message: t.aboutOpenLinkErrorMessage(e),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    PerformanceMonitorService().trackRebuild('NoticePage');

    return ScaffoldPage(
      header: Consumer<NoticeService>(
        builder: (context, service, _) => SettingsPageHeader(
          title: t.noticePageTitle,
          icon: CustomIcons.FluentIcons.alert_20,
          // WinUI：刷新/视图切换属于页面级命令，统一放在 CommandBar；
          // 窄窗口下自动收进溢出菜单，不挤压标题
          commandBar: CommandBar(
            mainAxisAlignment: MainAxisAlignment.end,
            overflowBehavior: CommandBarOverflowBehavior.dynamicOverflow,
            primaryItems: [
              CommandBarButton(
                icon: const Icon(FluentIcons.refresh),
                label: Text(t.noticeRefresh),
                onPressed: service.isLoading
                    ? null
                    : () => service.fetchNotices(force: true),
              ),
              CommandBarButton(
                icon: Icon(
                  _useSplitView
                      ? FluentIcons.grid_view_medium
                      : FluentIcons.side_panel,
                ),
                label:
                    Text(_useSplitView ? t.noticeViewCards : t.noticeViewSplit),
                onPressed: () {
                  setState(() => _useSplitView = !_useSplitView);
                  context
                      .read<ClientConfigService>()
                      .setNoticeUseSplitView(_useSplitView);
                },
              ),
            ],
          ),
        ),
      ),
      content: Consumer<NoticeService>(
        builder: (context, service, _) {
          if (service.isLoading && service.notices.isEmpty) {
            return const Center(child: ProgressRing());
          }

          if (service.error != null && service.notices.isEmpty) {
            return _buildErrorState(service);
          }

          final notices = service.activeNotices;
          if (notices.isEmpty) return _buildEmptyState();

          return AnimatedSwitcher(
            duration: AppTheme.motionNormal,
            switchInCurve: AppTheme.motionStandard,
            switchOutCurve: AppTheme.motionAccelerate,
            // 默认布局是 Stack.loose + 居中：内容不满一屏时会被垂直居中，
            // 页头下面凭空多出一大截空白。改成撑满 + 左上对齐。
            layoutBuilder: fillingSwitcherLayout,
            child: _useSplitView
                ? _buildSplitViewPane(notices, service)
                : _buildFlowCardsPane(notices, service),
          );
        },
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 分栏视图
  // --------------------------------------------------------------------------

  Widget _buildSplitViewPane(List<Notice> notices, NoticeService service) {
    final selected = _selectedNotice(notices);

    return Padding(
      key: const ValueKey('split'),
      padding: const EdgeInsets.fromLTRB(20, 0, 24, 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 窄窗口下退化为“列表 → 详情”单栏切换，避免两栏都被挤扁
          if (constraints.maxWidth < 720) {
            return selected == null
                ? _buildMasterList(notices, service)
                : _buildDetailCard(selected);
          }

          // WinUI 双栏：列表栏宽度按比例取值并夹在 280~420 之间，
          // 保证行内的等级磁贴 / 标题 / 日期永远有足够空间
          final masterWidth = (constraints.maxWidth * 0.34).clamp(280.0, 420.0);

          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: masterWidth,
                child: _buildMasterList(notices, service),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 28),
                  child: AnimatedSwitcher(
                    duration: AppTheme.motionNormal,
                    switchInCurve: AppTheme.motionStandard,
                    switchOutCurve: AppTheme.motionAccelerate,
                    layoutBuilder: fillingSwitcherLayout,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.02, 0),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: selected == null
                        ? _buildDetailPlaceholder()
                        : _buildDetailCard(selected),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMasterList(List<Notice> notices, NoticeService service) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
          child: _buildSyncInfo(service, notices.length),
        ),
        Expanded(
          child: ScrollEdgeFade(
            topExtent: 20,
            bottomExtent: 20,
            child: SmoothListView.builder(
              config: SmoothScrollConfig.fast,
              padding: const EdgeInsets.only(right: 4, bottom: 8),
              itemCount: notices.length,
              itemBuilder: (context, index) {
                final notice = notices[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: _NoticeListTile(
                    notice: notice,
                    isSelected: _selectedNoticeId == notice.id,
                    onTap: () => setState(() => _selectedNoticeId = notice.id),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDetailPlaceholder() {
    return Container(
      key: const ValueKey('detail-placeholder'),
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderDefault),
      ),
      child: _NoticePlaceholder(
        icon: FluentIcons.reading_mode,
        title: t.noticeSelectPromptTitle,
        description: t.noticeSelectPromptSubtitle,
      ),
    );
  }

  Widget _buildDetailCard(Notice notice) {
    return Container(
      key: ValueKey('detail-${notice.id}'),
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderDefault),
        boxShadow: AppTheme.shadowSm,
      ),
      clipBehavior: Clip.antiAlias,
      child: _NoticeDetailPane(
        notice: notice,
        onLinkTap: _launchUrl,
        onClose: () => setState(() => _selectedNoticeId = null),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 卡片视图
  // --------------------------------------------------------------------------

  Widget _buildFlowCardsPane(List<Notice> notices, NoticeService service) {
    return ScrollEdgeFade(
      key: const ValueKey('cards'),
      child: SmoothSingleChildScrollView(
        config: SmoothScrollConfig.fast,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildSyncInfo(service, notices.length),
            ),
            ...notices.map(
              (notice) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _NoticeExpanderCard(
                  key: ValueKey(notice.id),
                  notice: notice,
                  onLinkTap: _launchUrl,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 状态区
  // --------------------------------------------------------------------------

  Widget _buildSyncInfo(NoticeService service, int count) {
    final parts = <String>[t.noticeListHeader(count)];

    if (service.lastFetchTime != null) {
      final elapsed = DateTime.now().difference(service.lastFetchTime!);
      final String timeAgo;
      if (elapsed.inMinutes < 1) {
        timeAgo = t.noticeJustNow;
      } else if (elapsed.inMinutes < 60) {
        timeAgo = t.noticeMinutesAgo(elapsed.inMinutes);
      } else if (elapsed.inHours < 24) {
        timeAgo = t.noticeHoursAgo(elapsed.inHours);
      } else {
        timeAgo = t.noticeDaysAgo(elapsed.inDays);
      }
      parts.add(t.noticeLastSynced(timeAgo));
    }

    return Row(
      children: [
        Expanded(
          child: Text(
            parts.join('  ·  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: AppTheme.textTertiary),
          ),
        ),
        if (service.isLoading)
          const SizedBox(
            width: 14,
            height: 14,
            child: ProgressRing(strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return _NoticePlaceholder(
      icon: CustomIcons.FluentIcons.getIcon('alert_off_20'),
      title: t.noticeEmpty,
      description: t.noticeEmptySubtitle,
      action: Button(
        onPressed: () =>
            context.read<NoticeService>().fetchNotices(force: true),
        child: Text(t.noticeRefresh),
      ),
    );
  }

  Widget _buildErrorState(NoticeService service) {
    return _NoticePlaceholder(
      icon: FluentIcons.error,
      iconColor: AppTheme.statusError,
      title: t.noticeLoadError,
      description: service.error,
      action: FilledButton(
        onPressed: () => service.fetchNotices(force: true),
        child: Text(t.noticeRetry),
      ),
    );
  }
}

// ============================================================================
// 列表行
// ============================================================================

/// WinUI 3 ListViewItem：subtle hover/press（铺满整行），
/// 选中 = subtle 填充 + 左侧 3×16 accent 指示条。
class _NoticeListTile extends StatelessWidget {
  final Notice notice;
  final bool isSelected;
  final VoidCallback onTap;

  const _NoticeListTile({
    required this.notice,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.isDarkContext(context)
        ? AppTheme.accentLight
        : AppTheme.accentPrimary;

    return FluentInteractiveSurface(
      onPressed: onTap,
      colors: isSelected
          ? FluentInteractionColors(
              rest: AppTheme.subtleFillHover,
              hovered: AppTheme.surfaceCardHover,
              pressed: AppTheme.subtleFillPressed,
            )
          : FluentInteractionColors.subtle(),
      padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
      constraints: const BoxConstraints(minHeight: 64),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 选中指示条
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: AnimatedContainer(
              duration: AppTheme.motionFast,
              curve: AppTheme.motionStandard,
              width: 3,
              height: isSelected ? 16 : 0,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: 9),
          _NoticeLevelTile(level: notice.level, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        notice.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w500,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    if (notice.pinned) ...[
                      const SizedBox(width: 8),
                      Icon(FluentIcons.pin, size: 10, color: accent),
                    ],
                  ],
                ),
                if (notice.summary != null && notice.summary!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    notice.summary!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  _noticeFormatDate(notice.publishedAt ?? notice.createdAt),
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textDisabled,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 详情面板
// ============================================================================

class _NoticeDetailPane extends StatelessWidget {
  final Notice notice;
  final Future<void> Function(String url) onLinkTap;
  final VoidCallback? onClose;

  const _NoticeDetailPane({
    required this.notice,
    required this.onLinkTap,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题区：等级/置顶徽标 → 标题 → 时间
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FluentChip(
                          icon: _noticeLevelIcon(notice.level),
                          label: _noticeLevelLabel(t, notice.level),
                          color: _noticeLevelColor(notice.level),
                          fontSize: 11,
                          iconSize: 10,
                        ),
                        if (notice.pinned)
                          const _NoticePinnedBadge(fontSize: 11),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      notice.title,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          FluentIcons.clock,
                          size: 11,
                          color: AppTheme.textTertiary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _noticeFormatDateTime(
                              notice.publishedAt ?? notice.createdAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onClose != null) ...[
                const SizedBox(width: 12),
                FluentIconButton(
                  icon: CustomIcons.FluentIcons.chrome_close,
                  tooltip: t.noticeCloseDetail,
                  iconSize: 14,
                  onPressed: onClose,
                ),
              ],
            ],
          ),
        ),
        Container(height: 1, color: AppTheme.borderSubtle),
        // 正文
        Expanded(
          child: ScrollEdgeFade(
            topExtent: 18,
            bottomExtent: 18,
            child: SmoothSingleChildScrollView(
              config: SmoothScrollConfig.fast,
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
              child: _buildNoticeMarkdown(
                context,
                content: notice.content ?? '',
                compact: false,
                onLinkTap: onLinkTap,
              ),
            ),
          ),
        ),
        // 底部命令区
        if (notice.link != null && notice.link!.url != null) ...[
          Container(height: 1, color: AppTheme.borderSubtle),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
            child: Row(
              children: [
                FilledButton(
                  onPressed: () => onLinkTap(notice.link!.url!),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(FluentIcons.globe, size: 14),
                      const SizedBox(width: 8),
                      Text(notice.link?.label ?? t.noticeOpenLink),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ============================================================================
// 卡片视图（Expander）
// ============================================================================

/// WinUI 3 `Expander`：header 最小高度 64、整块可点且高亮铺满，
/// chevron 为旋转指示；展开区使用二级卡面 + 顶部分隔线。
class _NoticeExpanderCard extends StatefulWidget {
  final Notice notice;
  final Future<void> Function(String url) onLinkTap;

  const _NoticeExpanderCard({
    super.key,
    required this.notice,
    required this.onLinkTap,
  });

  @override
  State<_NoticeExpanderCard> createState() => _NoticeExpanderCardState();
}

class _NoticeExpanderCardState extends State<_NoticeExpanderCard> {
  bool _isExpanded = false;

  void _toggle() => setState(() => _isExpanded = !_isExpanded);

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;
    final t = AppLocalizations.of(context)!;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: AppTheme.borderDefault),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FluentInteractiveSurface(
            onPressed: _toggle,
            colors: FluentInteractionColors.subtle(),
            borderRadius: BorderRadius.zero,
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            constraints: const BoxConstraints(minHeight: 64),
            child: Row(
              children: [
                _NoticeLevelTile(level: notice.level, size: 30),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              notice.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ),
                          if (notice.pinned) ...[
                            const SizedBox(width: 8),
                            const _NoticePinnedBadge(),
                          ],
                        ],
                      ),
                      if (notice.summary != null &&
                          notice.summary!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          notice.summary!,
                          maxLines: _isExpanded ? 3 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: AppTheme.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _noticeFormatDate(notice.publishedAt ?? notice.createdAt),
                  style: TextStyle(fontSize: 11, color: AppTheme.textDisabled),
                ),
                const SizedBox(width: 8),
                // chevron 交给外层整行处理点击，这里只做旋转指示
                FluentExpanderChevron(expanded: _isExpanded, size: 28),
              ],
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: _buildExpandedContent(notice, t),
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

  Widget _buildExpandedContent(Notice notice, AppLocalizations t) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.subtleFillHover,
        border: Border(top: BorderSide(color: AppTheme.borderSubtle)),
      ),
      padding: const EdgeInsets.fromLTRB(60, 14, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FluentChip(
                icon: _noticeLevelIcon(notice.level),
                label: _noticeLevelLabel(t, notice.level),
                color: _noticeLevelColor(notice.level),
              ),
              const SizedBox(width: 8),
              Text(
                _noticeFormatDateTime(notice.publishedAt ?? notice.createdAt),
                style: TextStyle(fontSize: 11, color: AppTheme.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildNoticeMarkdown(
            context,
            content: notice.content ?? '',
            compact: true,
            onLinkTap: widget.onLinkTap,
          ),
          if (notice.link != null && notice.link!.url != null) ...[
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () => widget.onLinkTap(notice.link!.url!),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(FluentIcons.globe, size: 14),
                  const SizedBox(width: 8),
                  Text(notice.link?.label ?? t.noticeOpenLink),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
