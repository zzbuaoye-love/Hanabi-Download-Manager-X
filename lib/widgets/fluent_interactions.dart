/// WinUI 3 交互控件基元。
///
/// 这里的组件共同遵守一条硬性规则：**交互反馈（hover / pressed / focus）必须铺满
/// 控件的整个命中区域**。历史上本项目多处把高亮画在内层的 `Container` 上，而外层
/// 还包着 `Padding`，于是鼠标已经进入控件、高亮块却比控件本体小一圈，观感割裂。
/// 所有新控件都通过 [FluentInteractiveSurface] 统一处理：内边距画在高亮层内部，
/// 命中区域与高亮区域天然等大。
library;

import 'package:fluent_ui/fluent_ui.dart';

import '../theme/app_theme.dart';

/// [AnimatedSwitcher] 的撑满布局：子项填满可用空间并左上对齐。
///
/// 框架默认的 `AnimatedSwitcher.defaultLayoutBuilder` 是 `Stack(alignment: center)`
/// 配 loose 约束 —— 内容不足一屏时会被**垂直居中**，页头下面凭空空出一大截。
/// 页面级的视图切换几乎都不想要这个行为，统一用这个 builder。
Widget fillingSwitcherLayout(
  Widget? currentChild,
  List<Widget> previousChildren,
) {
  return Stack(
    fit: StackFit.expand,
    alignment: AlignmentDirectional.topStart,
    children: <Widget>[
      ...previousChildren,
      if (currentChild != null) currentChild,
    ],
  );
}

/// 交互态配色。
class FluentInteractionColors {
  const FluentInteractionColors({
    required this.rest,
    required this.hovered,
    required this.pressed,
  });

  final Color rest;
  final Color hovered;
  final Color pressed;

  /// WinUI `SubtleButton`：静置透明，悬停/按下使用 SubtleFill 令牌。
  factory FluentInteractionColors.subtle() {
    return FluentInteractionColors(
      rest: Colors.transparent,
      hovered: AppTheme.subtleFillHover,
      pressed: AppTheme.subtleFillPressed,
    );
  }

  /// WinUI `SettingsCard` / `ListViewItem`：卡面底色 + subtle 变化。
  factory FluentInteractionColors.card() {
    return FluentInteractionColors(
      rest: AppTheme.surfaceCard,
      hovered: AppTheme.surfaceCardHover,
      pressed: AppTheme.surfaceCardPressed,
    );
  }

  /// 语义色调（删除等破坏性操作）：悬停/按下使用极淡的语义底色。
  factory FluentInteractionColors.tinted(Color color) {
    return FluentInteractionColors(
      rest: Colors.transparent,
      hovered: color.withValues(alpha: 0.14),
      pressed: color.withValues(alpha: 0.09),
    );
  }

  /// accent 选中态（如生效中的筛选按钮）。
  factory FluentInteractionColors.accent() {
    return FluentInteractionColors(
      rest: AppTheme.accentPrimary.withValues(alpha: 0.14),
      hovered: AppTheme.accentPrimary.withValues(alpha: 0.20),
      pressed: AppTheme.accentPrimary.withValues(alpha: 0.10),
    );
  }

  Color resolve(Set<WidgetState> states) {
    if (states.isPressed) return pressed;
    if (states.isHovered) return hovered;
    return rest;
  }
}

/// 铺满整个命中区域的 WinUI 交互层。
///
/// - [padding] 应用在高亮层**内部**，因此高亮永远等于控件本体大小。
/// - [onPressed] 为 null 时仍会响应 hover（用于卡片这类“只高亮不可点”的容器），
///   但不会进入 Tab 焦点序列。
/// - 需要根据交互态改变内容（图标/文字颜色）时使用 [builder]，否则用 [child]。
class FluentInteractiveSurface extends StatelessWidget {
  const FluentInteractiveSurface({
    super.key,
    this.child,
    this.builder,
    this.onPressed,
    this.onLongPress,
    this.colors,
    this.padding = EdgeInsets.zero,
    this.borderRadius,
    this.border,
    this.hoverBorder,
    this.constraints,
    this.alignment,
    this.enableHover = true,
    this.pressedScale = 1.0,
    this.semanticLabel,
    this.tooltip,
    this.cursor,
    this.clipBehavior = Clip.none,
  }) : assert(child != null || builder != null,
            'FluentInteractiveSurface 需要 child 或 builder 之一');

  final Widget? child;
  final Widget Function(BuildContext context, Set<WidgetState> states)? builder;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final FluentInteractionColors? colors;
  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;
  final BoxBorder? border;
  final BoxBorder? hoverBorder;
  final BoxConstraints? constraints;
  final AlignmentGeometry? alignment;
  final bool enableHover;

