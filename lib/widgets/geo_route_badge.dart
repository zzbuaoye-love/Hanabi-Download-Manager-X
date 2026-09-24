/// 下载卡片上的「出口国 → 目标服务器国」归属地徽标。
///
/// 视觉上与 `download_list.dart` 里的其它 header badge 完全同构
/// （11px caption / 4px 圆角 / 1px hairline / alpha 0.12 填充 + 0.28 描边），
/// 因为它就挂在同一个 `Wrap` 里。
///
/// 交互契约：
/// * 每次 build 都会调用 [GeoIpService.requestRouteForUrl]，该方法自身做了
///   去重 + TTL + 队列限流，因此在高频重建的下载卡片里也是安全的。
/// * 读取走 [GeoIpService.routeForUrl]，纯同步、无 IO。
/// * 徽标主体无状态。唯一有状态的是 [_TrafficArrows]，它只在「有流量 ↔ 无流量」
///   切换的瞬间跑一次 240ms 透明度补间，静止时不持有任何动画，
///   不会拖累所在列表的光栅化。
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/geo_route.dart';
import '../services/geo_ip_service.dart';
import '../theme/app_theme.dart';
import '../utils/fluent_icons.dart' as CustomIcons;
import 'country_flag.dart';

/// 徽标配色：填充/描边共用 [seed]，文字与字形用 [text]。
///
/// 两者不一致是刻意的——沿用 `_buildHttpVersionBadge` 的既有做法
/// （accentPrimary 打底、accentLight 写字），否则深色主题下文字会糊在底色里。
class _GeoBadgeTone {
  const _GeoBadgeTone({required this.seed, required this.text});

  final Color seed;
  final Color text;
}

class GeoRouteBadge extends StatelessWidget {
  const GeoRouteBadge({
    super.key,
    required this.url,
    required this.downloadSpeed,
  });

  /// 下载任务的原始 URL（服务内部按 host 归并缓存）。
  final String url;

  /// 当前下载速率，单位 byte/s。<= 0 时不渲染下行信息。
  final double downloadSpeed;

  /// 单行布局的宽度上限，避免在窄窗口下把卡片撑宽。
  static const double _maxWidth = 260;

  /// 旗帜宽度；配合 4:3 得到 15x11.25，与中间箭头区（11px 高）等高，
  /// 三个元素在同一条视觉基线上，不会一高一低。
  static const double _flagWidth = 15;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final geo = context.watch<GeoIpService>();

    // 即发即忘：服务内部保证去重与限流，且不会在 build 期间同步 notify。
    geo.requestRouteForUrl(url);
    final route = geo.routeForUrl(url);

