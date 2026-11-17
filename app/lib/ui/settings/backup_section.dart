import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../backup/app_backup.dart';
import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/settings_state.dart';
import '../common/brief_notice.dart';
import '../theme/app_icons.dart';
import 'settings_widgets.dart';

final appBackupStoreProvider = Provider<AppBackupStore>((ref) => AppBackupStore());

/// Where a backup is written before it is handed on. Tests swap it.
final appBackupDirProvider = Provider<Future<Directory> Function()>((ref) => getTemporaryDirectory);

/// The system share sheet also lets the user save the ZIP to Files/Downloads.
final appBackupShareProvider = Provider<Future<void> Function(String path, String name)>(
  (ref) => (path, name) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: 'application/zip', name: name)],
        fileNameOverrides: [name],
      ),
    );
  },
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

  Future<void> _backup() async {
    if (_work != null) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _work = _BackupWork.backup);
    var restart = false;
    try {
      restart = await _stopRuntime();
      final directory = await ref.read(appBackupDirProvider)();
      final name = appBackupName(DateTime.now());
      final path = '${directory.path}/$name';
      final info = await ref.read(appBackupStoreProvider).backup(path);
      await ref.read(appBackupShareProvider)(path, name);
      messenger?.showBriefNotice(
        info.skippedLinks == 0
            ? l10n.backupReady(info.fileCount, appBackupSize(info.totalBytes))
            : l10n.backupReadySkipped(info.fileCount, appBackupSize(info.totalBytes), info.skippedLinks),
      );
    } catch (error) {
      messenger?.showBriefNotice(l10n.backupFailed('$error'));
    } finally {
      if (restart) await _restartRuntime();
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
      messenger?.showBriefNotice(l10n.backupRestored(info.fileCount));
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
      ],
    );
  }
}
