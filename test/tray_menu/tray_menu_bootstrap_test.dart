import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanabi_download_manager_x/tray_menu/tray_menu_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TrayMenuLaunchData', () {
    test('parses presentation, positioning, and active-task payload', () {
      final data = TrayMenuLaunchData.fromArgs(const [
        '{"locale":"zh-CN","mouse_x":120.5,"mouse_y":640,'
            '"show_on_ready":false,"theme_mode":"dark",'
            '"classic_control_visuals":true,"active_tasks":['
            '{"id":"task-1","file_name":"archive.zip",'
            '"status":"downloading","progress":0.25}]}'
      ]);

      expect(data.localeTag, 'zh-CN');
      expect(data.mousePositionX, 120.5);
      expect(data.mousePositionY, 640);
      expect(data.showOnReady, isFalse);
      expect(data.themeMode, 'dark');
      expect(data.classicControlVisuals, isTrue);
      expect(data.activeTasks, hasLength(1));
      expect(data.activeTasks.single.fileName, 'archive.zip');
      expect(data.activeTasks.single.progress, 0.25);
    });

    test('uses safe defaults for malformed payload', () {
      final data = TrayMenuLaunchData.fromArgs(const ['not-json']);

      expect(data.localeTag, isNull);
      expect(data.mousePositionX, 0);
      expect(data.mousePositionY, 0);
      expect(data.showOnReady, isTrue);
      expect(data.activeTasks, isEmpty);
    });

    test('compares equivalent active-task payloads by value', () {
      final first = TrayMenuLaunchData.fromArgs(const [
        '{"locale":"en-US","mouse_x":1,"mouse_y":2,'
            '"active_tasks":[{"id":"a","file_name":"a.bin",'
            '"status":"pending","progress":0}]}'
      ]);
      final second = TrayMenuLaunchData.fromArgs(const [
        '{"locale":"en-US","mouse_x":1,"mouse_y":2,'
            '"active_tasks":[{"id":"a","file_name":"a.bin",'
            '"status":"pending","progress":0}]}'
      ]);

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });
  });

  test('window size reserves symmetric panel and shadow space', () {
    const contentSize = Size(156.2, 203.1);

    expect(
      calculateTrayMenuWindowSize(contentSize),
      const Size(181, 232),
    );
  });

  testWidgets('submenu hover is stable and Escape closes once', (tester) async {
    const channel = MethodChannel('com.hanabi.download/window');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(
      const TrayMenuApp(
        launchData: TrayMenuLaunchData(
          localeTag: 'en-US',
          mousePositionX: 0,
          mousePositionY: 0,
          showOnReady: false,
        ),
        locale: Locale('en', 'US'),
      ),
    );
    await tester.pump();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Open folders')));
    // Two pumps: the native resize must be acknowledged before the submenu
    // is allowed to paint.
    await tester.pump();
    await tester.pump();
    expect(find.text('Downloads'), findsOneWidget);

    await mouse.moveTo(const Offset(760, 560));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 279));
    expect(find.text('Downloads'), findsOneWidget);
    // The grace timer fires at 280ms and starts the close animation; the
    // panel leaves the tree once the 90ms fade-out completes.
    await tester.pump(const Duration(milliseconds: 2));
    expect(find.text('Downloads'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();
    expect(find.text('Downloads'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(calls.where((call) => call.method == 'closeWindow'), hasLength(1));
  });

  testWidgets('submenu grows the native window before it paints',
      (tester) async {
    const channel = MethodChannel('com.hanabi.download/window');
    final resizes = <Map<Object?, Object?>>[];
    var downloadsVisibleWhenResized = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'resizeWindow') {
        resizes.add(Map<Object?, Object?>.from(call.arguments as Map));
        downloadsVisibleWhenResized =
            find.text('Downloads').evaluate().isNotEmpty;
      }
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(
      const TrayMenuApp(
        launchData: TrayMenuLaunchData(
          localeTag: 'en-US',
          mousePositionX: 0,
          mousePositionY: 0,
          showOnReady: false,
        ),
        locale: Locale('en', 'US'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(resizes, isNotEmpty,
        reason: 'the window must be sized without user interaction');
    // The window hugs the main panel while no submenu is open: on machines
    // without DWM alpha the uncovered window area renders as an opaque box,
    // so no speculative space may be reserved.
    final initialWidth = resizes.last['width'] as int;
    resizes.clear();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Open folders')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Downloads'), findsOneWidget);
    expect(resizes, isNotEmpty,
        reason: 'opening a submenu must grow the native window');
    expect(resizes.first['width'] as int, greaterThan(initialWidth));
    expect(downloadsVisibleWhenResized, isFalse,
        reason: 'the submenu must not paint before the window has grown');
  });

  testWidgets('region rect tracks the settled submenu position across a switch',
      (tester) async {
    const channel = MethodChannel('com.hanabi.download/window');
    final regionCalls = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setTrayMenuRegion') {
        regionCalls.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(600, 400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const TrayMenuApp(
        launchData: TrayMenuLaunchData(
          localeTag: 'en-US',
          mousePositionX: 0,
          mousePositionY: 0,
          showOnReady: false,
        ),
        locale: Locale('en', 'US'),
      ),
    );
    await tester.pump();
    await tester.pump();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);

    // Open the tasks submenu first, then glide down to the folders group so
    // the vertical offset animates 70 -> 102. The region used to be captured
    // mid-flight, which sliced the settled panel at its old position.
    await mouse.moveTo(tester.getCenter(find.text('Active')));
    await tester.pump();
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.text('Open folders')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(regionCalls, isNotEmpty);
    final rects = (regionCalls.last['rects'] as List)
        .map((rect) => Map<Object?, Object?>.from(rect as Map))
        .toList(growable: false);
    expect(rects, hasLength(2),
        reason: 'main panel and submenu must both be in the region');

    // Submenu rect = the one to the right of the main panel. Its unpadded top
    // must equal insets.top(8) + folders offset(6 + 3*32 = 102) = 110; the
    // 8px shadow pad brings the sent value to 102 at DPR 1.0.
    final submenuRect = rects.reduce((a, b) =>
        (a['x'] as num).toDouble() > (b['x'] as num).toDouble() ? a : b);
    expect((submenuRect['y'] as num).toDouble(), closeTo(102, 1.5),
        reason: 'region must cover the SETTLED submenu position');
  });

  testWidgets('failed native resize is retried instead of latched',
      (tester) async {
    const channel = MethodChannel('com.hanabi.download/window');
    var resizeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'resizeWindow') {
        resizeCalls++;
        // First attempt reports failure, as the native side does while the
        // window handle is not ready yet.
        return resizeCalls > 1;
      }
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await tester.pumpWidget(
      const TrayMenuApp(
        launchData: TrayMenuLaunchData(
          localeTag: 'en-US',
          mousePositionX: 0,
          mousePositionY: 0,
          showOnReady: false,
        ),
        locale: Locale('en', 'US'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(resizeCalls, 1);

    // The retry timer fires after 60ms and must re-issue the same resize.
    // Before the fix the failed attempt was latched as applied and the menu
    // stayed at its 184x320 creation size — visibly cut through the middle.
    await tester.pump(const Duration(milliseconds: 61));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 61));
    await tester.pump();
    expect(resizeCalls, greaterThanOrEqualTo(2));
  });
}
