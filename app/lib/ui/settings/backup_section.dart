import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../backup/app_backup.dart';
import '../../backup/auto_backup.dart';
import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/artifacts.dart';
import '../../state/settings_state.dart';
import '../common/brief_notice.dart';
import '../theme/app_icons.dart';
import 'settings_widgets.dart';

final appBackupStoreProvider = Provider<AppBackupStore>((ref) => AppBackupStore());

/// Where a backup is written before it is handed on. Tests swap it.
final appBackupDirProvider = Provider<Future<Directory> Function()>((ref) => getTemporaryDirectory);

/// Puts the finished ZIP on the phone itself and returns where it landed
/// (`Download/DSH-Go/…`), or null when it went through the share sheet.
///
/// Android copies it into public Downloads through `FilesChannel` — the same
/// path the app uses for exported reports — so no extra permission is asked for
/// on Android 10+. A platform without that channel, or a refused write, falls
/// back to the share sheet, which can save the file too.
final appBackupSaveProvider = Provider<Future<String?> Function(String path, String name)>((ref) {
  final files = ref.read(filesChannelProvider);
  return (path, name) async {
    try {
      return await files.saveToDownloads(path, name: name, mime: 'application/zip');
    } on MissingPluginException {
      await _shareBackup(path, name);
      return null;
    } on PlatformException catch (error) {
      // Closing the system's save window saved nothing and is not a failure.
      if (saveWindowDismissed(error)) throw const _BackupSaveDismissed();
      await _shareBackup(path, name);
      return null;
    }
  };
});

/// The person closed the system's save window: no file was written.
class _BackupSaveDismissed implements Exception {
  const _BackupSaveDismissed();
}

/// What to say after a ZIP has been written: the saved location when there is
/// one, and a plain warning when the key store could not be read — a backup
/// without API keys must not look complete.
String _backupNotice(L10n l10n, AppBackupInfo info, String? where) {
  if (!info.secretsSaved) return l10n.backupNoSecrets;
  final size = appBackupSize(info.totalBytes);
  if (where == null) {
    return info.skippedLinks == 0
        ? l10n.backupReady(info.fileCount, size)
        : l10n.backupReadySkipped(info.fileCount, size, info.skippedLinks);
  }
  return info.skippedLinks == 0
      ? l10n.backupSavedTo(where, info.fileCount, size)
      : l10n.backupSavedToSkipped(where, info.fileCount, size, info.skippedLinks);
}

Future<void> _shareBackup(String path, String name) => SharePlus.instance.share(
  ShareParams(
    files: [XFile(path, mimeType: 'application/zip', name: name)],
    fileNameOverrides: [name],
  ),
);

/// The path of a backup ZIP to restore, or null if none was picked. Tests
/// swap it.
final appBackupPickerProvider = Provider<Future<String?> Function()>(
  (ref) => () async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['zip']);
    return picked.isEmpty ? null : picked.first.path;
  },
);

/// Settings › 通用: one full phone-data backup and its guarded restoration.
class BackupSettingsSection extends ConsumerStatefulWidget {
  const BackupSettingsSection({super.key});

  @override
  ConsumerState<BackupSettingsSection> createState() => _BackupSettingsSectionState();
}

enum _BackupWork { backup, restore }

class _BackupSettingsSectionState extends ConsumerState<BackupSettingsSection> {
  _BackupWork? _work;

