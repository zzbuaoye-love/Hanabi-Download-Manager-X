import 'dart:convert';

import 'plugin_ui_schema.dart';

enum PluginInstallState {
  available,
  enabled,
  disabled,
  incompatible,
  invalid,
}

enum PluginSidebarPlacement {
  top,
  bottom,
}

class PluginRuntimeConfig {
  const PluginRuntimeConfig({
    this.executable,
    this.arguments = const <String>[],
    this.environment = const <String, String>{},
    this.workingDirectory,
    this.timeoutSeconds = 30,
    this.invalidEnvironmentKeys = const <String>[],
  });

  final String? executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? workingDirectory;
  final int timeoutSeconds;
  final List<String> invalidEnvironmentKeys;

  factory PluginRuntimeConfig.fromJson(Object? raw) {
    if (raw is! Map) {
      return const PluginRuntimeConfig();
    }
    final json = <String, dynamic>{
      for (final entry in raw.entries) entry.key.toString(): entry.value,
    };
    final argumentsRaw = json['arguments'] ?? json['args'];
    final environmentRaw = json['environment'] ?? json['env'];
    final timeoutRaw = json['timeoutSeconds'] ?? json['timeout_seconds'];
    final parsedTimeout = _strictInt(timeoutRaw);

    final invalidEnvironmentKeys = environmentRaw is Map
        ? environmentRaw.entries
            .where((entry) => !_isJsonScalar(entry.value))
            .map((entry) => entry.key.toString())
            .toList(growable: false)
        : const <String>[];

    return PluginRuntimeConfig(
      executable: _optionalString(json['executable'] ?? json['command']),
      arguments: argumentsRaw is List
          ? argumentsRaw
              .map((value) => value.toString())
              .toList(growable: false)
          : const <String>[],
      environment: environmentRaw is Map
          ? {
              for (final entry in environmentRaw.entries)
                entry.key.toString(): entry.value?.toString() ?? '',
            }
          : const <String, String>{},
      workingDirectory: _optionalString(
        json['workingDirectory'] ?? json['working_directory'],
      ),
      timeoutSeconds: timeoutRaw == null ? 30 : parsedTimeout ?? 0,
      invalidEnvironmentKeys: invalidEnvironmentKeys,
    );
  }

  bool get isDefault =>
      executable == null &&
      arguments.isEmpty &&
      environment.isEmpty &&
      workingDirectory == null &&
      timeoutSeconds == 30 &&
      invalidEnvironmentKeys.isEmpty;

  Map<String, dynamic> toJson() => {
        if (executable != null) 'executable': executable,
        if (arguments.isNotEmpty) 'arguments': arguments,
        if (environment.isNotEmpty) 'environment': environment,
        if (workingDirectory != null) 'workingDirectory': workingDirectory,
        if (timeoutSeconds != 30) 'timeoutSeconds': timeoutSeconds,
      };

  List<String> validate() {
    final errors = <String>[];
    if (timeoutSeconds < 1 || timeoutSeconds > 300) {
      errors.add('runtime.timeoutSeconds must be between 1 and 300');
    }
    if (workingDirectory != null &&
        !_isSafeRelativePath(workingDirectory!, allowCurrentDirectory: true)) {
      errors.add(
          'runtime.workingDirectory must stay inside the plugin directory');
    }
    if (executable != null &&
        !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(executable!) &&
        !executable!.startsWith('/') &&
        (executable!.contains('/') || executable!.contains('\\')) &&
        !_isSafeRelativePath(executable!)) {
      errors.add('runtime.executable must stay inside the plugin directory');
    }
    if (arguments.length > 128) {
      errors.add('runtime.arguments cannot contain more than 128 items');
    }
    for (final entry in environment.entries) {
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(entry.key)) {
        errors.add('runtime.environment contains an invalid key: ${entry.key}');
      }
      if (entry.key.toUpperCase().startsWith('HANABI_')) {
        errors.add(
            'runtime.environment cannot override reserved HANABI_ variables');
      }
    }
    for (final key in invalidEnvironmentKeys) {
      errors.add('runtime.environment.$key must be a JSON scalar');
    }
    return errors;
  }
}

