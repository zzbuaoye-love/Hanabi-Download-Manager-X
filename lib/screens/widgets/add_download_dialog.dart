import 'package:fluent_ui/fluent_ui.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../models/download_intent.dart';
import '../../models/download_task.dart';
import '../../services/integrated_download_service.dart';
import '../../services/plugin_lifecycle_service.dart';
import '../../theme/app_theme.dart';
import '../../utils/fluent_icons.dart' as custom_icons;
import '../../widgets/animated_notifications.dart';
import '../../widgets/fluent_interactions.dart';
import '../../widgets/smooth_scroll_wrapper.dart';

enum _DuplicateAction {
  useExisting,
  addNew,
  cancel,
}

class AddDownloadDialog extends StatefulWidget {
  final String? initialUrl;
  final String? initialFileName;
  final VoidCallback? onMuteClipboardForSession;

  const AddDownloadDialog({
    super.key,
    this.initialUrl,
    this.initialFileName,
    this.onMuteClipboardForSession,
  });

  @override
  State<AddDownloadDialog> createState() => _AddDownloadDialogState();
}

class _AddDownloadDialogState extends State<AddDownloadDialog> {
  final _urlController = TextEditingController();
  final _fileNameController = TextEditingController();
  final _urlFocusNode = FocusNode();
  final _fileNameFocusNode = FocusNode();

  bool _isLoading = false;
  bool _showAdvanced = false;
  bool _hasUserEditedFileName = false;
  bool _isUpdatingFileNameProgrammatically = false;
  String? _parsedFileName;
  String? _urlError;
  String? _lastSuggestedFileName;

  AppLocalizations get t => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    if (widget.initialUrl != null && widget.initialUrl!.trim().isNotEmpty) {
      _urlController.text = widget.initialUrl!.trim();
    }
    if (widget.initialFileName != null &&
        widget.initialFileName!.trim().isNotEmpty) {
      _fileNameController.text = widget.initialFileName!.trim();
      _hasUserEditedFileName = true;
    }

