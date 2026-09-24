import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:rhttp/rhttp.dart' as rhttp;

import '../models/geo_route.dart';
import 'app_logger_service.dart';
import 'client_config_service.dart';
import 'kernel/kernel_interface.dart' as kernel;
import 'kernel/kernel_manager.dart';
import 'kernel/next/downloader/proxy_runtime.dart';

/// 解析后的离线 IPv4 归属地表。
///
/// 三个并行的定长数组按 [starts] 升序排列，可直接二分查找：
/// - [starts] / [ends]：IPv4 区间闭区间端点（无符号 32 位，存在 Dart int 里）
/// - [codes]：ISO2 国家码，`(高位字符 << 8) | 低位字符`
///
/// ~20 万条记录约占 2.5 MB 内存，远小于把 10 MB CSV 常驻字符串的代价。
class GeoV4Table {
  const GeoV4Table({
    required this.starts,
    required this.ends,
    required this.codes,
  });

  final Uint32List starts;
  final Uint32List ends;
  final Uint16List codes;

  int get length => starts.length;

  bool get isEmpty => starts.isEmpty;

  /// 查询一个 IPv4 整数对应的 ISO2 国家码，未命中返回 null。
  String? lookup(int ip) {
    final index = GeoIpService.lookupIndex(starts, ip);
    if (index < 0 || index >= ends.length) {
      return null;
    }
    if (ip > ends[index]) {
      return null;
    }
    final code = codes[index];
    return String.fromCharCodes(<int>[(code >> 8) & 0xFF, code & 0xFF]);
  }
}

/// 下载卡片“出口国 → 目标服务器国”徽标的数据源。
///
/// 设计要点：
/// 1. [routeForUrl] 是纯同步的缓存读取，可以在 `build()` 里随便调用。
/// 2. [requestRouteForUrl] 也在 `build()` 里被调用，因此它**绝不会**同步触发
///    `notifyListeners()`（否则就是经典的 “setState during build” 崩溃），
///    只会做去重入队 + `scheduleMicrotask`。
/// 3. 全局同一时刻最多只有一个归属地请求在飞，配合最小间隔与滑动窗口限流，
///    保证不会打爆 ip-api 的免费额度（约 45 次/分钟，且额度按“来源 IP”计算，
///    走同一个代理出口的所有用户是共享的）。
/// 4. 任何网络异常都被吞进 [GeoLookupState.failed]，绝不向 UI 抛出。
///
/// 关于 DNS 的两条硬性结论（都是在真机上实测出来的，不要想当然改回去）：
///
/// 1. **在线模式下本机 DNS 不可信。** 大量用户运行 Clash / mihomo / sing-box 的 fake-ip
///    模式，本地解析会把所有域名映射到 198.18.0.0/15 的合成地址；把它交给
///    归属地接口只会拿到 `{"status":"fail","message":"reserved range"}`。
///    因此在线模式不使用 `InternetAddress.lookup` 解析下载目标。离线模式为了
///    不把主机名交给固定第三方 DoH，只使用用户的系统解析器；fake-ip 命中时
///    会如实显示未知，而不会悄悄改走在线接口。
/// 2. **决定答案的是「在哪儿解析」。** 同一个 CDN 主机
///    （download-cdn.jetbrains.com），在 ip-api 自己的机房解析得到 GB，
///    而从本机真实出口解析得到的是 TW 的 CloudFront 节点——本机根本不会连去
///    英国。所以目标侧必须**从生效代理出去做 DoH**，拿到本机真正会连的那个
///    IP，再对这个 IP 查归属地。
///
/// 于是目标侧的解析顺序固定为：
///   ① 走生效代理的 DoH（dns.google → cloudflare-dns.com）拿真实 IP，再查该 IP；
///   ② DoH 整体失败时，才退化成「把主机名交给在线接口」，并把结果标记为
///      [GeoRoute.targetApproximate]，让 Tooltip 明说这是近似值；
///   ③ 离线模式没有 ② 这一步（那是一次在线调用），DoH 失败即报未知。
class GeoIpService extends ChangeNotifier {
  GeoIpService(this._config);

  final ClientConfigService _config;
  final AppLoggerService _logger = AppLoggerService();

  // ========== 配置键 ==========

  /// 徽标总开关，默认开启。
  static const String kEnabledKey = 'download.geo_route_badge_enabled';

  /// 数据源键，取值 [sourceOnline] / [sourceOffline]，默认在线。
  static const String kSourceKey = 'download.geo_route_source';

  /// `ClientConfigService` 目前只暴露通用的 `getBool` / `setBool`，
  /// 没有通用的字符串读写。为了不越界修改那个文件，这里额外写一份布尔镜像键：
  /// 语义与 [kSourceKey] 完全等价（true 表示离线库）。
  /// 若将来 `ClientConfigService` 补上了 `getString` / `setString`，
  /// 读写会自动优先走字符串键，镜像键继续同步写入，两边不会打架。
  static const String _kSourceOfflineMirrorKey =
      'download.geo_route_source_offline';

  static const String sourceOnline = 'online';
  static const String sourceOffline = 'offline';

  // ========== 端点 ==========

  static const String _ipWhoBaseUrl = 'https://ipwho.is/';

  /// DoH 端点。两家返回的 JSON 结构一致（`Status` + `Answer[{type,data}]`），
  /// 只是 Cloudflare 必须显式带 `accept: application/dns-json`。
  /// 备用一家是必要的：dns.google 在部分网络里被整段阻断。
  static const List<(String, String)> _dohEndpoints = <(String, String)>[
    ('https://dns.google/resolve', 'application/json'),
    ('https://cloudflare-dns.com/dns-query', 'application/dns-json'),
  ];

  /// 内置下载源。两个都实测可用，取舍不同：
  /// * jsDelivr 支持 Range（断点续传），约 1.5 MB/s；
  /// * unpkg 更快（约 4.5 MB/s）但忽略 Range，断了只能重下。
  ///
  /// 都在墙外——所以必须允许用户自定义 URL，以及完全离线地本地导入。
  static const String defaultOfflinePackUrl =
      'https://cdn.jsdelivr.net/npm/@ip-location-db/geo-whois-asn-country/geo-whois-asn-country-ipv4.csv';
  static const String unpkgOfflinePackUrl =
      'https://unpkg.com/@ip-location-db/geo-whois-asn-country/geo-whois-asn-country-ipv4.csv';

  /// 自定义资源包下载地址（留空则用 [defaultOfflinePackUrl]）。
  static const String kPackUrlKey = 'download.geo_offline_pack_url';

  static const String _packFileName = 'geo-whois-asn-country-ipv4.csv';
  static const String _packDirName = 'geoip';
  static const String _userAgent = 'HanabiDownloadManagerX/GeoBadge';

  // ========== 缓存 / 限流参数 ==========

  /// 主机 → 国家几乎是静态的，缓存 6 小时。
  static const Duration _targetTtl = Duration(hours: 6);

  /// 出口可能随代理节点切换而变，缓存 10 分钟。
  static const Duration _egressTtl = Duration(minutes: 10);

  /// 内核尚未启动（读不到代理配置）时的短 TTL，避免把“直连”钉死。
  static const Duration _kernelColdTtl = Duration(seconds: 60);

  /// 失败结果同样要缓存，否则一个死主机会让每帧都发一次请求。
  static const Duration _negativeTtl = Duration(minutes: 10);

  /// 归属地接口之间的最小间隔（ip-api 免费额度约 45 次/分钟，
  /// 而且额度按「来源 IP」计——同一个代理出口后面的所有用户是共享的）。
  static const Duration _minRequestGap = Duration(milliseconds: 1500);

  /// DoH 不计入归属地接口的额度，只需要一个礼貌性的间隔。
  static const Duration _dohRequestGap = Duration(milliseconds: 300);

  static const Duration _rateWindow = Duration(seconds: 60);
  static const int _maxRequestsPerWindow = 20;
  static const Duration _providerCooldown = Duration(minutes: 5);
  static const int _providerFailureThreshold = 3;

  static const Duration _connectTimeout = Duration(seconds: 6);
  static const Duration _requestTimeout = Duration(seconds: 10);
  static const Duration _dnsTimeout = Duration(seconds: 6);

  static const int _maxCacheEntries = 512;
  static const int _maxQueueLength = 32;
  static const int _maxResponseBytes = 128 * 1024;
  static const int _maxOfflinePackBytes = 256 * 1024 * 1024;
  static const Duration _packBodyIdleTimeout = Duration(seconds: 20);
  static const Duration _packDownloadDeadline = Duration(minutes: 5);

  /// 合并通知窗口：N 张卡片同时拿到结果只会触发一次重建。
  static const Duration _notifyDebounce = Duration(milliseconds: 16);

  // ========== 状态 ==========

  bool _initialized = false;
  bool _disposed = false;
  bool _enabled = true;
  String _source = sourceOnline;

  final Map<String, _TargetEntry> _targetCache = <String, _TargetEntry>{};
  final Map<String, _EgressEntry> _egressCache = <String, _EgressEntry>{};

