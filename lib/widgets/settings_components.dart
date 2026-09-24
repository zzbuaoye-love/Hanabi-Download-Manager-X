import 'package:fluent_ui/fluent_ui.dart';
import '../theme/app_theme.dart';
import '../utils/fluent_icons.dart' as CustomIcons;
import '../l10n/app_localizations.dart';
import 'fluent_interactions.dart';

/// WinUI 3 设置卡片度量。
/// Windows 11 设置的 SettingsCard：最小高度 68、内容左右留白 16。
/// 这里按本项目稍小的字号收敛到 60，并把卡片间距从原来的 6 放宽到 10 ——
/// 之前的间距既不像“紧邻成组”也不像“分组留白”，视觉上会显得挤。
class _SettingsMetrics {
  static const double cardGap = 10;
  static const double cardMinHeight = 60;
  static const EdgeInsets cardPadding =
      EdgeInsets.symmetric(horizontal: 16, vertical: 12);
  static const double sectionHeaderGap = 10;
}

class RegisteredSetting {
  final String id;
  final String targetId;
  final String title;
  final String subtitle;
  final int tabIndex;

  RegisteredSetting({
    required this.id,
    required this.targetId,
    required this.title,
    required this.subtitle,
    required this.tabIndex,
  });
}

class SettingsSearchRegistry {
  static final Map<String, GlobalKey> keys = {};
  static final Map<String, RegisteredSetting> items = {};

  static GlobalKey getKey(String id) {
    return keys.putIfAbsent(id, () => GlobalKey());
  }

  static void register({
    required String id,
    String? targetId,
    required String title,
    String subtitle = '',
    required int tabIndex,
  }) {
    items[id] = RegisteredSetting(
      id: id,
      targetId: targetId ?? id,
      title: title,
      subtitle: subtitle,
      tabIndex: tabIndex,
    );
  }

  static List<RegisteredSetting> getAllSettings() {
    return items.values.toList();
  }
}

class SettingsTabScope extends InheritedWidget {
  final int tabIndex;
  final bool isRegistrationPhase;

  const SettingsTabScope({
    super.key,
    required this.tabIndex,
    this.isRegistrationPhase = false,
    required super.child,
  });

  static SettingsTabScope? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<SettingsTabScope>();
  }

  @override
  bool updateShouldNotify(SettingsTabScope oldWidget) {
    return tabIndex != oldWidget.tabIndex;
  }
}

