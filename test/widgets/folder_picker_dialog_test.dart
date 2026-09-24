import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanabi_download_manager_x/l10n/app_localizations.dart';
import 'package:hanabi_download_manager_x/services/quick_path_service.dart';
import 'package:hanabi_download_manager_x/theme/app_theme.dart';
import 'package:hanabi_download_manager_x/widgets/folder_picker_dialog.dart';
import 'package:provider/provider.dart';

Widget _buildTestApp(Widget child) {
  final theme = AppTheme.themeDataForBrightness(Brightness.dark);
  AppTheme.applyFluentTheme(theme);

  return ChangeNotifierProvider<QuickPathService>.value(
    value: QuickPathService(),
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

Future<void> _settleFileSystem(WidgetTester tester) async {
  // Widget tests run with a fake clock; let real Windows directory I/O finish
  // before pumping each state change it schedules. Initialization has several
  // chained I/O awaits, so one runAsync window is not sufficient.
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    if (find.byType(ProgressRing).evaluate().isEmpty) {
      return;
    }
  }
  fail('Folder picker did not finish loading the test directory');
}

void main() {
  testWidgets('file mode filters files and remains single-select by default',
      (tester) async {
    final temporary = Directory.systemTemp.createTempSync('hanabi-picker-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final zipFile =
        File('${temporary.path}${Platform.pathSeparator}plugin.zip');
    final packageFile = File(
      '${temporary.path}${Platform.pathSeparator}plugin.hanabi-plugin',
    );
    final ignoredFile =
        File('${temporary.path}${Platform.pathSeparator}notes.txt');
    zipFile.writeAsStringSync('zip');
    packageFile.writeAsStringSync('package');
    ignoredFile.writeAsStringSync('ignored');
    Directory('${temporary.path}${Platform.pathSeparator}nested').createSync();

    await tester.binding.setSurfaceSize(const Size(960, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _buildTestApp(
        FolderPickerDialog(
          initialPath: temporary.path,
          mode: FileSystemPickerMode.file,
          allowedExtensions: const <String>['zip', 'hanabi-plugin'],
          title: '选择插件安装包',
          selectButtonLabel: '使用此文件',
        ),
      ),
    );
    await tester.pump();
    await _settleFileSystem(tester);

    expect(find.text('plugin.zip'), findsOneWidget);
    expect(find.text('plugin.hanabi-plugin'), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing);
    expect(find.text('nested'), findsOneWidget);
    expect(find.text('快速访问'), findsOneWidget);
    expect(find.text('名称'), findsOneWidget);
    expect(find.text('类型'), findsOneWidget);
    expect(find.textContaining('.zip, .hanabi-plugin'), findsOneWidget);

    final selectButton = find.widgetWithText(FilledButton, '使用此文件');
    expect(tester.widget<FilledButton>(selectButton).onPressed, isNull);

    await tester.tap(find.text('plugin.zip'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.widget<FilledButton>(selectButton).onPressed, isNotNull);
    expect(find.text(zipFile.absolute.path), findsOneWidget);

    await tester.tap(find.text('plugin.hanabi-plugin'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(packageFile.absolute.path), findsOneWidget);
    expect(find.text(zipFile.absolute.path), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('allowMultiple selects and deselects several visible files',
      (tester) async {
    final temporary = Directory.systemTemp.createTempSync('hanabi-multi-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    File('${temporary.path}${Platform.pathSeparator}first.zip')
        .writeAsStringSync('first');
    File(
      '${temporary.path}${Platform.pathSeparator}second.hanabi-plugin',
    ).writeAsStringSync('second');

    await tester.binding.setSurfaceSize(const Size(960, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _buildTestApp(
        FolderPickerDialog(
          initialPath: temporary.path,
          mode: FileSystemPickerMode.file,
          allowMultiple: true,
          allowedExtensions: const <String>['zip', 'hanabi-plugin'],
          selectButtonLabel: '使用所选文件',
        ),
      ),
    );
    await tester.pump();
    await _settleFileSystem(tester);

    expect(find.byType(Checkbox), findsNWidgets(2));
    final selectButton = find.widgetWithText(FilledButton, '使用所选文件 (0)');
    expect(tester.widget<FilledButton>(selectButton).onPressed, isNull);

    await tester.tap(find.text('first.zip'));
    await tester.tap(find.text('second.hanabi-plugin'));
    await tester.pump();

    expect(find.text('已选择 2 个文件'), findsOneWidget);
    final selectedButton = find.widgetWithText(FilledButton, '使用所选文件 (2)');
    expect(tester.widget<FilledButton>(selectedButton).onPressed, isNotNull);

    await tester.tap(find.text('first.zip'));
    await tester.pump();

    expect(find.text('已选择 1 个文件'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '使用所选文件 (1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('directory mode remains backward compatible', (tester) async {
    final temporary = Directory.systemTemp.createTempSync('hanabi-folder-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    File('${temporary.path}${Platform.pathSeparator}hidden.zip')
        .writeAsStringSync('zip');
    Directory('${temporary.path}${Platform.pathSeparator}visible').createSync();

    await tester.binding.setSurfaceSize(const Size(960, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _buildTestApp(FolderPickerDialog(initialPath: temporary.path)),
    );
    await tester.pump();
    await _settleFileSystem(tester);

    expect(find.text('visible'), findsOneWidget);
    expect(find.text('hidden.zip'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, '选择'),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact layout collapses the navigation rail without overflow',
      (tester) async {
    final temporary = Directory.systemTemp.createTempSync('hanabi-compact-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    Directory('${temporary.path}${Platform.pathSeparator}visible').createSync();

    await tester.binding.setSurfaceSize(const Size(640, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _buildTestApp(FolderPickerDialog(initialPath: temporary.path)),
    );
    await tester.pump();
    await _settleFileSystem(tester);

    expect(find.text('visible'), findsOneWidget);
    expect(find.text('快速访问'), findsNothing);
    expect(find.text('类型'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