  /// 按下时的缩放（1.0 表示不缩放）。WinUI 只在小尺寸控件上使用轻微缩放。
  final double pressedScale;
  final String? semanticLabel;
  final String? tooltip;
  final MouseCursor? cursor;
  final Clip clipBehavior;

  bool get _interactive => onPressed != null || onLongPress != null;

  @override
  Widget build(BuildContext context) {
    final palette = colors ?? FluentInteractionColors.subtle();
    final radius = borderRadius ?? BorderRadius.circular(AppTheme.radiusSm);

    // 既不可点又不需要 hover 时，不必挂 HoverButton —— 那会为每次鼠标进出
    // 做一次无意义的 setState。（这两个开关对单个实例是恒定的，树形不会抖动。）
    if (!_interactive && !enableHover) {
      Widget plain = Container(
        constraints: constraints,
        alignment: alignment,
        padding: padding,
        clipBehavior: clipBehavior,
        decoration: BoxDecoration(
          color: palette.rest,
          borderRadius: radius,
          border: border,
        ),
        child: child ?? builder!(context, const <WidgetState>{}),
      );
      if (tooltip != null && tooltip!.isNotEmpty) {
        plain = Tooltip(message: tooltip!, child: plain);
      }
      return plain;
    }

    Widget button = HoverButton(
      onPressed: onPressed,
      onLongPress: onLongPress,
      cursor: cursor ??
          (_interactive ? SystemMouseCursors.click : MouseCursor.defer),
      // 不可点击时仍然接收 hover，但不占用焦点序列
      forceEnabled: !_interactive,
      focusEnabled: _interactive,
      semanticLabel: semanticLabel,
      builder: (context, states) {
        final active = enableHover ? states : const <WidgetState>{};
        final resolvedBorder =
            (active.isHovered && hoverBorder != null) ? hoverBorder : border;

        Widget content = AnimatedContainer(
          duration:
              active.isPressed ? AppTheme.motionPress : AppTheme.motionFast,
          curve: AppTheme.motionStandard,
          constraints: constraints,
          alignment: alignment,
          padding: padding,
          clipBehavior: clipBehavior,
          decoration: BoxDecoration(
            color: palette.resolve(active),
            borderRadius: radius,
            border: resolvedBorder,
          ),
          child: child ?? builder!(context, active),
        );

        if (pressedScale != 1.0) {
          content = AnimatedScale(
            scale: active.isPressed ? pressedScale : 1.0,
            duration: AppTheme.motionPress,
            curve: AppTheme.motionStandard,
            child: content,
          );
        }

        if (!_interactive) return content;

        return FocusBorder(
          focused: states.isFocused,
          renderOutside: false,
          child: content,
        );
      },
    );

    if (tooltip != null && tooltip!.isNotEmpty) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}

/// 颜色补间的图标，用于交互态之间的平滑过渡。
class _FadingIcon extends StatelessWidget {
  const _FadingIcon({
    required this.icon,
    required this.color,
    required this.size,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: color),
      duration: AppTheme.motionFast,
      curve: AppTheme.motionStandard,
      builder: (context, animated, _) {
        return Icon(icon, size: size, color: animated ?? color);
      },
    );
  }
}

/// WinUI 3 `SubtleButton` 图标按钮：正方形命中区、subtle 填充、按下微缩。
///
/// [accentColor] 只影响图标颜色（悬停/按下时着色），填充保持中性 —— 这是 WinUI
/// 的做法，避免出现整块彩色方块。破坏性操作可传 [tinted] 让填充带一点语义色。
class FluentIconButton extends StatelessWidget {
  const FluentIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.accentColor,
    this.restColor,
    this.size = 32,
    this.iconSize = 16,
    this.tinted = false,
    this.selected = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  /// 悬停/按下时的图标颜色，默认使用 [AppTheme.textPrimary]。
  final Color? accentColor;

  /// 静置时的图标颜色，默认使用 [AppTheme.textSecondary]。
  final Color? restColor;
  final double size;
  final double iconSize;

  /// 填充是否带 [accentColor] 的极淡色调（用于删除等破坏性操作）。
  final bool tinted;

  /// 处于“已激活”状态（如筛选生效），使用 accent 填充与图标色。
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? AppTheme.textPrimary;
    final rest = restColor ?? AppTheme.textSecondary;
    final disabled = onPressed == null;
    final selectedColor = AppTheme.isDarkContext(context)
        ? AppTheme.accentLight
        : AppTheme.accentPrimary;

    return FluentInteractiveSurface(
      onPressed: onPressed,
      tooltip: tooltip,
      semanticLabel: tooltip,
      colors: selected
          ? FluentInteractionColors.accent()
          : tinted
              ? FluentInteractionColors.tinted(accent)
              : FluentInteractionColors.subtle(),
      constraints: BoxConstraints.tightFor(width: size, height: size),
      alignment: Alignment.center,
      pressedScale: 0.92,
      builder: (context, states) {
        final color = disabled
            ? AppTheme.textDisabled
            : selected
                ? selectedColor
                : (states.isHovered || states.isPressed)
                    ? accent
                    : rest;
        return _FadingIcon(icon: icon, color: color, size: iconSize);
      },
    );
  }
}