/// 设置页面区块 - WinUI 3 (Windows 11 设置) 风格
/// 组标题为卡片外的纯文本，每个子项渲染为独立的 SettingsCard
class SettingsSection extends StatelessWidget {
  final String title;
  final String? searchId;
  final IconData? icon;
  final Widget Function(BuildContext, Color)? iconBuilder;
  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  const SettingsSection({
    super.key,
    this.searchId,
    required this.title,
    this.icon,
    this.iconBuilder,
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: 20),
  }) : assert(icon != null || iconBuilder != null);

  /// 判断是否为调用方插入的纯占位间距（统一替换为 WinUI 卡片间距）
  static bool _isSpacer(Widget child) {
    return child is SizedBox && child.child == null;
  }

  /// 逐层剥开常见的单子透明包装，识别最内层内容
  /// （Opacity/IgnorePointer 用于禁用态、SizedBox 用于拉伸等）
  ///
  /// [pointerBlocked] 表示途中遇到了 IgnorePointer/AbsorbPointer —— 此时即便
  /// 内层是可点击行，也不能把点击提升到卡片本体上（否则禁用态会重新变得可点）。
  static ({Widget inner, bool pointerBlocked}) _unwrapProxies(Widget w) {
    var current = w;
    var blocked = false;
    while (true) {
      if (current is Opacity && current.child != null) {
        current = current.child!;
        continue;
      }
      if (current is IgnorePointer && current.child != null) {
        blocked = blocked || current.ignoring;
        current = current.child!;
        continue;
      }
      if (current is AbsorbPointer && current.child != null) {
        blocked = blocked || current.absorbing;
        current = current.child!;
        continue;
      }
      if (current is SizedBox && current.child != null) {
        current = current.child!;
        continue;
      }
      if (current is ConstrainedBox && current.child != null) {
        current = current.child!;
        continue;
      }
      if (current is RepaintBoundary && current.child != null) {
        current = current.child!;
        continue;
      }
      if (current is KeyedSubtree) {
        current = current.child;
        continue;
      }
      if (current is MouseRegion && current.child != null) {
        current = current.child!;
        continue;
      }
      return (inner: current, pointerBlocked: blocked);
    }
  }

  /// 将子项包装为 Windows 11 设置风格的独立卡片
  ///
  /// 卡片本身负责内边距与 hover/press 高亮，子项只负责排版 —— 这样无论子项是否
  /// 被 Builder/Consumer 之类的包装挡住，高亮都恰好铺满整张卡片。
  static Widget wrapCard(BuildContext context, Widget child) {
    final (:inner, :pointerBlocked) = _unwrapProxies(child);

    // 自带完整视觉样式的内容不再包卡，避免“卡中卡”：
    // - InfoBar 自带 severity 底色与描边
    // - 已设置 decoration 的 Container（彩色提示块等）
    // - 按钮自带描边与底色
    if (inner is InfoBar ||
        inner is BaseButton ||
        (inner is Container && inner.decoration != null)) {
      return SizedBox(width: double.infinity, child: child);
    }

    // 可点击行：把点击/焦点交给卡片本体，高亮与卡片边界完全一致
    if (inner is SettingsLinkItem && !pointerBlocked) {
      return SettingsCardSurface(
        onPressed: inner.onPressed,
        child: child,
      );
    }

    return SettingsCardSurface(child: child);
  }

  @override
  Widget build(BuildContext context) {
    final tabScope = SettingsTabScope.of(context);
    final isReg = tabScope?.isRegistrationPhase ?? false;

    if (searchId != null) {
      if (tabScope != null) {
        SettingsSearchRegistry.register(
          id: searchId!,
          targetId: 'section:$searchId',
          title: title,
          tabIndex: tabScope.tabIndex,
        );
      }
    }

    final searchKey = (searchId != null && !isReg)
        ? SettingsSearchRegistry.getKey('section:$searchId')
        : null;

    final isDark = AppTheme.isDarkContext(context);
    final headerAccent = isDark ? AppTheme.accentLight : AppTheme.accentPrimary;

    final cardChildren = <Widget>[];
    for (final child in children) {
      if (_isSpacer(child)) continue;
      if (cardChildren.isNotEmpty) {
        cardChildren.add(const SizedBox(height: _SettingsMetrics.cardGap));
      }
      cardChildren.add(wrapCard(context, child));
    }

    return Container(
      key: searchKey,
      margin: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // WinUI 3: 组标题位于卡片之外（BodyStrong 文本）
          Padding(
            padding: const EdgeInsets.fromLTRB(
                2, 0, 2, _SettingsMetrics.sectionHeaderGap),
            child: Row(
              children: [
                if (iconBuilder != null)
                  iconBuilder!(context, headerAccent)
                else
                  Icon(icon, size: 14, color: headerAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FluentTheme.of(context).typography.body?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                          fontSize: 13.5,
                        ),
                  ),
                ),
              ],
            ),
          ),
          ...cardChildren,
        ],
      ),
    );
  }
}

/// WinUI 3 SettingsCard 表面：圆角 4、卡片描边、卡片底色。
///
/// 内边距、最小高度、hover/press 高亮全部由这一层负责，子项不再自绘背景 ——
/// 高亮区域因此永远与卡片本体等大（历史上子项自绘背景会比卡片小一圈）。
class SettingsCardSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double minHeight;
  final VoidCallback? onPressed;

  const SettingsCardSurface({
    super.key,
    required this.child,
    this.padding = _SettingsMetrics.cardPadding,
    this.minHeight = _SettingsMetrics.cardMinHeight,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FluentInteractiveSurface(
      onPressed: onPressed,
      // WinUI 的 SettingsCard 只有 IsClickEnabled 时才有 hover 反馈。
      // 给普通开关/下拉行也加高亮会有副作用：改动任意一项导致行高变化时，
      // 布局位移会让鼠标"穿过"其它卡片，触发一串本不该出现的高亮闪动。
      enableHover: onPressed != null,
      colors: FluentInteractionColors.card(),
      border: Border.all(color: AppTheme.borderDefault),
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      padding: padding,
      clipBehavior: Clip.antiAlias,
      constraints: BoxConstraints(
        minWidth: double.infinity,
        minHeight: minHeight,
      ),
      child: child,
    );
  }
}

/// 设置项组件
class SettingsItem extends StatefulWidget {
  final String title;
  final String? searchId;
  final String? subtitle;
  final Widget trailing;
  final bool stackOnNarrow;
  final double narrowBreakpoint;
  final AlignmentGeometry stackedTrailingAlignment;
  final bool showBetaBadge;

  const SettingsItem({
    super.key,
    this.searchId,
    required this.title,
    this.subtitle,
    required this.trailing,
    this.stackOnNarrow = false,
    this.narrowBreakpoint = 760,
    this.stackedTrailingAlignment = Alignment.centerLeft,
    this.showBetaBadge = false,
  });

  @override
  State<SettingsItem> createState() => _SettingsItemState();
}