class PluginPermissionSet {
  const PluginPermissionSet({
    this.network = false,
    this.fileWrite = false,
    this.systemCommand = false,
    this.unknown = const <String>[],
  });

  final bool network;
  final bool fileWrite;
  final bool systemCommand;
  final List<String> unknown;

  factory PluginPermissionSet.fromJson(Object? json) {
    if (json is List) {
      final values = json.map((value) => value.toString()).toSet();
      const known = <String>{
        'network',
        'file_write',
        'fileWrite',
        'system_command',
        'systemCommand',
      };
      return PluginPermissionSet(
        network: values.contains('network'),
        fileWrite:
            values.contains('file_write') || values.contains('fileWrite'),
        systemCommand: values.contains('system_command') ||
            values.contains('systemCommand'),
        unknown: values.where((value) => !known.contains(value)).toList(),
      );
    }
    if (json is Map) {
      const known = <String>{
        'network',
        'file_write',
        'fileWrite',
        'system_command',
        'systemCommand',
      };
      return PluginPermissionSet(
        network: json['network'] == true,
        fileWrite: json['file_write'] == true || json['fileWrite'] == true,
        systemCommand:
            json['system_command'] == true || json['systemCommand'] == true,
        unknown: json.entries
            .where((entry) => entry.value == true && !known.contains(entry.key))
            .map((entry) => entry.key.toString())
            .toList(growable: false),
      );
    }
    return const PluginPermissionSet();
  }

  List<String> toList() {
    return [
      if (network) 'network',
      if (fileWrite) 'file_write',
      if (systemCommand) 'system_command',
      ...unknown,
    ];
  }
}

/// A full page contributed by a plugin through `ui_extensions.pages`.
///
/// A page either shows up as its own sidebar entry (when [replaces] is null)
/// or takes over one of the replaceable built-in pages (currently only
/// `completed`). Content is rendered from the same declarative element schema
/// used by the sidebar; when [provider] is set the host additionally asks the
/// plugin for a fresh element list at runtime.
class PluginPageExtension {
  const PluginPageExtension({
    required this.id,
    required this.title,
    this.icon,
    this.replaces,
    this.placement = PluginSidebarPlacement.bottom,
    this.elements = const <PluginUIElement>[],
    this.provider,
    this.refreshSeconds = 0,
  });

  /// Built-in pages that plugins are allowed to replace.
  static const Set<String> replaceableBuiltInPages = <String>{'completed'};

  static const int minRefreshSeconds = 5;
  static const int maxRefreshSeconds = 3600;

  final String id;
  final String title;

  /// `fluent:<name>` or a relative image path inside the plugin directory.
  final String? icon;

  /// Id of the built-in page this page replaces, or null for a standalone
  /// page with its own sidebar entry.
  final String? replaces;

  /// Sidebar placement for standalone pages.
  final PluginSidebarPlacement placement;

  /// Static content, rendered when no [provider] is configured (and shown as
  /// fallback while a provider call is in flight or failing).
  final List<PluginUIElement> elements;

  /// Optional plugin method invoked by the host to obtain a dynamic element
  /// list. The method receives the page id, persisted state and host context
  /// data, and must return `{"elements": [...]}`.
  final String? provider;

  /// Auto-refresh interval for [provider] pages. `0` disables polling.
  final int refreshSeconds;