  final ListQueue<String> _queue = ListQueue<String>();
  final Set<String> _queued = <String>{};
  final Set<String> _inFlight = <String>{};
  bool _pumping = false;

  String _lastProxyIdentity = 'direct';
  bool _lastViaProxy = false;
  String? _lastProxyLabel;

  DateTime? _lastRequestAt;
  final List<DateTime> _requestWindow = <DateTime>[];
  DateTime? _ipWhoCooldownUntil;
  DateTime? _dohCooldownUntil;
  int _ipWhoFailures = 0;
  int _dohFailures = 0;

  Timer? _notifyTimer;

  bool _offlinePackInstalled = false;
  int _offlinePackBytes = 0;
  double _offlinePackProgress = -1;
  String? _lastOfflinePackError;
  bool _packDownloadInFlight = false;
  bool _packImportInFlight = false;

  GeoV4Table? _offlineTable;
  Future<GeoV4Table?>? _offlineTableLoading;

  static Future<void>? _rhttpInitFuture;

  // ========== 生命周期 ==========

  /// 读取持久化配置并探测离线资源包是否已安装。
  ///
  /// 必须在 `ClientConfigService.initialize()` 之后调用：
  /// 那之前 `_getFromConfig` 一律返回默认值，用户的设置会被静默丢弃。
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;

