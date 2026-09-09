import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:apexbooks/common/breakpoints.dart';
import 'package:apexbooks/common/common.dart';
import 'package:apexbooks/l10n/app_localizations.dart';
import 'package:apexbooks/providers/app_config_provider.dart';
import 'package:apexbooks/providers/repositories.dart';
import 'package:apexbooks/screens/settings/accessibility_screen.dart';
import 'package:apexbooks/screens/settings/backup_management_screen.dart';
import 'package:apexbooks/screens/settings/cloud_sync_screen.dart';
// import 'package:apexbooks/screens/settings/invoice_settings_screen.dart';
import 'package:apexbooks/screens/settings/invoice_settings_screen_v2.dart';
// import 'package:apexbooks/screens/settings/pdf_settings_screen.dart';
import 'package:apexbooks/screens/settings/pdf_settings_screen_v2.dart';
import 'package:apexbooks/screens/settings/product_columns_settings_screen.dart';
import 'package:apexbooks/screens/settings/app_info_screen.dart';
import 'package:apexbooks/screens/settings/company_info_screen.dart';
import 'package:apexbooks/screens/settings/customization_screen.dart';
// import 'package:apexbooks/screens/settings/user_management_screen.dart';
import 'package:apexbooks/screens/settings/user_management_screen_v2.dart';
import 'package:apexbooks/models/user.dart';
import 'package:apexbooks/services/update_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  final User currentUser;
  // Bump this (e.g. a counter) each time the caller wants to force-navigate
  // to the Accessibility tab, even if this screen is already mounted.
  final Object? openAccessibilityToken;
  const SettingsScreen(
      {super.key, required this.currentUser, this.openAccessibilityToken});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

enum SettingsSection {
  company,
  team,
  backup,
  users,
  pdf,
  invoice,
  productColumns,
  customize,
  accessibility,
  cloudSync,
  softwareInfo,
}

class _SettingsDestination {
  final SettingsSection section;
  final IconData icon;
  final String label;
  final bool showUpdateDot;
  const _SettingsDestination(this.section, this.icon, this.label,
      {this.showUpdateDot = false});
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  SettingsSection _selectedSection = SettingsSection.company;
  int? _highlightCustomIndex;
  Object? _handledAccessibilityToken;

