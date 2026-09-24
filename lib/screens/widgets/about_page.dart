import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../utils/constants.dart';
import '../../widgets/animated_notifications.dart';
import '../../widgets/app_logo.dart';
import '../../widgets/scroll_edge_fade.dart';
import '../../widgets/settings_components.dart';
import '../../widgets/smooth_scroll_wrapper.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const double _maxContentWidth = 840;

  Future<void> _launchUrl(BuildContext context, String url) async {
    try {
      await Process.start('cmd', ['/c', 'start', '', url], runInShell: true);
    } catch (e) {
      if (context.mounted) {
        final t = AppLocalizations.of(context)!;
        NotificationManager.of(context)?.showError(
          t.aboutOpenLinkErrorTitle,
          message: t.aboutOpenLinkErrorMessage(e),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;

    return ScaffoldPage(
      header: SettingsPageHeader(
        title: t.aboutPageTitle,
        icon: FluentIcons.info,
      ),
      content: ScrollEdgeFade(
        child: SmoothSingleChildScrollView(
          config: SmoothScrollConfig.fast,
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 40),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _AppSummary(
                    appName: t.appTitle,
                    version: t.aboutVersionLabel(AppConstants.version),
                    developer: t.aboutMadeBy(AppConstants.developer),
                  ),
                  const SizedBox(height: 24),
                  SettingsSection(
                    title: t.aboutSectionAppInfo,
                    icon: FluentIcons.info,
                    margin: EdgeInsets.zero,
                    children: [
                      SettingsItem(
                        title: t.aboutDetailDeveloperLabel,
                        subtitle: AppConstants.developer,
                        trailing: const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 12),
                      SettingsItem(
                        title: t.aboutDetailKernelLabel,
                        subtitle:
                            '${AppConstants.nsfxKernelFormattedString} / ${AppConstants.neoKernelFormattedString}',
                        trailing: const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 12),
                      SettingsItem(
                        title: t.aboutDetailUiFrameworkLabel,
                        subtitle: t.aboutDetailUiFrameworkValue,
                        trailing: const SizedBox.shrink(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SettingsSection(
                    title: t.aboutSectionLinks,
                    icon: FluentIcons.link,
                    margin: EdgeInsets.zero,
                    children: [
                      SettingsLinkItem(
                        title: t.aboutLinkOfficialTitle,
                        subtitle: t.aboutLinkOfficialSubtitle,
                        onPressed: () =>
                            _launchUrl(context, AppConstants.officialUrl),
                      ),
                      SettingsLinkItem(
                        title: t.aboutLinkGithubTitle,
                        subtitle: t.aboutLinkGithubSubtitle,
                        onPressed: () =>
                            _launchUrl(context, AppConstants.githubUrl),
                      ),
                      SettingsLinkItem(
                        title: t.aboutLinkContactTitle,
                        subtitle: AppConstants.contactEmail,
                        onPressed: () => _launchUrl(
                          context,
                          'mailto:${AppConstants.contactEmail}',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Text(
                    t.aboutCopyrightMessage(
                      DateTime.now().year,
                      AppConstants.developer,
                    ),
                    style: FluentTheme.of(context)
                        .typography
                        .caption
                        ?.copyWith(color: AppTheme.textTertiary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppSummary extends StatelessWidget {
  const _AppSummary({
    required this.appName,
    required this.version,
    required this.developer,
  });

  final String appName;
  final String version;
  final String developer;

  @override
  Widget build(BuildContext context) {
    final typography = FluentTheme.of(context).typography;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.borderDefault),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(
            width: 64,
            height: 64,
            child: AppLogo(),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: typography.title?.copyWith(
                    fontSize: 20,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  version,
                  style: typography.body?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  developer,
                  style: typography.caption?.copyWith(
                    color: AppTheme.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