    try {
      _enabled = _config.getBool(kEnabledKey, defaultValue: true);
    } catch (_) {
      _enabled = true;
    }
    _source = _readPersistedSource();
    await _refreshOfflinePackState();
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _queue.clear();
    _queued.clear();
    _offlineTable = null;
    super.dispose();
  }

  // ========== 设置 ==========

  bool get enabled => _enabled;

  String get source => _source;

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) {
      return;
    }
    _enabled = value;
    if (!value) {
      _queue.clear();
      _queued.clear();
    }
    await _persistBool(kEnabledKey, value);
    _safeNotify();
  }

  Future<void> setSource(String value) async {
    final normalized = normalizeSource(value);
    if (_source == normalized) {
      return;
    }
    _source = normalized;
    // 数据源变了，之前的结果全部作废（在线与离线的口径不同）。
    _targetCache.clear();
    _egressCache.clear();
    _queue.clear();
    _queued.clear();
    if (normalized == sourceOnline) {
      _offlineTable = null;
    }
    await _writePersistedSource(normalized);
    _safeNotify();
  }

  // ========== 对外查询 ==========

  /// 同步读取缓存。没有任何 IO，可以在 `build()` 中安全调用。
  GeoRoute routeForUrl(String url) {
    if (!_enabled) {
      return const GeoRoute(state: GeoLookupState.disabled);
    }

    final host = hostKeyFor(url);
    if (host == null) {
      return GeoRoute.idle;
    }

    final target = _targetCache[host];
    if (target == null) {
      if (_inFlight.contains(host) || _queued.contains(host)) {
        return GeoRoute(
          state: GeoLookupState.resolving,
          viaProxy: _lastViaProxy,
          proxyLabel: _lastProxyLabel,
        );
      }
      return GeoRoute.idle;
    }

    // 本地链路：两端都标 local，且**绝不**回读出口缓存——那里存的是本机公网
    // 出口（或代理落地），拿来当「本机连本机」的发起端就是在骗人。
    if (target.localRoute) {
      return GeoRoute(
        state: GeoLookupState.ready,
        egress: const GeoEndpoint(isLocal: true),
        target: target.endpoint,
        viaProxy: false,
        fromOfflineDb: target.fromOffline,
      );
    }

    // 出口条目必须查过期后才敢画。
    //
    // 这里曾经直接 `_egressCache[...]?.endpoint` 一把梭，没有任何 isExpired 判断，
    // 而唯一的过期检查在 `_resolveEgress` 里、只有目标条目（6 小时 TTL）失效才
    // 走得到。后果是：把 Clash 节点从日本切到美国时，代理 identity 根本没变
    // （它是本地监听地址 127.0.0.1:7897，不是远端节点），于是没有任何东西触发
    // 重测，徽标能顶着日本国旗显示 6 小时。10 分钟的 _egressTtl 形同虚设。
    //
    // 宁可留白也不画过期值——与本文件「宁可空着也不给错国家」的一贯口径一致。
    final egressEntry = _egressCache[target.egressIdentity];
    final GeoEndpoint egress =
        (egressEntry == null || egressEntry.isExpired(DateTime.now()))
            ? const GeoEndpoint()
            // 规则型代理下出口国只是「很可能」，标出来让 tooltip 如实说明。
            : (target.egressRuleBased
                ? egressEntry.endpoint.copyWith(approximate: true)
                : egressEntry.endpoint);
    final failed = target.error != null && !target.endpoint.hasCountry;

    return GeoRoute(
      state: failed ? GeoLookupState.failed : GeoLookupState.ready,
      egress: egress,
      target: target.endpoint,
      viaProxy: target.viaProxy,
      proxyLabel: target.proxyLabel,
      fromOfflineDb: target.fromOffline,
      targetApproximate: target.approximate,
      error: target.error,
    );
  }

  /// 代理配置变了：之前测出来的通道与出口全部作废。
  ///
  /// `viaProxy` / `proxyLabel` / `egressIdentity` 都是「按当时生效的代理」测出来的，
  /// 而目标条目缓存 6 小时。不主动清的话：在设置里关掉代理后，徽标还会顶着
  /// 「经代理 → 日本」显示半天；反向更糟——关着时缓存了 direct，开启代理后
  /// 徽标仍然断言「直连」，而流量其实已经全部走代理了。
  void invalidateProxyDependentCache() {
    if (_targetCache.isEmpty && _egressCache.isEmpty) return;
    _targetCache.clear();
    _egressCache.clear();
    _queue.clear();
    _queued.clear();
    _lastProxyIdentity = 'direct';
    _lastViaProxy = false;
    _lastProxyLabel = null;
    _safeNotify();
  }

  /// 这条链路整体是否仍然新鲜。
  ///
  /// 光看目标条目不够：出口条目有自己的、短得多的 TTL（代理节点随时会切），
  /// 而重测出口的唯一入口是 `_resolveHost`，它又被目标条目的新鲜度挡着。
  /// 两个 TTL 必须连坐，否则短的那个永远等不到执行——这正是「切了节点还显示
  /// 旧国家」的成因。
  bool _routeFresh(_TargetEntry entry, DateTime now) {
    if (entry.isExpired(now)) return false;
    // 本地链路压根不查出口，不该被出口的新鲜度拖着反复重跑。
    if (entry.localRoute) return true;
    final egress = _egressCache[entry.egressIdentity];
    return egress != null && !egress.isExpired(now);
  }

  /// 触发一次归属地解析（fire-and-forget）。
  ///
  /// 这个方法会被每一帧的 `build()` 调用，所以它做且只做三件事：
  /// 判重、入队、`scheduleMicrotask`。它**不会**同步 `notifyListeners()`。
  void requestRouteForUrl(String url) {
    if (!_enabled) {
      return;
    }

    final host = hostKeyFor(url);
    if (host == null) {
      return;
    }
    if (_inFlight.contains(host) || _queued.contains(host)) {
      return;
    }

    final cached = _targetCache[host];
    if (cached != null && _routeFresh(cached, DateTime.now())) {
      return;
    }

    _queued.add(host);
    _queue.addLast(host);
    while (_queue.length > _maxQueueLength) {
      _queued.remove(_queue.removeFirst());
    }

    scheduleMicrotask(() {
      unawaited(_pumpQueue());
    });
  }

  // ========== 离线资源包 ==========

  bool get offlinePackInstalled => _offlinePackInstalled;

  int get offlinePackBytes => _offlinePackBytes;

  /// 当前生效的资源包下载地址；未自定义时返回内置默认源。
  String get offlinePackUrl {
    final custom = _config.getString(kPackUrlKey, defaultValue: '').trim();
    return custom.isEmpty ? defaultOfflinePackUrl : custom;
  }

  /// 是否使用了自定义下载源。
  bool get usesCustomPackUrl => offlinePackUrl != defaultOfflinePackUrl;

  /// 设置自定义下载源。传空串恢复默认源。
  Future<void> setOfflinePackUrl(String value) async {
    final normalized = value.trim();
    if (normalized.isNotEmpty) {
      final uri = Uri.tryParse(normalized);
      if (uri == null ||
          !uri.hasAuthority ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw const FormatException('invalid pack url');
      }
    }
    await _config.setString(
      kPackUrlKey,
      normalized == defaultOfflinePackUrl ? '' : normalized,
    );
    _safeNotify();
  }

  /// 正在导入本地资源包。
  bool get packImportInFlight => _packImportInFlight;

  /// 从本地文件导入离线资源包。
  ///
  /// 内置源全在墙外，这是被墙时唯一的退路：用户自己下好文件再导进来。
  ///
  /// 先在后台 isolate 里完整解析校验，**通过了才覆盖**已装的包——
  /// 否则一个格式不对的文件会把用户原本能用的库毁掉。
  /// 接受 ip-location-db 点分格式、IP2Location LITE 十进制带引号格式，以及两者的 .gz。
  Future<bool> importOfflinePack(String sourcePath) async {
    if (_packImportInFlight || _packDownloadInFlight) {
      return false;
    }

    final dirPath = _packDirPath();
    if (dirPath == null) {
      _lastOfflinePackError = 'no writable data directory';
      _safeNotify();
      return false;
    }

    _packImportInFlight = true;
    _lastOfflinePackError = null;
    _safeNotify();

    final staged = File(p.join(dirPath, '$_packFileName.import'));
    try {
      final source = File(sourcePath);
      if (!await source.exists()) {
        throw const FileSystemException('source file not found');
      }

      await Directory(dirPath).create(recursive: true);
      // 先落一份到数据目录再校验：源文件可能在移动盘上，随时会消失。
      await source.copy(staged.path);

      final raw = await compute(parseGeoV4Csv, staged.path);
      final ranges = raw.length == 3 ? (raw[0] as Uint32List).length : 0;
      if (ranges < _minImportableRanges) {
        throw FormatException(
          'unrecognised geolocation pack (only $ranges usable ranges)',
        );
      }

      final target = await _replaceOfflinePack(staged, dirPath);

      _offlinePackInstalled = true;
      _offlinePackBytes = await target.length();
      _offlineTable = null; // 强制下次查询重新解析
      _logger.info(
        'GeoIP',
        'Offline pack imported from $sourcePath '
            '($ranges ranges, ${formatPackSize(_offlinePackBytes)})',
      );
      return true;
    } catch (e) {
      _lastOfflinePackError = e.toString();
      _logger.warning('GeoIP', 'Offline pack import failed: $e');
      try {
        if (await staged.exists()) await staged.delete();
      } catch (_) {
        // 清理失败无所谓，下次导入会覆盖。
      }
      return false;
    } finally {
      _packImportInFlight = false;
      _safeNotify();
    }
  }

  /// 低于这个区间数就认为文件根本不是归属地库（真实库有 20 万条以上）。
  static const int _minImportableRanges = 1000;

  /// 下载进度 0..1；空闲时为 -1。
  double get offlinePackProgress => _offlinePackProgress;

  String? get lastOfflinePackError => _lastOfflinePackError;

  /// 下载离线归属地资源包（ip-location-db，CC0）。
  ///
  /// 走当前生效的代理下载：jsDelivr 在部分网络下不可直连。
  /// 进度最多每 100 ms / 256 KB 通知一次，避免刷爆 UI。
  Future<bool> downloadOfflinePack() async {
    if (_packDownloadInFlight) {
      return false;
    }

    final dirPath = _packDirPath();
    if (dirPath == null) {
      _lastOfflinePackError = 'no writable data directory';
      _safeNotify();
      return false;
    }

    _packDownloadInFlight = true;
    _lastOfflinePackError = null;
    _offlinePackProgress = 0;
    _safeNotify();

    final tempFile = File(p.join(dirPath, '$_packFileName.part'));
    _GeoClient? client;
    IOSink? sink;
    var success = false;

    try {
      await Directory(dirPath).create(recursive: true);

      final uri = Uri.parse(offlinePackUrl);
      final proxy = NsfxProxyRuntime.resolveFromKernelConfig(
        await _readProxyConfig(),
        uri,
      );
      client = await _openClient(proxy);

      final request = await client.client.getUrl(uri).timeout(_connectTimeout);
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }

      final total = response.contentLength;
      if (total > _maxOfflinePackBytes) {
        throw const HttpException('offline pack exceeds size limit');
      }
      sink = tempFile.openWrite();
      var received = 0;
      var lastNotifyAt = DateTime.now();
      var lastNotifyBytes = 0;
      final downloadWatch = Stopwatch()..start();

      await for (final chunk in response.timeout(_packBodyIdleTimeout)) {
        if (downloadWatch.elapsed > _packDownloadDeadline) {
          throw TimeoutException(
            'offline pack download exceeded '
            '${_packDownloadDeadline.inMinutes} minutes',
          );
        }
        if (received + chunk.length > _maxOfflinePackBytes) {
          throw const HttpException('offline pack exceeds size limit');
        }
        sink.add(chunk);
        received += chunk.length;
        if (total <= 0) {
          continue;
        }
        final now = DateTime.now();
        if (now.difference(lastNotifyAt) >= const Duration(milliseconds: 100) ||
            received - lastNotifyBytes >= 256 * 1024) {
          lastNotifyAt = now;
          lastNotifyBytes = received;
          _offlinePackProgress = (received / total).clamp(0.0, 1.0);
          _safeNotify();
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (received <= 0) {
        throw const HttpException('empty response body');
      }
      if (total > 0 && received != total) {
        throw HttpException(
          'incomplete response body ($received of $total bytes)',
          uri: uri,
        );
      }

      final raw = await compute(parseGeoV4Csv, tempFile.path);
      final ranges = raw.length == 3 ? (raw[0] as Uint32List).length : 0;
      if (ranges < _minImportableRanges) {
        throw FormatException(
          'unrecognised geolocation pack (only $ranges usable ranges)',
        );
      }

      final targetFile = await _replaceOfflinePack(tempFile, dirPath);

      _offlinePackInstalled = true;
      _offlinePackBytes = await targetFile.length();
      // 强制下次查询时重新解析新包。
      _offlineTable = null;
      success = true;
      _logger.info(
        'GeoIP',
        'Offline geolocation pack installed '
            '($ranges ranges, ${formatPackSize(_offlinePackBytes)})',
      );
    } catch (e) {
      _lastOfflinePackError = e.toString();
      _logger.warning('GeoIP', 'Offline pack download failed: $e');
      try {
        await sink?.close();
      } catch (_) {
        // 忽略：错误路径下的清理。
      }
      sink = null;
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {
        // 忽略：临时文件删不掉不影响功能。
      }
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // 忽略。
      }
      client?.close();
      _packDownloadInFlight = false;
      _offlinePackProgress = -1;
      _safeNotify();
    }

    return success;
  }

  /// Replaces the installed pack without destroying the last known-good file
  /// when staging or rename fails. Windows cannot rename over an existing file,
  /// so retain a short-lived backup and restore it on failure.
  Future<File> _replaceOfflinePack(File staged, String dirPath) async {
    final target = File(p.join(dirPath, _packFileName));
    final backup = File(p.join(dirPath, '$_packFileName.backup'));
    var previousMoved = false;

    try {
      if (await backup.exists()) {
        await backup.delete();
      }
      if (await target.exists()) {
        await target.rename(backup.path);
        previousMoved = true;
      }

      await staged.rename(target.path);

      if (previousMoved && await backup.exists()) {
        try {
          await backup.delete();
        } catch (e) {
          _logger.warning('GeoIP', 'Could not remove old pack backup: $e');
        }
      }
      return target;
    } catch (_) {
      if (previousMoved && await backup.exists()) {
        try {
          if (await target.exists()) {
            await target.delete();
          }
          await backup.rename(target.path);
        } catch (rollbackError) {
          _logger.error(
            'GeoIP',
            'Offline pack rollback failed: $rollbackError',
          );
        }
      }
      rethrow;
    }
  }

  /// 删除离线资源包并释放已解析的内存表。
  Future<void> removeOfflinePack() async {
    final dirPath = _packDirPath();
    if (dirPath != null) {
      try {
        final file = File(p.join(dirPath, _packFileName));
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        _lastOfflinePackError = e.toString();
      }
    }

    _offlineTable = null;
    _offlinePackInstalled = false;
    _offlinePackBytes = 0;
    _offlinePackProgress = -1;
    _safeNotify();
  }

  Future<void> _refreshOfflinePackState() async {
    try {
      final dirPath = _packDirPath();
      if (dirPath == null) {
        _offlinePackInstalled = false;
        _offlinePackBytes = 0;
        return;
      }
      final file = File(p.join(dirPath, _packFileName));
      final backup = File(p.join(dirPath, '$_packFileName.backup'));
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
        _logger.warning(
          'GeoIP',
          'Recovered the previous offline pack after an interrupted replace',
        );
      }
      if (await file.exists()) {
        _offlinePackInstalled = true;
        _offlinePackBytes = await file.length();
      } else {
        _offlinePackInstalled = false;
        _offlinePackBytes = 0;
      }
    } catch (_) {
      // 探测失败按“未安装”处理，绝不抛出。
      _offlinePackInstalled = false;
      _offlinePackBytes = 0;
    }
  }

  String? _packDirPath() {
    final base = _config.dataDir;
    if (base.isNotEmpty) {
      return p.join(base, _packDirName);
    }
    // ClientConfigService 还没 initialize 时的兜底，路径与它保持一致。
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    if (home.isEmpty) {
      return null;
    }
    return p.join(home, '.hdmx', 'data', _packDirName);
  }

  // ========== 解析主流程 ==========

  Future<void> _pumpQueue() async {
    if (_pumping) {
      return;
    }
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        if (!_enabled || _disposed) {
          _queue.clear();
          _queued.clear();
          break;
        }

        final host = _queue.removeFirst();
        _queued.remove(host);

        final cached = _targetCache[host];
        if (cached != null && _routeFresh(cached, DateTime.now())) {
          continue;
        }

        _inFlight.add(host);
        try {
          await _resolveHost(host);
        } catch (e) {
          // 兜底：任何未预期异常都退化为 failed，绝不冒泡到 UI。
          _logger.warning('GeoIP', 'Route lookup crashed for $host: $e');
          _commitTarget(
            host,
            _TargetEntry(
              endpoint: const GeoEndpoint(),
              at: DateTime.now(),
              ttl: _negativeTtl,
              viaProxy: _lastViaProxy,
              proxyLabel: _lastProxyLabel,
              egressIdentity: _lastProxyIdentity,
              fromOffline: _source == sourceOffline,
              error: 'internal error',
            ),
          );
        } finally {
          _inFlight.remove(host);
        }
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _resolveHost(String host) async {
    final proxyConfig = await _readProxyConfig();
    final kernelReady = _kernelConfigSeen;

    // 出口侧必须跟随**这个下载任务实际走的代理**。
    //
    // 曾经这里按 ip-api 自己的 URL 单独解析过一个 geoProxy，然后拿它去查出口——
    // 那是错的：代理配置里的 bypass 规则是按目标地址生效的，两个 URL 完全可能
    // 落在不同的通道上。最刺眼的例子就是下载 127.0.0.1：目标被 bypass 走直连，
    // 而 ip-api.com 照常走代理，于是徽标显示「日本 → 本机」——本机连本机的流量
    // 根本没出过网卡，却被标成从日本发起。
    //
    // 用 taskProxy 查出口，上述情况自动全部正确：目标走代理就查到代理落地国，
    // 目标被 bypass 就查到本机真实出口。
    final taskProxy = NsfxProxyRuntime.resolveFromKernelConfig(
      proxyConfig,
      _probeUriForHost(host),
    );

    _lastProxyIdentity = taskProxy.identity;
    _lastViaProxy = taskProxy.hasProxy;
    _lastProxyLabel = taskProxy.displayLabel;

    final viaProxy = taskProxy.hasProxy;
    final proxyLabel = taskProxy.displayLabel;
    final egressIdentity = taskProxy.identity;
    final offline = _source == sourceOffline;
    final egressRuleBased = isRuleBasedProxy(taskProxy);

    // 内网 / 回环 / 合成地址（含 fake-ip 的 198.18.0.0/15）：整条链路都在本机
    // 或局域网内，两端都不存在「归属国」。
    //
    // 这里**不发任何网络请求**——既问不出有意义的答案，也没有理由为了一个
    // 本地下载去联网。出口侧同样标成 local，而不是拿本机公网出口去充数：
    // 下载 127.0.0.1 时流量根本没离开过这台机器。
    if (isPrivateHost(host)) {
      _commitTarget(
        host,
        _TargetEntry(
          endpoint: GeoEndpoint(
            ip: InternetAddress.tryParse(host) != null ? host : null,
            isLocal: true,
          ),
          at: DateTime.now(),
          ttl: _targetTtl,
          viaProxy: viaProxy,
          proxyLabel: proxyLabel,
          egressIdentity: egressIdentity,
          egressRuleBased: egressRuleBased,
          fromOffline: offline,
          localRoute: true,
        ),
      );
      return;
    }

    // 离线模式且资源包缺失：直接失败，绝不偷偷回落到在线接口，
    // 否则就违背了设置页对用户作出的隐私承诺。
    if (offline && !_offlinePackInstalled) {
      _commitTarget(
        host,
        _TargetEntry(
          endpoint: const GeoEndpoint(),
          at: DateTime.now(),
          ttl: _negativeTtl,
          viaProxy: viaProxy,
          proxyLabel: proxyLabel,
          egressIdentity: egressIdentity,
          egressRuleBased: egressRuleBased,
          fromOffline: true,
          error: 'offline pack not installed',
        ),
      );
      return;
    }

    final client = await _openClient(taskProxy);
    try {
      await _resolveEgress(
        client,
        identity: egressIdentity,
        kernelReady: kernelReady,
      );

      final entry = offline
          ? await _resolveTargetOffline(
              client,
              host,
              viaProxy: viaProxy,
              proxyLabel: proxyLabel,
              egressIdentity: egressIdentity,
              egressRuleBased: egressRuleBased,
            )
          : await _resolveTargetOnline(
              client,
              host,
              viaProxy: viaProxy,
              proxyLabel: proxyLabel,
              egressIdentity: egressIdentity,
              egressRuleBased: egressRuleBased,
            );
      _commitTarget(host, entry);
    } finally {
      client.close();
    }
  }

  // ========== 出口侧 ==========

  Future<void> _resolveEgress(
    _GeoClient client, {
    required String identity,
    required bool kernelReady,
  }) async {
    final cached = _egressCache[identity];
    if (cached != null && !cached.isExpired(DateTime.now())) {
      return;
    }

    final ttl = kernelReady ? _egressTtl : _kernelColdTtl;

    if (!client.reflectsEgress) {
      // 无法确认请求真的从代理出去（例如 SOCKS5 且 rhttp 不可用）。
      // 与其报一个错误的国家，不如留空。
      _commitEgress(
        identity,
        _EgressEntry(
          endpoint: const GeoEndpoint(),
          at: DateTime.now(),
          ttl: _negativeTtl,
        ),
      );
      return;
    }

    final endpoint = _source == sourceOffline
        ? await _resolveEgressOffline(client)
        : await _resolveEgressOnline(client);

    _commitEgress(
      identity,
      _EgressEntry(
        endpoint: endpoint ?? const GeoEndpoint(),
        at: DateTime.now(),
        ttl: endpoint == null ? _negativeTtl : ttl,
      ),
    );
  }

  Future<GeoEndpoint?> _resolveEgressOnline(_GeoClient client) async {
    if (_providerAvailable()) {
      final response = await _getJson(client, Uri.parse(_ipWhoBaseUrl));
      final endpoint = _parseIpWho(response);
      if (endpoint != null) {
        _noteProviderSuccess();
        return endpoint;
      }
      _noteProviderFailure(response);
    }

    return null;
  }

  /// A truly offline geolocation mode cannot discover the public egress IP
  /// without contacting an external reflector. Leave it unknown instead of
  /// silently calling ip-api and violating the selected privacy mode.
  Future<GeoEndpoint?> _resolveEgressOffline(_GeoClient _) async => null;

  // ========== 目标侧 ==========

  /// 在线模式的目标解析。
  ///
  /// ① 先走生效代理做 DoH，拿到**本机真正会连过去**的那个 IP，再查这个 IP；
  /// ② 只有 DoH 整体失败时，才退化成把主机名交给接口，并置
  ///    [_TargetEntry.approximate]——CDN 的 anycast/GeoDNS 会让接口在它自己的
  ///    位置解析出另一个国家（实测 jetbrains CDN：接口侧 GB / 本机侧 TW）。
  ///
  /// 全程不碰 `InternetAddress.lookup`：fake-ip 代理会返回 198.18.x.x。
  Future<_TargetEntry> _resolveTargetOnline(
    _GeoClient client,
    String host, {
    required bool viaProxy,
    required String? proxyLabel,
    required String egressIdentity,
    required bool egressRuleBased,
  }) async {
    _TargetEntry build({
      GeoEndpoint endpoint = const GeoEndpoint(),
      String? error,
      bool approximate = false,
    }) {
      return _TargetEntry(
        endpoint: endpoint,
        at: DateTime.now(),
        ttl: error == null ? _targetTtl : _negativeTtl,
        viaProxy: viaProxy,
        proxyLabel: proxyLabel,
        egressIdentity: egressIdentity,
        egressRuleBased: egressRuleBased,
        fromOffline: false,
        approximate: approximate,
        error: error,
      );
    }

    // ① 出口视角的真实 IP。
    //
    // `reflectsEgress` 为 false 说明这个客户端并没有真的走上任务的通道
    // （典型场景：SOCKS5 代理但 rhttp 初始化失败，只能退化成直连客户端）。
    // 此时做 DoH 拿到的是**本机直连视角**的解析结果，而下载走的是 SOCKS 出口，
    // 两条完全不同的通道——拿它当实测值就违背了本文件顶部那条硬性结论。
    // 这里直接放弃 DoH，让流程落到「主机名交给接口」的退化路径，
    // 那条路径会自己标 approximate。
    final literal = InternetAddress.tryParse(host);
    final ip = literal?.address ?? await _resolveViaSystemDns(host);

    if (ip != null) {
      if (isNonRoutableIp(ip)) {
        // 目标本身就落在保留段（内网镜像等）：这是确定答案，不是失败。
        return build(endpoint: GeoEndpoint(ip: ip));
      }

      final (endpoint, error) = await _geolocate(client, ip);
      if (endpoint != null) {
        return build(endpoint: endpoint);
      }
      // IP 已知但两家接口都拿不到结果——退化成主机名也一样会失败，
      // 直接把已知的 IP 交出去，别再多打一次请求。
      return build(
        endpoint: GeoEndpoint(ip: ip),
        error: error ?? 'geolocation lookup failed',
      );
    }

    // ② DoH 整体失败：退化成主机名查询，结果标记为近似。
    final (endpoint, error) = await _geolocate(client, host);
    if (endpoint != null) {
      return build(endpoint: endpoint, approximate: true);
    }
    return build(
      error: error ?? 'geolocation lookup failed',
      approximate: true,
    );
  }

  /// 离线模式：DoH 拿到真实 IP，再查本地库。
  ///
  /// “离线”指的是**归属地数据库**在本地；DNS 往返仍然免不了（下载本身也要
  /// 解析域名），而且必须走 DoH——本机解析器在 fake-ip 环境下返回合成地址。
  /// 这里没有「主机名交给在线接口」这条退路：那是一次在线调用，
  /// 会违背设置页对用户作出的隐私承诺。
  Future<_TargetEntry> _resolveTargetOffline(
    _GeoClient client,
    String host, {
    required bool viaProxy,
    required String? proxyLabel,
    required String egressIdentity,
    required bool egressRuleBased,
  }) async {
    _TargetEntry build({
      GeoEndpoint endpoint = const GeoEndpoint(),
      String? error,
    }) {
      return _TargetEntry(
        endpoint: endpoint,
        at: DateTime.now(),
        ttl: error == null ? _targetTtl : _negativeTtl,
        viaProxy: viaProxy,
        proxyLabel: proxyLabel,
        egressIdentity: egressIdentity,
        egressRuleBased: egressRuleBased,
        fromOffline: true,
        error: error,
      );
    }

    // 同上：客户端没走上任务通道时，DoH 结果不代表下载的出口视角。
    // 离线模式没有「主机名交给接口」这条退路（那是一次在线调用），
    // 所以只能如实报未知。
    final literal = InternetAddress.tryParse(host);
    final ip = literal?.address ??
        (client.reflectsEgress ? await _resolveViaDoh(client, host) : null);
    if (ip == null) {
      return build(error: 'dns resolve failed');
    }

    if (isNonRoutableIp(ip)) {
      return build(endpoint: GeoEndpoint(ip: ip));
    }

    final parsed = InternetAddress.tryParse(ip);
    if (parsed != null && parsed.type == InternetAddressType.IPv6) {
      // 离线库暂不支持 IPv6，见 [_lookupOffline] 的说明。
      return build(
        endpoint: GeoEndpoint(ip: ip),
        error: 'ipv6 not supported by offline db',
      );
    }

    final code = await _lookupOffline(ip);
    if (code == null) {
      return build(endpoint: GeoEndpoint(ip: ip), error: 'offline db miss');
    }
    return build(endpoint: GeoEndpoint(ip: ip, countryCode: code));
  }

  /// Uses only the resolver configured by the operating system. This may be
  /// less accurate behind a remote-DNS proxy, but avoids disclosing every
  /// download hostname to a hard-coded public DoH provider in offline mode.
  Future<String?> _resolveViaSystemDns(String host) async {
    try {
      final addresses = await InternetAddress.lookup(host).timeout(_dnsTimeout);
      for (final address in addresses) {
        if (address.type == InternetAddressType.IPv4 &&
            !isNonRoutableIp(address.address)) {
          return address.address;
        }
      }
      for (final address in addresses) {
        if (!isNonRoutableIp(address.address)) {
          return address.address;
        }
      }
    } catch (e) {
      _logger.debug('GeoIP', 'System DNS failed for $host: $e');
    }
    return null;
  }

  /// 通过 HTTPS 的 ipwho.is 查询一个 IP（或退化路径下的主机名）的归属地。
  ///
  /// 返回 `(结果, 失败原因)`，两者必有其一。
  Future<(GeoEndpoint?, String?)> _geolocate(
    _GeoClient client,
    String query,
  ) async {
    final encoded = Uri.encodeComponent(query);
    String? lastError;

    if (_providerAvailable()) {
      final response = await _getJson(
        client,
        Uri.parse('$_ipWhoBaseUrl$encoded'),
      );
      final endpoint = _parseIpWho(response);
      if (endpoint != null) {
        _noteProviderSuccess();
        return (endpoint, null);
      }
      lastError = _readString(response?.json?['message']) ??
          response?.error ??
          lastError;
      _noteProviderFailure(response);
    }

    return (null, lastError);
  }

  /// 走生效代理做 DoH，优先 A 记录、其次 AAAA，两家端点依次尝试。
  ///
  /// 请求本身跟着代理走，所以它同时解决了两个问题：
  /// 绕开本机 fake-ip 解析器，并且从**真实出口**的视角看 CDN 的 GeoDNS。
  /// 整段失败会进入冷却，避免在 DoH 被墙的网络里每个主机都白白多打两次请求。
  Future<String?> _resolveViaDoh(_GeoClient client, String host) async {
    if (_dohCooldownUntil != null &&
        _dohCooldownUntil!.isAfter(DateTime.now())) {
      return null;
    }

    final encodedHost = Uri.encodeQueryComponent(host);
    var reachable = false;

    for (final (endpoint, accept) in _dohEndpoints) {
      final (ip, alive) =
          await _dohQuery(client, endpoint, accept, encodedHost);
      if (ip != null) {
        _dohFailures = 0;
        _dohCooldownUntil = null;
        return ip;
      }
      if (alive) {
        // 端点是通的，只是这个主机确实没有 A/AAAA 记录——换一家也是同样答案。
        reachable = true;
        break;
      }
    }

    if (!reachable) {
      _dohFailures++;
      if (_dohFailures >= _providerFailureThreshold) {
        _dohFailures = 0;
        _dohCooldownUntil = DateTime.now().add(_providerCooldown);
        _logger.warning(
          'GeoIP',
          'DoH unreachable, falling back to hostname geolocation for '
              '${_providerCooldown.inMinutes} min',
        );
      }
    }
    return null;
  }

  /// 向单个 DoH 端点查询一个主机名。
  ///
  /// 返回 `(命中的地址, 该端点是否可达)`：端点不可达时立刻放弃第二种记录类型，
  /// 免得在被墙的网络里对同一家白等两次超时。
  Future<(String?, bool)> _dohQuery(
    _GeoClient client,
    String endpoint,
    String accept,
    String encodedHost,
  ) async {
    var reachable = false;

    // A 优先：拿到 IPv4 才能同时喂给离线库，而且绝大多数主机都有 A 记录。
    for (final type in const <String>['A', 'AAAA']) {
      final response = await _getJson(
        client,
        Uri.parse('$endpoint?name=$encodedHost&type=$type'),
        timeout: _dnsTimeout,
        accept: accept,
        countsTowardQuota: false,
      );

      final json = response?.json;
      if (json == null) {
        // 传输失败 / 不是 JSON：这家端点不通。
        return (null, reachable);
      }
      reachable = true;

      final answers = json['Answer'];
      if (answers is! List) {
        continue; // 没有该类型的记录，换一种记录类型。
      }

      final wanted = type == 'A' ? 1 : 28;
      for (final item in answers) {
        if (item is! Map) {
          continue;
        }
        if (item['type'] != wanted) {
          continue; // CNAME 链上的中间记录，跳过。
        }
        final parsed = InternetAddress.tryParse(
          _readString(item['data']) ?? '',
        );
        if (parsed != null) {
          return (parsed.address, true);
        }
      }
    }

    return (null, reachable);
  }

  /// 在本地离线表里查一个 IP。
  ///
  /// 只支持 IPv4：Dart 没有 128 位整数，IPv6 需要 BigInt 或 hi/lo 双键比较器，
  /// 而且要多下 12.6 MB 的第二份 CSV。当前 A 记录优先的解析顺序让 IPv6
  /// 只在 AAAA-only 的主机上出现，收益远低于复杂度，故明确不做。
  Future<String?> _lookupOffline(String ip) async {
    final value = ipv4ToInt(ip);
    if (value == null) {
      return null;
    }
    final table = await _ensureOfflineTable();
    if (table == null || table.isEmpty) {
      return null;
    }
    return normalizeCountryCode(table.lookup(value));
  }

  Future<GeoV4Table?> _ensureOfflineTable() {
    final existing = _offlineTable;
    if (existing != null) {
      return Future<GeoV4Table?>.value(existing);
    }
    final pending = _offlineTableLoading;
    if (pending != null) {
      return pending;
    }

    final future = _loadOfflineTable();
    _offlineTableLoading = future;
    return future.whenComplete(() {
      if (identical(_offlineTableLoading, future)) {
        _offlineTableLoading = null;
      }
    });
  }

  /// 解析 10 MB CSV。
  ///
  /// 明确使用 `compute()`（后台 isolate）：主 isolate 上做这件事会造成
  /// 几百毫秒的掉帧，而这个页面正在滚动。
  Future<GeoV4Table?> _loadOfflineTable() async {
    final dirPath = _packDirPath();
    if (dirPath == null) {
      return null;
    }
    final file = File(p.join(dirPath, _packFileName));
    try {
      if (!await file.exists()) {
        return null;
      }
      final raw = await compute(parseGeoV4Csv, file.path);
      if (raw.length != 3) {
        return null;
      }
      final table = GeoV4Table(
        starts: raw[0] as Uint32List,
        ends: raw[1] as Uint32List,
        codes: raw[2] as Uint16List,
      );
      if (table.isEmpty) {
        return null;
      }
      _offlineTable = table;
      _logger.info('GeoIP', 'Offline table loaded (${table.length} ranges)');
      return table;
    } catch (e) {
      _logger.warning('GeoIP', 'Offline table parse failed: $e');
      return null;
    }
  }

  // ========== HTTP ==========

  Future<kernel.ProxyConfig?> _readProxyConfig() async {
    try {
      final config = await KernelManager().getConfig().timeout(
            const Duration(seconds: 3),
          );
      _kernelConfigSeen = config != null;
      return config?.proxy;
    } catch (_) {
      // 内核尚未启动或调用超时：按直连处理，但用短 TTL 让它很快复查。
      _kernelConfigSeen = false;
      return null;
    }
  }

  bool _kernelConfigSeen = false;

  /// 按生效代理打开一个 HTTP 客户端。
  ///
  /// `dart:io` 的 `HttpClient.findProxy` **不认识 SOCKS5** —— 传入
  /// `'SOCKS5 host:port'` 会直接抛 `HttpException`，而不是静默直连。
  /// 因此 SOCKS 场景改用 rhttp 的 `IoCompatibleClient`（内核下载走的也是它）。
  /// 万一 rhttp 不可用，就退化成直连客户端并把 `reflectsEgress` 置 false：
  /// 目标国仍然查得到（那是接口在它自己的位置解析的，与我们的出口无关），
  /// 但出口国会留空——绝不能拿直连的国家去冒充代理出口。
  Future<_GeoClient> _openClient(NsfxResolvedProxy proxy) async {
    if (_requiresSocksTransport(proxy)) {
      try {
        await _ensureRhttpInitialized();
        final settings = rhttp.ClientSettings(
          throwOnStatusCode: false,
          proxySettings: NsfxProxyRuntime.toRhttpProxySettings(proxy),
          timeoutSettings: const rhttp.TimeoutSettings(
            connectTimeout: _connectTimeout,
          ),
        );
        final client = await rhttp.IoCompatibleClient.create(
          settings: settings,
        );
        return _GeoClient(client, reflectsEgress: true);
      } catch (e) {
        _logger.warning(
          'GeoIP',
          'SOCKS transport unavailable, egress country will stay unknown: $e',
        );
        final fallback = HttpClient()
          ..connectionTimeout = _connectTimeout
          ..idleTimeout = const Duration(seconds: 5)
          ..userAgent = _userAgent;
        fallback.findProxy = (_) => 'DIRECT';
        return _GeoClient(fallback, reflectsEgress: false);
      }
    }

    final client = HttpClient()
      ..connectionTimeout = _connectTimeout
      ..idleTimeout = const Duration(seconds: 5)
      ..userAgent = _userAgent;
    NsfxProxyRuntime.applyToHttpClient(client, proxy);
    return _GeoClient(client, reflectsEgress: true);
  }

  static bool _requiresSocksTransport(NsfxResolvedProxy proxy) {
    if (!proxy.hasProxy || proxy.usesSystemSettings) {
      return false;
    }
    if (proxy.type.toLowerCase().contains('socks')) {
      return true;
    }
    final directive =
        (proxy.proxyChainDirective ?? proxy.proxyDirective ?? '').toUpperCase();
    return directive.contains('SOCKS');
  }

  static Future<void> _ensureRhttpInitialized() {
    final existing = _rhttpInitFuture;
    if (existing != null) {
      return existing;
    }
    final initFuture = rhttp.Rhttp.init();
    _rhttpInitFuture = initFuture;
    return initFuture.catchError((Object error) {
      if (identical(_rhttpInitFuture, initFuture)) {
        _rhttpInitFuture = null;
      }
      throw error;
    });
  }

  Future<_JsonResponse?> _getJson(
    _GeoClient client,
    Uri uri, {
    Duration? timeout,
    String accept = 'application/json',
    bool countsTowardQuota = true,
  }) async {
    await _throttle(countsTowardQuota: countsTowardQuota);

    try {
      final request = await client.client.getUrl(uri).timeout(_connectTimeout);
      request.headers.set(HttpHeaders.acceptHeader, accept);
      final response =
          await request.close().timeout(timeout ?? _requestTimeout);

      // 先攒字节再整体解码：分块解码会在多字节字符被切开时产生乱码。
      final buffer = BytesBuilder(copy: false);
      final bodyTimeout = timeout ?? _requestTimeout;
      final watch = Stopwatch()..start();
      await for (final chunk in response.timeout(bodyTimeout)) {
        if (watch.elapsed > bodyTimeout) {
          throw TimeoutException(
              'response body deadline exceeded', bodyTimeout);
        }
        final remaining = _maxResponseBytes - buffer.length;
        if (remaining <= 0) break;
        buffer.add(
          chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
        );
      }

      Map<String, dynamic>? json;
      try {
        final text = const Utf8Decoder(
          allowMalformed: true,
        ).convert(buffer.takeBytes());
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          json = decoded;
        }
      } catch (_) {
        json = null;
      }

      return _JsonResponse(
        statusCode: response.statusCode,
        json: json,
        retryAfterSeconds: _parseRetryAfter(response),
      );
    } catch (e) {
      return _JsonResponse(statusCode: 0, json: null, error: e.toString());
    }
  }

  static int? _parseRetryAfter(HttpClientResponse response) {
    try {
      final ttl = response.headers.value('x-ttl') ??
          response.headers.value(HttpHeaders.retryAfterHeader);
      if (ttl == null) {
        return null;
      }
      return int.tryParse(ttl.trim());
    } catch (_) {
      return null;
    }
  }

  /// 全局限流：最小间隔 + 60 秒滑动窗口。
  ///
  /// [countsTowardQuota] 为 false 时（DoH）只遵守一个很小的礼貌间隔，
  /// 不占用归属地接口的配额窗口——两者的额度完全是两回事。
  Future<void> _throttle({bool countsTowardQuota = true}) async {
    final requiredGap = countsTowardQuota ? _minRequestGap : _dohRequestGap;
    final last = _lastRequestAt;
    if (last != null) {
      final gap = DateTime.now().difference(last);
      if (gap < requiredGap) {
        await Future<void>.delayed(requiredGap - gap);
      }
    }

    if (countsTowardQuota) {
      _pruneRequestWindow();
      if (_requestWindow.length >= _maxRequestsPerWindow) {
        final oldest = _requestWindow.first;
        final wait = _rateWindow - DateTime.now().difference(oldest);
        if (wait > Duration.zero) {
          await Future<void>.delayed(wait);
        }
        _pruneRequestWindow();
      }
    }

    final stamp = DateTime.now();
    _lastRequestAt = stamp;
    if (countsTowardQuota) {
      _requestWindow.add(stamp);
    }
  }

  void _pruneRequestWindow() {
    final now = DateTime.now();
    _requestWindow.removeWhere((at) => now.difference(at) > _rateWindow);
  }

  bool _providerAvailable() {
    final until = _ipWhoCooldownUntil;
    return until == null || !until.isAfter(DateTime.now());
  }

  void _noteProviderSuccess() {
    _ipWhoFailures = 0;
    _ipWhoCooldownUntil = null;
  }

  void _noteProviderFailure(_JsonResponse? response) {
    // Respect Retry-After on quota responses.
    if (response != null && response.statusCode == 429) {
      final seconds = response.retryAfterSeconds ?? 60;
      _ipWhoCooldownUntil = DateTime.now().add(
        Duration(seconds: seconds < 60 ? 60 : seconds),
      );
      return;
    }

    // 只有传输层失败才计入熔断；接口正常返回 "fail" 说明服务是活的。
    final transportFailure = response == null ||
        response.error != null ||
        response.statusCode >= 500 ||
        response.json == null;
    if (!transportFailure) {
      return;
    }

    _ipWhoFailures++;
    if (_ipWhoFailures >= _providerFailureThreshold) {
      _ipWhoFailures = 0;
      _ipWhoCooldownUntil = DateTime.now().add(_providerCooldown);
    }
  }

  // ========== 响应解析（逐字段防御，不做盲目 cast） ==========

  static GeoEndpoint? _parseIpWho(_JsonResponse? response) {
    final json = response?.json;
    if (json == null || json['success'] != true) {
      return null;
    }
    final code = normalizeCountryCode(_readString(json['country_code']));
    final ip = _readString(json['ip']);
    if (code == null && ip == null) {
      return null;
    }

    String? asnOrg;
    final connection = json['connection'];
    if (connection is Map) {
      final asn = connection['asn'];
      final org = _readString(connection['org']) ??
          _readString(connection['isp']) ??
          _readString(connection['domain']);
      if (asn is int && asn > 0) {
        asnOrg = org == null ? 'AS$asn' : 'AS$asn $org';
      } else {
        asnOrg = org;
      }
    }

    return GeoEndpoint(
      ip: ip,
      countryCode: code,
      countryName: _readString(json['country']),
      asnOrg: asnOrg,
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  // ========== 缓存提交 / 通知 ==========

  void _commitTarget(String host, _TargetEntry entry) {
    final previous = _targetCache[host];
    _targetCache[host] = entry;
    _evictOldest<_TargetEntry>(_targetCache, (e) => e.at);

    final changed = previous == null ||
        !_sameEndpoint(previous.endpoint, entry.endpoint) ||
        previous.error != entry.error ||
        previous.viaProxy != entry.viaProxy ||
        previous.proxyLabel != entry.proxyLabel ||
        previous.fromOffline != entry.fromOffline ||
        previous.approximate != entry.approximate ||
        previous.egressIdentity != entry.egressIdentity;
    if (changed) {
      _scheduleNotify();
    }
  }

  void _commitEgress(String identity, _EgressEntry entry) {
    final previous = _egressCache[identity];
    _egressCache[identity] = entry;
    _evictOldest<_EgressEntry>(_egressCache, (e) => e.at);

    if (previous == null || !_sameEndpoint(previous.endpoint, entry.endpoint)) {
      _scheduleNotify();
    }
  }

  static bool _sameEndpoint(GeoEndpoint a, GeoEndpoint b) {
    return a.ip == b.ip &&
        a.countryCode == b.countryCode &&
        a.countryName == b.countryName &&
        a.asnOrg == b.asnOrg;
  }

  static void _evictOldest<T>(Map<String, T> cache, DateTime Function(T) at) {
    if (cache.length <= _maxCacheEntries) {
      return;
    }
    String? oldestKey;
    DateTime? oldest;
    for (final entry in cache.entries) {
      final stamp = at(entry.value);
      if (oldest == null || stamp.isBefore(oldest)) {
        oldest = stamp;
        oldestKey = entry.key;
      }
    }
    if (oldestKey != null) {
      cache.remove(oldestKey);
    }
  }

  /// 合并 16 ms 内的多次结果，避免 N 张卡片触发 N 次全局重建。
  void _scheduleNotify() {
    if (_disposed || _notifyTimer != null) {
      return;
    }
    _notifyTimer = Timer(_notifyDebounce, () {
      _notifyTimer = null;
      _safeNotify();
    });
  }

  void _safeNotify() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  // ========== 持久化 ==========

  /// 读取数据源设置。
  ///
  /// 主键 [kSourceKey] 是字符串。历史版本在 `ClientConfigService` 还没有
  /// `getString`/`setString` 时用布尔镜像键 [_kSourceOfflineMirrorKey] 存过一次，
  /// 所以主键为空时仍然回落到镜像键，避免老用户的选择被静默重置。
  String _readPersistedSource() {
    try {
      final raw = _config.getString(kSourceKey, defaultValue: '');
      if (raw.trim().isNotEmpty) {
        return normalizeSource(raw);
      }
    } catch (e) {
      _logger.warning('GeoIP', 'Failed to read $kSourceKey: $e');
    }

    try {
      return _config.getBool(_kSourceOfflineMirrorKey, defaultValue: false)
          ? sourceOffline
          : sourceOnline;
    } catch (_) {
      return sourceOnline;
    }
  }

  Future<void> _writePersistedSource(String value) async {
    await _persistString(kSourceKey, value);
    // 镜像键继续写，保证降级安装回旧版本时设置不丢。
    await _persistBool(_kSourceOfflineMirrorKey, value == sourceOffline);
  }

  /// 写一个字符串配置，永不抛出。理由同 [_persistBool]。
  Future<void> _persistString(String key, String value) async {
    try {
      await _config.setString(key, value);
    } catch (e) {
      _logger.warning('GeoIP', 'Failed to persist $key: $e');
    }
  }

  /// 写一个布尔配置，永不抛出。
  ///
  /// `ClientConfigService` 的写入路径依赖 `late` 的文件路径字段：在它
  /// `initialize()` 完成之前调用 `setBool` 会抛 `LateInitializationError`。
  /// 这个异常一旦冒泡，就会从设置页的 `onChanged` 里炸出来；
  /// 用户此刻真正想要的是「开关立刻生效」，持久化失败只是下次启动回到默认值。
  Future<void> _persistBool(String key, bool value) async {
    try {
      await _config.setBool(key, value);
    } catch (e) {
      _logger.warning('GeoIP', 'Failed to persist $key: $e');
    }
  }

  // ========== 纯函数工具（单元测试只针对这些，不触网不落盘） ==========

  /// 把下载 URL 归一化成缓存键：只取主机名，忽略端口与路径。
  static String? hostKeyFor(String url) {
    final raw = url.trim();
    if (raw.isEmpty) {
      return null;
    }

    var uri = Uri.tryParse(raw);
    if (uri == null || uri.host.trim().isEmpty) {
      uri = Uri.tryParse('http://$raw');
    }

    final host = uri?.host.trim().toLowerCase() ?? '';
    return host.isEmpty ? null : host;
  }

  /// 归一化 ISO 3166-1 alpha-2 国家码，非法值返回 null。
  static String? normalizeCountryCode(String? raw) {
    final value = raw?.trim().toUpperCase() ?? '';
    if (value.length != 2) {
      return null;
    }
    for (var i = 0; i < 2; i++) {
      final unit = value.codeUnitAt(i);
      if (unit < 0x41 || unit > 0x5A) {
        return null;
      }
    }
    return value;
  }

  /// 归一化数据源取值，未知输入一律回落到在线接口。
  static String normalizeSource(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    return value == sourceOffline ? sourceOffline : sourceOnline;
  }

  /// 点分十进制 → 无符号 32 位整数（用 Dart 的 64 位 int 承载，不会溢出）。
  static int? ipv4ToInt(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return null;
    }
    final parts = text.split('.');
    if (parts.length != 4) {
      return null;
    }

    var result = 0;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) {
        return null;
      }
      var octet = 0;
      for (var i = 0; i < part.length; i++) {
        final unit = part.codeUnitAt(i);
        if (unit < 0x30 || unit > 0x39) {
          return null;
        }
        octet = octet * 10 + (unit - 0x30);
      }
      if (octet > 255) {
        return null;
      }
      result = (result << 8) | octet;
    }
    return result;
  }

  /// 在升序的 [starts] 上做上界二分：返回最大的 `i` 使 `starts[i] <= ip`。
  /// 全部大于 [ip] 时返回 -1。
  static int lookupIndex(Uint32List starts, int ip) {
    var low = 0;
    var high = starts.length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (starts[mid] <= ip) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  /// 主机是否属于“不该也不能定位”的一类。
  /// 代理是否为「规则型」本地客户端（Clash / mihomo / sing-box / v2ray 等）。
  ///
  /// 判据是代理监听在本机回环上。这类客户端把分流规则放在自己内部，应用只能
  /// 看到 `127.0.0.1:7897` 这一个地址，**无法得知某个具体目标会被分流到哪条
  /// 规则**——同一个客户端完全可能把 A 站点走日本节点、B 站点直连。
  ///
  /// 于是我们测到的「出口国」其实是「查询归属地接口时命中的那条规则」的落地，
  /// 下载目标很可能命中另一条。这种情况下把出口国当确定值展示就是在编，
  /// 所以标成 approximate，由 tooltip 如实说明。
  ///
  /// 想要精确只有一条路：读取客户端自己的 API（如 Clash 的 external-controller
  /// `/connections`）拿到每条连接实际走的节点。那需要用户开启该接口并配置密钥，
  /// 且各客户端互不兼容，不在当前范围内。
  static bool isRuleBasedProxy(NsfxResolvedProxy proxy) {
    if (!proxy.hasProxy) return false;
    // 系统代理走 PAC / 系统设置，分流同样不透明。
    if (proxy.usesSystemSettings) return true;
    final host = proxy.host.trim().toLowerCase();
    if (host.isEmpty) return false;
    return host == 'localhost' ||
        host.endsWith('.localhost') ||
        isNonRoutableIp(host);
  }

  static bool isPrivateHost(String host) {
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }
    if (normalized == 'localhost' ||
        normalized.endsWith('.localhost') ||
        normalized.endsWith('.local')) {
      return true;
    }
    return isNonRoutableIp(normalized);
  }

  /// 是否为不可路由 / 合成地址。
  ///
  /// 198.18.0.0/15（RFC 2544 基准测试段）与 100.64.0.0/10（CGNAT）在这里
  /// 尤其关键：Clash / mihomo / sing-box 的 fake-ip 模式会把所有域名解析到
  /// 198.18.x.x，这是“本机处在 fake-ip 代理之后”的确凿信号，
  /// 绝不能拿它当作目标服务器的真实位置去查询。
  static bool isNonRoutableIp(String raw) {
    final address = InternetAddress.tryParse(raw.trim());
    if (address == null) {
      return false;
    }

    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return _isNonRoutableV4(bytes[0], bytes[1], bytes[2], bytes[3]);
    }
    if (bytes.length != 16) {
      return false;
    }

    var leadingZeros = true;
    for (var i = 0; i < 10; i++) {
      if (bytes[i] != 0) {
        leadingZeros = false;
        break;
      }
    }

    if (leadingZeros) {
      // ::ffff:a.b.c.d —— IPv4 映射地址
      if (bytes[10] == 0xFF && bytes[11] == 0xFF) {
        return _isNonRoutableV4(bytes[12], bytes[13], bytes[14], bytes[15]);
      }
      // :: 与 ::1
      var tailZero = true;
      for (var i = 10; i < 15; i++) {
        if (bytes[i] != 0) {
          tailZero = false;
          break;
        }
      }
      if (tailZero && (bytes[15] == 0 || bytes[15] == 1)) {
        return true;
      }
    }

    if ((bytes[0] & 0xFE) == 0xFC) {
      return true; // fc00::/7 ULA
    }
    if (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) {
      return true; // fe80::/10 link-local
    }
    if (bytes[0] == 0xFF) {
      return true; // ff00::/8 multicast
    }
    return false;
  }

  static bool _isNonRoutableV4(int a, int b, int c, int d) {
    final value = (a << 24) | (b << 16) | (c << 8) | d;
    for (final range in _nonRoutableV4Ranges) {
      final prefix = range.$2;
      final mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
      if ((value & mask) == (range.$1 & mask)) {
        return true;
      }
    }
    return false;
  }

  static const List<(int, int)> _nonRoutableV4Ranges = <(int, int)>[
    (0x00000000, 8), // 0.0.0.0/8
    (0x0A000000, 8), // 10.0.0.0/8
    (0x64400000, 10), // 100.64.0.0/10 CGNAT
    (0x7F000000, 8), // 127.0.0.0/8
    (0xA9FE0000, 16), // 169.254.0.0/16
    (0xAC100000, 12), // 172.16.0.0/12
    (0xC0000000, 24), // 192.0.0.0/24
    (0xC0000200, 24), // 192.0.2.0/24
    (0xC0A80000, 16), // 192.168.0.0/16
    (0xC6120000, 15), // 198.18.0.0/15 fake-ip
    (0xC6336400, 24), // 198.51.100.0/24
    (0xCB007100, 24), // 203.0.113.0/24
    (0xE0000000, 4), // 224.0.0.0/4
    (0xF0000000, 4), // 240.0.0.0/4（含 255.255.255.255）
  ];

  /// 人类可读的资源包体积，例如 `10.3 MB`。
  static String formatPackSize(int bytes) {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static Uri _probeUriForHost(String host) {
    final literal = host.contains(':') ? '[$host]' : host;
    return Uri.parse('https://$literal/');
  }
}