  factory PluginPageExtension.fromJson(Object? raw) {
    if (raw is! Map) {
      return const PluginPageExtension(id: '', title: '');
    }
    final json = <String, dynamic>{
      for (final entry in raw.entries) entry.key.toString(): entry.value,
    };
    final elementsRaw = json['elements'] ?? json['items'] ?? json['controls'];
    final elements = <PluginUIElement>[];
    if (elementsRaw is List) {
      for (final rawElement in elementsRaw) {
        try {
          elements.add(PluginUIElement.fromJson(rawElement));
        } catch (_) {
          elements.add(const PluginUIElement(
            type: PluginUIElementType.unknown,
            id: '',
            label: '',
          ));
        }
      }
    }
    final refreshRaw = json['refreshSeconds'] ?? json['refresh_seconds'];
    return PluginPageExtension(
      id: json['id']?.toString().trim() ?? '',
      title: json['title']?.toString().trim() ?? '',
      icon: _optionalString(json['icon']),
      replaces: _optionalString(json['replaces'])?.toLowerCase(),
      placement: PluginManifest._placementFromRaw(
        json['placement'] ?? json['position'],
      ),
      elements: List.unmodifiable(elements),
      provider: _optionalString(json['provider']),
      refreshSeconds: refreshRaw == null ? 0 : _strictInt(refreshRaw) ?? -1,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (icon != null) 'icon': icon,
        if (replaces != null) 'replaces': replaces,
        if (placement != PluginSidebarPlacement.bottom) 'placement': 'top',
        if (elements.isNotEmpty)
          'elements': elements.map((element) => element.toJson()).toList(),
        if (provider != null) 'provider': provider,
        if (refreshSeconds != 0) 'refresh_seconds': refreshSeconds,
      };

  List<String> validate(String context) {
    final errors = <String>[];
    if (id.trim().isEmpty) {
      errors.add('$context requires an id');
    } else if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,62}$').hasMatch(id)) {
      errors.add(
          '$context.id must use lowercase letters, numbers, dot, dash or underscore');
    }
    if (title.trim().isEmpty) {
      errors.add('$context.$id requires a title');
    }
    if (replaces != null && !replaceableBuiltInPages.contains(replaces)) {
      errors.add(
        '$context.$id cannot replace "$replaces"; allowed: '
        '${replaceableBuiltInPages.join(', ')}',
      );
    }
    if (icon != null &&
        !icon!.startsWith('fluent:') &&
        !_isSafeRelativePath(icon!)) {
      errors.add(
          '$context.$id icon must be fluent:<name> or a relative path inside the plugin directory');
    }
    if (provider != null &&
        !RegExp(r'^[A-Za-z][A-Za-z0-9._-]*$').hasMatch(provider!)) {
      errors.add('$context.$id provider must be a valid method name');
    }
    if (refreshSeconds != 0 &&
        (refreshSeconds < minRefreshSeconds ||
            refreshSeconds > maxRefreshSeconds)) {
      errors.add(
        '$context.$id refresh_seconds must be 0 or between '
        '$minRefreshSeconds and $maxRefreshSeconds',
      );
    }
    if (refreshSeconds != 0 && provider == null) {
      errors.add('$context.$id refresh_seconds requires a provider');
    }
    if (elements.isEmpty && provider == null) {
      errors.add('$context.$id requires elements or a provider');
    }
    final ids = <String>{};
    for (final element in elements) {
      if (element.type == PluginUIElementType.unknown) {
        errors.add('$context.$id.${element.id} has an unknown type');
      }
      if (element.id.trim().isEmpty) {
        errors.add('$context.$id contains an element with an empty id');
      } else if (!ids.add(element.id)) {
        errors.add('$context.$id contains duplicate element id: ${element.id}');
      }
    }
    return errors;
  }
}