  /// Null until the preferences are read, so the row never shows a made-up
  /// period; tests without a preference store simply do not see it.
  AutoBackupPeriod? _autoPeriod;
  DateTime? _autoLast;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAutoBackup());
  }

  Future<void> _loadAutoBackup() async {
    try {
      final settings = AutoBackupSettings.read(await SharedPreferences.getInstance());
      if (!mounted) return;
      setState(() {
        _autoPeriod = settings.period;
        _autoLast = settings.lastRun;
      });
    } catch (_) {
      // No preferences on this platform: the row stays hidden.
    }
  }

  String _periodLabel(L10n l10n, AutoBackupPeriod period) => switch (period) {
    AutoBackupPeriod.off => l10n.autoBackupOff,
    AutoBackupPeriod.daily => l10n.autoBackupDaily,
    AutoBackupPeriod.weekly => l10n.autoBackupWeekly,
  };

  Future<void> _pickAutoBackup() async {
    final l10n = context.l10n;
    final picked = await showDialog<AutoBackupPeriod>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: Text(l10n.autoBackupTitle),
        children: [
          for (final period in AutoBackupPeriod.values)
            RadioListTile<AutoBackupPeriod>(
              value: period,
              groupValue: _autoPeriod ?? AutoBackupPeriod.off,
              title: Text(_periodLabel(l10n, period)),
              onChanged: (value) => Navigator.of(dialog).pop(value),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      await AutoBackupSettings.writePeriod(preferences, picked);
      if (!mounted) return;
      setState(() => _autoPeriod = picked);
    } catch (_) {
      // Nothing stored, nothing shown as chosen.
    }
  }

  /// `2026-11-20 15:40`, in the phone's own zone.
  static String _formatWhen(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    final local = at.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  /// Stops the local engine so no chat is written while files are read or
  /// replaced. Returns whether it was running and should start again after.
  Future<bool> _stopRuntime() async {
    final bridge = ref.read(runtimeBridgeProvider);
    final RuntimeStatus initial;
    try {
      initial = await bridge.status();
    } on MissingPluginException {
      return false;
    }
    if (initial.phase == RuntimePhase.notInstalled || initial.phase == RuntimePhase.installed) return false;
    final restart = initial.phase == RuntimePhase.running || initial.phase == RuntimePhase.starting;
    await ref.read(localRuntimeProvider.notifier).stop();
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final status = await bridge.status();
      if (status.phase != RuntimePhase.starting &&
          status.phase != RuntimePhase.running &&
          status.phase != RuntimePhase.stopping &&
          status.phase != RuntimePhase.installing) {
        return restart;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError('The local engine did not stop in time');
  }

  Future<void> _restartRuntime() async {
    try {
      await ref.read(localRuntimeProvider.notifier).start();
    } catch (_) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showBriefNotice(context.l10n.backupRestartFailed);
    }
  }

  /// Asks which slices of the phone's data to pack, or returns null when the
  /// person cancels. Everything is on by default.
  Future<BackupSelection?> _pickScope(L10n l10n) async {
    final categories = [
      (BackupCategory.chats, l10n.backupCatChatsLabel, l10n.backupCatChatsDesc),
      (BackupCategory.workspace, l10n.backupCatWorkspaceLabel, l10n.backupCatWorkspaceDesc),
      (BackupCategory.agents, l10n.backupCatAgentsLabel, l10n.backupCatAgentsDesc),
      (BackupCategory.tavern, l10n.backupCatTavernLabel, l10n.backupCatTavernDesc),
      (BackupCategory.companion, l10n.backupCatCompanionLabel, l10n.backupCatCompanionDesc),
      (BackupCategory.appearance, l10n.backupCatAppearanceLabel, l10n.backupCatAppearanceDesc),
      (BackupCategory.settings, l10n.backupCatSettingsLabel, l10n.backupCatSettingsDesc),
      (BackupCategory.secrets, l10n.backupCatSecretsLabel, l10n.backupCatSecretsDesc),
    ];
    var selected = BackupCategory.values.toSet();
    return showDialog<BackupSelection>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setState) {
          final all = selected.length == categories.length;
          final none = selected.isEmpty;
          return AlertDialog(
            title: Text(l10n.backupScopeTitle),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (category, label, description) in categories)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(label),
                        subtitle: Text(description),
                        value: selected.contains(category),
                        onChanged: (on) => setState(() {
                          if (on == true) {
                            selected.add(category);
                          } else {
                            selected.remove(category);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => setState(() {
                  selected = all ? <BackupCategory>{} : BackupCategory.values.toSet();
                }),
                child: Text(all ? l10n.backupScopeNone : l10n.backupScopeAll),
              ),
              TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(l10n.commonCancel)),
              TextButton(
                onPressed: none
                    ? null
                    : () => Navigator.of(dialog).pop(
                        BackupSelection(
                          roots: {
                            for (final category in selected)
                              for (final root in backupCategoryRoots[category]!) root,
                          },
                          settings: selected.contains(BackupCategory.settings),
                          secrets: selected.contains(BackupCategory.secrets),
                        ),
                      ),
                child: Text(l10n.backupScopeConfirm),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _backup() async {
    if (_work != null) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final selection = await _pickScope(l10n);
    if (selection == null || !mounted) return;
    setState(() => _work = _BackupWork.backup);
    var restart = false;
    var discard = false;
    String? path;
    try {
      restart = await _stopRuntime();
      final directory = await ref.read(appBackupDirProvider)();
      final name = appBackupName(DateTime.now());
      path = '${directory.path}/$name';
      final info = await ref.read(appBackupStoreProvider).backup(path, selection: selection);
      final where = await ref.read(appBackupSaveProvider)(path, name);
      discard = true;
      messenger?.showBriefNotice(_backupNotice(l10n, info, where));
    } on _BackupSaveDismissed {
      // Nothing saved, nothing wrong: the person closed the save window.
      discard = true;
    } catch (error) {
      messenger?.showBriefNotice(l10n.backupAppFailed('$error'));
    } finally {
      if (restart) await _restartRuntime();
      // The ZIP is a copy: the phone or the share sheet has taken it by now.
      // A failed hand-over keeps it, so nothing is lost without a word.
      if (discard && path != null) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _work = null);
    }
  }

  Future<void> _restore() async {
    if (_work != null) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _work = _BackupWork.restore);
    var restart = false;
    try {
      final path = await ref.read(appBackupPickerProvider)();
      if (path == null || !mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.backupRestoreConfirmTitle),
          content: Text(l10n.backupRestoreConfirmMessage),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(l10n.commonCancel)),
            TextButton(onPressed: () => Navigator.of(dialog).pop(true), child: Text(l10n.backupRestoreAction)),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      restart = await _stopRuntime();
      final info = await ref.read(appBackupStoreProvider).restore(path);
      // The restored preferences are already on disk; reload them so this
      // session cannot write the stale values back over them.
      ref.invalidate(settingsProvider);
      messenger?.showBriefNotice(
        info.secretCount > 0
            ? l10n.backupRestoredSecrets(info.fileCount, info.secretCount)
            : l10n.backupAppRestored(info.fileCount),
      );
    } catch (error) {
      messenger?.showBriefNotice(l10n.backupRestoreFailed('$error'));
    } finally {
      // A committed restore needs the engine to read the new data; a failed
      // one leaves an originally running engine as it was.
      if (restart) await _restartRuntime();
      if (mounted) setState(() => _work = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final busy = _work != null;
    Widget? progress(_BackupWork work) =>
        _work == work ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null;
    return SettingsSection(
      footer: Text(l10n.backupDataNote),
      children: [
        SettingsTile(
          key: const ValueKey('settings-backup'),
          icon: AppIcons.archive,
          tint: SettingsHues.general,
          spot: Spots.backupNow,
          subtitle: l10n.backupNowSubtitle,
          trailing: progress(_BackupWork.backup),
          onTap: busy ? null : () => unawaited(_backup()),
        ),
        SettingsTile(
          key: const ValueKey('settings-restore'),
          icon: AppIcons.unarchive,
          tint: SettingsHues.general,
          spot: Spots.backupRestore,
          subtitle: l10n.backupRestoreSubtitle,
          trailing: progress(_BackupWork.restore),
          onTap: busy ? null : () => unawaited(_restore()),
        ),
        if (_autoPeriod != null)
          SettingsTile(
            key: const ValueKey('settings-auto-backup'),
            icon: AppIcons.scheduled,
            tint: SettingsHues.general,
            title: l10n.autoBackupTitle,
            subtitle: _autoLast == null ? l10n.autoBackupSubtitle : l10n.autoBackupLast(_formatWhen(_autoLast!)),
            value: Text(_periodLabel(l10n, _autoPeriod!)),
            onTap: () => unawaited(_pickAutoBackup()),
          ),
      ],
    );
  }
}