/// 一个已经按生效代理配置好的 HTTP 客户端。
class _GeoClient {
  _GeoClient(this.client, {required this.reflectsEgress});

  final HttpClient client;

  /// 该客户端是否真的从「生效代理」出去。false 时出口国必须留空。
  final bool reflectsEgress;

  void close() {
    try {
      client.close(force: true);
    } catch (_) {
      // 忽略：关闭失败不影响调用方。
    }
  }
}

class _JsonResponse {
  const _JsonResponse({
    required this.statusCode,
    required this.json,
    this.retryAfterSeconds,
    this.error,
  });

  final int statusCode;
  final Map<String, dynamic>? json;
  final int? retryAfterSeconds;
  final String? error;
}

class _TargetEntry {
  const _TargetEntry({
    required this.endpoint,
    required this.at,
    required this.ttl,
    required this.viaProxy,
    required this.proxyLabel,
    required this.egressIdentity,
    required this.fromOffline,
    this.approximate = false,
    this.localRoute = false,
    this.egressRuleBased = false,
    this.error,
  });

  final GeoEndpoint endpoint;
  final DateTime at;
  final Duration ttl;
  final bool viaProxy;
  final String? proxyLabel;
  final String egressIdentity;
  final bool fromOffline;

  /// 目标国来自「主机名交给接口」的退化路径，可能与本机实际连接的节点不符。
  final bool approximate;

