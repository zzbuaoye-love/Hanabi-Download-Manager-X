import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

/// Windows 11 `NavigationView` 的页面入场动效常量。
///
/// 对应 XAML 的 `EntranceNavigationTransitionInfo`：内容从下方 28px 处
/// 上移归位，同时淡入；缓动用 Fluent 标准曲线 KeySpline(0.1, 0.9, 0.2, 1.0)。
/// 注意位移是**像素**而不是比例 —— 用 SlideTransition 的分数位移会随页面宽高
/// 变化，窗口越大滑得越远，那不是 WinUI 的观感。
class WinUiEntranceMotion {
  const WinUiEntranceMotion._();

  static const Duration duration = Duration(milliseconds: 300);
  static const Curve curve = Cubic(0.1, 0.9, 0.2, 1.0);
  static const double verticalOffset = 28;

  /// 淡入在前 60% 完成，避免位移还没结束就已经完全不透明。
  static const Interval fadeInterval = Interval(0, 0.6, curve: Curves.easeOut);

  /// 把一段 0→1 的动画包装成 Win11 入场效果。
  static Widget build(Animation<double> animation, Widget child) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, inner) {
        final t = curve.transform(animation.value.clamp(0.0, 1.0));
        return Opacity(
          opacity: fadeInterval.transform(animation.value.clamp(0.0, 1.0)),
          child: Transform.translate(
            offset: Offset(0, verticalOffset * (1 - t)),
            child: inner,
          ),
        );
      },
      child: child,
    );
  }
}

/// 页面切换动画组件 — Windows 11 NavigationView 同款入场
class PageTransition extends StatefulWidget {
  final Widget child;
  final String pageKey;
  final Duration duration;
  final Curve curve;

  const PageTransition({
    super.key,
    required this.child,
    required this.pageKey,
    this.duration = WinUiEntranceMotion.duration,
    this.curve = WinUiEntranceMotion.curve,
  });

  @override
  State<PageTransition> createState() => _PageTransitionState();
}

class _PageTransitionState extends State<PageTransition>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );
    _controller.forward();
  }

  @override
  void didUpdateWidget(PageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (oldWidget.pageKey != widget.pageKey) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: WinUiEntranceMotion.build(_controller, widget.child),
    );
  }
}

/// 带加载动画的页面包装器 - 优化版本
class AnimatedPageWrapper extends StatefulWidget {
  final Widget child;
  final bool isLoading;
  final String? loadingText;

  const AnimatedPageWrapper({
    super.key,
    required this.child,
    this.isLoading = false,
    this.loadingText,
  });

  @override
  State<AnimatedPageWrapper> createState() => _AnimatedPageWrapperState();
}

class _AnimatedPageWrapperState extends State<AnimatedPageWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );

    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );

    if (!widget.isLoading) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(AnimatedPageWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isLoading != widget.isLoading) {
      if (widget.isLoading) {
        _controller.reverse();
      } else {
        _controller.forward();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        children: [
          FadeTransition(
            opacity: _fadeAnimation,
            child: widget.child,
          ),
          if (widget.isLoading)
            Container(
              color: Colors.black.withValues(alpha: 0.3),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const fluent.ProgressRing(),
                    if (widget.loadingText != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        widget.loadingText!,
                        style: fluent.FluentTheme.of(context).typography.body,
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 列表项入场动画 - 优化版本
/// 使用交错动画，限制最大延迟
class ListItemAnimation extends StatefulWidget {
  final Widget child;
  final int index;
  final Duration delay;
  final Duration duration;
  final int maxStaggerIndex;

  const ListItemAnimation({
    super.key,
    required this.child,
    required this.index,
    this.delay = const Duration(milliseconds: 40), // 更快的交错
    this.duration = const Duration(milliseconds: 350),
    this.maxStaggerIndex = 8, // 限制最大交错索引
  });

  @override
  State<ListItemAnimation> createState() => _ListItemAnimationState();
}

class _ListItemAnimationState extends State<ListItemAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    ));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.08), // 更小的位移
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));

    // 限制最大延迟
    final effectiveIndex = widget.index.clamp(0, widget.maxStaggerIndex);
    final delay = widget.delay * effectiveIndex;

    Future.delayed(delay, () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return SlideTransition(
            position: _slideAnimation,
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// 淡入动画组件 - 简单高效
class FadeInAnimation extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Duration delay;
  final Curve curve;

  const FadeInAnimation({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 300),
    this.delay = Duration.zero,
    this.curve = Curves.easeOutCubic,
  });

  @override
  State<FadeInAnimation> createState() => _FadeInAnimationState();
}

class _FadeInAnimationState extends State<FadeInAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: widget.curve,
    );

    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _animation,
        child: widget.child,
      ),
    );
  }
}

/// 缩放淡入动画组件
class ScaleFadeInAnimation extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Duration delay;
  final double beginScale;
  final Curve curve;

  const ScaleFadeInAnimation({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 400),
    this.delay = Duration.zero,
    this.beginScale = 0.9,
    this.curve = Curves.easeOutCubic,
  });

  @override
  State<ScaleFadeInAnimation> createState() => _ScaleFadeInAnimationState();
}

class _ScaleFadeInAnimationState extends State<ScaleFadeInAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.duration,
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );

    _scaleAnimation = Tween<double>(
      begin: widget.beginScale,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: widget.curve,
    ));

    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: Opacity(
              opacity: _fadeAnimation.value,
              child: child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}
