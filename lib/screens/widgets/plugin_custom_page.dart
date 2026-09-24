import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import '../../models/download_task.dart';
import '../../models/plugin_manifest.dart';
import '../../models/plugin_ui_schema.dart';
import '../../services/integrated_download_service.dart';
import '../../services/plugin_diagnostic_logger.dart';
import '../../services/plugin_lifecycle_service.dart';
import '../../services/plugin_process_runner.dart';
import '../../theme/app_theme.dart';
import '../../utils/fluent_icons.dart' as custom_icons;
import '../../widgets/plugin_ui_renderer.dart';
import '../../widgets/settings_components.dart';
import '../../widgets/smooth_scroll_wrapper.dart';

/// Renders a plugin-contributed page declared in `ui_extensions.pages`.
///
/// The page shows the static element schema from the manifest and, when the
/// page declares a `provider` method, asks the plugin for a fresh element
/// list at runtime. Pages replacing the built-in completed page receive a
/// snapshot of completed tasks as context data.
class PluginCustomPage extends StatefulWidget {
  final InstalledPlugin plugin;
  final PluginPageExtension page;
  final bool isChinese;

  const PluginCustomPage({
    super.key,
    required this.plugin,
    required this.page,
    required this.isChinese,
  });

  @override
  State<PluginCustomPage> createState() => _PluginCustomPageState();
}

class _PluginCustomPageState extends State<PluginCustomPage> {
  static const int _maxContextTasks = 200;

  late Map<String, dynamic> _state;
  List<PluginUIElement>? _dynamicElements;
  bool _didLoadSaved = false;
  bool _providerBusy = false;
  String? _providerError;
  Timer? _refreshTimer;
  final PluginDiagnosticLogger _diag = PluginDiagnosticLogger();

  String get _settingsKey => '${widget.plugin.id}_page_${widget.page.id}';