  /// 整条链路都在本机 / 内网，两端都没有归属国，也不该去查出口。
  final bool localRoute;

  /// 代理是本机回环上的规则型客户端，出口国只能算「很可能」。
  final bool egressRuleBased;

  final String? error;

  bool isExpired(DateTime now) => now.difference(at) >= ttl;
}

class _EgressEntry {
  const _EgressEntry({
    required this.endpoint,
    required this.at,
    required this.ttl,
  });

  final GeoEndpoint endpoint;
  final DateTime at;
  final Duration ttl;

  bool isExpired(DateTime now) => now.difference(at) >= ttl;
}

/// 在后台 isolate 解析 ip-location-db 的 IPv4 CSV。
///
/// 每行形如 `1.0.0.0,1.0.0.255,AU`，无表头。返回
/// `[Uint32List starts, Uint32List ends, Uint16List codes]` —— 只用 typed data
/// 是为了让 `compute()` 的跨 isolate 传递零歧义，也把内存压到 ~2.5 MB。
///
/// 上游声明按起始地址升序，但这里仍然做一次 O(n) 单调性校验，
/// 一旦发现乱序就整体排序，保证二分查找永远正确。
/// 读取资源包文本行，透明处理 gzip。
///
/// 手动下载来的包常常是 `.csv.gz`——用户不该被要求先自己解压。
/// 靠魔数（0x1f 0x8b）判断而不是扩展名：扩展名会骗人，魔数不会。
List<String> readGeoPackLines(String filePath) {
  final file = File(filePath);
  final raf = file.openSync();
  bool gzipped;
  try {
    final head = raf.readSync(2);
    gzipped = head.length == 2 && head[0] == 0x1f && head[1] == 0x8b;
  } finally {
    raf.closeSync();
  }

  if (!gzipped) {
    return file.readAsLinesSync();
  }
  final decoded = gzip.decode(file.readAsBytesSync());
  return const LineSplitter()
      .convert(utf8.decode(decoded, allowMalformed: true));
}

