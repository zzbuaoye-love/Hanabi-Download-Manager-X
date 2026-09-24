import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanabi_download_manager_x/l10n/app_localizations.dart';
import 'package:hanabi_download_manager_x/models/notice_model.dart';
import 'package:hanabi_download_manager_x/screens/widgets/notice_page.dart';
import 'package:hanabi_download_manager_x/services/client_config_service.dart';
import 'package:hanabi_download_manager_x/services/notice_service.dart';
import 'package:hanabi_download_manager_x/theme/app_theme.dart';
import 'package:provider/provider.dart';

class _FakeNoticeService extends NoticeService {
  _FakeNoticeService(this._items);

  final List<Notice> _items;
  int fetchCalls = 0;

  @override
  List<Notice> get notices => _items;

  @override
  List<Notice> get activeNotices => _items;

  @override
  bool get isLoading => false;

  @override
  String? get error => null;

  @override
  DateTime? get lastFetchTime => DateTime(2026, 7, 26, 10, 0);

  @override
  Future<void> fetchNotices({bool force = false}) async {
    fetchCalls++;
  }
}

Notice _notice({
  required String id,
  required String title,
  NoticeLevel level = NoticeLevel.info,
  bool pinned = false,
}) {
  final now = DateTime(2026, 7, 20, 9, 30);
  return Notice(
    id: id,
    title: title,
    summary: '$title 的摘要文案，用于验证两行截断表现。',
    content: '## $title\n\n正文段落。\n\n- 列表项 A\n- 列表项 B\n\n> 引用块\n',
    level: level,
    status: NoticeStatus.published,
    pinned: pinned,
    publishedAt: now,
    createdAt: now,
    updatedAt: now,
    link: NoticeLink(label: '查看详情', url: 'https://example.com'),
  );
}

Widget _app(Widget child, NoticeService service) {
  final theme = AppTheme.themeDataForBrightness(Brightness.dark);
  AppTheme.applyFluentTheme(theme);

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<NoticeService>.value(value: service),
      ChangeNotifierProvider<ClientConfigService>.value(
        value: ClientConfigService(),
      ),
    ],
    child: FluentApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh'),
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        FluentLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: theme,
      home: child,
    ),
  );
}

void main() {
  final notices = <Notice>[
    _notice(
        id: 'a', title: '重要维护公告', level: NoticeLevel.critical, pinned: true),
    _notice(id: 'b', title: '版本更新说明', level: NoticeLevel.success),
    _notice(id: 'c', title: '使用提示'),
  ];

  testWidgets('split view renders the list and detail placeholder',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _FakeNoticeService(notices);
    await tester.pumpWidget(_app(const NoticePage(), service));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('重要维护公告'), findsOneWidget);
    expect(find.text('版本更新说明'), findsOneWidget);
    // 未选中任何通知时右侧显示 WinUI 占位块，而不是塌陷成空白
    expect(find.text('选择一条通知'), findsOneWidget);

    // AnimatedSwitcher 默认布局会让内容按自身高度居中，页面顶部凭空空出一大截。
    // 这里要求详情面板撑满整栏。
    final placeholder = tester.getSize(
      find.byKey(const ValueKey('detail-placeholder')),
    );
    expect(placeholder.height, greaterThan(500));
  });

  testWidgets('selecting a notice opens the detail pane', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _FakeNoticeService(notices);
    await tester.pumpWidget(_app(const NoticePage(), service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('版本更新说明'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('选择一条通知'), findsNothing);
    // 详情面板渲染 Markdown 正文与底部链接命令
    expect(find.text('查看详情'), findsOneWidget);
  });

  testWidgets('narrow window falls back to a single detail pane',
      (tester) async {
    // 窄窗口（< 720）下选中通知应整屏展示详情，而不是把两栏都挤扁
    await tester.binding.setSurfaceSize(const Size(680, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _FakeNoticeService(notices);
    await tester.pumpWidget(_app(const NoticePage(), service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('使用提示'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('重要维护公告'), findsNothing);
    expect(find.text('查看详情'), findsOneWidget);
  });
}