class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.entry,
    required this.capabilities,
    this.icon,
    this.description = '',
    this.category = 'other',
    this.minAppVersion,
    this.permissions = const PluginPermissionSet(),
    this.themeOverrides,
    this.uiExtensions,
    this.pageExtensions = const <PluginPageExtension>[],
    this.sidebarPlacement = PluginSidebarPlacement.bottom,
    this.manifestVersion = currentManifestVersion,
    this.apiVersion = currentApiVersion,
    this.maxAppVersion,
    this.runtime = const PluginRuntimeConfig(),
    this.intentSchemes = const <String>[],
    this.priority = 0,
    this.homepage,
    this.repository,
    this.license,
  });

  static const int currentManifestVersion = 1;
  static const String currentApiVersion = '1.0';

  final String id;
  final String name;
  final String version;
  final String author;
  final String entry;
  final List<String> capabilities;
  final String? icon;
  final String description;
  final String category;
  final String? minAppVersion;
  final PluginPermissionSet permissions;
  final Map<String, dynamic>? themeOverrides;
  final Map<String, List<PluginUIElement>>? uiExtensions;
  final List<PluginPageExtension> pageExtensions;
  final PluginSidebarPlacement sidebarPlacement;
  final int manifestVersion;
  final String apiVersion;
  final String? maxAppVersion;
  final PluginRuntimeConfig runtime;
  final List<String> intentSchemes;
  final int priority;
  final String? homepage;
  final String? repository;
  final String? license;

  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    final capabilitiesRaw = json['capabilities'];
    final capabilities = capabilitiesRaw is List
        ? capabilitiesRaw
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false)
        : const <String>[];

    final uiExtensionsRaw = json['ui_extensions'] ?? json['uiExtensions'];
    final manifestVersionRaw =
        json['manifestVersion'] ?? json['manifest_version'];
    final priorityRaw = json['priority'];

    return PluginManifest(
      id: json['id']?.toString().trim() ?? '',
      name: json['name']?.toString().trim() ?? '',
      version: json['version']?.toString().trim() ?? '',
      author: json['author']?.toString().trim() ?? '',
      entry: json['entry']?.toString().trim() ?? '',
      capabilities: capabilities,
      icon: json['icon']?.toString().trim(),
      description: json['description']?.toString().trim() ?? '',
      category: json['category']?.toString().trim() ?? 'other',
      minAppVersion: json['minAppVersion']?.toString().trim(),
      permissions: PluginPermissionSet.fromJson(json['permissions']),
      themeOverrides:
          _stringKeyedMap(json['theme_overrides'] ?? json['themeOverrides']),
      uiExtensions: _parseUiExtensions(uiExtensionsRaw),
      pageExtensions: _parsePageExtensions(uiExtensionsRaw),
      sidebarPlacement: _parseSidebarPlacement(uiExtensionsRaw, json),
      manifestVersion: manifestVersionRaw == null
          ? currentManifestVersion
          : _strictInt(manifestVersionRaw) ?? -1,
      apiVersion: json['apiVersion'] == null && json['api_version'] == null
          ? currentApiVersion
          : (json['apiVersion'] ?? json['api_version']).toString().trim(),
      maxAppVersion:
          _optionalString(json['maxAppVersion'] ?? json['max_app_version']),
      runtime: PluginRuntimeConfig.fromJson(json['runtime']),
      intentSchemes: _stringList(
        json['intentSchemes'] ?? json['intent_schemes'],
        lowerCase: true,
      ),
      priority: priorityRaw == null ? 0 : _strictInt(priorityRaw) ?? 1001,
      homepage: _optionalString(json['homepage']),
      repository: _optionalString(json['repository']),
      license: _optionalString(json['license']),
    );
  }

  static Map<String, List<PluginUIElement>>? _parseUiExtensions(dynamic json) {
    if (json is! Map) return null;
    final map = <String, List<PluginUIElement>>{};
    for (final entry in json.entries) {
      // `pages` uses a richer schema and is parsed separately into
      // [pageExtensions]; keep it out of the flat element map.
      if (entry.key.toString() == 'pages') {
        continue;
      }
      final elementsRaw = _uiElementsRaw(entry.value);
      if (elementsRaw == null) {
        map[entry.key.toString()] = const <PluginUIElement>[
          PluginUIElement(
            type: PluginUIElementType.unknown,
            id: '',
            label: '',
          ),
        ];
        continue;
      }
      final elements = <PluginUIElement>[];
      for (final rawElement in elementsRaw) {
        try {
          final element = PluginUIElement.fromJson(rawElement);
          elements.add(element);
        } catch (_) {
          elements.add(const PluginUIElement(
            type: PluginUIElementType.unknown,
            id: '',
            label: '',
          ));
        }
      }
      if (elements.isNotEmpty) {
        map[entry.key.toString()] = elements;
      }
    }
    return map.isEmpty ? null : map;
  }

  static List<dynamic>? _uiElementsRaw(dynamic value) {
    if (value is List) {
      return value;
    }
    if (value is Map) {
      final elements = value['elements'] ?? value['items'] ?? value['controls'];
      if (elements is List) {
        return elements;
      }
    }
    return null;
  }

  static List<PluginPageExtension> _parsePageExtensions(dynamic uiExtensions) {
    if (uiExtensions is! Map) {
      return const <PluginPageExtension>[];
    }
    final pagesRaw = uiExtensions['pages'];
    if (pagesRaw is! List) {
      return const <PluginPageExtension>[];
    }
    return List.unmodifiable(
      pagesRaw.map(PluginPageExtension.fromJson),
    );
  }

  static PluginSidebarPlacement _parseSidebarPlacement(
    dynamic uiExtensions,
    Map<String, dynamic> manifestJson,
  ) {
    Object? rawPlacement =
        manifestJson['sidebar_placement'] ?? manifestJson['sidebarPlacement'];
    if (rawPlacement == null && uiExtensions is Map) {
      final sidebar = uiExtensions['sidebar'];
      if (sidebar is Map) {
        rawPlacement = sidebar['placement'] ??
            sidebar['position'] ??
            sidebar['nav_position'] ??
            sidebar['navPosition'];
      }
    }
    return _placementFromRaw(rawPlacement);
  }

  static PluginSidebarPlacement _placementFromRaw(Object? rawPlacement) {
    final placement = rawPlacement?.toString().trim().toLowerCase();
    switch (placement) {
      case 'top':
      case 'upper':
      case 'main':
        return PluginSidebarPlacement.top;
      case 'bottom':
      case 'lower':
      case 'footer':
        return PluginSidebarPlacement.bottom;
      default:
        return PluginSidebarPlacement.bottom;
    }
  }

  static String _sidebarPlacementToString(PluginSidebarPlacement placement) {
    switch (placement) {
      case PluginSidebarPlacement.top:
        return 'top';
      case PluginSidebarPlacement.bottom:
        return 'bottom';
    }
  }

  static Map<String, dynamic>? _stringKeyedMap(dynamic value) {
    if (value is! Map) {
      return null;
    }
    return {
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }

  factory PluginManifest.fromJsonString(String content) {
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException('plugin.json must be a JSON object');
    }
    return PluginManifest.fromJson(_stringKeyedMap(decoded)!);
  }

  Map<String, dynamic> toJson() => {
        'manifestVersion': manifestVersion,
        'apiVersion': apiVersion,
        'id': id,
        'name': name,
        'version': version,
        'author': author,
        'entry': entry,
        'capabilities': capabilities,
        if (icon != null && icon!.isNotEmpty) 'icon': icon,
        if (description.isNotEmpty) 'description': description,
        if (category.isNotEmpty && category != 'other') 'category': category,
        if (minAppVersion != null && minAppVersion!.isNotEmpty)
          'minAppVersion': minAppVersion,
        if (maxAppVersion != null && maxAppVersion!.isNotEmpty)
          'maxAppVersion': maxAppVersion,
        if (!runtime.isDefault) 'runtime': runtime.toJson(),
        if (intentSchemes.isNotEmpty) 'intentSchemes': intentSchemes,
        if (priority != 0) 'priority': priority,
        if (homepage != null && homepage!.isNotEmpty) 'homepage': homepage,
        if (repository != null && repository!.isNotEmpty)
          'repository': repository,
        if (license != null && license!.isNotEmpty) 'license': license,
        'permissions': permissions.toList(),
        if (themeOverrides != null) 'theme_overrides': themeOverrides,
        if (uiExtensions != null || pageExtensions.isNotEmpty)
          'ui_extensions': <String, dynamic>{
            if (uiExtensions != null)
              for (final entry in uiExtensions!.entries)
                entry.key:
                    entry.value.map((element) => element.toJson()).toList(),
            if (pageExtensions.isNotEmpty)
              'pages': pageExtensions.map((page) => page.toJson()).toList(),
          },
        if (sidebarPlacement != PluginSidebarPlacement.bottom)
          'sidebar_placement': _sidebarPlacementToString(sidebarPlacement),
      };

  List<String> validate() {
    final errors = <String>[];
    if (manifestVersion != currentManifestVersion) {
      errors.add(
        'manifestVersion $manifestVersion is not supported; expected $currentManifestVersion',
      );
    }
    final apiMajor = int.tryParse(apiVersion.split('.').first);
    final currentApiMajor = int.parse(currentApiVersion.split('.').first);
    if (apiMajor == null || apiMajor != currentApiMajor) {
      errors.add(
        'apiVersion $apiVersion is not supported; expected major version $currentApiMajor',
      );
    }
    if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(apiVersion)) {
      errors.add('apiVersion must use numeric major.minor format');
    }
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{1,62}$').hasMatch(id)) {
      errors.add(
          'id must be 2-63 lowercase letters, numbers, dot, dash or underscore');
    }
    if (name.isEmpty) {
      errors.add('name is required');
    }
    if (version.isEmpty) {
      errors.add('version is required');
    }
    if (author.isEmpty) {
      errors.add('author is required');
    }
    if (entry.isEmpty) {
      errors.add('entry is required');
    } else if (!_isSafeRelativePath(entry)) {
      errors.add('entry must be a relative path inside the plugin directory');
    }
    if (capabilities.isEmpty) {
      errors.add('capabilities is required');
    }
    if (capabilities.toSet().length != capabilities.length) {
      errors.add('capabilities must not contain duplicates');
    }
    for (final capability in capabilities) {
      if (!RegExp(r'^[a-z][a-z0-9._-]*(?::[a-z0-9][a-z0-9._+-]*)*$')
          .hasMatch(capability)) {
        errors.add('invalid capability: $capability');
      }
    }
    if (permissions.unknown.isNotEmpty) {
      errors.add('unknown permissions: ${permissions.unknown.join(', ')}');
    }
    if (icon != null && icon!.isNotEmpty && !_isSafeRelativePath(icon!)) {
      errors.add('icon must be a relative path inside the plugin directory');
    }
    if (priority < -1000 || priority > 1000) {
      errors.add('priority must be between -1000 and 1000');
    }
    if (intentSchemes.toSet().length != intentSchemes.length) {
      errors.add('intentSchemes must not contain duplicates');
    }
    for (final scheme in intentSchemes) {
      if (!RegExp(r'^(hanabi|plugin)\+[a-z0-9][a-z0-9+.-]*$')
          .hasMatch(scheme)) {
        errors.add('invalid intent scheme: $scheme');
      }
    }
    errors.addAll(runtime.validate());
    for (final versionEntry in <MapEntry<String, String?>>[
      MapEntry('minAppVersion', minAppVersion),
      MapEntry('maxAppVersion', maxAppVersion),
    ]) {
      final value = versionEntry.value;
      if (value != null &&
          value.isNotEmpty &&
          !RegExp(r'^\d+(?:\.\d+){0,3}(?:[-+][0-9A-Za-z.-]+)?$')
              .hasMatch(value)) {
        errors.add('${versionEntry.key} must be a version number');
      }
    }
    for (final uriEntry in <MapEntry<String, String?>>[
      MapEntry('homepage', homepage),
      MapEntry('repository', repository),
    ]) {
      final value = uriEntry.value;
      final uri = value == null ? null : Uri.tryParse(value);
      if (value != null &&
          (uri == null ||
              !uri.hasScheme ||
              (uri.scheme != 'https' && uri.scheme != 'http'))) {
        errors.add('${uriEntry.key} must be an HTTP or HTTPS URL');
      }
    }
    errors.addAll(_validateUiExtensions());
    errors.addAll(_validatePageExtensions());
    return errors;
  }

  List<String> _validatePageExtensions() {
    final errors = <String>[];
    final pageIds = <String>{};
    final replacedPages = <String>{};
    for (final page in pageExtensions) {
      errors.addAll(page.validate('ui_extensions.pages'));
      if (page.id.trim().isNotEmpty && !pageIds.add(page.id)) {
        errors.add('ui_extensions.pages contains duplicate id: ${page.id}');
      }
      final replaces = page.replaces;
      if (replaces != null &&
          PluginPageExtension.replaceableBuiltInPages.contains(replaces) &&
          !replacedPages.add(replaces)) {
        errors.add(
          'ui_extensions.pages declares multiple replacements for "$replaces"',
        );
      }
    }
    return errors;
  }

  bool supportsCapability(String capability) {
    return capabilities.contains(capability);
  }

  bool handlesIntentScheme(String? scheme) {
    final normalized = scheme?.trim().toLowerCase();
    return normalized != null &&
        normalized.isNotEmpty &&
        intentSchemes.contains(normalized);
  }

  List<String> _validateUiExtensions() {
    final errors = <String>[];
    for (final extension in uiExtensions?.entries ??
        const <MapEntry<String, List<PluginUIElement>>>[]) {
      final ids = <String>{};
      for (final element in extension.value) {
        if (element.type == PluginUIElementType.unknown) {
          errors.add(
            'ui_extensions.${extension.key}.${element.id} has an unknown type',
          );
        }
        if (element.id.trim().isEmpty) {
          errors.add('ui_extensions.${extension.key} contains an empty id');
        } else if (!ids.add(element.id)) {
          errors.add(
            'ui_extensions.${extension.key} contains duplicate id: ${element.id}',
          );
        }
        if (element.label.trim().isEmpty) {
          errors.add(
            'ui_extensions.${extension.key}.${element.id} requires a label',
          );
        }
        if (element.type == PluginUIElementType.button &&
            (element.action == null || element.action!.trim().isEmpty)) {
          errors.add(
            'ui_extensions.${extension.key}.${element.id} requires an action',
          );
        }
        if (element.type == PluginUIElementType.slider &&
            element.min != null &&
            element.max != null &&
            element.min! >= element.max!) {
          errors.add(
            'ui_extensions.${extension.key}.${element.id} requires min < max',
          );
        }
        if (element.type == PluginUIElementType.dropdown &&
            (element.options == null || element.options!.isEmpty)) {
          errors.add(
            'ui_extensions.${extension.key}.${element.id} requires options',
          );
        }
      }
    }
    return errors;
  }
}