    _urlController.addListener(_onUrlChanged);
    _fileNameController.addListener(_onFileNameChanged);
    if (_urlController.text.trim().isNotEmpty) {
      _onUrlChanged();
    }
  }

  void _onUrlChanged() {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      final shouldClearSuggestedName = !_hasUserEditedFileName &&
          (_fileNameController.text.trim().isEmpty ||
              _fileNameController.text.trim() == _lastSuggestedFileName);
      setState(() {
        _parsedFileName = null;
        _urlError = null;
      });
      if (shouldClearSuggestedName) {
        _setFileNameFromSuggestion('');
      }
      _lastSuggestedFileName = null;
      return;
    }

    final nextSuggestedName = DownloadIntent.parse(url).suggestedFileName();
    final previousSuggestion = _lastSuggestedFileName;
    final currentFileName = _fileNameController.text.trim();
    final shouldApplySuggestion = currentFileName.isEmpty ||
        !_hasUserEditedFileName ||
        (previousSuggestion != null && currentFileName == previousSuggestion);

    setState(() {
      _parsedFileName = nextSuggestedName;
      _urlError = null;
    });
    _lastSuggestedFileName = nextSuggestedName;

    if (shouldApplySuggestion) {
      _setFileNameFromSuggestion(nextSuggestedName ?? '');
    }
  }

  void _onFileNameChanged() {
    if (_isUpdatingFileNameProgrammatically) return;

    final text = _fileNameController.text.trim();
    final suggestion = _lastSuggestedFileName?.trim();
    _hasUserEditedFileName = text.isNotEmpty && text != (suggestion ?? '');
  }

  void _setFileNameFromSuggestion(String value) {
    _isUpdatingFileNameProgrammatically = true;
    _fileNameController.text = value;
    _fileNameController.selection =
        TextSelection.collapsed(offset: _fileNameController.text.length);
    _isUpdatingFileNameProgrammatically = false;
    _hasUserEditedFileName = false;
  }

  @override
  void dispose() {
    _urlController.removeListener(_onUrlChanged);
    _fileNameController.removeListener(_onFileNameChanged);
    _urlController.dispose();
    _fileNameController.dispose();
    _urlFocusNode.dispose();
    _fileNameFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final availableWidth =
        (size.width - 48).clamp(0.0, double.infinity).toDouble();
    final dialogWidth = availableWidth.clamp(0.0, 480.0).toDouble();
    final dialogMaxHeight = (size.height - 48).clamp(0.0, 720.0).toDouble();
    final theme = FluentTheme.of(context);
    final accent = AppTheme.isDarkContext(context)
        ? AppTheme.accentLight
        : AppTheme.accentPrimary;

    return ContentDialog(
      constraints: BoxConstraints(
        minWidth: dialogWidth,
        maxWidth: dialogWidth,
        maxHeight: dialogMaxHeight,
      ),
      style: ContentDialogThemeData(
        titleStyle: theme.typography.subtitle?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        actionsDecoration: BoxDecoration(
          color: theme.resources.layerFillColorAlt,
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(AppTheme.radiusLg),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      ),
      // WinUI 图标磁贴 + 标题，和各页面页头保持同一套视觉
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.accentPrimary.withValues(
                alpha: AppTheme.isDarkContext(context) ? 0.16 : 0.10,
              ),
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: Icon(
              custom_icons.FluentIcons.download,
              size: 16,
              color: accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(t.addDownloadTitle)),
        ],
      ),
      content: _buildContent(context),
      actions: _buildActions(),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = FluentTheme.of(context);

    return SmoothSingleChildScrollView(
      config: SmoothScrollConfig.fast,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.addDownloadSubtitle,
            style: theme.typography.caption?.copyWith(
              fontSize: 13,
              height: 1.45,
              color: theme.resources.textFillColorSecondary,
            ),
          ),
          const SizedBox(height: 14),
          _buildProtocolSupport(context),
          const SizedBox(height: 18),
          _buildUrlInput(context),
          AnimatedSwitcher(
            duration: AppTheme.motionFast,
            switchInCurve: AppTheme.motionStandard,
            switchOutCurve: AppTheme.motionAccelerate,
            child: _buildUrlFeedback(context),
          ),
          const SizedBox(height: 16),
          _buildAdvancedOptions(context),
        ],
      ),
    );
  }

  InlineSpan _requiredLabel(BuildContext context, String label) {
    final theme = FluentTheme.of(context);
    return TextSpan(
      children: [
        TextSpan(text: label),
        TextSpan(
          text: ' *',
          style: TextStyle(
            color: theme.resources.systemFillColorCritical,
          ),
        ),
      ],
    );
  }

  Widget _buildUrlInput(BuildContext context) {
    final theme = FluentTheme.of(context);
    final errorColor = theme.resources.systemFillColorCritical;

    return InfoLabel.rich(
      label: _requiredLabel(context, t.addDownloadUrlLabel),
      child: TextBox(
        controller: _urlController,
        focusNode: _urlFocusNode,
        autofocus: widget.initialUrl == null,
        enabled: !_isLoading,
        placeholder: t.addDownloadUrlPlaceholder,
        highlightColor: _urlError == null ? null : errorColor,
        unfocusedColor: _urlError == null ? null : errorColor,
        prefix: Padding(
          padding: const EdgeInsets.only(left: 10, right: 2),
          child: Icon(
            custom_icons.FluentIcons.link,
            size: 14,
            color: AppTheme.textTertiary,
          ),
        ),
        suffix: _urlController.text.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(right: 4),
                // 清除按钮的高亮铺满自身 24×24 命中区域
                child: FluentIconButton(
                  icon: FluentIcons.clear,
                  size: 24,
                  iconSize: 11,
                  tooltip: t.logClearFiltersButton,
                  onPressed: _isLoading
                      ? null
                      : () {
                          _urlController.clear();
                          _urlFocusNode.requestFocus();
                        },
                ),
              ),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) {
          if (!_isLoading) _handleSubmit();
        },
      ),
    );
  }

  /// Human readable label for a canonical protocol key coming from
  /// [PluginLifecycleService.supportedProtocols].
  String _protocolLabel(String key) {
    switch (key) {
      case 'http':
        return t.addDownloadProtocolHttp;
      case 'magnet':
        return t.addDownloadProtocolMagnet;
      case 'torrent_file':
        return t.addDownloadProtocolTorrentFile;
      case 'ed2k':
        return t.addDownloadProtocolEd2k;
      case 'resolver':
        return t.addDownloadProtocolResolver;
      default:
        return key;
    }
  }

  String _intentTypeLabel(DownloadIntent intent) {
    switch (intent.type) {
      case DownloadIntentType.http:
        return t.addDownloadProtocolHttp;
      case DownloadIntentType.magnet:
        return t.addDownloadProtocolMagnet;
      case DownloadIntentType.torrentFile:
        return t.addDownloadProtocolTorrentFile;
      case DownloadIntentType.ed2k:
        return t.addDownloadProtocolEd2k;
      case DownloadIntentType.resolver:
        return t.addDownloadProtocolResolver;
      case DownloadIntentType.custom:
        return intent.uri?.scheme ?? t.downloadIntentTypeUnknown;
      case DownloadIntentType.unsupported:
        return t.downloadIntentTypeUnknown;
    }
  }

  /// 支持的协议：收进一块 subtle 信息条里，标签和徽标同处一个层级，
  /// 不再是一排各自带描边、互相打架的小方块。
  Widget _buildProtocolSupport(BuildContext context) {
    final protocols =
        context.watch<PluginLifecycleService>().supportedProtocols();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppTheme.subtleFillHover,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Text(
              t.addDownloadSupportedProtocolsLabel,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.textTertiary,
              ),
            ),
          ),
          for (final protocol in protocols)
            _buildProtocolChip(context, protocol),
        ],
      ),
    );
  }

  Widget _buildProtocolChip(BuildContext context, SupportedProtocol protocol) {
    final accent = AppTheme.isDarkContext(context)
        ? AppTheme.accentLight
        : AppTheme.accentPrimary;
    final tooltip = protocol.builtIn
        ? t.addDownloadProtocolBuiltIn
        : t.addDownloadProtocolProvidedBy(protocol.pluginNames.join(', '));

    // 插件提供的协议用 accent 着色区分，内置协议保持中性
    return Tooltip(
      message: tooltip,
      child: FluentChip(
        label: _protocolLabel(protocol.key),
        icon: protocol.builtIn ? null : custom_icons.FluentIcons.apps_20,
        color: protocol.builtIn ? null : accent,
      ),
    );
  }

  Widget _buildUrlFeedback(BuildContext context) {
    final theme = FluentTheme.of(context);

    if (_urlError != null) {
      return Padding(
        key: const ValueKey('url-error'),
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                FluentIcons.error_badge,
                size: 12,
                color: theme.resources.systemFillColorCritical,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _urlError!,
                style: theme.typography.caption?.copyWith(
                  color: theme.resources.systemFillColorCritical,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final rows = <Widget>[];
    final routingRow = _buildPluginRoutingRow(context);
    if (routingRow != null) {
      rows.add(routingRow);
    }

    if (_parsedFileName != null && !_showAdvanced) {
      rows.add(
        Row(
          children: [
            Icon(
              FluentIcons.document_approval,
              size: 12,
              color: theme.resources.systemFillColorSuccess,
            ),
            const SizedBox(width: 6),
            Text(
              '${t.addDownloadParsedFileNameTitle}:',
              style: theme.typography.caption?.copyWith(
                color: theme.resources.textFillColorSecondary,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                _parsedFileName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.caption?.copyWith(
                  color: theme.resources.textFillColorPrimary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (rows.isEmpty) {
      return const SizedBox.shrink(key: ValueKey('url-feedback-empty'));
    }

    return Padding(
      key: ValueKey('url-feedback-${rows.length}-${routingRow != null}'),
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            rows[i],
          ],
        ],
      ),
    );
  }

  /// Feedback line telling the user which plugin (if any) will handle a
  /// recognized non-HTTP link.
  Widget? _buildPluginRoutingRow(BuildContext context) {
    final theme = FluentTheme.of(context);
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      return null;
    }

    final intent = DownloadIntent.parse(url);
    if (!intent.isRecognized || intent.isHttp) {
      return null;
    }

    final pluginService = context.watch<PluginLifecycleService>();
    final handler = pluginService.resolvePluginForIntent(intent);
    final typeLabel = _intentTypeLabel(intent);

    if (handler != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              custom_icons.FluentIcons.apps_20,
              size: 12,
              color: theme.accentColor,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              t.addDownloadIntentPluginReady(typeLabel, handler.name),
              style: theme.typography.caption?.copyWith(
                color: theme.resources.textFillColorSecondary,
              ),
            ),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            custom_icons.FluentIcons.warning,
            size: 12,
            color: theme.resources.systemFillColorCaution,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            t.addDownloadIntentNoPlugin(typeLabel),
            style: theme.typography.caption?.copyWith(
              color: theme.resources.systemFillColorCaution,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAdvancedOptions(BuildContext context) {
    final theme = FluentTheme.of(context);

    return Expander(
      leading: Icon(
        FluentIcons.rename,
        size: 16,
        color: theme.resources.textFillColorSecondary,
      ),
      header: Text(t.addDownloadAdvancedToggle),
      trailing: Text(
        _showAdvanced
            ? t.addDownloadAdvancedExpandedHint
            : t.addDownloadAdvancedCollapsedHint,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.typography.caption?.copyWith(
          color: theme.resources.textFillColorTertiary,
        ),
      ),
      enabled: !_isLoading,
      initiallyExpanded: false,
      onStateChanged: (expanded) {
        setState(() => _showAdvanced = expanded);
        if (expanded && widget.initialFileName != null) {
          _fileNameFocusNode.requestFocus();
        }
      },
      // 与全局卡片一致的圆角 4 / 中性描边，避免这里单独一套圆角
      headerShape: (expanded) => RoundedRectangleBorder(
        side: BorderSide(color: AppTheme.borderDefault),
        borderRadius: expanded
            ? const BorderRadius.vertical(
                top: Radius.circular(AppTheme.radiusSm))
            : BorderRadius.circular(AppTheme.radiusSm),
      ),
      contentShape: (expanded) => RoundedRectangleBorder(
        side: BorderSide(color: AppTheme.borderDefault),
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(AppTheme.radiusSm),
        ),
      ),
      contentBackgroundColor: AppTheme.subtleFillHover,
      contentPadding: const EdgeInsets.all(16),
      content: InfoLabel(
        label: '${t.addDownloadFileNameLabel} (${t.addDownloadOptionalBadge})',
        child: TextBox(
          controller: _fileNameController,
          focusNode: _fileNameFocusNode,
          enabled: !_isLoading,
          placeholder: t.addDownloadFileNamePlaceholder,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            if (!_isLoading) _handleSubmit();
          },
        ),
      ),
    );
  }

  List<Widget> _buildActions() {
    return [
      if (widget.onMuteClipboardForSession != null)
        Button(
          onPressed: _isLoading ? null : _handleMuteClipboardForSession,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(FluentIcons.volume_disabled, size: 13),
                const SizedBox(width: 7),
                Text(t.clipboardListenerMuteSessionButton),
              ],
            ),
          ),
        ),
      Button(
        onPressed: _isLoading ? null : () => Navigator.pop(context, false),
        child: Text(t.addDownloadCancelButton),
      ),
      FilledButton(
        onPressed: _isLoading ? null : _handleSubmit,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isLoading) ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: ProgressRing(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
              ],
              Text(_isLoading ? t.addDownloadAdding : t.addDownloadStart),
            ],
          ),
        ),
      ),
    ];
  }

  void _handleMuteClipboardForSession() {
    widget.onMuteClipboardForSession?.call();
    NotificationManager.of(context)?.showInfo(
      t.clipboardListenerSessionMutedTitle,
      message: t.clipboardListenerSessionMutedMessage,
    );
    Navigator.pop(context, false);
  }

  String _getStatusLabel(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.downloading:
        return t.downloadStatusDownloading;
      case DownloadStatus.paused:
        return t.downloadStatusPaused;
      case DownloadStatus.completed:
        return t.downloadStatusCompleted;
      case DownloadStatus.failed:
        return t.downloadStatusFailed;
      case DownloadStatus.merging:
        return t.downloadStatusMerging;
      case DownloadStatus.pending:
        return t.downloadStatusPending;
    }
  }

  Future<_DuplicateAction> _showDuplicateDialog(DownloadTask task) async {
    final statusLabel = _getStatusLabel(task.status);
    final result = await showDialog<_DuplicateAction>(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(t.downloadDuplicateTitle),
        content: Text(t.downloadDuplicateMessage(task.fileName, statusLabel)),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context, _DuplicateAction.cancel),
            child: Text(t.downloadDuplicateCancelButton),
          ),
          Button(
            onPressed: () => Navigator.pop(context, _DuplicateAction.addNew),
            child: Text(t.downloadDuplicateAddNewButton),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _DuplicateAction.useExisting),
            child: Text(t.downloadDuplicateUseExistingButton),
          ),
        ],
      ),
    );
    return result ?? _DuplicateAction.cancel;
  }

  void _showUrlError(String message) {
    setState(() => _urlError = message);
    _urlFocusNode.requestFocus();
  }

  Future<void> _handleSubmit() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _showUrlError(t.addDownloadErrorMissingUrl);
      return;
    }

    final intent = DownloadIntent.parse(url);
    if (!url.startsWith('test_task_') && !intent.isRecognized) {
      _showUrlError(t.addDownloadErrorInvalidUrl);
      return;
    }

    // Non-HTTP links are dispatched to plugins; fail fast with a clear hint
    // when no enabled plugin can handle the protocol instead of surfacing a
    // dispatcher error after submission.
    if (intent.isRecognized && !intent.isHttp) {
      final pluginService = context.read<PluginLifecycleService>();
      final handler = pluginService.resolvePluginForIntent(intent);
      if (handler == null) {
        _showUrlError(t.addDownloadIntentNoPlugin(_intentTypeLabel(intent)));
        return;
      }
    }

    setState(() => _urlError = null);

    String fileName = _fileNameController.text.trim();
    if (fileName.isEmpty) {
      fileName = _parsedFileName ??
          intent.suggestedFileName() ??
          'download_${DateTime.now().millisecondsSinceEpoch}';
    }

    final downloadService = context.read<IntegratedDownloadService>();
    final duplicate = downloadService.findDuplicateTask(url);
    if (duplicate != null) {
      final action = await _showDuplicateDialog(duplicate);
      if (!mounted) return;
      if (action == _DuplicateAction.cancel) return;
      if (action == _DuplicateAction.useExisting) {
        if (duplicate.status == DownloadStatus.paused ||
            duplicate.status == DownloadStatus.failed ||
            duplicate.status == DownloadStatus.pending) {
          await downloadService.resumeTask(duplicate.id);
        }
        if (mounted) Navigator.pop(context, true);
        return;
      }
    }

    setState(() => _isLoading = true);

    try {
      final taskId = await downloadService.addTask(url, fileName);
      if (taskId == null) {
        throw StateError(
          downloadService.lastAddTaskError ?? 'Failed to add task',
        );
      }

      if (mounted) {
        Navigator.pop(context, true);
        _showSuccessMessage(fileName);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        await _showErrorDialog(t.addDownloadErrorAddFailed(e.toString()));
      }
    }
  }

  Future<void> _showErrorDialog(String message) async {
    final theme = FluentTheme.of(context);
    await showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(t.addDownloadErrorTitle),
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                FluentIcons.error_badge,
                size: 16,
                color: theme.resources.systemFillColorCritical,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.addDownloadErrorConfirm),
          ),
        ],
      ),
    );
  }

  void _showSuccessMessage(String fileName) {
    if (!mounted) return;
    NotificationManager.of(context)?.showSuccess(
      t.addDownloadSuccessTitle,
      message: t.addDownloadSuccessMessage(fileName),
    );
  }
}