    // 用 switch 表达式而非语句：编译期强制穷举，将来 GeoLookupState
    // 新增取值时这里会直接报错，而不是悄悄漏掉一个分支。
    return switch (route.state) {
      GeoLookupState.idle => const SizedBox.shrink(),

      // 正常路径下卡片那一层的开关已经把徽标摘掉了，这里只是防御性兜底。
      GeoLookupState.disabled => Tooltip(
          message: t.geoBadgeDisabledHint,
          child: _glyphOnlyBadge(context),
        ),
      GeoLookupState.resolving => Tooltip(
          message: t.geoBadgeResolving,
          child: _labelledBadge(
            context,
            tone: _resolvingTone,
            label: t.geoBadgeResolving,
          ),
        ),

      // 定位失败是常态（内网、DNS 污染、接口限流），保持中性配色，
      // 绝不使用 statusError——那会让用户以为下载本身出了问题。
      GeoLookupState.failed => Tooltip(
          message: _tooltipMessage(t, route),
          child: _labelledBadge(
            context,
            tone: _neutralTone,
            label: t.geoBadgeFailed,
          ),
        ),
      GeoLookupState.ready => Tooltip(
          message: _tooltipMessage(t, route),
          child: _routeBadge(context, route),
        ),
    };
  }

  // ============ 配色 ============

  _GeoBadgeTone get _resolvingTone => _GeoBadgeTone(
        seed: AppTheme.textTertiary,
        text: AppTheme.textDisabled,
      );

  _GeoBadgeTone get _neutralTone => _GeoBadgeTone(
        seed: AppTheme.textTertiary,
        text: AppTheme.textTertiary,
      );

  _GeoBadgeTone _readyTone(GeoRoute route) {
    // 走代理时用强调色 + 盾牌字形，和直连在一眼之内就能区分开。
    if (route.viaProxy) {
      return _GeoBadgeTone(
        seed: AppTheme.accentPrimary,
        text: AppTheme.accentLight,
      );
    }
    return _GeoBadgeTone(
      seed: AppTheme.textTertiary,
      text: AppTheme.textSecondary,
    );
  }

  // ============ 外壳 ============

  /// 与卡片上其它 header badge 逐像素一致的外壳。
  Widget _shell(BuildContext context,
      {required _GeoBadgeTone tone, required Widget child}) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: tone.seed.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: tone.seed.withValues(alpha: 0.28),
            width: 1,
          ),
        ),
        child: child,
      ),
    );
  }

  TextStyle? _codeStyle(BuildContext context, Color color) {
    return FluentTheme.of(context).typography.caption?.copyWith(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        );
  }

  /// 只有一个地球仪字形的徽标（徽标被关闭时的兜底形态）。
  Widget _glyphOnlyBadge(BuildContext context) {
    return _shell(
      context,
      tone: _neutralTone,
      child: Icon(
        CustomIcons.FluentIcons.globe_20,
        size: 11,
        color: _neutralTone.text,
      ),
    );
  }

  /// 地球仪 + 一行文字（定位中 / 定位失败）。
  Widget _labelledBadge(
    BuildContext context, {
    required _GeoBadgeTone tone,
    required String label,
  }) {
    return _shell(
      context,
      tone: tone,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            CustomIcons.FluentIcons.globe_20,
            size: 11,
            color: tone.text,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: _codeStyle(context, tone.text),
            ),
          ),
        ],
      ),
    );
  }

  // ============ 主形态：出口国 → 目标国 ============

  Widget _routeBadge(BuildContext context, GeoRoute route) {
    final tone = _readyTone(route);
    final showDownlink = downloadSpeed > 0;

    // 走代理不再另画一个盾形图标：徽标整体已经换成强调色调（见 [_readyTone]），
    // 一眼就能与直连区分，再塞一个字形只会把本就很窄的徽标撑长。
    // 代理的具体地址在 tooltip 里。
    final children = <Widget>[];

    // 出口侧
    children.addAll(_endpointSlice(context, route.egress, tone));

    // 中间那对细长箭头同时承担两件事：横贯两端表达路由方向，
    // 以及像手机状态栏那样指示上下行流量。空闲时淡出，占位恒定。
    //
    // 间距给到 6：箭头是细线条，靠太近会和旗帜的实心色块糊在一起。
    children.add(const SizedBox(width: 5));
    children.add(_TrafficArrows(
      active: showDownlink,
      speed: downloadSpeed,
    ));
    children.add(const SizedBox(width: 5));

    // 目标侧
    children.addAll(_endpointSlice(context, route.target, tone));

    return _shell(
      context,
      tone: tone,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      ),
    );
  }

  /// 一侧端点 = 一面旗帜，没有别的。
  ///
  /// 刻意不再画国家码文字：旗帜本身已经把国家说清楚了，再补一个 "JP" 属于
  /// 同义重复，还会把徽标撑长。ISO 代码、IP、ASN 全部留在 tooltip 里。
  List<Widget> _endpointSlice(
      BuildContext context, GeoEndpoint endpoint, _GeoBadgeTone tone) {
    // 本机 / 内网端点不是「查不到」，而是「本来就没有归属国」，
    // 用一台设备的字形把这两种情况区分开，否则用户会以为定位失败了。
    //
    // 判定直接读 [GeoEndpoint.isLocal]——由服务层给出，不在这里靠 IP 反推：
    // 出口侧本来就没有 IP 可推，一推就只能拿本机公网出口去充数，
    // 而那正是「本地下载被标成从代理落地国发起」那个 bug 的来源。
    if (endpoint.isLocal) {
      // 只锁宽不锁高。
      //
      // 之前锁了 `height: _flagWidth * 0.75`（= 11.25）却把字形放到 15px，
      // 图标比盒子高，撑出去之后看着就是没对齐——「小电脑没居中」正是这么来的。
      // 交给 Row 的 crossAxisAlignment.center 去对齐，字形多高都能落在中线上。
      //
      // 13px 是相对旗帜（15x11.25 的实心色块）配平出来的：线框图形墨量本就比
      // 实心块轻，画到和旗帜等高会显得单薄，略大一点才压得住。
      return <Widget>[
        SizedBox(
          width: _flagWidth,
          child: Center(
            child: Icon(
              CustomIcons.FluentIcons.desktop_16,
              size: 13,
              color: tone.text,
            ),
          ),
        ),
      ];
    }

    return <Widget>[
      CountryFlag(
        countryCode: endpoint.hasCountry ? endpoint.countryCode : null,
        width: _flagWidth,
        radius: 2,
      ),
    ];
  }

  // ============ Tooltip ============

  /// fluent_ui 的 [Tooltip] 只接受纯文本 `message`，多行靠 `\n` 拼。
  String _tooltipMessage(AppLocalizations t, GeoRoute route) {
    if (route.state == GeoLookupState.resolving) {
      return t.geoBadgeResolving;
    }

    final lines = <String>[
      '${t.geoBadgeTooltipEgress}: ${_describeEndpoint(t, route.egress)}',
      '${t.geoBadgeTooltipTarget}: ${_describeEndpoint(t, route.target)}',
      _describeProxy(t, route),
      _describeDirection(t),
      route.fromOfflineDb
          ? t.geoBadgeSourceOfflineTag
          : t.geoBadgeSourceOnlineTag,
    ];

    // 规则型代理：出口国只是近似值，必须说清楚，不能让用户当成实测事实。
    if (route.egress.approximate) {
      lines.add(t.geoBadgeEgressRuleBased);
    }

    // 失败时把原始技术原因附在最后（与 _buildHttpDecisionBadge 的做法一致）。
    final error = route.error?.trim();
    if (route.state == GeoLookupState.failed &&
        error != null &&
        error.isNotEmpty) {
      lines.add(error);
    }

    return lines.join('\n');
  }

  String _describeEndpoint(AppLocalizations t, GeoEndpoint endpoint) {
    // 本地端点不是「查不到国家」，如实说成本机 / 内网。
    if (endpoint.isLocal) {
      final ip = endpoint.ip?.trim();
      return ip == null || ip.isEmpty
          ? t.geoBadgeLocalEndpoint
          : '${t.geoBadgeLocalEndpoint} · $ip';
    }

    final parts = <String>[
      endpoint.hasCountry
          ? endpoint.countryCode!.toUpperCase()
          : t.geoBadgeUnknownCountry,
    ];

    for (final value in [
      endpoint.countryName,
      endpoint.ip,
      endpoint.asnOrg,
    ]) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        parts.add(trimmed);
      }
    }

    return parts.join(' · ');
  }

  String _describeProxy(AppLocalizations t, GeoRoute route) {
    if (!route.viaProxy) return t.geoBadgeTooltipDirect;

    final label = route.proxyLabel?.trim();
    if (label == null || label.isEmpty) return t.geoBadgeTooltipVia;
    return '${t.geoBadgeTooltipVia}: $label';
  }

  String _describeDirection(AppLocalizations t) {
    final base = '${t.geoBadgeUplink} / ${t.geoBadgeDownlink}';
    if (downloadSpeed <= 0) return base;
    return '$base ${formatGeoSpeed(downloadSpeed)}';
  }
}

