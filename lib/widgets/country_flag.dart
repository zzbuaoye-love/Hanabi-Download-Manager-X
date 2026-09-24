/// 国旗小图标（4:3 位图 + 优雅降级）。
///
/// 资源位于 `assets/flags/<小写 ISO 3166-1 alpha-2>.png`（60x45，共 260 个）。
/// 该组件**永远不会抛异常**：无论国家码为空、格式非法，还是资源包里根本没有
/// 对应的旗帜（例如 `XK`），都会退化成一个中性的占位符，绝不影响卡片布局。
library;

import 'package:fluent_ui/fluent_ui.dart';

import '../theme/app_theme.dart';
import '../utils/fluent_icons.dart' as CustomIcons;

class CountryFlag extends StatelessWidget {
  const CountryFlag({
    super.key,
    required this.countryCode,
    this.width = 18,
    this.radius = 3,
  });

  /// ISO 3166-1 alpha-2，大小写不敏感；为 null / 空 / 非法时走降级分支。
  final String? countryCode;

  final double width;
  final double radius;

  /// 资源是 60x45 的 4:3 位图，高度必须跟着宽度走，否则会被拉伸。
  static const double _aspectRatio = 0.75;

  double get _height => width * _aspectRatio;

  /// 规范化为大写两位字母；任何不满足的输入都返回 null。
  String? get _normalizedCode {
    final raw = countryCode?.trim();
    if (raw == null || raw.length != 2) return null;

    final upper = raw.toUpperCase();
    for (var i = 0; i < upper.length; i++) {
      final unit = upper.codeUnitAt(i);
      if (unit < 0x41 || unit > 0x5A) return null; // 非 A-Z
    }
    return upper;
  }

  @override
  Widget build(BuildContext context) {
    final code = _normalizedCode;

    // 连国家码都没有：直接给一个地球仪字形，不画卡片底色和描边。
    if (code == null) {
      return _buildGlobePlaceholder();
    }

    return SizedBox(
      width: width,
      height: _height,
      child: Container(
        // 描边画在图片**上层**：JP / CH 这类大面积白底旗帜在浅色主题下
        // 若没有这条 hairline 会直接和背景融为一体。
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: AppTheme.borderSubtle, width: 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Image.asset(
            'assets/flags/${code.toLowerCase()}.png',
            width: width,
            height: _height,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            // 资源缺失（未在 pubspec 声明 / 旗帜集里没有该国）时的兜底。
            errorBuilder: (context, error, stackTrace) => _buildCodeChip(code),
          ),
        ),
      ),
    );
  }

  /// 有合法国家码但没有对应图片时的文字色块。
  ///
  /// 只负责底色与文字，描边由外层的 [Container.foregroundDecoration] 提供，
  /// 因此不会出现「双层描边」。
  Widget _buildCodeChip(String code) {
    return Container(
      width: width,
      height: _height,
      alignment: Alignment.center,
      color: AppTheme.bgLayer2,
      child: Text(
        code,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: TextStyle(
          fontSize: 8,
          height: 1.0,
          fontWeight: FontWeight.w600,
          color: AppTheme.textTertiary,
        ),
      ),
    );
  }

  /// 完全未知时的地球仪占位符。
  ///
  /// 尺寸被夹紧到旗帜位图的外框内，保证同一行里「有旗帜」和「无旗帜」
  /// 的基线与行高完全一致，也不会把 badge 撑高。
  Widget _buildGlobePlaceholder() {
    final preferred = width * 0.8;
    final iconSize = preferred < _height ? preferred : _height;

    return SizedBox(
      width: width,
      height: _height,
      child: Center(
        child: Icon(
          CustomIcons.FluentIcons.globe_20,
          size: iconSize,
          color: AppTheme.textTertiary,
        ),
      ),
    );
  }
}