String? _optionalString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

List<String> _stringList(Object? value, {bool lowerCase = false}) {
  if (value is! List) {
    return const <String>[];
  }
  return value
      .map((item) => item.toString().trim())
      .where((item) => item.isNotEmpty)
      .map((item) => lowerCase ? item.toLowerCase() : item)
      .toList(growable: false);
}

bool _isSafeRelativePath(String value, {bool allowCurrentDirectory = false}) {
  final normalized = value.trim().replaceAll('\\', '/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    return false;
  }
  if (allowCurrentDirectory && normalized == '.') {
    return true;
  }
  final segments = normalized.split('/');
  return segments.every(
    (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
  );
}

bool _isJsonScalar(Object? value) =>
    value == null || value is String || value is num || value is bool;

int? _strictInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value == value.toInt() ? value.toInt() : null;
  }
  return int.tryParse(value?.toString() ?? '');
}

class InstalledPlugin {
  const InstalledPlugin({
    required this.manifest,
    required this.directory,
    required this.state,
    this.enabled = false,
    this.lastError,
  });

  final PluginManifest manifest;
  final String directory;
  final PluginInstallState state;
  final bool enabled;
  final String? lastError;

  String get id => manifest.id;
  String get name => manifest.name;
  String get version => manifest.version;

  InstalledPlugin copyWith({
    PluginManifest? manifest,
    String? directory,
    PluginInstallState? state,
    bool? enabled,
    String? lastError,
  }) {
    return InstalledPlugin(
      manifest: manifest ?? this.manifest,
      directory: directory ?? this.directory,
      state: state ?? this.state,
      enabled: enabled ?? this.enabled,
      lastError: lastError ?? this.lastError,
    );
  }
}
