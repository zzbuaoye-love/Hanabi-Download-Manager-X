import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../l10n/app_localizations.dart';
import '../l10n/fallback_localizations_delegate.dart';
import '../theme/app_theme.dart';
import '../utils/constants.dart';
import '../utils/fluent_icons.dart' as CustomIcons;

const MethodChannel _windowChannel =
    MethodChannel('com.hanabi.download/window');

@visibleForTesting
const EdgeInsets kTrayMenuWindowInsets = EdgeInsets.fromLTRB(12, 8, 12, 20);

@visibleForTesting
Size calculateTrayMenuWindowSize(Size contentSize) {
  return Size(
    contentSize.width.ceilToDouble() + kTrayMenuWindowInsets.horizontal,
    contentSize.height.ceilToDouble() + kTrayMenuWindowInsets.vertical,
  );
}

/// Everything the native window needs to host the menu.
///
/// [envelope] is the content currently on screen (main panel, plus the open
/// submenu). The window hugs it: on machines where DWM per-pixel alpha is
/// unavailable the uncovered window area renders as an opaque near-black
/// rectangle, so any speculative reservation shows up as a giant dark box.
/// Submenu opens grow the window FIRST and paint only after the native side
/// acknowledges, which is what prevents the flyout being sliced off mid-tile.
/// [mainPanel] is the visible menu panel used to anchor positioning.
class TrayMenuGeometry {
  const TrayMenuGeometry({
    required this.envelope,
    required this.mainPanel,
  });

  final Size envelope;
  final Size mainPanel;

  bool closeTo(TrayMenuGeometry? other) {
    if (other == null) {
      return false;
    }
    bool near(double a, double b) => (a - b).abs() <= 0.5;
    return near(envelope.width, other.envelope.width) &&
        near(envelope.height, other.envelope.height) &&
        near(mainPanel.width, other.mainPanel.width) &&
        near(mainPanel.height, other.mainPanel.height);
  }
}

bool get _disableWindowsSemanticsWorkaround =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

class TrayMenuThemeConfig {
  const TrayMenuThemeConfig({
    this.themeMode = AppThemeMode.system,
    required this.fontFamily,
    this.fontFamilyFallback = const [],
    this.textScaleFactor = 1.0,
    this.classicControlVisuals = true,
  });

  final AppThemeMode themeMode;
  final String fontFamily;
  final List<String> fontFamilyFallback;
  final double textScaleFactor;
  final bool classicControlVisuals;

  bool get hasFontFamily => fontFamily.trim().isNotEmpty;
  double get safeTextScaleFactor =>
      textScaleFactor.isFinite && textScaleFactor > 0 ? textScaleFactor : 1.0;
}

Future<void> runTrayMenuApp(
  List<String> args, {
  TrayMenuThemeConfig? themeConfig,
}) async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  await CustomIcons.FluentIcons.initialize();

  final launchData = TrayMenuLaunchData.fromArgs(args);
  final locale = parseTrayLocaleTag(launchData.localeTag) ??
      binding.platformDispatcher.locale;

  runApp(TrayMenuApp(
    launchData: launchData,
    locale: locale,
    themeConfig: themeConfig,
  ));
}

class TrayMenuLaunchData {
  const TrayMenuLaunchData({
    required this.localeTag,
    required this.mousePositionX,
    required this.mousePositionY,
    this.showOnReady = true,
    this.themeMode,
    this.classicControlVisuals,
    this.activeTasks = const [],
  });

  final String? localeTag;
  final double mousePositionX;
  final double mousePositionY;
  final bool showOnReady;
  final String? themeMode;
  final bool? classicControlVisuals;
  final List<TrayMenuActiveTaskPreview> activeTasks;

  factory TrayMenuLaunchData.fromJson(Map<String, dynamic> json) {
    final activeTasksRaw = json['active_tasks'];
    return TrayMenuLaunchData(
      localeTag: json['locale']?.toString(),
      mousePositionX: (json['mouse_x'] is num)
          ? (json['mouse_x'] as num).toDouble()
          : double.tryParse(json['mouse_x']?.toString() ?? '') ?? 0.0,
      mousePositionY: (json['mouse_y'] is num)
          ? (json['mouse_y'] as num).toDouble()
          : double.tryParse(json['mouse_y']?.toString() ?? '') ?? 0.0,
      showOnReady:
          json['show_on_ready'] is bool ? json['show_on_ready'] as bool : true,
      themeMode: json['theme_mode']?.toString(),
      classicControlVisuals: json['classic_control_visuals'] is bool
          ? json['classic_control_visuals'] as bool
          : null,
      activeTasks: activeTasksRaw is List
          ? activeTasksRaw
              .whereType<Map>()
              .map(
                (entry) => TrayMenuActiveTaskPreview.fromJson(
                  entry.map(
                    (key, value) => MapEntry(key.toString(), value),
                  ),
                ),
              )
              .toList(growable: false)
          : const <TrayMenuActiveTaskPreview>[],
    );
  }

