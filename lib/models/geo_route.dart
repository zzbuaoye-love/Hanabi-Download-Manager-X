/// 下载任务的“出口国 → 目标服务器国”链路模型。
///
/// 这些类型只承载数据，不含任何 IO / 状态逻辑：
/// - [GeoEndpoint] 描述链路的一端（发起出口 或 下载目标服务器）
/// - [GeoRoute] 描述完整链路以及本次查询的状态
///
/// 与仓库内其它 model 保持一致：全部字段 `final`、`const` 构造、
/// 不实现 `==` / `hashCode` / `copyWith`（服务层每次产出新实例）。
library;

/// 单次归属地查询的生命周期状态。
enum GeoLookupState {
  /// 尚未开始查询（也没有缓存）。
  idle,

  /// 查询已入队或正在进行中。
  resolving,

  /// 查询完成，至少目标侧结果可用（出口侧可能仍然未知）。
  ready,

  /// 查询失败，[GeoRoute.error] 携带技术原因。
  failed,

  /// 功能被用户关闭。
  disabled,
}

/// 链路的一端。
///
/// 所有字段都可能为 null —— 在线接口失败、离线库缺少该段、
/// 或地址属于不可路由段（内网 / fake-ip）时都会退化成空端点。
class GeoEndpoint {
  /// 实际解析出的 IP（在线模式下由归属地接口回填，不使用本机 DNS 结果）。
  final String? ip;

  /// ISO 3166-1 alpha-2 国家码，大写，例如 `US`。
  final String? countryCode;

  /// 国家全称，例如 `United States`。
  final String? countryName;

  /// 自治域信息，例如 `AS15169 Google LLC`。
  final String? asnOrg;

  /// 这一端在本机 / 内网，不存在「归属国」这回事。
  ///
  /// 与「查不到国家」是两码事：查不到是失败，本地是压根没有这个概念。
  /// 下载 `127.0.0.1` 时连接不出本机，两端都是 true。
  final bool isLocal;

  /// 这个国家只是「很可能」，不是实测。
  ///
  /// 出口侧用得最多：代理若是 Clash / mihomo / sing-box 这类**规则型**本地客户端，
  /// 分流规则在客户端内部，应用只能看到 `127.0.0.1:7897`。我们测到的出口是
  /// 「查询归属地接口时匹配到的那条规则」的落地，下载目标完全可能匹配到另一条
  /// 规则（比如直连）。这种情况下把出口国说成确定值就是在编。
  final bool approximate;

  const GeoEndpoint({
    this.ip,
    this.countryCode,
    this.countryName,
    this.asnOrg,
    this.isLocal = false,
    this.approximate = false,
  });

  GeoEndpoint copyWith({bool? approximate}) => GeoEndpoint(
        ip: ip,
        countryCode: countryCode,
        countryName: countryName,
        asnOrg: asnOrg,
        isLocal: isLocal,
        approximate: approximate ?? this.approximate,
      );

  /// 是否拿到了可用于渲染国旗的国家码。
  bool get hasCountry => countryCode != null && countryCode!.length == 2;

  /// 是否完全没有任何可展示的信息。
  bool get isEmpty =>
      ip == null &&
      countryCode == null &&
      countryName == null &&
      asnOrg == null;
}

/// 一条完整的“发起出口 → 下载目标”链路。
class GeoRoute {
  /// 本次查询状态。
  final GeoLookupState state;

  /// 发起侧（使用代理时即代理出口）。
  final GeoEndpoint egress;

  /// 下载目标服务器侧。
  final GeoEndpoint target;

  /// 该任务是否实际走代理（已考虑 bypass / NO_PROXY 规则）。
  final bool viaProxy;

  /// 代理展示名，例如 `system` 或 `socks5 127.0.0.1:7897`。
  final String? proxyLabel;

  /// 结果是否来自本地离线库（false 表示来自在线接口）。
  final bool fromOfflineDb;

  /// 目标国是否为「近似值」。
  ///
  /// true 表示这一次没能从本机出口的视角解析出目标 IP（DoH 失败），
  /// 只能把主机名交给归属地接口、由它在**它自己**的位置解析。
  /// 对 anycast / GeoDNS 类 CDN 来说，那个结果可能与本机实际连接的节点
  /// 不在同一个国家，所以 UI 层应当在 Tooltip 里注明“近似”。
  final bool targetApproximate;

  /// 失败原因（技术性英文短句，仅用于 Tooltip 兜底展示）。
  final String? error;

  const GeoRoute({
    required this.state,
    this.egress = const GeoEndpoint(),
    this.target = const GeoEndpoint(),
    this.viaProxy = false,
    this.proxyLabel,
    this.fromOfflineDb = false,
    this.targetApproximate = false,
    this.error,
  });

  /// 空链路：尚未触发查询。
  static const GeoRoute idle = GeoRoute(state: GeoLookupState.idle);

  /// 任意一端拿到国家码时为 true —— 徽标至少可以画出一面旗。
  bool get hasAnyCountry => egress.hasCountry || target.hasCountry;
}
