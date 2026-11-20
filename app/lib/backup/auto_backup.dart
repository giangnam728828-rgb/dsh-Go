import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../runtime/runtime_bridge.dart';
import '../state/artifacts.dart';
import 'app_backup.dart';

/// How often the phone copies its own data into `Download/DSH-Go`.
///
/// The engine is never stopped for this: an automatic backup either finds the
/// engine idle or skips the turn, so a running conversation is never cut.
enum AutoBackupPeriod {
  off('off'),
  daily('daily'),
  weekly('weekly');

  const AutoBackupPeriod(this.id);

  /// Stored in preferences; renaming one resets that choice, so keep them.
  final String id;

  Duration get interval => switch (this) {
    AutoBackupPeriod.off => Duration.zero,
    AutoBackupPeriod.daily => const Duration(days: 1),
    AutoBackupPeriod.weekly => const Duration(days: 7),
  };

  static AutoBackupPeriod fromId(String? id) {
    for (final period in values) {
      if (period.id == id) return period;
    }
    return AutoBackupPeriod.off;
  }
}

/// The chosen period and when a backup last finished.
class AutoBackupSettings {
  const AutoBackupSettings({required this.period, required this.lastRun});

  final AutoBackupPeriod period;
  final DateTime? lastRun;

  bool get enabled => period != AutoBackupPeriod.off;

  /// Preferences keys; a backup carries them like every other setting.
  static const periodKey = 'backup.auto.period';
  static const lastKey = 'backup.auto.last';

  static AutoBackupSettings read(SharedPreferences preferences) => AutoBackupSettings(
    period: AutoBackupPeriod.fromId(preferences.getString(periodKey)),
    lastRun: DateTime.tryParse(preferences.getString(lastKey) ?? ''),
  );

  static Future<void> writePeriod(SharedPreferences preferences, AutoBackupPeriod period) =>
      preferences.setString(periodKey, period.id);

  static Future<void> markRun(SharedPreferences preferences, DateTime at) =>
      preferences.setString(lastKey, at.toIso8601String());

  /// Whether a backup is owed at [now]. A clock that moved backwards still
  /// counts as due, so a wrong date cannot silence the schedule forever.
  bool isDue(DateTime now) {
    if (!enabled) return false;
    final last = lastRun;
    if (last == null) return true;
    final elapsed = now.difference(last);
    if (elapsed.isNegative) return true;
    return elapsed >= period.interval;
  }
}

/// Runs at most one scheduled backup per launch.
///
/// Everything it touches is injectable so tests never start a runtime, read
/// the phone's own storage or wait on a timer.
class AutoBackup {
  const AutoBackup({
    this.preferences = SharedPreferences.getInstance,
    this.engineBusy = _defaultEngineBusy,
    this.store,
    this.temporaryDir = getTemporaryDirectory,
    this.save,
    this.now = DateTime.now,
    this.grace = const Duration(seconds: 15),
  });

  final Future<SharedPreferences> Function() preferences;

  /// True while the engine holds the data: writing a ZIP now would read
  /// half-written sessions and stopping it would interrupt the conversation.
  final Future<bool> Function() engineBusy;
  final AppBackupStore? store;
  final Future<Directory> Function() temporaryDir;

  /// Hands the finished ZIP to the phone. Null means the platform has no such
  /// channel (or the copy was refused); the schedule then stays due.
  final Future<String?> Function(String path, String name)? save;
  final DateTime Function() now;

  /// The first frame must not compete with a few hundred megabytes of file IO.
  final Duration grace;

  /// Returns where the ZIP landed, or null when nothing was due or it failed.
  Future<String?> runIfDue() async {
    final SharedPreferences prefs;
    try {
      prefs = await preferences();
    } catch (_) {
      return null;
    }
    final settings = AutoBackupSettings.read(prefs);
    final at = now();
    if (!settings.isDue(at)) return null;

    if (grace > Duration.zero) await Future<void>.delayed(grace);

    final bool busy;
    try {
      busy = await engineBusy();
    } catch (_) {
      return null;
    }
    if (busy) return null;

    final Directory directory;
    try {
      directory = await temporaryDir();
      if (!await directory.exists()) await directory.create(recursive: true);
    } catch (_) {
      return null;
    }

    final name = appBackupName(at);
    final path = '${directory.path}/$name';
    String? where;
    try {
      await (store ?? AppBackupStore()).backup(path);
      where = await (save ?? _defaultSave)(path, name);
      if (where == null) return null;
      await AutoBackupSettings.markRun(prefs, at);
      return where;
    } catch (_) {
      // A failure leaves the schedule due: the next launch tries again.
      return null;
    } finally {
      // The phone owns its copy now; the scratch file is never the only one.
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }
}

Future<String?> _defaultSave(String path, String name) async {
  try {
    return await const FilesChannel().saveToDownloads(path, name: name, mime: 'application/zip');
  } catch (_) {
    return null;
  }
}

Future<bool> _defaultEngineBusy() async {
  try {
    final status = await RuntimeBridge().status();
    return status.phase.isBusy || status.phase == RuntimePhase.running;
  } on MissingPluginException {
    return false;
  } catch (_) {
    return false;
  }
}