  factory TrayMenuLaunchData.fromArgs(List<String> args) {
    if (args.isEmpty) {
      return const TrayMenuLaunchData(
        localeTag: null,
        mousePositionX: 0,
        mousePositionY: 0,
      );
    }

    try {
      final json = jsonDecode(args.first) as Map<Object?, Object?>;
      return TrayMenuLaunchData.fromJson(
        json.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (_) {
      return const TrayMenuLaunchData(
        localeTag: null,
        mousePositionX: 0,
        mousePositionY: 0,
        activeTasks: <TrayMenuActiveTaskPreview>[],
      );
    }
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TrayMenuLaunchData &&
            other.localeTag == localeTag &&
            other.mousePositionX == mousePositionX &&
            other.mousePositionY == mousePositionY &&
            other.showOnReady == showOnReady &&
            other.themeMode == themeMode &&
            other.classicControlVisuals == classicControlVisuals &&
            listEquals(other.activeTasks, activeTasks);
  }

  @override
  int get hashCode => Object.hash(
        localeTag,
        mousePositionX,
        mousePositionY,
        showOnReady,
        themeMode,
        classicControlVisuals,
        Object.hashAll(activeTasks),
      );
}

class TrayMenuActiveTaskPreview {
  const TrayMenuActiveTaskPreview({
    required this.id,
    required this.fileName,
    required this.status,
    required this.progress,
  });

  final String id;
  final String fileName;
  final String status;
  final double progress;

  factory TrayMenuActiveTaskPreview.fromJson(Map<String, dynamic> json) {
    return TrayMenuActiveTaskPreview(
      id: json['id']?.toString() ?? '',
      fileName: json['file_name']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      progress: (json['progress'] is num)
          ? (json['progress'] as num).toDouble()
          : double.tryParse(json['progress']?.toString() ?? '') ?? 0,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TrayMenuActiveTaskPreview &&
            other.id == id &&
            other.fileName == fileName &&
            other.status == status &&
            other.progress == progress;
  }

  @override
  int get hashCode => Object.hash(id, fileName, status, progress);
}

Locale? parseTrayLocaleTag(String? tag) {
  final value = tag?.trim();
  if (value == null || value.isEmpty) {
    return null;
  }

  final parts = value.replaceAll('_', '-').split('-');
  if (parts.isEmpty || parts.first.isEmpty) {
    return null;
  }

  return Locale.fromSubtags(
    languageCode: parts.first.toLowerCase(),
    countryCode: parts.length > 1 ? parts[1].toUpperCase() : null,
  );
}

class TrayMenuApp extends StatefulWidget {
  const TrayMenuApp({
    super.key,
    required this.launchData,
    required this.locale,
    this.themeConfig,
  });

  final TrayMenuLaunchData launchData;
  final Locale locale;
  final TrayMenuThemeConfig? themeConfig;

  @override
  State<TrayMenuApp> createState() => _TrayMenuAppState();
}

class _TrayMenuAppState extends State<TrayMenuApp> with WidgetsBindingObserver {
  late TrayMenuLaunchData _launchData;

  @override
  void initState() {
    super.initState();
    _launchData = widget.launchData;
    WidgetsBinding.instance.addObserver(this);
    _windowChannel.setMethodCallHandler(_handleAppMethodCall);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _windowChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<Object?> _handleAppMethodCall(MethodCall call) async {
    if (call.method != 'updateTrayMenuPayload') {
      return null;
    }

    final args = call.arguments;
    String? rawPayload;
    if (args is Map) {
      rawPayload = args['payload']?.toString();
    } else if (args is String) {
      rawPayload = args;
    }

    if (rawPayload == null || rawPayload.trim().isEmpty) {
      return false;
    }

    try {
      final decoded = jsonDecode(rawPayload) as Map<Object?, Object?>;
      final launchData = TrayMenuLaunchData.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      if (mounted) {
        setState(() {
          _launchData = launchData;
        });
      }
      return true;
    } catch (e) {
      debugPrint('Failed to update tray menu payload: $e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    AppThemeMode currentThemeMode =
        widget.themeConfig?.themeMode ?? AppThemeMode.system;
    if (_launchData.themeMode != null && _launchData.themeMode!.isNotEmpty) {
      currentThemeMode =
          AppThemeModeStorage.fromStorageValue(_launchData.themeMode!);
    }

    final baseTheme = AppTheme.themeDataForMode(
      currentThemeMode,
      platformBrightness:
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
      classicControlVisuals: _launchData.classicControlVisuals ??
          widget.themeConfig?.classicControlVisuals ??
          true,
    );
    AppTheme.applyBrightness(
      baseTheme.brightness,
      classicControlVisuals: _launchData.classicControlVisuals ??
          widget.themeConfig?.classicControlVisuals ??
          true,
    );
    final typography = baseTheme.typography;
    final fontFamily = widget.themeConfig?.fontFamily.trim() ?? '';
    final fontFallbacks =
        widget.themeConfig?.fontFamilyFallback ?? const <String>[];
    final appliedTheme = widget.themeConfig?.hasFontFamily == true
        ? baseTheme.copyWith(
            typography: Typography.raw(
              body: typography.body?.copyWith(
                fontFamily: fontFamily,
                fontFamilyFallback: fontFallbacks,
              ),
              bodyLarge: typography.bodyLarge?.copyWith(
                fontFamily: fontFamily,
                fontFamilyFallback: fontFallbacks,
              ),
              bodyStrong: typography.bodyStrong?.copyWith(
                fontFamily: fontFamily,
                fontFamilyFallback: fontFallbacks,
              ),
              caption: typography.caption?.copyWith(
                fontFamily: fontFamily,
                fontFamilyFallback: fontFallbacks,
              ),
              subtitle: typography.subtitle?.copyWith(
                fontFamily: fontFamily,
                fontFamilyFallback: fontFallbacks,
              ),
              title: typography.title?.copyWith(
                fontFamily: fontFamily,
                fontFamilyFallback: fontFallbacks,
              ),
              titleLarge: typography.titleLarge?.copyWith(
                fontFamily: fontFamily,
                fontFamilyFallback: fontFallbacks,
              ),
              display: typography.display?.copyWith(
                fontFamily: fontFamily,
                fontFamilyFallback: fontFallbacks,
              ),
            ),
          )
        : baseTheme;

    return FluentApp(
      title: 'Hanabi Tray Menu',
      debugShowCheckedModeBanner: false,
      theme: appliedTheme,
      locale: widget.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        FallbackFluentLocalizationsDelegate(),
        FallbackMaterialLocalizationsDelegate(),
        FallbackCupertinoLocalizationsDelegate(),
        GlobalWidgetsLocalizations.delegate,
      ],
      builder: (context, child) {
        Widget content = child ?? const SizedBox.shrink();
        if (widget.themeConfig?.hasFontFamily == true) {
          content = DefaultTextStyle.merge(
            style: TextStyle(
              fontFamily: fontFamily,
              fontFamilyFallback: fontFallbacks,
            ),
            child: content,
          );
        }
        if (_disableWindowsSemanticsWorkaround) {
          content = ExcludeSemantics(child: content);
        }
        final scaleFactor = widget.themeConfig?.safeTextScaleFactor ?? 1.0;
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scaleFactor),
          ),
          child: content,
        );
      },
      home: TrayMenuWindowPage(launchData: _launchData),
    );
  }
}

class TrayMenuWindowPage extends StatefulWidget {
  const TrayMenuWindowPage({
    super.key,
    required this.launchData,
  });

  final TrayMenuLaunchData launchData;

  @override
  State<TrayMenuWindowPage> createState() => _TrayMenuWindowPageState();
}

class _TrayMenuWindowPageState extends State<TrayMenuWindowPage>
    with SingleTickerProviderStateMixin {
  static const int _maxResizeAttempts = 8;
  static const Duration _resizeRetryDelay = Duration(milliseconds: 60);
  static const Duration _exitFadeDuration = Duration(milliseconds: 80);

  /// One settle probe before the first reveal. A cold tray engine finishes
  /// loading its CJK font and its DPI scale a few frames after the first
  /// layout; showing on the very first measurement briefly presented a menu
  /// with the wrong metrics that then visibly snapped into shape.
  static const Duration _settleProbeDelay = Duration(milliseconds: 40);
  static const int _maxSettleLoops = 6;

  bool _isClosing = false;
  bool _isActionRunning = false;
  bool _windowSizeSyncScheduled = false;
  bool _windowSizeSyncRunning = false;
  bool _windowSizeSyncPending = false;
  late TrayMenuLaunchData _currentLaunchData;
  int _contentSessionId = 0;
  bool _needsPrecisePosition = true;
  TrayMenuGeometry? _reportedGeometry;
  int? _lastAppliedWindowHeight;
  int? _lastAppliedWindowWidth;
  int _resizeAttempts = 0;
  Timer? _resizeRetryTimer;
  int _revealTick = 0;
  bool _isExitFading = false;
  String? _lastRegionSignature;
  int _settleLoops = 0;

  @override
  void initState() {
    super.initState();
    _currentLaunchData = widget.launchData;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduleWindowSizeSync();
    });
  }