/// 夹在两面旗帜中间的一对细长箭头：上面一条指向目标（上行），
/// 下面一条从目标折返（下行）。
///
/// 为什么是手绘而不是字体图标：`arrow_right_12` 这类字形是为「独立按钮」
/// 设计的，箭杆短、头部粗，在 11px 下挤成两个墨点，既看不出方向也谈不上好看。
/// 这里需要的是横贯两端的**细长**箭头——长度、杆粗、头部比例都得单独调，
/// 而且两个方向要能各自点亮，一个整体字形（如 arrow_swap）做不到。
///
/// **尺寸恒定是硬约束**：画布是固定的 [SizedBox]，明暗与显隐只改透明度，
/// 绝不改变布局尺寸。否则下载一暂停徽标就会缩一下，把同一个 `Wrap` 里
/// 其它徽标全部推位移。
///
/// 上行没有真实速率指标（全应用都没有上传速率），所以这里只表达「该方向此刻
/// 有流量」——下载进行时出站方向确实有请求与 ACK 在跑，这是事实而非臆造。
class _TrafficArrows extends StatelessWidget {
  const _TrafficArrows({required this.active, required this.speed});

  /// 当前是否有数据在传输。
  final bool active;

  /// 当前下载速率，byte/s。用来决定箭头有多亮。
  final double speed;

  /// 恒定占位尺寸。任何状态下都占这么大——这是「不改变控件尺寸」的实现基础。
  ///
  /// 26 → 18 → 13 → 10 一路收敛。要的是「两面旗之间的连接符」，
  /// 不是「横贯徽标的长杆」。
  static const double _slotWidth = 10;
  static const double _slotHeight = 11;

  /// 亮度映射的速度区间。
  ///
  /// 用对数刻度：真实下载速度跨越 KB/s 到几百 MB/s 好几个数量级，
  /// 线性映射会把绝大多数日常速度全挤在最暗的一小段里，看不出变化。
  static const double _dimSpeed = 16 * 1024; // 16 KB/s 以下恒为最暗
  static const double _brightSpeed = 32 * 1024 * 1024; // 32 MB/s 以上恒为最亮

