import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanabi_download_manager_x/l10n/app_localizations.dart';
import 'package:hanabi_download_manager_x/theme/app_theme.dart';
import 'package:hanabi_download_manager_x/widgets/fluent_interactions.dart';
import 'package:hanabi_download_manager_x/widgets/scroll_edge_fade.dart';
import 'package:hanabi_download_manager_x/widgets/settings_components.dart';

Widget _app(Widget child) {
  final theme = AppTheme.themeDataForBrightness(Brightness.dark);
  AppTheme.applyFluentTheme(theme);

  return FluentApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh'),
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      FluentLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    theme: theme,
    home: ScaffoldPage(content: SingleChildScrollView(child: child)),
  );
}

void main() {
  testWidgets('settings section renders cards inside a scroll view',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(
      SettingsSection(
        title: '分组标题',
        icon: FluentIcons.settings,
        children: [
          const SettingsItem(
            title: '普通设置项',
            subtitle: '副标题',
            trailing: ToggleSwitch(checked: true, onChanged: null),
          ),
          const SizedBox(height: 12),
          Builder(
            builder: (context) => const SettingsItem(
              title: '被 Builder 包装的设置项',
              subtitle: '高亮应铺满整张卡片',
              trailing: SizedBox.shrink(),
            ),
          ),
          SettingsLinkItem(
            title: '可点击行',
            subtitle: '整卡可点',
            onPressed: () {},
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('普通设置项'), findsOneWidget);
    expect(find.text('可点击行'), findsOneWidget);
    expect(find.byType(SettingsCardSurface), findsNWidgets(3));

    // 卡片高度不小于 WinUI SettingsCard 的最小高度收敛值
    final size = tester.getSize(find.byType(SettingsCardSurface).first);
    expect(size.height, greaterThanOrEqualTo(60.0));
  });

  testWidgets('interactive surface highlight covers the whole hit area',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(
      Align(
        alignment: Alignment.topLeft,
        child: FluentInteractiveSurface(
          onPressed: () {},
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: const Text('目标'),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final surface = find.byType(FluentInteractiveSurface);
    final container = find.descendant(
      of: surface,
      matching: find.byType(AnimatedContainer),
    );

    // 高亮层（AnimatedContainer）与整个控件命中区域完全等大
    expect(tester.getSize(container.first), tester.getSize(surface));
    expect(tester.takeException(), isNull);
  });

  testWidgets('filling switcher layout does not center short content',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const shortChild = SizedBox(key: ValueKey('short'), height: 100);

    final theme = AppTheme.themeDataForBrightness(Brightness.dark);
    AppTheme.applyFluentTheme(theme);

    // 需要一个高度受限的容器才能体现居中 / 撑满的差别
    Widget host(AnimatedSwitcherLayoutBuilder? layoutBuilder) {
      return FluentApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: SizedBox(
          height: 600,
          width: 400,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 1),
            layoutBuilder:
                layoutBuilder ?? AnimatedSwitcher.defaultLayoutBuilder,
            child: shortChild,
          ),
        ),
      );
    }

    // 框架默认布局：内容按自身高度居中，上方留出大片空白
    await tester.pumpWidget(host(null));
    await tester.pumpAndSettle();
    final centeredTop = tester.getTopLeft(find.byKey(const ValueKey('short')));
    expect(centeredTop.dy, greaterThan(100));

    // 撑满布局：内容顶到可用区域最上方
    await tester.pumpWidget(host(fillingSwitcherLayout));
    await tester.pumpAndSettle();
    final filledTop = tester.getTopLeft(find.byKey(const ValueKey('short')));
    expect(filledTop.dy, lessThan(centeredTop.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('scroll edge fade wraps a list without changing its layout',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final theme = AppTheme.themeDataForBrightness(Brightness.dark);
    AppTheme.applyFluentTheme(theme);

    await tester.pumpWidget(FluentApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: ScaffoldPage(
        content: ScrollEdgeFade(
          topExtent: 24,
          bottomExtent: 24,
          child: ListView.builder(
            itemCount: 40,
            itemBuilder: (context, index) => SizedBox(
              height: 40,
              child: Text('行 $index'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 遮罩不改变滚动区尺寸，也不拦截滚动手势
    final fade = find.byType(ScrollEdgeFade);
    expect(tester.getSize(fade), tester.getSize(find.byType(ListView)));

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 遮罩随滚动变化时不能重建滚动区，否则滚动位置会被重置
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(position.pixels, greaterThan(100));

    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .pixels,
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('fluent controls render without layout errors', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_app(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FluentIconButton(
                icon: FluentIcons.play,
                tooltip: '开始',
                onPressed: () {},
              ),
              const SizedBox(width: 4),
              FluentIconButton(
                icon: FluentIcons.delete,
                tooltip: '删除',
                tinted: true,
                accentColor: AppTheme.statusError,
                onPressed: () {},
              ),
              const SizedBox(width: 4),
              FluentIconButton(
                icon: FluentIcons.filter,
                selected: true,
                onPressed: () {},
              ),
              const SizedBox(width: 8),
              FluentSubtleButton(
                icon: FluentIcons.folder_open,
                label: '打开位置',
                onPressed: () {},
              ),
            ],
          ),
          const SizedBox(height: 12),
          const FluentChip(label: '置顶', icon: FluentIcons.pin),
          const SizedBox(height: 12),
          const FluentProgressTrack(value: 0.42, height: 6),
          const SizedBox(height: 12),
          const FluentProgressTrack(value: 0, indeterminate: true),
          const SizedBox(height: 12),
          FluentExpanderChevron(expanded: true, onPressed: () {}),
        ],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.byType(FluentIconButton), findsNWidgets(3));

    // 图标按钮命中区域为 WinUI 的 32×32
    expect(
      tester.getSize(find.byType(FluentIconButton).first),
      const Size(32, 32),
    );
  });
}