  @override
  void initState() {
    super.initState();
    _state = {};
    for (final element in widget.page.elements) {
      if (element.defaultValue != null) {
        _state[element.id] = element.defaultValue;
      }
    }
    _diag.mark(
      'page.initState',
      pluginId: widget.plugin.id,
      data: <String, Object?>{
        'pageId': widget.page.id,
        'replaces': widget.page.replaces,
        'provider': widget.page.provider,
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didLoadSaved) {
      _didLoadSaved = true;
      final pluginService = context.read<PluginLifecycleService>();
      final savedSettings = pluginService.getPluginSettings(_settingsKey);
      if (savedSettings != null) {
        _state.addAll(savedSettings);
      }
      if (widget.page.provider != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(_refreshFromProvider());
          }
        });
        _armRefreshTimer();
      }
    }
  }

  void _armRefreshTimer() {
    _refreshTimer?.cancel();
    final seconds = widget.page.refreshSeconds;
    if (widget.page.provider == null ||
        seconds < PluginPageExtension.minRefreshSeconds) {
      return;
    }
    _refreshTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (mounted && !_providerBusy) {
        unawaited(_refreshFromProvider());
      }
    });
  }

  Map<String, dynamic> _buildContextData() {
    if (widget.page.replaces != 'completed') {
      return const <String, dynamic>{};
    }
    final downloadService = context.read<IntegratedDownloadService>();
    final completed = downloadService.tasks
        .where((task) => task.status == DownloadStatus.completed)
        .toList()
      ..sort((left, right) {
        final leftTime = left.endTime ?? left.createdAt;
        final rightTime = right.endTime ?? right.createdAt;
        return rightTime.compareTo(leftTime);
      });
    return <String, dynamic>{
      'completedCount': completed.length,
      'completedTasks': [
        for (final task in completed.take(_maxContextTasks))
          <String, dynamic>{
            'id': task.id,
            'url': task.url,
            'fileName': task.fileName,
            if (task.fileSize != null) 'fileSize': task.fileSize,
            if (task.filePath != null) 'filePath': task.filePath,
            if (task.endTime != null)
              'endTime': task.endTime!.toIso8601String(),
            if (task.averageSpeed != null) 'averageSpeed': task.averageSpeed,
          },
      ],
    };
  }

  Future<void> _refreshFromProvider() async {
    final provider = widget.page.provider;
    if (provider == null || _providerBusy) {
      return;
    }
    setState(() {
      _providerBusy = true;
      _providerError = null;
    });
    final runner = context.read<PluginProcessRunner>();
    try {
      final result = await runner.invoke(
        widget.plugin,
        method: provider,
        params: <String, dynamic>{
          'page': widget.page.id,
          if (widget.page.replaces != null) 'replaces': widget.page.replaces,
          'state': _state,
          'context': _buildContextData(),
        },
      );
      if (!mounted) return;
      if (!result.success) {
        setState(() {
          _providerBusy = false;
          _providerError = result.error ??
              (widget.isChinese ? '插件返回了错误' : 'The plugin returned an error');
        });
        return;
      }
      final elements = _parseElements(result.result);
      setState(() {
        _providerBusy = false;
        if (elements != null) {
          _dynamicElements = elements;
        } else {
          _providerError = widget.isChinese
              ? '插件返回的页面数据无效（需要 {"elements": [...]}）'
              : 'Invalid page payload from plugin (expected {"elements": [...]})';
        }
      });
    } catch (e) {
      _diag.error(
        'page.provider.error',
        e,
        pluginId: widget.plugin.id,
        data: <String, Object?>{'pageId': widget.page.id},
      );
      if (!mounted) return;
      setState(() {
        _providerBusy = false;
        _providerError = e.toString();
      });
    }
  }

  List<PluginUIElement>? _parseElements(Object? result) {
    if (result is! Map) {
      return null;
    }
    final elementsRaw = result['elements'];
    if (elementsRaw is! List) {
      return null;
    }
    final elements = <PluginUIElement>[];
    for (final rawElement in elementsRaw) {
      try {
        final element = PluginUIElement.fromJson(rawElement);
        if (element.type != PluginUIElementType.unknown &&
            element.id.trim().isNotEmpty) {
          elements.add(element);
        }
      } catch (_) {
        // Skip malformed elements instead of failing the whole page.
      }
    }
    return elements;
  }

  void _handleStateChanged(Map<String, dynamic> newState) {
    setState(() {
      _state = newState;
    });
    final pluginService = context.read<PluginLifecycleService>();
    unawaited(
      pluginService.savePluginSettings(_settingsKey, newState).catchError((e) {
        _diag.error('page.saveState.error', e, pluginId: widget.plugin.id);
        debugPrint('Failed to save plugin page state: $e');
      }),
    );

    final runner = context.read<PluginProcessRunner>();
    runner.invoke(
      widget.plugin,
      method: 'onPageStateChanged',
      params: <String, dynamic>{
        'page': widget.page.id,
        'state': newState,
      },
    ).catchError((e) {
      debugPrint('Failed to notify plugin of page state change: $e');
      return const PluginInvocationResult(success: false);
    });
  }

  void _handleAction(String action) {
    final runner = context.read<PluginProcessRunner>();
    _diag.mark(
      'page.action.start',
      pluginId: widget.plugin.id,
      data: <String, Object?>{'pageId': widget.page.id, 'action': action},
    );
    runner.invoke(
      widget.plugin,
      method: action,
      params: <String, dynamic>{
        'page': widget.page.id,
        'state': _state,
        'context': _buildContextData(),
      },
    ).then((result) {
      _diag.mark(
        'page.action.done',
        pluginId: widget.plugin.id,
        data: <String, Object?>{
          'pageId': widget.page.id,
          'action': action,
          'success': result.success,
          'error': result.error,
        },
      );
      // Actions frequently mutate what the page shows; re-render if dynamic.
      if (mounted && widget.page.provider != null) {
        unawaited(_refreshFromProvider());
      }
    }).catchError((e) {
      _diag.error(
        'page.action.error',
        e,
        pluginId: widget.plugin.id,
        data: <String, Object?>{'pageId': widget.page.id, 'action': action},
      );
      debugPrint('Failed to invoke plugin page action $action: $e');
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iconParts = _resolveIcon();
    final elements = _dynamicElements ?? widget.page.elements;
    final title =
        widget.page.title.isNotEmpty ? widget.page.title : widget.plugin.name;

    return ScaffoldPage(
      header: SettingsPageHeader(
        title: title,
        icon: iconParts.icon,
        iconBuilder: iconParts.builder,
      ),
      content: SmoothSingleChildScrollView(
        config: SmoothScrollConfig.fast,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeaderCard(),
                if (_providerError != null) ...[
                  const SizedBox(height: 12),
                  _buildProviderError(),
                ],
                const SizedBox(height: 16),
                if (elements.isEmpty && _providerBusy)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: ProgressRing(),
                    ),
                  )
                else if (elements.isEmpty)
                  _emptyState(
                    widget.isChinese
                        ? '这个页面还没有内容。'
                        : 'This page has no content yet.',
                  )
                else
                  Column(
                    children: elements.map((element) {
                      return PluginUIRenderer.renderElement(
                        element: element,
                        state: _state,
                        onStateChanged: _handleStateChanged,
                        onAction: _handleAction,
                      );
                    }).toList(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderCard() {
    final providerLabel = widget.isChinese
        ? '此页面由「${widget.plugin.name}」插件提供'
        : 'This page is provided by the "${widget.plugin.name}" plugin';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground(darkAlpha: 0.74, lightAlpha: 0.88),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: AppTheme.borderSubtle.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          Icon(
            custom_icons.FluentIcons.app_icon_default,
            size: 14,
            color: AppTheme.textTertiary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              providerLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: FluentTheme.of(context).typography.caption?.copyWith(
                    color: AppTheme.textTertiary,
                    fontSize: 12,
                  ),
            ),
          ),
          if (widget.page.provider != null) ...[
            const SizedBox(width: 8),
            if (_providerBusy)
              const SizedBox(
                width: 14,
                height: 14,
                child: ProgressRing(strokeWidth: 2),
              )
            else
              Tooltip(
                message: widget.isChinese ? '刷新' : 'Refresh',
                child: IconButton(
                  icon: Icon(
                    custom_icons.FluentIcons.refresh,
                    size: 14,
                    color: AppTheme.textSecondary,
                  ),
                  onPressed: () => unawaited(_refreshFromProvider()),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildProviderError() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.statusError.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: AppTheme.statusError.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            custom_icons.FluentIcons.error_badge,
            size: 14,
            color: AppTheme.statusError,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.isChinese
                  ? '插件页面加载失败：$_providerError'
                  : 'Failed to load plugin page: $_providerError',
              style: FluentTheme.of(context).typography.caption?.copyWith(
                    color: AppTheme.statusError,
                    fontSize: 12,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.bgLayer2.withValues(alpha: 0.44),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.borderSubtle.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
        style: FluentTheme.of(context).typography.caption?.copyWith(
              color: AppTheme.textTertiary,
              fontSize: 12,
            ),
      ),
    );
  }

  _PageIconParts _resolveIcon() {
    IconData? iconData;
    Widget Function(BuildContext, Color)? iconBuilder;

    final iconRaw = widget.page.icon ?? widget.plugin.manifest.icon;
    if (iconRaw != null && iconRaw.isNotEmpty) {
      if (iconRaw.startsWith('fluent:')) {
        iconData = custom_icons.FluentIcons.getIcon(iconRaw.substring(7));
      } else {
        iconBuilder = (context, color) {
          final iconFile = File(path.join(widget.plugin.directory, iconRaw));
          if (!iconFile.existsSync()) {
            return Icon(
              custom_icons.FluentIcons.app_icon_default,
              size: 16,
              color: color,
            );
          }
          return Image.file(
            iconFile,
            width: 16,
            height: 16,
            color: color,
            errorBuilder: (context, error, stackTrace) => Icon(
              custom_icons.FluentIcons.app_icon_default,
              size: 16,
              color: color,
            ),
          );
        };
      }
    } else {
      iconData = custom_icons.FluentIcons.app_icon_default;
    }

    return _PageIconParts(
      icon: iconData ?? custom_icons.FluentIcons.app_icon_default,
      builder: iconBuilder,
    );
  }
}

class _PageIconParts {
  const _PageIconParts({
    required this.icon,
    this.builder,
  });

  final IconData icon;
  final Widget Function(BuildContext, Color)? builder;
}
