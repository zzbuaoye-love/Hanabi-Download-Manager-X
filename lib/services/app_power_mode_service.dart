import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'app_logger_service.dart';
import 'client_config_service.dart';

/// 应用整体的功耗档位。
///
/// 三档之间只有"后台业务保留多少"的差别，下载内核本身永远不受影响：
/// NSFX 引擎与 NeoNSF 边车进程都不订阅这里的状态，任务该跑还是照跑。
/// 这里降的全部是"为了让界面好看"而付出的开销——轮询、统计、动画、重建。
enum AppPowerMode {
  /// 主窗口可见：全速运行，一切按原有节奏。
  active,

  /// 主窗口被隐藏到托盘或最小化：降频，但仍保持较快的响应。
  background,

  /// 长时间没人把窗口拉到前台：极致精简模式。
  ultraLite,
}

/// 全局功耗调度中枢。
///
/// 单一事实来源：窗口可见性由 [setWindowVisible] 汇入，空闲计时到点后自动
/// 切到 [AppPowerMode.ultraLite]；任何"要把窗口拉起来"的路径都必须先调用
/// [wakeForForeground]，这样第一帧渲染之前各服务已经恢复到全速档。
class AppPowerModeService extends ChangeNotifier {
  static final AppPowerModeService _instance = AppPowerModeService._internal();

  factory AppPowerModeService() => _instance;

  AppPowerModeService._internal();

  static const MethodChannel _windowChannel =
      MethodChannel('com.hanabi.download/window');

  /// 空闲阈值的合法区间，设置页与配置读取共用。
  static const int minIdleMinutes = 1;
  static const int maxIdleMinutes = 180;
  static const int defaultIdleMinutes = 5;

  final ClientConfigService _config = ClientConfigService();
  final AppLoggerService _logger = AppLoggerService();

  AppPowerMode _mode = AppPowerMode.active;
  bool _windowVisible = true;
  bool _initialized = false;
  Timer? _idleTimer;
  DateTime? _backgroundSince;
  DateTime? _ultraLiteSince;

  AppPowerMode get mode => _mode;

  /// 是否处于极致精简模式。
  bool get isUltraLite => _mode == AppPowerMode.ultraLite;

  /// 窗口不可见（含托盘隐藏与最小化）。
  bool get isBackground => _mode != AppPowerMode.active;

  bool get isWindowVisible => _windowVisible;

  /// 进入极致精简模式的时刻，未进入时为 null。
  DateTime? get ultraLiteSince => _ultraLiteSince;

  /// 已经在后台待了多久，前台时为 null。
  Duration? get backgroundDuration {
    final since = _backgroundSince;
    if (since == null) return null;
    return DateTime.now().difference(since);
  }

  bool get autoUltraLiteEnabled => _config.getUltraLiteModeEnabled();

  Duration get idleThreshold =>
      Duration(minutes: _config.getUltraLiteIdleMinutes());

  /// 由主窗口启动流程调用一次。popup / 托盘菜单等副进程不应调用。
  void initialize({bool windowVisible = true}) {
    if (_initialized) return;
    _initialized = true;
    _config.addListener(_handleConfigChanged);
    setWindowVisible(windowVisible);
  }

  /// 窗口可见性变化的唯一入口。
  void setWindowVisible(bool visible) {
    final changed = _windowVisible != visible;
    _windowVisible = visible;

    if (visible) {
      _backgroundSince = null;
      _cancelIdleTimer();
      _applyMode(AppPowerMode.active);
      return;
    }

    if (changed || _backgroundSince == null) {
      _backgroundSince = DateTime.now();
    }
    if (_mode != AppPowerMode.ultraLite) {
      _applyMode(AppPowerMode.background);
    }
    _scheduleIdleTimer();
  }

  /// 在真正把窗口显示出来之前调用，保证服务先回到全速档。
  ///
  /// 同步返回：所有恢复动作都是"取消/重排定时器 + 补一次通知"，不含 await，
  /// 因此不会给窗口显示路径增加任何延迟。
  void wakeForForeground() {
    if (_windowVisible && _mode == AppPowerMode.active) return;
    setWindowVisible(true);
  }

  /// 后台发生了真实业务（浏览器交来新下载、弹窗桥收到请求……）。
  ///
  /// 窗口仍然不可见，所以只退回 [AppPowerMode.background] 并重新开始倒计时，
  /// 不假装用户已经回到前台。
  void noteBackgroundActivity() {
    if (_windowVisible) return;

    _backgroundSince = DateTime.now();
    if (_mode == AppPowerMode.ultraLite) {
      _applyMode(AppPowerMode.background);
    }
    _scheduleIdleTimer();
  }

  void _applyMode(AppPowerMode next) {
    if (_mode == next) return;

    final previous = _mode;
    _mode = next;
    _ultraLiteSince = next == AppPowerMode.ultraLite ? DateTime.now() : null;

    _logger.info(
      'Power',
      'App power mode: ${previous.name} -> ${next.name}',
    );

    if (next == AppPowerMode.ultraLite) {
      _releaseIdleResources();
    }

    notifyListeners();
  }

  void _scheduleIdleTimer() {
    _cancelIdleTimer();
    if (_windowVisible || !autoUltraLiteEnabled) return;
    if (_mode == AppPowerMode.ultraLite) return;

    final elapsed = backgroundDuration ?? Duration.zero;
    final remaining = idleThreshold - elapsed;
    _idleTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        _idleTimer = null;
        if (_windowVisible || !autoUltraLiteEnabled) return;
        _applyMode(AppPowerMode.ultraLite);
      },
    );
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _handleConfigChanged() {
    if (_windowVisible) return;

    if (!autoUltraLiteEnabled) {
      _cancelIdleTimer();
      if (_mode == AppPowerMode.ultraLite) {
        _applyMode(AppPowerMode.background);
      }
      return;
    }

    if (_mode == AppPowerMode.ultraLite) return;
    _scheduleIdleTimer();
  }

  /// 进入极致精简模式时一次性归还内存。
  ///
  /// 图片缓存在窗口隐藏后完全没有用处，解码后的位图往往是常驻内存里最大的
  /// 一块；工作集裁剪则把已经冷掉的页交还给系统，任务管理器里的占用会明显
  /// 下降。两者都只影响下次显示时的首帧解码，不影响下载。
  void _releaseIdleResources() {
    try {
      final imageCache = PaintingBinding.instance.imageCache;
      imageCache.clear();
      imageCache.clearLiveImages();
    } catch (error) {
      _logger.debug('Power', 'Image cache release skipped: $error');
    }

    unawaited(_trimNativeWorkingSet());
  }

  Future<void> _trimNativeWorkingSet() async {
    if (!Platform.isWindows) return;
    try {
      await _windowChannel.invokeMethod<bool>('trimWorkingSet');
    } catch (error) {
      _logger.debug(
        'Power',
        'Native working-set trim unavailable: $error',
        toConsole: false,
      );
    }
  }

  @override
  void dispose() {
    _cancelIdleTimer();
    if (_initialized) {
      _config.removeListener(_handleConfigChanged);
      _initialized = false;
    }
    super.dispose();
  }
}
