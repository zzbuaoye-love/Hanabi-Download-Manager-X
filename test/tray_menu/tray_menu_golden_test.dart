import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanabi_download_manager_x/tray_menu/tray_menu_bootstrap.dart';

// Renders the real tray menu widget tree to PNGs so layout regressions are
// visible instead of inferred. Regenerate with:
//   flutter test test/tray_menu/tray_menu_golden_test.dart --update-goldens
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpTrayApp(
    WidgetTester tester, {
    required String locale,
    List<Map<String, Object>> activeTasks = const [],
  }) async {
    const channel = MethodChannel('com.hanabi.download/window');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(520, 360);
    addTearDown(tester.view.reset);

    final payload = <String, Object>{
      'locale': locale,
      'mouse_x': 100.0,
      'mouse_y': 100.0,
      'show_on_ready': true,
      'theme_mode': 'dark',
      'active_tasks': activeTasks,
    };
    final parts = locale.split('-');

    await tester.pumpWidget(
      TrayMenuApp(
        launchData: TrayMenuLaunchData.fromArgs([jsonEncode(payload)]),
        locale: Locale(parts.first, parts.length > 1 ? parts[1] : null),
      ),
    );
    // Let geometry reporting, the settle probe, the reveal tick, and the
    // entrance animation all run to completion.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('golden: zh menu closed', (tester) async {
    await pumpTrayApp(
      tester,
      locale: 'zh-CN',
      activeTasks: const [
        {
          'id': 't1',
          'file_name': 'zh-cn_windows_11_business_editions.iso',
          'status': 'downloading',
          'progress': 0.42,
        },
      ],
    );
    await expectLater(
      find.byType(TrayMenuApp),
      matchesGoldenFile('goldens/tray_menu_zh_closed.png'),
    );
  });

  testWidgets('golden: zh menu with tasks submenu open', (tester) async {
    await pumpTrayApp(
      tester,
      locale: 'zh-CN',
      activeTasks: const [
        {
          'id': 't1',
          'file_name': 'zh-cn_windows_11_business_editions.iso',
          'status': 'downloading',
          'progress': 0.42,
        },
      ],
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('正在进行')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(TrayMenuApp),
      matchesGoldenFile('goldens/tray_menu_zh_submenu.png'),
    );
  });
}