/// 按逗号切出前 [maxFields] 个字段，顺带剥掉包裹的引号。
///
/// IP2Location LITE 的每个字段都带双引号（`"16777216","16777471","AU","Australia"`），
/// 而 ip-location-db 不带。统一在这里抹平差异。
List<String> splitGeoPackFields(String line, int maxFields) {
  final fields = <String>[];
  var start = 0;
  for (var i = 0; i <= line.length && fields.length < maxFields; i++) {
    if (i == line.length || line[i] == ',') {
      var field = line.substring(start, i).trim();
      if (field.length >= 2 && field.startsWith('"') && field.endsWith('"')) {
        field = field.substring(1, field.length - 1).trim();
      }
      fields.add(field);
      start = i + 1;
      if (i == line.length) break;
    }
  }
  return fields;
}

/// 解析一个 IPv4 区间端点，同时接受点分与十进制两种写法。
///
/// ip-location-db 写 `1.0.0.0`，IP2Location LITE 写 `16777216`。
int? parseGeoPackAddress(String text) {
  final value = text.trim();
  if (value.isEmpty) return null;

  if (value.contains('.')) {
    return GeoIpService.ipv4ToInt(value);
  }

  final decimal = int.tryParse(value);
  if (decimal == null || decimal < 0 || decimal > 0xFFFFFFFF) {
    return null;
  }
  return decimal;
}