/// WinUI 3 标准按钮尺寸的“图标 + 文字”按钮（subtle 变体）。
class FluentSubtleButton extends StatelessWidget {
  const FluentSubtleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.accentColor,
    this.tooltip,
    this.iconSize = 14,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? accentColor;
  final String? tooltip;
  final double iconSize;

  /// 使用 WinUI `Standard` 按钮外观（卡面填充 + 描边），而不是完全透明的 subtle 外观。
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final accent = accentColor ?? AppTheme.textPrimary;
    final disabled = onPressed == null;

    return FluentInteractiveSurface(
      onPressed: onPressed,
      tooltip: tooltip,
      semanticLabel: label,
      pressedScale: 0.98,
      colors: filled
          ? FluentInteractionColors.card()
          : FluentInteractionColors.subtle(),
      border: filled ? Border.all(color: AppTheme.borderDefault) : null,
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 11),
      builder: (context, states) {
        final hovered = states.isHovered || states.isPressed;
        final color = disabled
            ? AppTheme.textDisabled
            : hovered
                ? accent
                : AppTheme.textSecondary;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _FadingIcon(icon: icon, color: color, size: iconSize),
            const SizedBox(width: 8),
            AnimatedDefaultTextStyle(
              duration: AppTheme.motionFast,
              curve: AppTheme.motionStandard,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: color,
              ),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        );
      },
    );
  }
}

/// WinUI 3 徽标（`InfoBadge` 风格的胶囊标签）。
class FluentChip extends StatelessWidget {
  const FluentChip({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.fontSize = 11,
    this.iconSize = 10,
    this.strong = false,
  });

  final String label;
  final IconData? icon;

  /// 语义色，为空时使用中性配色。
  final Color? color;
  final double fontSize;
  final double iconSize;

  /// 实心变体（语义色作为底色，文字反白）。
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final semantic = color ?? AppTheme.textSecondary;
    final background = strong
        ? semantic
        : color == null
            ? AppTheme.subtleFillHover
            : semantic.withValues(alpha: 0.14);
    final foreground = strong ? const Color(0xFFFFFFFF) : semantic;

    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: icon == null ? 8 : 7, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppTheme.radiusRound),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: iconSize, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: foreground,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// WinUI 3 `ProgressBar`：进度变化带补间动画，避免逐帧跳变。
class FluentProgressTrack extends StatelessWidget {
  const FluentProgressTrack({
    super.key,
    required this.value,
    this.height = 4,
    this.color,
    this.trackColor,
    this.indeterminate = false,
    this.duration = AppTheme.motionNormal,
  });

  /// 0.0 ~ 1.0。
  final double value;
  final double height;
  final Color? color;
  final Color? trackColor;
  final bool indeterminate;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(height);

    if (indeterminate) {
      return ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          height: height,
          child: ProgressBar(strokeWidth: height),
        ),
      );
    }

    final track = trackColor ??
        (AppTheme.isDarkContext(context)
            ? AppTheme.bgLayer2.withValues(alpha: 0.6)
            : AppTheme.bgLayer3.withValues(alpha: 0.9));
    final fill = color ?? AppTheme.accentPrimary;

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: radius,
        child: Container(
          height: height,
          color: track,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0)),
            duration: duration,
            curve: AppTheme.motionStandard,
            builder: (context, animated, _) {
              return Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: animated,
                  child: Container(
                    height: height,
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: radius,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// WinUI 3 `Expander` 的展开箭头：旋转 180° 的 chevron，本身是一个 subtle 图标按钮。
class FluentExpanderChevron extends StatelessWidget {
  const FluentExpanderChevron({
    super.key,
    required this.expanded,
    this.onPressed,
    this.size = 32,
  });

  final bool expanded;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final chevron = AnimatedRotation(
      turns: expanded ? 0.5 : 0.0,
      duration: AppTheme.motionNormal,
      curve: AppTheme.motionStandard,
      child: Icon(
        FluentIcons.chevron_down,
        size: 12,
        color: AppTheme.textSecondary,
      ),
    );

    // 由外层行整体负责点击时，这里只做展示，不再叠加一层命中区域
    if (onPressed == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(child: chevron),
      );
    }

    return FluentInteractiveSurface(
      onPressed: onPressed,
      colors: FluentInteractionColors.subtle(),
      constraints: BoxConstraints.tightFor(width: size, height: size),
      alignment: Alignment.center,
      pressedScale: 0.92,
      child: chevron,
    );
  }
}
