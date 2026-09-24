/// 滚动内容边缘的渐隐（可选叠加模糊）。
///
/// 目的：内容滚到页头下沿时不要被硬切出一条直边，而是柔和地消失。
///
/// 关键约束是**只在真的有内容被滚上去时才出现**：监听滚动位置，离边缘越远遮罩越强，
/// 停在顶部时完全不生效。否则首屏第一行文字会被永久糊掉，还会凭空多出一截空白。
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/widgets.dart';

/// 上/下边缘的遮罩强度（0 = 不生效，1 = 完整强度）。
typedef _EdgeProgress = ({double top, double bottom});

const _EdgeProgress _idle = (top: 0.0, bottom: 0.0);

class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({
    super.key,
    required this.child,
    this.topExtent = 24,
    this.bottomExtent = 0,
    this.blurSigma = 0,
    this.blurLayers = 3,
  });

  final Widget child;

  /// 顶部渐隐区高度，0 表示不处理顶部。
  final double topExtent;

  /// 底部渐隐区高度，0 表示不处理底部。
  final double bottomExtent;

  /// 边缘处的模糊强度。默认 0（只渐隐不模糊）——
  /// 叠层模糊会在边界留下可见的接缝，多数场景下单纯渐隐更干净。
  final double blurSigma;

  /// 渐进模糊的层数，仅在 [blurSigma] > 0 时有意义。
  final int blurLayers;

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  /// 用 ValueNotifier 而不是 setState：滚动时只重建遮罩本身，
  /// 下面的列表子树原样复用，不会因为遮罩变化而整棵重建。
  final ValueNotifier<_EdgeProgress> _progress = ValueNotifier(_idle);

  bool get _hasBlur => widget.blurSigma > 0 && widget.blurLayers > 0;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    // depth != 0 是嵌套在内部的滚动区，与本层边缘无关
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical || !metrics.hasContentDimensions) {
      return false;
    }

    double ratio(double distance, double extent) {
      if (extent <= 0) return 0.0;
      // 量化到 0.05，避免每一帧都触发遮罩重建
      final raw = (distance / extent).clamp(0.0, 1.0);
      return (raw * 20).roundToDouble() / 20;
    }

    final next = (
      top: ratio(metrics.pixels - metrics.minScrollExtent, widget.topExtent),
      bottom:
          ratio(metrics.maxScrollExtent - metrics.pixels, widget.bottomExtent),
    );
    if (next != _progress.value) {
      _progress.value = next;
    }
    return false;
  }

  Shader _buildMaskShader(Rect bounds, _EdgeProgress progress) {
    const opaque = Color(0xFF000000);
    const clear = Color(0x00000000);

    final height = bounds.height;
    final top = height <= 0
        ? 0.0
        : ((widget.topExtent * progress.top) / height).clamp(0.0, 0.45);
    final bottom = height <= 0
        ? 0.0
        : ((widget.bottomExtent * progress.bottom) / height).clamp(0.0, 0.45);

    if (top <= 0 && bottom <= 0) {
      return const LinearGradient(colors: [opaque, opaque])
          .createShader(bounds);
    }

    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: <Color>[
        if (top > 0) clear,
        opaque,
        opaque,
        if (bottom > 0) clear,
      ],
      stops: <double>[
        if (top > 0) 0.0,
        top,
        1 - bottom,
        if (bottom > 0) 1.0,
      ],
    ).createShader(bounds);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.topExtent <= 0 && widget.bottomExtent <= 0) return widget.child;

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: RepaintBoundary(
        child: ValueListenableBuilder<_EdgeProgress>(
          valueListenable: _progress,
          // child 原样透传，滚动时不重建列表子树（也保住滚动位置）
          child: widget.child,
          builder: (context, progress, child) {
            final masked = ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => _buildMaskShader(bounds, progress),
              child: child,
            );

            if (!_hasBlur) return masked;

            // 结构保持稳定：模糊层始终挂着，靠高度归零来"关闭"，
            // 否则树形变化会重建滚动区、丢掉滚动位置。
            return Stack(
              fit: StackFit.passthrough,
              children: [
                masked,
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _EdgeBlur(
                    extent: widget.topExtent * progress.top,
                    sigma: widget.blurSigma,
                    layers: widget.blurLayers,
                    alignment: Alignment.topCenter,
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _EdgeBlur(
                    extent: widget.bottomExtent * progress.bottom,
                    sigma: widget.blurSigma,
                    layers: widget.blurLayers,
                    alignment: Alignment.bottomCenter,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 高度递减、模糊递增的堆叠层，合成"越靠边越糊"的渐进模糊。
class _EdgeBlur extends StatelessWidget {
  const _EdgeBlur({
    required this.extent,
    required this.sigma,
    required this.layers,
    required this.alignment,
  });

  final double extent;
  final double sigma;
  final int layers;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (extent <= 0.5) return const SizedBox.shrink();

    // 高斯模糊叠加时方差相加，单层取 sigma/sqrt(layers)，叠满后接近目标强度
    final stepSigma = sigma / math.sqrt(layers);

    return IgnorePointer(
      child: SizedBox(
        height: extent,
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < layers; i++)
              Align(
                alignment: alignment,
                child: FractionallySizedBox(
                  alignment: alignment,
                  widthFactor: 1,
                  heightFactor: 1 - i / layers,
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: stepSigma,
                        sigmaY: stepSigma,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