  @override
  void didUpdateWidget(TrayMenuWindowPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.launchData, oldWidget.launchData)) {
      _applyUpdatedLaunchData(widget.launchData);
    }
  }

  @override
  void dispose() {
    _resizeRetryTimer?.cancel();
    super.dispose();
  }

  void _applyUpdatedLaunchData(TrayMenuLaunchData launchData) {
    if (!mounted) {
      return;
    }
    _resizeRetryTimer?.cancel();
    setState(() {
      _currentLaunchData = launchData;
      _contentSessionId++;
      _reportedGeometry = null;
      _needsPrecisePosition = true;
      _resizeAttempts = 0;
      _settleLoops = 0;
      _lastRegionSignature = null;
      _isExitFading = false;
      _isClosing = false;
    });
    _scheduleWindowSizeSync();
  }

  Future<void> _closeWindow() async {
    if (_isClosing) return;
    _isClosing = true;
    try {
      // Brief fade so dismissal reads as intentional instead of the window
      // vanishing mid-click. Native deactivation (clicking elsewhere) still
      // closes instantly, matching platform flyouts.
      if (mounted && _revealTick > 0) {
        setState(() => _isExitFading = true);
        await Future<void>.delayed(_exitFadeDuration);
      }
      await _windowChannel.invokeMethod('closeWindow');
    } finally {
      _isClosing = false;
    }
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_isActionRunning || _isClosing) {
      return;
    }
    setState(() => _isActionRunning = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _isActionRunning = false);
      } else {
        _isActionRunning = false;
      }
    }
  }

  Future<void> _onShowWindow() async {
    await _runAction(() async {
      try {
        await _windowChannel.invokeMethod('showMainWindow');
      } catch (e) {
        debugPrint('Failed to show main window: $e');
      }
      await _closeWindow();
    });
  }

  Future<void> _openMainWindowToDownloadingPage() async {
    await _runAction(() async {
      try {
        await _windowChannel.invokeMethod(
          'showMainWindowWithAction',
          const <String, Object>{
            'action': 'show_downloading_page',
          },
        );
      } catch (e) {
        debugPrint('Failed to open downloading page from tray: $e');
      }
      await _closeWindow();
    });
  }

  Future<void> _openMainWindowToAddDownload() async {
    await _runAction(() async {
      try {
        await _windowChannel.invokeMethod(
          'showMainWindowWithAction',
          const <String, Object>{
            'action': 'open_add_download_dialog',
          },
        );
      } catch (e) {
        debugPrint('Failed to open add download dialog from tray: $e');
      }
      await _closeWindow();
    });
  }

  Future<void> _onExit() async {
    await _runAction(() async {
      try {
        await _windowChannel.invokeMethod(
          'showMainWindowWithAction',
          const <String, Object>{
            'action': 'exit_application',
          },
        );
      } catch (e) {
        debugPrint('Failed to exit app: $e');
      }
      await _closeWindow();
    });
  }

  Future<void> _openDownloadsFolder() async {
    await _runAction(() async {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      final downloadPath = '$home\\Downloads';
      await Process.start(
        'explorer',
        [downloadPath],
        mode: ProcessStartMode.detached,
      );
      await _closeWindow();
    });
  }

  Future<void> _openLogsFolder() async {
    await _runAction(() async {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;
      final logsDir =
          Directory('$home\\Documents\\HanabiDownloadManagerX\\logs');
      if (!logsDir.existsSync()) {
        logsDir.createSync(recursive: true);
      }
      await Process.start(
        'explorer',
        [logsDir.path],
        mode: ProcessStartMode.detached,
      );
      await _closeWindow();
    });
  }

  Future<void> _openProjectPage() async {
    await _runAction(() async {
      await Process.start(
        'explorer',
        [AppConstants.githubUrl],
        mode: ProcessStartMode.detached,
      );
      await _closeWindow();
    });
  }

  Future<void> _openOfficialPage() async {
    await _runAction(() async {
      await Process.start(
        'explorer',
        [AppConstants.officialUrl],
        mode: ProcessStartMode.detached,
      );
      await _closeWindow();
    });
  }

  void _scheduleWindowSizeSync() {
    if (!Platform.isWindows) {
      return;
    }
    if (_windowSizeSyncRunning) {
      _windowSizeSyncPending = true;
      return;
    }
    if (_windowSizeSyncScheduled) {
      return;
    }
    _windowSizeSyncScheduled = true;
    // A microtask, not a post-frame callback: the sync only reads the cached
    // geometry and talks to the platform channel, so it must not depend on a
    // new frame ever being produced. The retry timer fires on an idle window
    // where nothing schedules frames, and a post-frame hop would leave the
    // stale window size in place until the user happened to hover something.
    scheduleMicrotask(() {
      _windowSizeSyncScheduled = false;
      unawaited(_drainWindowSizeSync());
    });
  }

  Future<void> _drainWindowSizeSync() async {
    if (_windowSizeSyncRunning || !mounted) {
      return;
    }
    _windowSizeSyncRunning = true;
    try {
      do {
        _windowSizeSyncPending = false;
        await _syncWindowSize();
      } while (mounted && _windowSizeSyncPending);
    } finally {
      _windowSizeSyncRunning = false;
    }
  }

  void _handleGeometryChanged(TrayMenuGeometry geometry) {
    if (geometry.closeTo(_reportedGeometry)) {
      return;
    }
    _reportedGeometry = geometry;
    _needsPrecisePosition = true;
    _resizeAttempts = 0;
    _scheduleWindowSizeSync();
  }

  void _handlePanelRectsChanged(List<Rect> panelRects) {
    if (!Platform.isWindows || panelRects.isEmpty) {
      return;
    }
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    // Panels get a small halo for the drop shadow; the window region clips
    // painting AND hit-testing, so it doubles as the click-through boundary
    // and hides the opaque host rectangle on machines without DWM alpha.
    const shadowPad = 8.0;
    final rects = <Map<String, Object>>[];
    final signature = StringBuffer('$devicePixelRatio');
    for (final rect in panelRects) {
      final padded = rect.inflate(shadowPad);
      final scaled = Rect.fromLTRB(
        padded.left * devicePixelRatio,
        padded.top * devicePixelRatio,
        padded.right * devicePixelRatio,
        padded.bottom * devicePixelRatio,
      );
      rects.add(<String, Object>{
        'x': scaled.left,
        'y': scaled.top,
        'width': scaled.width,
        'height': scaled.height,
      });
      signature.write(
        ';${scaled.left.round()},${scaled.top.round()},'
        '${scaled.width.round()},${scaled.height.round()}',
      );
    }
    final nextSignature = signature.toString();
    if (nextSignature == _lastRegionSignature) {
      return;
    }
    _lastRegionSignature = nextSignature;
    unawaited(
      _windowChannel.invokeMethod<void>('setTrayMenuRegion', <String, Object>{
        'radius': (AppTheme.radiusLg + shadowPad).round(),
        'rects': rects,
      }).catchError((Object error) {
        _lastRegionSignature = null;
        debugPrint('Failed to set tray menu region: $error');
      }),
    );
  }

  /// Content-side request to grow the window before a submenu paints.
  Future<bool> _ensureContentSpace(TrayMenuGeometry geometry) async {
    _reportedGeometry = geometry;
    final applied = await _applyWindowSize(geometry);
    if (!applied) {
      _scheduleResizeRetry();
    }
    return applied;
  }

  /// Pushes the window size for [geometry]. Returns false when the native
  /// side refused or errored, in which case nothing is latched so the next
  /// attempt retries instead of being deduplicated away.
  Future<bool> _applyWindowSize(TrayMenuGeometry geometry) async {
    final desiredSize = calculateTrayMenuWindowSize(geometry.envelope);
    final desiredHeight = desiredSize.height.toInt();
    final desiredWidth = desiredSize.width.toInt();
    final heightUnchanged = _lastAppliedWindowHeight != null &&
        (_lastAppliedWindowHeight! - desiredHeight).abs() <= 1;
    final widthUnchanged = _lastAppliedWindowWidth != null &&
        (_lastAppliedWindowWidth! - desiredWidth).abs() <= 1;
    if (heightUnchanged && widthUnchanged) {
      return true;
    }

    try {
      final applied = await _windowChannel.invokeMethod<bool>(
        'resizeWindow',
        <String, Object>{
          'width': desiredWidth,
          'height': desiredHeight,
        },
      );
      if (applied != true) {
        return false;
      }
    } catch (e) {
      debugPrint('Failed to resize tray menu window: $e');
      return false;
    }

    // Only latch on success. Latching before the call meant one failed resize
    // (engine still booting, channel hiccup) left the window at its 184x320
    // creation size forever while the dedup logic insisted nothing needed
    // doing — the menu showed up cut through the middle.
    _lastAppliedWindowHeight = desiredHeight;
    _lastAppliedWindowWidth = desiredWidth;
    _resizeAttempts = 0;
    return true;
  }

  Future<void> _syncWindowSize() async {
    if (!mounted || !Platform.isWindows) {
      return;
    }

    final geometry = _reportedGeometry;
    if (geometry == null) {
      // Content has not reported yet; the post-frame report will reschedule.
      return;
    }

    final anchorSize = calculateTrayMenuWindowSize(geometry.mainPanel);
    if (!await _applyWindowSize(geometry)) {
      _scheduleResizeRetry();
      return;
    }

    try {
      if (_needsPrecisePosition && _currentLaunchData.showOnReady) {
        // Hold the reveal while the layout is still moving. A cold engine
        // settles its font and DPI within the first few frames; revealing on
        // the very first measurement showed those wrong metrics on screen.
        if (_settleLoops < _maxSettleLoops) {
          _settleLoops++;
          await Future<void>.delayed(_settleProbeDelay);
          if (!mounted) {
            return;
          }
          if (!identical(_reportedGeometry, geometry)) {
            // Geometry shifted during the probe; run the loop again with the
            // fresh values before anything becomes visible.
            _windowSizeSyncPending = true;
            return;
          }
        }
        if (mounted) {
          // Start the entrance animation before the native window becomes
          // visible so its first presented frame is already mid-fade. Each
          // session positions exactly once, so this fires once per open.
          setState(() => _revealTick++);
        }
        await _windowChannel.invokeMethod<void>(
          'positionTrayMenu',
          <String, Object>{
            'x': _currentLaunchData.mousePositionX,
            'y': _currentLaunchData.mousePositionY,
            'anchorWidth': anchorSize.width.toInt(),
            'anchorHeight': anchorSize.height.toInt(),
          },
        );
        _needsPrecisePosition = false;
      }
    } catch (e) {
      debugPrint('Failed to sync tray menu window size: $e');
      _scheduleResizeRetry();
    }
  }

  void _scheduleResizeRetry() {
    if (_resizeAttempts >= _maxResizeAttempts) {
      return;
    }
    _resizeAttempts++;
    _resizeRetryTimer?.cancel();
    _resizeRetryTimer = Timer(_resizeRetryDelay, () {
      if (mounted) {
        _scheduleWindowSizeSync();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          unawaited(_closeWindow());
        },
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: Colors.transparent,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: kTrayMenuWindowInsets,
              child: AnimatedOpacity(
                opacity: _isExitFading ? 0 : 1,
                duration: _exitFadeDuration,
                curve: Curves.easeOut,
                child: TrayMenuContent(
                  key: ValueKey(_contentSessionId),
                  onShowWindow: _onShowWindow,
                  onCreateDownload: _openMainWindowToAddDownload,
                  onOpenDownloadingPage: _openMainWindowToDownloadingPage,
                  onOpenDownloads: _openDownloadsFolder,
                  onOpenLogs: _openLogsFolder,
                  onOpenProject: _openProjectPage,
                  onOpenOfficial: _openOfficialPage,
                  onExit: _onExit,
                  isBusy: _isActionRunning,
                  activeTasks: _currentLaunchData.activeTasks,
                  revealTick: _revealTick,
                  onGeometryChanged: _handleGeometryChanged,
                  onPanelRectsChanged: _handlePanelRectsChanged,
                  onEnsureContentSpace: _ensureContentSpace,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TrayMenuContent extends StatefulWidget {
  final Future<void> Function() onShowWindow;
  final Future<void> Function() onCreateDownload;
  final Future<void> Function() onOpenDownloadingPage;
  final Future<void> Function() onOpenDownloads;
  final Future<void> Function() onOpenLogs;
  final Future<void> Function() onOpenProject;
  final Future<void> Function() onOpenOfficial;
  final Future<void> Function() onExit;
  final bool isBusy;
  final List<TrayMenuActiveTaskPreview> activeTasks;

  /// Incremented by the host page right before the native window is shown;
  /// each new value replays the entrance animation.
  final int revealTick;
  final ValueChanged<TrayMenuGeometry> onGeometryChanged;
  final ValueChanged<List<Rect>> onPanelRectsChanged;

  /// Grows the native window to [TrayMenuGeometry.envelope] and completes once
  /// the platform acknowledged. Painting a submenu before this resolves is what
  /// used to slice the flyout off at the old window edge.
  final Future<bool> Function(TrayMenuGeometry geometry) onEnsureContentSpace;

  const TrayMenuContent({
    super.key,
    required this.onShowWindow,
    required this.onCreateDownload,
    required this.onOpenDownloadingPage,
    required this.onOpenDownloads,
    required this.onOpenLogs,
    required this.onOpenProject,
    required this.onOpenOfficial,
    required this.onExit,
    required this.isBusy,
    required this.activeTasks,
    required this.revealTick,
    required this.onGeometryChanged,
    required this.onPanelRectsChanged,
    required this.onEnsureContentSpace,
  });

  @override
  State<TrayMenuContent> createState() => _TrayMenuContentState();
}

class _TrayMenuContentState extends State<TrayMenuContent>
    with TickerProviderStateMixin {
  static const double _minMenuWidth = 156;
  static const double _maxMenuWidth = 228;
  static const double _menuTileChrome = 58;
  static const double _groupTileChrome = 74;
  static const double _submenuGap = 8;
  static const double _menuTileHeight = 32;
  static const double _panelInnerTop = 6;
  static const double _panelInnerBottom = 5;

  /// Vertical panel chrome: inner padding plus the 1px border on each side.
  static const double _panelVerticalChrome =
      _panelInnerTop + _panelInnerBottom + 2;

  static const Duration _entranceDuration = Duration(milliseconds: 150);
  static const Duration _submenuOpenDuration = Duration(milliseconds: 130);
  static const Duration _submenuCloseDuration = Duration(milliseconds: 90);
  static const Duration _hoverDuration = Duration(milliseconds: 90);
  static const TextStyle _menuLabelBaseStyle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.22,
  );

  static const int _showWindowIndex = 0;
  static const int _createDownloadIndex = 1;
  static const int _activeTasksGroupIndex = 2;
  static const int _foldersGroupIndex = 3;
  static const int _downloadsIndex = 4;
  static const int _logsIndex = 5;
  static const int _linksGroupIndex = 6;
  static const int _projectIndex = 7;
  static const int _officialIndex = 8;
  static const int _activeTaskBaseIndex = 100;
  static const int _moreActiveTasksIndex = 104;
  static const int _exitIndex = 9;

  final GlobalKey _layoutKey = GlobalKey();
  final GlobalKey _mainPanelKey = GlobalKey();
  final GlobalKey _submenuPanelKey = GlobalKey();
  int? _hoveredIndex;
  int? _pressedIndex;
  _TraySubmenuGroup? _activeSubmenu;

  /// The submenu whose panel is currently in the tree. Lags [_activeSubmenu]
  /// while the close animation plays, so the panel can fade out instead of
  /// vanishing between two frames.
  _TraySubmenuGroup? _renderedSubmenu;
  Timer? _submenuCloseTimer;
  bool _measurementScheduled = false;
  int? _lastMeasurementSignature;
  TrayMenuGeometry? _lastReportedGeometry;
  Size? _lastMainPanelSize;

  /// Width and tile count of the rendered submenu, captured during build so
  /// the region rect can be computed from target values instead of measuring
  /// a panel that may be mid-animation.
  double _renderedSubmenuWidth = 0;
  int _renderedSubmenuTileCount = 0;

  late final AnimationController _entranceController = AnimationController(
    vsync: this,
    duration: _entranceDuration,
  );
  late final AnimationController _submenuController = AnimationController(
    vsync: this,
    duration: _submenuOpenDuration,
    reverseDuration: _submenuCloseDuration,
  );

  late final Animation<double> _entranceOpacity = CurvedAnimation(
    parent: _entranceController,
    curve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _entranceSlide = Tween<Offset>(
    begin: const Offset(0, 0.02),
    end: Offset.zero,
  ).animate(CurvedAnimation(
    parent: _entranceController,
    curve: Curves.easeOutCubic,
  ));
  late final Animation<double> _submenuOpacity = CurvedAnimation(
    parent: _submenuController,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeIn,
  );
  late final Animation<Offset> _submenuSlide = Tween<Offset>(
    begin: const Offset(-0.03, 0),
    end: Offset.zero,
  ).animate(CurvedAnimation(
    parent: _submenuController,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeIn,
  ));

  @override
  void initState() {
    super.initState();
    _submenuController.addStatusListener(_handleSubmenuAnimationStatus);
    if (widget.revealTick > 0) {
      _entranceController.forward();
    }
  }

  @override
  void didUpdateWidget(TrayMenuContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revealTick != oldWidget.revealTick && widget.revealTick > 0) {
      _entranceController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _submenuCloseTimer?.cancel();
    _entranceController.dispose();
    _submenuController.dispose();
    super.dispose();
  }

  void _handleSubmenuAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _renderedSubmenu != null) {
      setState(() => _renderedSubmenu = null);
    }
  }

  /// Schedule submenu close with a short delay.
  /// This allows the user to traverse diagonal paths from a main-menu
  /// trigger item to the submenu panel without the submenu flickering away.
  void _scheduleSubmenuClose() {
    _submenuCloseTimer?.cancel();
    _submenuCloseTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      if (_activeSubmenu != null || _renderedSubmenu != null) {
        setState(() => _activeSubmenu = null);
        _submenuController.reverse();
      }
    });
  }

  /// Cancel any pending submenu close (e.g. when the mouse enters a tile
  /// that should keep or change the active submenu).
  void _cancelSubmenuClose() {
    _submenuCloseTimer?.cancel();
    _submenuCloseTimer = null;
  }

  void _openSubmenu(_TraySubmenuGroup group) {
    _cancelSubmenuClose();
    if (_activeSubmenu == group && _renderedSubmenu == group) {
      return;
    }
    setState(() => _activeSubmenu = group);
    unawaited(_openSubmenuSequenced(group));
  }

  /// Grow the native window first, paint the submenu only once the platform
  /// has acknowledged. The fade-in fully masks the sub-frame resize latency,
  /// and the ordering is what guarantees the flyout can never be clipped by a
  /// window that has not caught up yet.
  Future<void> _openSubmenuSequenced(_TraySubmenuGroup group) async {
    final mainSize = _lastMainPanelSize;
    if (mainSize != null && mounted) {
      final isDark = FluentTheme.of(context).brightness == Brightness.dark;
      final labelStyle =
          DefaultTextStyle.of(context).style.merge(_menuLabelBaseStyle);
      final specs = _getSubmenuSpecs(group, isDark);
      final submenuWidth = _resolveMenuWidth(
        context,
        specs
            .map((spec) =>
                _MenuWidthSpec(label: spec.title, chrome: _menuTileChrome))
            .toList(growable: false),
        labelStyle,
      );
      final submenuHeight =
          specs.length * _menuTileHeight + _panelVerticalChrome;
      final target = TrayMenuGeometry(
        envelope: Size(
          mainSize.width + _submenuGap + submenuWidth,
          math.max(
            mainSize.height,
            _resolveSubmenuOffset(group) + submenuHeight,
          ),
        ),
        mainPanel: mainSize,
      );
      // A refused resize still falls through to painting: a briefly clipped
      // submenu beats one that never appears, and the retry loop repairs the
      // window size moments later.
      await widget.onEnsureContentSpace(target);
    }

    if (!mounted || _activeSubmenu != group) {
      // The user moved on while the window was growing.
      return;
    }
    setState(() => _renderedSubmenu = group);
    // From zero this is the entrance; from a partial close it resumes, and a
    // group switch mid-flight just keeps whatever opacity is on screen.
    _submenuController.forward();
  }

  bool get _isChinese =>
      Localizations.localeOf(context).languageCode.toLowerCase().startsWith(
            'zh',
          );

  String get _foldersGroupTitle => _isChinese ? '打开目录' : 'Open folders';
  String get _createDownloadTitle => _isChinese ? '新建下载' : 'New download';
  String get _activeTasksGroupTitle => _isChinese ? '正在进行' : 'Active';
  String get _noActiveTasksTitle => _isChinese ? '暂无进行中任务' : 'No active tasks';
  String get _linksGroupTitle => _isChinese ? '相关链接' : 'Links';
  String get _downloadsTitle => _isChinese ? '下载目录' : 'Downloads';
  String get _logsTitle => _isChinese ? '日志目录' : 'Logs';
  String get _projectTitle => _isChinese ? '项目主页' : 'Project';
  String get _officialTitle => _isChinese ? '官方网站' : 'Website';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final resolvedLabelStyle =
        DefaultTextStyle.of(context).style.merge(_menuLabelBaseStyle);
    final mainMenuWidth = _resolveMenuWidth(
      context,
      [
        _MenuWidthSpec(
          label: t.trayMenuShowWindowTitle,
          chrome: _menuTileChrome,
        ),
        _MenuWidthSpec(
          label: _createDownloadTitle,
          chrome: _menuTileChrome,
        ),
        _MenuWidthSpec(
          label: _activeTasksGroupTitle,
          chrome: _groupTileChrome,
        ),
        _MenuWidthSpec(label: _foldersGroupTitle, chrome: _groupTileChrome),
        _MenuWidthSpec(label: _linksGroupTitle, chrome: _groupTileChrome),
        _MenuWidthSpec(label: t.trayMenuExitTitle, chrome: _menuTileChrome),
      ],
      resolvedLabelStyle,
    );
    final submenuSpecs = _renderedSubmenu == null
        ? null
        : _getSubmenuSpecs(_renderedSubmenu!, isDark);
    final submenuWidth = submenuSpecs == null
        ? 0.0
        : _resolveMenuWidth(
            context,
            submenuSpecs
                .map(
                  (spec) => _MenuWidthSpec(
                      label: spec.title, chrome: _menuTileChrome),
                )
                .toList(growable: false),
            resolvedLabelStyle,
          );
    final submenuOffset = _resolveSubmenuOffset(_renderedSubmenu);
    _renderedSubmenuWidth = submenuWidth;
    _renderedSubmenuTileCount = submenuSpecs?.length ?? 0;
    _scheduleGeometryReport(
      measurementSignature: Object.hash(
        mainMenuWidth,
        submenuWidth,
        submenuOffset,
        submenuSpecs?.length ?? 0,
        widget.activeTasks.length,
      ),
    );

    return OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: 0,
      minHeight: 0,
      maxWidth: double.infinity,
      maxHeight: double.infinity,
      child: MouseRegion(
        onExit: (_) {
          if (_hoveredIndex == null && _activeSubmenu == null) {
            return;
          }
          setState(() {
            _hoveredIndex = null;
          });
          _scheduleSubmenuClose();
        },
        child: FadeTransition(
          opacity: _entranceOpacity,
          child: SlideTransition(
            position: _entranceSlide,
            child: NotificationListener<SizeChangedLayoutNotification>(
              onNotification: (_) {
                _forceGeometryReport();
                return true;
              },
              child: SizeChangedLayoutNotifier(
                child: KeyedSubtree(
                  key: _layoutKey,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildMenuPanel(
                        panelKey: _mainPanelKey,
                        width: mainMenuWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildMenuTile(
                              spec: _MenuActionSpec(
                                index: _showWindowIndex,
                                icon: CustomIcons.FluentIcons.window_20,
                                title: t.trayMenuShowWindowTitle,
                                iconColor: const Color(0xFF78C4FF),
                                onTap: widget.isBusy
                                    ? null
                                    : () {
                                        unawaited(widget.onShowWindow());
                                      },
                              ),
                              closeSubmenuOnEnter: true,
                            ),
                            _buildMenuTile(
                              spec: _MenuActionSpec(
                                index: _createDownloadIndex,
                                icon: CustomIcons.FluentIcons.add_20,
                                title: _createDownloadTitle,
                                iconColor: const Color(0xFFF2C879),
                                onTap: widget.isBusy
                                    ? null
                                    : () {
                                        unawaited(widget.onCreateDownload());
                                      },
                              ),
                              closeSubmenuOnEnter: true,
                            ),
                            _buildMenuTile(
                              spec: _MenuActionSpec(
                                index: _activeTasksGroupIndex,
                                icon: CustomIcons.FluentIcons.arrow_download_20,
                                title: _activeTasksGroupTitle,
                                iconColor: const Color(0xFF8FD8A9),
                                onTap: () => _toggleSubmenu(
                                    _TraySubmenuGroup.activeTasks),
                              ),
                              trailing: Icon(
                                CustomIcons.FluentIcons.chevron_right_20,
                                size: 10,
                                color: const Color(0xFF9B9B9B),
                              ),
                              isSelected: _activeSubmenu ==
                                  _TraySubmenuGroup.activeTasks,
                              submenuToActivateOnEnter:
                                  _TraySubmenuGroup.activeTasks,
                            ),
                            _buildMenuTile(
                              spec: _MenuActionSpec(
                                index: _foldersGroupIndex,
                                icon: CustomIcons.FluentIcons.folder_open_20,
                                title: _foldersGroupTitle,
                                iconColor: const Color(0xFF78C4FF),
                                onTap: () =>
                                    _toggleSubmenu(_TraySubmenuGroup.folders),
                              ),
                              trailing: Icon(
                                CustomIcons.FluentIcons.chevron_right_20,
                                size: 10,
                                color: const Color(0xFF9B9B9B),
                              ),
                              isSelected:
                                  _activeSubmenu == _TraySubmenuGroup.folders,
                              submenuToActivateOnEnter:
                                  _TraySubmenuGroup.folders,
                            ),
                            _buildMenuTile(
                              spec: _MenuActionSpec(
                                index: _linksGroupIndex,
                                icon: CustomIcons.FluentIcons.link_20,
                                title: _linksGroupTitle,
                                iconColor: const Color(0xFF8FD8A9),
                                onTap: () =>
                                    _toggleSubmenu(_TraySubmenuGroup.links),
                              ),
                              trailing: Icon(
                                CustomIcons.FluentIcons.chevron_right_20,
                                size: 10,
                                color: const Color(0xFF9B9B9B),
                              ),
                              isSelected:
                                  _activeSubmenu == _TraySubmenuGroup.links,
                              submenuToActivateOnEnter: _TraySubmenuGroup.links,
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Container(
                                height: 1,
                                color: AppTheme.borderSubtle,
                              ),
                            ),
                            _buildExitBar(
                              title: t.trayMenuExitTitle,
                              onTap: widget.isBusy
                                  ? null
                                  : () {
                                      unawaited(widget.onExit());
                                    },
                            ),
                          ],
                        ),
                      ),
                      if (submenuSpecs != null) ...[
                        const SizedBox(width: _submenuGap),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Animating the offset makes switching between groups
                            // read as one cascade gliding along the menu instead
                            // of a new panel popping into existence.
                            AnimatedContainer(
                              duration: _submenuOpenDuration,
                              curve: Curves.easeOutCubic,
                              height: submenuOffset,
                              // The region is computed from target values, but
                              // re-report once the glide settles in case layout
                              // truth drifted from the analytic rect.
                              onEnd: _reportPanelRects,
                            ),
                            FadeTransition(
                              opacity: _submenuOpacity,
                              child: SlideTransition(
                                position: _submenuSlide,
                                child: _buildMenuPanel(
                                  panelKey: _submenuPanelKey,
                                  width: submenuWidth,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      for (final spec in submenuSpecs)
                                        _buildMenuTile(
                                          spec: spec,
                                          closeSubmenuOnEnter: false,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _scheduleGeometryReport({required int measurementSignature}) {
    if (_measurementScheduled ||
        _lastMeasurementSignature == measurementSignature) {
      return;
    }
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      _measureAndReport(measurementSignature);
    });
  }

  /// Re-measure regardless of the build signature. Fired by the layout-change
  /// notifier: a cold engine swaps in its real font a few frames after first
  /// paint, which changes panel sizes without any rebuild, so signature-based
  /// scheduling alone would leave the window and region matching stale metrics.
  void _forceGeometryReport() {
    _lastMeasurementSignature = null;
    if (_measurementScheduled) {
      return;
    }
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      _measureAndReport(null);
    });
  }

  void _measureAndReport(int? measurementSignature) {
    if (!mounted) {
      return;
    }
    final panelBox = _mainPanelKey.currentContext?.findRenderObject();
    final layoutBox = _layoutKey.currentContext?.findRenderObject();
    if (panelBox is! RenderBox ||
        !panelBox.hasSize ||
        layoutBox is! RenderBox ||
        !layoutBox.hasSize) {
      return;
    }
    if (measurementSignature != null) {
      _lastMeasurementSignature = measurementSignature;
    }

    final mainPanelSize = panelBox.size;
    _lastMainPanelSize = mainPanelSize;
    final geometry = TrayMenuGeometry(
      envelope: layoutBox.size,
      mainPanel: mainPanelSize,
    );
    if (!geometry.closeTo(_lastReportedGeometry)) {
      _lastReportedGeometry = geometry;
      widget.onGeometryChanged(geometry);
    }
    _reportPanelRects();
  }

  /// Window-space rectangles of the visible panels, for the native window
  /// region (painting and hit-testing both clip to it).
  void _reportPanelRects() {
    if (!mounted) {
      return;
    }
    final mainBox = _mainPanelKey.currentContext?.findRenderObject();
    if (mainBox is! RenderBox || !mainBox.hasSize || !mainBox.attached) {
      return;
    }
    // Origin is the window inset constant, not localToGlobal: the entrance
    // slide and the submenu glide are transforms, and a rect measured through
    // them captures wherever the animation happened to be that frame.
    final mainRect = Offset(
          kTrayMenuWindowInsets.left,
          kTrayMenuWindowInsets.top,
        ) &
        mainBox.size;
    final rects = <Rect>[mainRect];

    final group = _renderedSubmenu;
    if (group != null && _renderedSubmenuTileCount > 0) {
      // The submenu rect is derived from target values, never measured: the
      // offset animation between groups means a measured rect can capture the
      // panel mid-flight, and a region built from that snapshot sliced the
      // settled panel apart at the old position.
      final panelHeight =
          _renderedSubmenuTileCount * _menuTileHeight + _panelVerticalChrome;
      rects.add(Rect.fromLTWH(
        mainRect.right + _submenuGap,
        mainRect.top + _resolveSubmenuOffset(group),
        _renderedSubmenuWidth,
        panelHeight,
      ));
    }
    widget.onPanelRectsChanged(rects);
  }

  List<_MenuActionSpec> _getSubmenuSpecs(
    _TraySubmenuGroup group,
    bool isDark,
  ) {
    switch (group) {
      case _TraySubmenuGroup.activeTasks:
        if (widget.activeTasks.isEmpty) {
          return [
            _MenuActionSpec(
              index: _activeTaskBaseIndex,
              icon: CustomIcons.FluentIcons.clock_20,
              title: _noActiveTasksTitle,
              iconColor:
                  isDark ? const Color(0xFF9B9B9B) : const Color(0xFF6B6B6B),
              onTap: null,
            ),
          ];
        }

        final visibleTasks = widget.activeTasks.take(3).toList(growable: false);
        final specs = <_MenuActionSpec>[
          for (var i = 0; i < visibleTasks.length; i++)
            _MenuActionSpec(
              index: _activeTaskBaseIndex + i,
              icon: _taskIconForStatus(visibleTasks[i].status),
              title: visibleTasks[i].fileName.trim().isNotEmpty
                  ? visibleTasks[i].fileName.trim()
                  : visibleTasks[i].id,
              iconColor: _taskColorForStatus(visibleTasks[i].status, isDark),
              onTap: widget.isBusy
                  ? null
                  : () {
                      unawaited(widget.onOpenDownloadingPage());
                    },
            ),
        ];

        if (widget.activeTasks.length > visibleTasks.length) {
          specs.add(
            _MenuActionSpec(
              index: _moreActiveTasksIndex,
              icon: CustomIcons.FluentIcons.more_horizontal_20,
              title: '...',
              iconColor:
                  isDark ? const Color(0xFF9FB0C9) : const Color(0xFF6B6B6B),
              onTap: widget.isBusy
                  ? null
                  : () {
                      unawaited(widget.onOpenDownloadingPage());
                    },
            ),
          );
        }

        return specs;
      case _TraySubmenuGroup.folders:
        return [
          _MenuActionSpec(
            index: _downloadsIndex,
            icon: CustomIcons.FluentIcons.arrow_download_20,
            title: _downloadsTitle,
            iconColor:
                isDark ? const Color(0xFF78C4FF) : const Color(0xFF0078D4),
            onTap: widget.isBusy
                ? null
                : () {
                    unawaited(widget.onOpenDownloads());
                  },
          ),
          _MenuActionSpec(
            index: _logsIndex,
            icon: CustomIcons.FluentIcons.document_20,
            title: _logsTitle,
            iconColor:
                isDark ? const Color(0xFF9FB0C9) : const Color(0xFF6B6B6B),
            onTap: widget.isBusy
                ? null
                : () {
                    unawaited(widget.onOpenLogs());
                  },
          ),
        ];
      case _TraySubmenuGroup.links:
        return [
          _MenuActionSpec(
            index: _projectIndex,
            icon: CustomIcons.FluentIcons.bookmark_20,
            title: _projectTitle,
            iconColor:
                isDark ? const Color(0xFF8FD8A9) : const Color(0xFF107C41),
            onTap: widget.isBusy
                ? null
                : () {
                    unawaited(widget.onOpenProject());
                  },
          ),
          _MenuActionSpec(
            index: _officialIndex,
            icon: CustomIcons.FluentIcons.globe_20,
            title: _officialTitle,
            iconColor:
                isDark ? const Color(0xFFF2C879) : const Color(0xFFD29200),
            onTap: widget.isBusy
                ? null
                : () {
                    unawaited(widget.onOpenOfficial());
                  },
          ),
        ];
    }
  }

  double _resolveSubmenuOffset(_TraySubmenuGroup? group) {
    switch (group) {
      case _TraySubmenuGroup.activeTasks:
        return _panelInnerTop + (_menuTileHeight * 2);
      case _TraySubmenuGroup.folders:
        return _panelInnerTop + (_menuTileHeight * 3);
      case _TraySubmenuGroup.links:
        return _panelInnerTop + (_menuTileHeight * 4);
      case null:
        return 0;
    }
  }

  IconData _taskIconForStatus(String status) {
    switch (status) {
      case 'downloading':
        return CustomIcons.FluentIcons.arrow_download_20;
      case 'merging':
        return CustomIcons.FluentIcons.arrow_sync_20;
      case 'pending':
      default:
        return CustomIcons.FluentIcons.clock_20;
    }
  }

  Color _taskColorForStatus(String status, bool isDark) {
    switch (status) {
      case 'downloading':
        return isDark ? const Color(0xFF78C4FF) : const Color(0xFF0078D4);
      case 'merging':
        return isDark ? const Color(0xFFF2C879) : const Color(0xFFD29200);
      case 'pending':
      default:
        return isDark ? const Color(0xFF8FD8A9) : const Color(0xFF107C41);
    }
  }

  void _toggleSubmenu(_TraySubmenuGroup group) {
    if (_activeSubmenu == group) {
      _cancelSubmenuClose();
      setState(() => _activeSubmenu = null);
      _submenuController.reverse();
      return;
    }
    _openSubmenu(group);
  }

  Widget _buildMenuPanel({
    Key? panelKey,
    required double width,
    required Widget child,
  }) {
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    return MouseRegion(
      onEnter: (_) => _cancelSubmenuClose(),
      child: Container(
        key: panelKey,
        width: width,
        decoration: BoxDecoration(
          color: AppTheme.bgLayer1.withValues(alpha: isDark ? 0.96 : 0.98),
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          border: Border.all(
            color: isDark ? const Color(0x33FFFFFF) : const Color(0x1A000000),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.16),
              blurRadius: 16,
              spreadRadius: 0,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.16 : 0.08),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg - 1),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              6,
              _panelInnerTop,
              6,
              _panelInnerBottom,
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _buildMenuTile({
    required _MenuActionSpec spec,
    Widget? trailing,
    bool isSelected = false,
    _TraySubmenuGroup? submenuToActivateOnEnter,
    bool closeSubmenuOnEnter = false,
  }) {
    final isHovered = _hoveredIndex == spec.index;
    final isHighlighted = isHovered || isSelected;
    final isDisabled = spec.onTap == null;
    final labelStyle =
        DefaultTextStyle.of(context).style.merge(_menuLabelBaseStyle).copyWith(
              color: isDisabled ? AppTheme.textDisabled : AppTheme.textPrimary,
            );
    const tilePadding = EdgeInsets.fromLTRB(8, 5, 8, 5);
    final tileRadius = AppTheme.radiusSm;
    const iconBoxSize = 22.0;
    final iconRadius = AppTheme.radiusSm;
    const iconSize = 13.0;
    final hoverColor = AppTheme.surfaceCardHover;

    final isPressed = _pressedIndex == spec.index;

    return MouseRegion(
      onEnter: (_) {
        _cancelSubmenuClose();
        final nextSubmenu = closeSubmenuOnEnter
            ? null
            : submenuToActivateOnEnter ?? _activeSubmenu;
        // When this tile would close the submenu, use a delay so that
        // diagonal mouse paths to the submenu panel don't flicker.
        if (closeSubmenuOnEnter &&
            _activeSubmenu != null &&
            nextSubmenu == null) {
          if (_hoveredIndex != spec.index) {
            setState(() => _hoveredIndex = spec.index);
          }
          _scheduleSubmenuClose();
          return;
        }
        if (nextSubmenu != null && nextSubmenu != _activeSubmenu) {
          _openSubmenu(nextSubmenu);
        }
        if (_hoveredIndex != spec.index) {
          setState(() => _hoveredIndex = spec.index);
        }
      },
      onExit: (_) {
        if (_hoveredIndex != spec.index && _pressedIndex != spec.index) {
          return;
        }
        setState(() {
          if (_hoveredIndex == spec.index) _hoveredIndex = null;
          if (_pressedIndex == spec.index) _pressedIndex = null;
        });
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: spec.onTap,
        onTapDown: isDisabled
            ? null
            : (_) => setState(() => _pressedIndex = spec.index),
        onTapUp: (_) {
          if (_pressedIndex == spec.index) {
            setState(() => _pressedIndex = null);
          }
        },
        onTapCancel: () {
          if (_pressedIndex == spec.index) {
            setState(() => _pressedIndex = null);
          }
        },
        child: AnimatedScale(
          scale: isPressed ? 0.97 : 1.0,
          duration: _hoverDuration,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: _hoverDuration,
            curve: Curves.easeOutCubic,
            margin: EdgeInsets.zero,
            padding: tilePadding,
            decoration: BoxDecoration(
              color: isHighlighted ? hoverColor : Colors.transparent,
              borderRadius: BorderRadius.circular(tileRadius),
            ),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: _hoverDuration,
                  curve: Curves.easeOutCubic,
                  width: iconBoxSize,
                  height: iconBoxSize,
                  decoration: BoxDecoration(
                    color: spec.iconColor
                        .withValues(alpha: isHighlighted ? 0.25 : 0.15),
                    borderRadius: BorderRadius.circular(iconRadius),
                  ),
                  child: Icon(
                    spec.icon,
                    size: iconSize,
                    color: isDisabled
                        ? AppTheme.textDisabled
                        : spec.iconColor.withValues(alpha: 0.95),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    spec.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 6),
                  AnimatedSlide(
                    offset: isHighlighted ? const Offset(0.12, 0) : Offset.zero,
                    duration: _hoverDuration,
                    curve: Curves.easeOutCubic,
                    child: trailing,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExitBar({
    required String title,
    required VoidCallback? onTap,
  }) {
    final isHovered = _hoveredIndex == _exitIndex;
    final isDisabled = onTap == null;
    final labelStyle =
        DefaultTextStyle.of(context).style.merge(_menuLabelBaseStyle).copyWith(
              color: isDisabled ? AppTheme.textDisabled : AppTheme.textPrimary,
            );
    return MouseRegion(
      onEnter: (_) {
        final needsUpdate =
            _hoveredIndex != _exitIndex || _activeSubmenu != null;
        if (!needsUpdate) {
          return;
        }
        setState(() => _hoveredIndex = _exitIndex);
        // Delay submenu close to allow diagonal mouse paths
        if (_activeSubmenu != null) {
          _scheduleSubmenuClose();
        }
      },
      onExit: (_) => setState(() => _hoveredIndex = null),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: isHovered ? AppTheme.bgLayer2 : AppTheme.bgLayer1,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(
              color: isHovered
                  ? AppTheme.statusError.withValues(alpha: 0.55)
                  : AppTheme.statusError.withValues(alpha: 0.24),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: AppTheme.statusError.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Icon(
                  CustomIcons.FluentIcons.dismiss_20,
                  size: 11,
                  color:
                      isDisabled ? AppTheme.textDisabled : AppTheme.statusError,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _resolveMenuWidth(
    BuildContext context,
    List<_MenuWidthSpec> items,
    TextStyle textStyle,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final maxRowWidth = items.fold<double>(0, (currentMax, item) {
      final painter = TextPainter(
        text: TextSpan(text: item.label, style: textStyle),
        textDirection: direction,
        maxLines: 1,
        textScaler: scaler,
      )..layout();
      return math.max(currentMax, painter.width + item.chrome);
    });

    return maxRowWidth.clamp(
      _minMenuWidth,
      _maxMenuWidth,
    );
  }
}

class _MenuWidthSpec {
  const _MenuWidthSpec({
    required this.label,
    required this.chrome,
  });

  final String label;
  final double chrome;
}

enum _TraySubmenuGroup {
  activeTasks,
  folders,
  links,
}

class _MenuActionSpec {
  const _MenuActionSpec({
    required this.index,
    required this.icon,
    required this.title,
    required this.iconColor,
    required this.onTap,
  });

  final int index;
  final IconData icon;
  final String title;
  final Color iconColor;
  final VoidCallback? onTap;
}