  /// 亮度补间时长。比进度回调的间隔略长，让明暗过渡是"呼吸"而不是"跳变"。
  static const Duration _glowDuration = Duration(milliseconds: 420);

  /// 速率 → 亮度系数 0..1。
  static double _intensityFor(double bytesPerSecond) {
    if (bytesPerSecond <= _dimSpeed) return 0;
    if (bytesPerSecond >= _brightSpeed) return 1;
    return math.log(bytesPerSecond / _dimSpeed) /
        math.log(_brightSpeed / _dimSpeed);
  }

  @override
  Widget build(BuildContext context) {
    final double intensity = active ? _intensityFor(speed) : 0;

    // 只补间颜色，不补间尺寸：静止时没有任何动画在跑，滚动列表不受影响。
    //
    // 「繁星」的闪烁不是靠驱动一个假动画做出来的，而是速率本身在真实波动——
    // 每次进度回调带来新的速率，这里用一段 420ms 的补间把它滑过去，
    // 于是快的时候亮、慢的时候暗，多个任务各自明灭。
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: intensity),
      duration: _glowDuration,
      curve: AppTheme.motionStandard,
      builder: (context, value, _) {
        return CustomPaint(
          size: const Size(_slotWidth, _slotHeight),
          painter: _TrafficArrowsPainter(
            uplinkColor: _glow(AppTheme.accentLight, value, isUplink: true),
            downlinkColor:
                _glow(AppTheme.statusSuccess, value, isUplink: false),
          ),
        );
      },
    );
  }

  /// 按亮度系数在「暗淡灰」与「本方向的强调色」之间取色。
  ///
  /// 亮度为 0 时**不是透明**，而是一层可见的暗灰：暂停 / 已完成的卡片中间
  /// 若整块空掉，徽标看着像缺了零件。位置和方向一直在，只是"没在流动"。
  /// 也不用 × 之类的符号——那对"已完成"的任务会误读成出错。
  ///
  /// 上行整体压暗一档：这条链路上出站的只有请求与 TCP ACK，
  /// 流量本就比下行小一到两个数量级，让它跟下行一样亮是在骗人。
  Color _glow(Color activeColor, double intensity, {required bool isUplink}) {
    final double t = isUplink ? intensity * 0.72 : intensity;
    final Color idle = AppTheme.textTertiary.withValues(alpha: 0.42);
    return Color.lerp(idle, activeColor, t.clamp(0.0, 1.0)) ?? activeColor;
  }
}

/// 画两条细长箭头：上面一条向右（上行），下面一条向左（下行）。
///
/// 箭杆用 [Path] 一次成形而不是 `drawLine` + 三角形拼接——拼接在 1.2px 线宽
/// 下接缝处会露出毛刺，一次成形加 [StrokeCap.round] 才干净。
class _TrafficArrowsPainter extends CustomPainter {
  const _TrafficArrowsPainter({
    required this.uplinkColor,
    required this.downlinkColor,
  });

  final Color uplinkColor;
  final Color downlinkColor;

  /// 杆粗。1.2 在 100% 与 125% 缩放下都还能保持锐利，1.0 会发虚。
  static const double _stroke = 1.2;

  /// 箭头开口的长与半高。随杆长一起收窄——杆短了头还那么大，
  /// 整个箭头就只剩两个尖，方向反而读不出来。
  static const double _headLen = 2.9;
  static const double _headHalf = 2.2;

  @override
  void paint(Canvas canvas, Size size) {
    // 两条箭头各占上下半区的中线，彼此留出可见的间隙。
    final double topY = size.height * 0.22;
    final double bottomY = size.height * 0.78;

    _drawArrow(canvas, size, y: topY, color: uplinkColor, pointsRight: true);
    _drawArrow(canvas, size,
        y: bottomY, color: downlinkColor, pointsRight: false);
  }

  void _drawArrow(
    Canvas canvas,
    Size size, {
    required double y,
    required Color color,
    required bool pointsRight,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = _stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // 留出半个线宽，避免箭头尖端被画布边缘裁掉。
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
  bool shouldRepaint(_TrafficArrowsPainter oldDelegate) =>
      oldDelegate.uplinkColor != uplinkColor ||
      oldDelegate.downlinkColor != downlinkColor;
}

/// 速率格式化。
///
/// 阈值与 `download_list.dart` 的 `_formatSpeed` 完全一致——刻意复制而非复用，
/// 因为那是 `_DownloadTaskCardState` 的私有方法，跨文件无法访问，
/// 而把它提到公共 util 会污染卡片文件的既有结构。
String formatGeoSpeed(double bytesPerSecond) {
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