  // Update check state — shared between the NavigationRail badge and
  // AppInfoScreen, so it lives here rather than duplicated in both.
  UpdateInfo? _updateInfo;
  bool _isCheckingUpdate = false;
  bool _updateCheckFailed = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(appEditionConfigProvider).enableUpdateCheck) {
      _loadCachedUpdateInfo();
    }
    _maybeJumpToAccessibility();
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.openAccessibilityToken != oldWidget.openAccessibilityToken) {
      setState(_maybeJumpToAccessibility);
    }
  }

  void _maybeJumpToAccessibility() {
    if (widget.openAccessibilityToken == null ||
        widget.openAccessibilityToken == _handledAccessibilityToken) {
      return;
    }
    _handledAccessibilityToken = widget.openAccessibilityToken;
    _selectedSection = SettingsSection.accessibility;
  }

  Future<void> _loadCachedUpdateInfo() async {
    final cached = await ref
        .read(settingsRepositoryProvider)
        .getSetting(SettingKey.lastKnownLatestVersion);
    if (cached != null && cached.isNotEmpty && mounted) {
      setState(() {
        _updateInfo = UpdateInfo(
            latestVersion: cached,
            currentVersion: ref.read(appEditionConfigProvider).version);
      });
    }
  }

  Future<void> _checkForUpdatesNow() async {
    if (_isCheckingUpdate) return;
    setState(() {
      _isCheckingUpdate = true;
      _updateCheckFailed = false;
    });
    final info = await UpdateService.checkForUpdate(force: true);
    if (!mounted) return;
    setState(() {
      _isCheckingUpdate = false;
      if (info != null) {
        _updateInfo = info;
        _updateCheckFailed = false;
      } else {
        _updateCheckFailed = true;
      }
    });
  }

  Widget _buildAppInfoScreen() {
    return AppInfoScreen(
      updateInfo: _updateInfo,
      isCheckingUpdate: _isCheckingUpdate,
      updateCheckFailed: _updateCheckFailed,
      onCheckForUpdates: _checkForUpdatesNow,
    );
  }

  Widget _buildContent(AppEditionConfig cfg, SettingsSection section) {
    switch (section) {
      case SettingsSection.company:
        return const CompanyInfoScreen();
      case SettingsSection.team:
        return cfg.extraSettingsTab!(context);
      case SettingsSection.backup:
        return BackupManagementScreen();
      case SettingsSection.users:
        return UserManagementScreenV2(
          currentUser: widget.currentUser,
        );
      case SettingsSection.pdf:
        return PdfSettingsScreenV2(
          onNavigateToCustomization: () {
            setState(() {
              _selectedSection = SettingsSection.customize;
              _highlightCustomIndex = 0;
            });
          },
        );
      case SettingsSection.invoice:
        return InvoiceSettingsScreenV2(
          currentUser: widget.currentUser,
          onNavigateToCustomization: () {
            setState(() {
              _selectedSection = SettingsSection.customize;
              _highlightCustomIndex = 1;
            });
          },
        );
      case SettingsSection.productColumns:
        return const ProductColumnsSettingsScreen();
      case SettingsSection.customize:
        return CustomizationScreen(highlightIndex: _highlightCustomIndex);
      case SettingsSection.accessibility:
        return const AccessibilityScreen();
      case SettingsSection.cloudSync:
        return const CloudSyncScreen();
      case SettingsSection.softwareInfo:
        return _buildAppInfoScreen();
    }
  }

  /// Section list shared by the desktop NavigationRail and the mobile chip
  /// bar. Selection is a [SettingsSection], so rail order can change without
  /// touching content routing.
  List<_SettingsDestination> _destinations(
      AppEditionConfig cfg, AppLocalizations l10n) {
    final showUpdateDot =
        cfg.enableUpdateCheck && _updateInfo?.hasUpdate == true;
    return [
      _SettingsDestination(SettingsSection.company, Icons.business,
          l10n.settingsNavCompanyInfoLabel),
      if (cfg.extraSettingsTab != null)
        _SettingsDestination(SettingsSection.team,
            cfg.extraSettingsTabIcon ?? Icons.group,
            cfg.extraSettingsTabLabel ?? l10n.settingsNavTeamLabel),
      if (!cfg.isCloud)
        _SettingsDestination(SettingsSection.backup, Icons.backup,
            l10n.settingsNavBackupLabel),
      if (!cfg.isCloud)
        _SettingsDestination(SettingsSection.users, Icons.people,
            l10n.settingsNavUsersLabel),
      _SettingsDestination(
          SettingsSection.pdf, Icons.settings, l10n.pdfSettingsTitle),
      _SettingsDestination(SettingsSection.invoice, Icons.file_present,
          l10n.invoiceSettingsAppBarTitle),
      _SettingsDestination(SettingsSection.productColumns,
          Icons.view_column_outlined, l10n.settingsNavProductDetailsLabel),
      _SettingsDestination(SettingsSection.customize, Icons.tune_rounded,
          l10n.settingsNavCustomizeLabel),
      _SettingsDestination(SettingsSection.accessibility,
          Icons.accessibility_new_rounded, l10n.settingsNavAccessibilityLabel),
      if (!cfg.isCloud)
        const _SettingsDestination(SettingsSection.cloudSync,
            Icons.cloud_sync_outlined, 'Cloud Sync'),
      _SettingsDestination(SettingsSection.softwareInfo, Icons.info_outline,
          l10n.settingsNavSoftwareInfoLabel,
          showUpdateDot: showUpdateDot),
    ];
  }

  /// Compact section selector: a single full-width row showing the current
  /// section; tapping opens a bottom-sheet menu of all destinations. No
  /// horizontal scrolling strip, so the selected section can never sit
  /// partially off-screen and never competes with a child screen's own tabs.
  Widget _buildMobileSectionBar(
      List<_SettingsDestination> destinations, SettingsSection section) {
    final theme = Theme.of(context);
    final current = destinations.firstWhere(
      (d) => d.section == section,
      orElse: () => destinations.first,
    );
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: InkWell(
        onTap: () => _showSectionSheet(destinations),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            border: Border(
              bottom:
                  BorderSide(color: theme.colorScheme.outlineVariant, width: 1),
            ),
          ),
          child: Row(
            children: [
              Icon(current.icon, size: 20, color: theme.primaryColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(current.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              Badge(
                smallSize: 8,
                isLabelVisible: current.showUpdateDot,
                child: const Icon(Icons.expand_more),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSectionSheet(List<_SettingsDestination> destinations) {
    final theme = Theme.of(context);
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.75,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          AppLocalizations.of(sheetContext)!.navSettings,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(sheetContext),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      for (final destination in destinations)
                        ListTile(
                          leading: Icon(destination.icon,
                              color: destination.section == _selectedSection
                                  ? theme.primaryColor
                                  : theme.colorScheme.onSurfaceVariant),
                          title: Text(
                            destination.label,
                            style: TextStyle(
                              fontWeight:
                                  destination.section == _selectedSection
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                              color: destination.section == _selectedSection
                                  ? theme.primaryColor
                                  : null,
                            ),
                          ),
                          trailing: destination.showUpdateDot
                              ? Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                      color: Colors.orange,
                                      shape: BoxShape.circle),
                                )
                              : null,
                          selected: destination.section == _selectedSection,
                          onTap: () {
                            Navigator.pop(sheetContext);
                            setState(() =>
                                _selectedSection = destination.section);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(appEditionConfigProvider);
    if (!widget.currentUser.isAdmin()) {
      return _buildAppInfoScreen();
    }
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final destinations = _destinations(cfg, l10n);
          final effectiveSection = destinations.any(
                  (destination) => destination.section == _selectedSection)
              ? _selectedSection
              : destinations.first.section;
          final selectedIndex = destinations.indexWhere(
              (destination) => destination.section == effectiveSection);
          if (constraints.maxWidth >= Breakpoints.expandedMin) {
            return Row(
              children: [
                NavigationRail(
                  selectedIndex:
                      selectedIndex < 0 ? 0 : selectedIndex,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (int index) {
                    setState(() {
                      _selectedSection = destinations[index].section;
                    });
                  },
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Icon(d.icon),
                            if (d.showUpdateDot)
                              Positioned(
                                right: -4,
                                top: -4,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Colors.orange,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        label: Text(d.label),
                      ),
                  ],
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(child: _buildContent(cfg, effectiveSection)),
              ],
            );
          }
          return Column(
            children: [
              _buildMobileSectionBar(destinations, effectiveSection),
              Expanded(child: _buildContent(cfg, effectiveSection)),
            ],
          );
        },
      ),
    );
  }
}