List<Object> parseGeoV4Csv(String filePath) {
  final starts = <int>[];
  final ends = <int>[];
  final codes = <int>[];

  for (final rawLine in readGeoPackLines(filePath)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }

    // 取前三个字段即可；IP2Location LITE 还有第四列国家全名，直接忽略。
    final fields = splitGeoPackFields(line, 3);
    if (fields.length < 3) {
      continue;
    }

    final startText = fields[0];
    final endText = fields[1];
    if (startText.contains(':') || endText.contains(':')) {
      continue; // IPv6 行：当前离线库只支持 IPv4
    }

    final code = GeoIpService.normalizeCountryCode(fields[2]);
    if (code == null) {
      continue;
    }

    final start = parseGeoPackAddress(startText);
    final end = parseGeoPackAddress(endText);
    if (start == null || end == null || end < start) {
      continue;
    }

    starts.add(start);
    ends.add(end);
    codes.add((code.codeUnitAt(0) << 8) | code.codeUnitAt(1));
  }

  var sorted = true;
  for (var i = 1; i < starts.length; i++) {
    if (starts[i] < starts[i - 1]) {
      sorted = false;
      break;
    }
  }

  if (!sorted) {
    final order = List<int>.generate(starts.length, (index) => index)
      ..sort((a, b) => starts[a].compareTo(starts[b]));
    final sortedStarts = List<int>.filled(order.length, 0);
    final sortedEnds = List<int>.filled(order.length, 0);
    final sortedCodes = List<int>.filled(order.length, 0);
    for (var i = 0; i < order.length; i++) {
      final source = order[i];
      sortedStarts[i] = starts[source];
      sortedEnds[i] = ends[source];
      sortedCodes[i] = codes[source];
    }
    return <Object>[
      Uint32List.fromList(sortedStarts),
      Uint32List.fromList(sortedEnds),
      Uint16List.fromList(sortedCodes),
    ];
  }

  return <Object>[
    Uint32List.fromList(starts),
    Uint32List.fromList(ends),
    Uint16List.fromList(codes),
  ];
}
