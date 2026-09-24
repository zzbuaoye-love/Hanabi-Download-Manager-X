import 'package:flutter_test/flutter_test.dart';
import 'package:hanabi_download_manager_x/models/plugin_manifest.dart';

void main() {
  group('PluginManifest', () {
    test('keeps legacy manifests compatible with API v1 defaults', () {
      final manifest = PluginManifest.fromJson({
        'id': 'hanabi.example.legacy',
        'name': 'Legacy plugin',
        'version': '0.1.0',
        'author': 'Hanabi',
        'entry': 'main.py',
        'capabilities': ['download:custom'],
      });

      expect(manifest.manifestVersion, PluginManifest.currentManifestVersion);
      expect(manifest.apiVersion, PluginManifest.currentApiVersion);
      expect(manifest.runtime.isDefault, isTrue);
      expect(manifest.validate(), isEmpty);
    });

    test('parses and serializes runtime and routing extensions', () {
      final manifest = PluginManifest.fromJson({
        'manifestVersion': 1,
        'apiVersion': '1.0',
        'id': 'hanabi.example.deno',
        'name': 'Deno plugin',
        'version': '1.2.3',
        'author': 'Hanabi',
        'entry': 'src/main.ts',
        'capabilities': ['download:custom:demo'],
        'intentSchemes': ['HANABI+DEMO'],
        'priority': 25,
        'maxAppVersion': '2.0.0',
        'runtime': {
          'executable': 'deno',
          'arguments': ['run', '--allow-net', '{entry}'],
          'environment': {'PLUGIN_MODE': 'production'},
          'workingDirectory': 'src',
          'timeoutSeconds': 45,
        },
      });

      expect(manifest.intentSchemes, ['hanabi+demo']);
      expect(manifest.handlesIntentScheme('HANABI+DEMO'), isTrue);
      expect(manifest.runtime.executable, 'deno');
      expect(manifest.runtime.arguments.last, '{entry}');
      expect(manifest.validate(), isEmpty);

      final serialized = manifest.toJson();
      expect(serialized['apiVersion'], '1.0');
      expect(serialized['intentSchemes'], ['hanabi+demo']);
      expect((serialized['runtime'] as Map)['timeoutSeconds'], 45);
    });

    test('rejects unsafe paths, reserved environment and malformed UI', () {
      final manifest = PluginManifest.fromJson({
        'manifestVersion': 2,
        'apiVersion': '2.0',
        'id': 'hanabi.example.invalid',
        'name': 'Invalid plugin',
        'version': '1.0.0',
        'author': 'Hanabi',
        'entry': '../outside.py',
        'icon': 'C:\\outside.png',
        'capabilities': ['download:custom', 'download:custom'],
        'permissions': ['network', 'registry'],
        'minAppVersion': 'latest',
        'intentSchemes': ['https'],
        'priority': 5000,
        'runtime': {
          'executable': '../outside.exe',
          'environment': {
            'HANABI_PLUGIN_ID': 'spoofed',
            'NESTED': {'value': true},
          },
          'timeoutSeconds': 0,
        },
        'ui_extensions': {
          'settings': [
            {'type': 'button', 'id': 'run', 'label': 'Run'},
          ],
        },
      });

      final errors = manifest.validate().join('\n');
      expect(errors, contains('manifestVersion 2 is not supported'));
      expect(errors, contains('apiVersion 2.0 is not supported'));
      expect(errors, contains('entry must be a relative path'));
      expect(errors, contains('icon must be a relative path'));
      expect(errors, contains('capabilities must not contain duplicates'));
      expect(errors, contains('unknown permissions: registry'));
      expect(errors, contains('minAppVersion must be a version number'));
      expect(errors, contains('invalid intent scheme'));
      expect(errors, contains('priority must be between'));
      expect(errors, contains('reserved HANABI_'));
      expect(errors, contains('runtime.executable must stay inside'));
      expect(
          errors, contains('runtime.environment.NESTED must be a JSON scalar'));
      expect(errors, contains('requires an action'));
    });

    test('parses ui_extensions.pages and keeps them out of the element map',
        () {
      final manifest = PluginManifest.fromJson({
        'id': 'hanabi.example.pages',
        'name': 'Pages plugin',
        'version': '1.0.0',
        'author': 'Hanabi',
        'entry': 'main.py',
        'capabilities': ['download:ed2k'],
        'ui_extensions': {
          'sidebar': [
            {'type': 'text', 'id': 'hint', 'label': 'Hi'},
          ],
          'pages': [
            {
              'id': 'dashboard',
              'title': 'Remote dashboard',
              'icon': 'fluent:cloud',
              'placement': 'top',
              'provider': 'aria2.dashboard.render',
              'refresh_seconds': 10,
              'elements': [
                {'type': 'text', 'id': 'loading', 'label': 'Loading…'},
              ],
            },
            {
              'id': 'history',
              'title': 'Download history',
              'replaces': 'COMPLETED',
              'provider': 'history.page.render',
            },
          ],
        },
      });

      expect(manifest.pageExtensions, hasLength(2));
      expect(manifest.uiExtensions?.containsKey('pages'), isFalse);
      expect(manifest.uiExtensions?['sidebar'], hasLength(1));

      final dashboard = manifest.pageExtensions.first;
      expect(dashboard.id, 'dashboard');
      expect(dashboard.placement, PluginSidebarPlacement.top);
      expect(dashboard.provider, 'aria2.dashboard.render');
      expect(dashboard.refreshSeconds, 10);
      expect(dashboard.elements, hasLength(1));
      expect(dashboard.replaces, isNull);

      final history = manifest.pageExtensions.last;
      expect(history.replaces, 'completed');
      expect(history.placement, PluginSidebarPlacement.bottom);
      expect(history.refreshSeconds, 0);
      expect(history.elements, isEmpty);

      expect(manifest.validate(), isEmpty);

      final pages =
          ((manifest.toJson()['ui_extensions'] as Map)['pages'] as List)
              .cast<Map<String, dynamic>>();
      expect(pages, hasLength(2));
      expect(pages.first['placement'], 'top');
      expect(pages.first['refresh_seconds'], 10);
      expect(pages.last['replaces'], 'completed');
      expect(pages.last.containsKey('refresh_seconds'), isFalse);
    });

    test('accepts snake_case and alias keys for page fields', () {
      final manifest = PluginManifest.fromJson({
        'id': 'hanabi.example.aliases',
        'name': 'Alias plugin',
        'version': '1.0.0',
        'author': 'Hanabi',
        'entry': 'main.py',
        'capabilities': ['download:ed2k'],
        'ui_extensions': {
          'pages': [
            {
              'id': 'panel',
              'title': 'Panel',
              'position': 'top',
              'controls': [
                {'type': 'text', 'id': 'row', 'label': 'Row'},
              ],
              'provider': 'panel.render',
              'refreshSeconds': 60,
            },
          ],
        },
      });

      final page = manifest.pageExtensions.single;
      expect(page.placement, PluginSidebarPlacement.top);
      expect(page.elements, hasLength(1));
      expect(page.refreshSeconds, 60);
      expect(manifest.validate(), isEmpty);
    });

    test('rejects malformed page declarations', () {
      final manifest = PluginManifest.fromJson({
        'id': 'hanabi.example.badpages',
        'name': 'Bad pages plugin',
        'version': '1.0.0',
        'author': 'Hanabi',
        'entry': 'main.py',
        'capabilities': ['download:ed2k'],
        'ui_extensions': {
          'pages': [
            {
              'id': 'Bad Id',
              'title': '',
              'icon': 'C:\\outside.png',
              'replaces': 'downloading',
              'provider': '1invalid',
              'refresh_seconds': 2,
            },
            {'id': 'empty', 'title': 'Empty'},
            {
              'id': 'ok',
              'title': 'Ok',
              'replaces': 'completed',
              'provider': 'render',
            },
            {
              'id': 'ok',
              'title': 'Duplicate',
              'replaces': 'completed',
              'provider': 'render',
            },
          ],
        },
      });

      final errors = manifest.validate().join('\n');
      expect(errors, contains('must use lowercase letters'));
      expect(errors, contains('requires a title'));
      expect(errors, contains('cannot replace "downloading"'));
      expect(errors, contains('provider must be a valid method name'));
      expect(errors, contains('refresh_seconds must be 0 or between'));
      expect(errors, contains('empty requires elements or a provider'));
      expect(errors, contains('icon must be fluent:<name>'));
      expect(errors, contains('contains duplicate id: ok'));
      expect(
          errors, contains('declares multiple replacements for "completed"'));
    });
  });
}
