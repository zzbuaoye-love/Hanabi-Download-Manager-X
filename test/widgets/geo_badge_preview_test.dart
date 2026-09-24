@Tags(['preview'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 徽标视觉预览：把中间那对细长箭头渲染成 PNG，便于在不整包构建 Windows
/// 应用的前提下核对几何比例（杆长、杆粗、箭头开口、上下间距）。
///
/// 这不是断言型测试，而是一个「看一眼」工具，因此打了 preview 标签，
/// 默认的 `flutter test` 不会跑它：
///   flutter test --run-skipped --tags preview test/widgets/geo_badge_preview_test.dart
void main() {
  testWidgets('render traffic arrows preview', (tester) async {
    final key = GlobalKey();

    // 放大 12 倍渲染，才能看清 1.2px 杆粗在小尺寸下的实际观感。
    const double scale = 12;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 1),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: Container(
              color: const Color(0xFF3A3540), // 近似卡片底色
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 活跃态：上行强调蓝 / 下行成功绿
                  Transform.scale(
                    scale: scale,
                    alignment: Alignment.topLeft,
                    child: CustomPaint(
                      size: const Size(26, 11),
                      painter: _PreviewPainter(
                        uplinkColor: const Color(0xFF60CDFF),
                        downlinkColor: const Color(0xFF6CCB5F),
                      ),
                    ),
                  ),
                  SizedBox(height: 11 * scale + 24),
                  // 空闲停留态：统一灰
                  Transform.scale(
                    scale: scale,
                    alignment: Alignment.topLeft,
                    child: CustomPaint(
                      size: const Size(26, 11),
                      painter: _PreviewPainter(
                        uplinkColor: const Color(0x8AFFFFFF),
                        downlinkColor: const Color(0x8AFFFFFF),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

    final out = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}geo_arrows_preview.png',
    );
    await out.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('PREVIEW_PNG=${out.path}');
  });
}

/// [_TrafficArrowsPainter] 的逐行复制。
///
/// 原件是 `geo_route_badge.dart` 的私有类，跨文件取不到；预览工具需要的是
/// 「画出来长什么样」，复制这段几何逻辑比为了预览把实现类公开更划算——
/// 一旦两边不同步，预览失真会立刻被肉眼发现。
class _PreviewPainter extends CustomPainter {
  const _PreviewPainter({
    required this.uplinkColor,
    required this.downlinkColor,
  });

  final Color uplinkColor;
  final Color downlinkColor;

  static const double _stroke = 1.2;
  static const double _headLen = 3.6;
  static const double _headHalf = 2.7;

  @override
  void paint(Canvas canvas, Size size) {
    _arrow(canvas, size,
        y: size.height * 0.22, color: uplinkColor, pointsRight: true);
    _arrow(canvas, size,
        y: size.height * 0.78, color: downlinkColor, pointsRight: false);
  }

  void _arrow(Canvas canvas, Size size,
      {required double y, required Color color, required bool pointsRight}) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = _stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final double left = _stroke / 2;
    final double right = size.width - _stroke / 2;
    final double tipX = pointsRight ? right : left;
    final double tailX = pointsRight ? left : right;
    final double headDir = pointsRight ? -_headLen : _headLen;

    final path = Path()
      ..moveTo(tailX, y)
      ..lineTo(tipX, y)
      ..moveTo(tipX + headDir, y - _headHalf)
      ..lineTo(tipX, y)
      ..lineTo(tipX + headDir, y + _headHalf);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.uplinkColor != uplinkColor || old.downlinkColor != downlinkColor;
}