class _SettingsItemState extends State<SettingsItem> {
  Widget _buildTitleContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                // WinUI 3 SettingsCard: 标题为 Body（常规字重）
                style: FluentTheme.of(context).typography.body?.copyWith(
                      fontWeight: FontWeight.w400,
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                    ),
              ),
            ),
            if (widget.showBetaBadge) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.accentPrimary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: AppTheme.accentPrimary.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  'Beta',
                  style: FluentTheme.of(context).typography.caption?.copyWith(
                        color: AppTheme.accentPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 10,
                      ),
                ),
              ),
            ],
          ],
        ),
        if (widget.subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            widget.subtitle!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: FluentTheme.of(context).typography.caption?.copyWith(
                  color: AppTheme.textTertiary,
                  fontSize: 12,
                  height: 1.25,
                ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabScope = SettingsTabScope.of(context);
    final isReg = tabScope?.isRegistrationPhase ?? false;

    if (widget.searchId != null) {
      if (tabScope != null) {
        SettingsSearchRegistry.register(
          id: widget.searchId!,
          targetId: 'item:${widget.searchId!}',
          title: widget.title,
          subtitle: widget.subtitle ?? '',
          tabIndex: tabScope.tabIndex,
        );
      }
    }

    final searchKey = (widget.searchId != null && !isReg)
        ? SettingsSearchRegistry.getKey('item:${widget.searchId!}')
        : null;

    // 排版而已：卡面底色、内边距与 hover/press 高亮全部由 SettingsCardSurface 负责，
    // 因此高亮永远铺满整张卡片，不会出现比卡片小一圈的高亮块。
    return KeyedSubtree(
      key: searchKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = widget.stackOnNarrow &&
              constraints.maxWidth < widget.narrowBreakpoint;

          if (compact) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTitleContent(context),
                const SizedBox(height: 10),
                Align(
                  alignment: widget.stackedTrailingAlignment,
                  child: widget.trailing,
                ),
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: _buildTitleContent(context)),
              const SizedBox(width: 16),
              widget.trailing,
            ],
          );
        },
      ),
    );
  }
}

/// WinUI 3 可点击设置行（整卡可点）
///
/// 只负责排版：点击、焦点与 hover/press 高亮由外层 [SettingsCardSurface] 承担
/// （见 [SettingsSection.wrapCard]），因此高亮与卡片边界完全一致。
class SettingsLinkItem extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? leadingIcon;
  final Widget? trailing;
  final VoidCallback onPressed;

  const SettingsLinkItem({
    super.key,
    required this.title,
    this.subtitle,
    this.leadingIcon,
    this.trailing,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final typography = FluentTheme.of(context).typography;

    return Row(
      children: [
        if (leadingIcon != null) ...[
          Icon(leadingIcon, size: 16, color: AppTheme.textSecondary),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: typography.body?.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AppTheme.textPrimary,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: typography.caption?.copyWith(
                    fontSize: 12,
                    height: 1.25,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 16),
        trailing ??
            Icon(
              FluentIcons.chevron_right,
              size: 12,
              color: AppTheme.textTertiary,
            ),
      ],
    );
  }
}

/// 危险操作区域
class DangerZone extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  const DangerZone({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: 20),
  });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;

    final cardChildren = <Widget>[];
    for (final child in children) {
      if (SettingsSection._isSpacer(child)) continue;
      if (cardChildren.isNotEmpty) {
        cardChildren.add(const SizedBox(height: _SettingsMetrics.cardGap));
      }
      cardChildren.add(SettingsSection.wrapCard(context, child));
    }

    return Container(
      margin: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                2, 0, 2, _SettingsMetrics.sectionHeaderGap),
            child: Row(
              children: [
                Icon(
                  CustomIcons.FluentIcons.warning,
                  size: 14,
                  color: AppTheme.statusError,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.settingsDangerZoneTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FluentTheme.of(context).typography.body?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                          fontSize: 13.5,
                        ),
                  ),
                ),
              ],
            ),
          ),
          ...cardChildren,
        ],
      ),
    );
  }
}

/// 页面头部组件
class SettingsPageHeader extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Widget Function(BuildContext, Color)? iconBuilder;
  final Widget? commandBar;

  const SettingsPageHeader({
    super.key,
    required this.title,
    this.icon,
    this.iconBuilder,
    this.commandBar,
  }) : assert(icon != null || iconBuilder != null);

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDarkContext(context);
    // WinUI 3: 扁平化的图标磁贴（无渐变、无描边），标题保持 Title 层级
    return PageHeader(
      commandBar: commandBar,
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.accentPrimary
                  .withValues(alpha: isDark ? 0.16 : 0.10),
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: iconBuilder != null
                ? iconBuilder!(context,
                    isDark ? AppTheme.accentLight : AppTheme.accentPrimary)
                : Icon(
                    icon,
                    size: 16,
                    color:
                        isDark ? AppTheme.accentLight : AppTheme.accentPrimary,
                  ),
          ),
          const SizedBox(width: 12),
          Text(title),
        ],
      ),
    );
  }
}
