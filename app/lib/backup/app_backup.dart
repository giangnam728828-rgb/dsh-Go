import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../runtime/local_paths.dart';
import '../secrets/secure_storage.dart';

const _format = 'dshgo-app-backup';
const _version = 1;
const _manifestName = 'manifest.json';
const _manifestByteCap = 8 * 1024 * 1024;

/// Ceilings for the credentials folded into the manifest, so a malformed ZIP
/// cannot make the app write an unbounded blob into the system key store.
const _secretKeyCap = 256;
const _secretValueCap = 64 * 1024;
const _secretByteCap = 2 * 1024 * 1024;

/// App data kept under the application support directory. `runtime` (the
/// engine's own rootfs), `speech` (downloaded voice models) and `workshop`
/// (a catalog cache) are rebuilt or downloaded again, so they are not here.
const _supportRoots = ['tavern', 'tavern_avatars', 'companion', 'pets', 'wallpaper', 'launch', 'call'];

/// The engine's user home. Chat sessions live in `.dsh/sessions`, storages in
/// `.dsh/storages`, skills in `.dsh/skills` and `.agents`, and files the person
/// asked the AI to write in `workspace`.
const _engineRoots = ['.dsh', '.agents', 'workspace'];

/// Top-level folders inside a root that a backup leaves out: the speech model
/// is a download of several hundred MB and `logs` is diagnosis, neither is
/// something a person can lose. The live copies stay untouched by a restore.
const _excluded = <String, Set<String>>{
  'engine/.dsh': {'speech-to-text', 'logs'},
};

final _knownRoots = List<String>.unmodifiable([
  for (final name in _engineRoots) 'engine/$name',
  for (final name in _supportRoots) 'support/$name',
]);

/// A group of phone data the person can include in a backup or leave out.
///
/// [BackupCategory.settings] and [BackupCategory.secrets] are not directories:
/// the former lives in SharedPreferences, the latter in the system key store,
/// and each is turned on or off by its own flag on [BackupSelection].
enum BackupCategory { chats, workspace, agents, tavern, companion, appearance, settings, secrets }

/// The data directories covered by each category. Every listed root is one of
/// [_knownRoots]; the two non-file categories map to an empty list.
const backupCategoryRoots = <BackupCategory, List<String>>{
  BackupCategory.chats: ['engine/.dsh'],
  BackupCategory.workspace: ['engine/workspace'],
  BackupCategory.agents: ['engine/.agents'],
  BackupCategory.tavern: ['support/tavern', 'support/tavern_avatars'],
  BackupCategory.companion: ['support/companion', 'support/pets'],
  BackupCategory.appearance: ['support/wallpaper', 'support/launch', 'support/call'],
  BackupCategory.settings: <String>[],
  BackupCategory.secrets: <String>[],
};

/// Which slices of the phone's data go into one backup. A partial selection
/// still produces a complete, valid archive; a restore then replaces only the
/// directories and flags this selection named.
class BackupSelection {
  const BackupSelection({required this.roots, required this.settings, required this.secrets});

  /// Every data directory, all preferences and all credentials.
  factory BackupSelection.full() => BackupSelection(roots: _knownRoots.toSet(), settings: true, secrets: true);

  final Set<String> roots;
  final bool settings;
  final bool secrets;
}

/// Metadata of the immutable snapshot carried by an app backup.
class AppBackupInfo {
  const AppBackupInfo({
    required this.createdAt,
    required this.fileCount,
    required this.totalBytes,
    required this.skippedLinks,
    this.secretCount = 0,
    this.secretsSaved = true,
  });

  final DateTime createdAt;
  final int fileCount;
  final int totalBytes;

  /// Symbolic links are never followed: a link may point outside the app or
  /// back into its own tree. A relative link that stays inside its root is
  /// recorded and recreated; an absolute or escaping one is skipped and
  /// counted here.
  final int skippedLinks;

  /// Model API keys, tavern channel keys and account tokens kept in the system
  /// key store, written into the ZIP in clear text (the ZIP itself is not
  /// encrypted). Zero when there were none or they could not be read.
  final int secretCount;

  /// False when the system key store could not be read: the ZIP then holds
  /// chats, settings and workspace, but no API keys, and the page says so
  /// instead of letting the person believe they were saved.
  final bool secretsSaved;
}

/// Reads and restores the phone's user data without touching the installed
/// engine binaries. The caller stops the local engine before either operation.
class AppBackupStore {
  AppBackupStore({
    Future<Directory> Function()? support,
    Future<Directory> Function()? engineHome,
    Future<SharedPreferences> Function()? preferences,
    Future<Map<String, String>> Function()? readSecrets,
    Future<void> Function(String key, String value)? writeSecret,
    Future<void> Function(String key)? deleteSecret,
    DateTime Function()? now,
  }) : _support = support ?? getApplicationSupportDirectory,
       _engineHome = engineHome ?? _defaultEngineHome,
       _preferences = preferences ?? SharedPreferences.getInstance,
       _readSecrets = readSecrets ?? (() => const AppSecureStorage().readAll()),
       _writeSecret = writeSecret ?? ((key, value) => const AppSecureStorage().write(key: key, value: value)),
       _deleteSecret = deleteSecret ?? ((key) => const AppSecureStorage().delete(key: key)),
       _now = now ?? DateTime.now;

  static Future<Directory> _defaultEngineHome() async {
    final root = LocalPaths.root ?? '${(await getApplicationSupportDirectory()).path}/runtime/rootfs';
    return Directory('$root/root');
  }

  final Future<Directory> Function() _support;
  final Future<Directory> Function() _engineHome;
  final Future<SharedPreferences> Function() _preferences;
  final Future<Map<String, String>> Function() _readSecrets;
  final Future<void> Function(String key, String value) _writeSecret;
  final Future<void> Function(String key) _deleteSecret;
  final DateTime Function() _now;

  Future<Map<String, Directory>> _targets() async {
    final support = await _support();
    final engine = await _engineHome();
    return {
      for (final name in _engineRoots) 'engine/$name': Directory('${engine.path}/$name'),
      for (final name in _supportRoots) 'support/$name': Directory('${support.path}/$name'),
    };
  }

  /// Writes a complete ZIP to [destinationPath], publishing it only after the
  /// encoder has closed successfully. No existing destination is overwritten.
  ///
  /// [selection] narrows what goes in; the default is everything. A partial
  /// backup records its scope in the manifest so a restore knows what not to
  /// touch.
  Future<AppBackupInfo> backup(String destinationPath, {BackupSelection? selection}) async {
    final scope = selection ?? BackupSelection.full();
    final targets = await _targets();
    final preferences = scope.settings ? await _readPreferences(await _preferences()) : const <String, Object?>{};
    // The system key store holds the model API keys and account tokens; a ZIP
    // without them restores settings that cannot talk to any model. A key store
    // that refuses to be read must not cost the person their chats, so the
    // backup goes on and reports that the keys are missing.
    Map<String, String> secrets;
    var secretsSaved = true;
    if (scope.secrets) {
      try {
        secrets = await _readSecrets();
      } catch (_) {
        secrets = const {};
        secretsSaved = false;
      }
    } else {
      secrets = const {};
    }
    final files = <_SourceFile>[];
    final links = <_SourceLink>[];
    final directories = <String>[];
    final presentRoots = <String>[];
    var skippedLinks = 0;
    var totalBytes = 0;

    for (final root in _knownRoots) {
      if (!scope.roots.contains(root)) continue;
      final directory = targets[root]!;
      final excluded = _excluded[root] ?? const <String>{};
      final type = await FileSystemEntity.type(directory.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException('A backup root is not a real directory', directory.path);
      }
      presentRoots.add(root);
      directories.add(root);

      Future<void> walk(Directory current, String prefix) async {
        final children = await current.list(followLinks: false).toList();
        children.sort((a, b) => a.path.compareTo(b.path));
        for (final entity in children) {
          final name = entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
          if (prefix == root && excluded.contains(name)) continue;
          final relative = '$prefix/$name';
          _checkRelativePath(relative);
          final childType = await FileSystemEntity.type(entity.path, followLinks: false);
          if (childType == FileSystemEntityType.directory) {
            directories.add(relative);
            await walk(Directory(entity.path), relative);
          } else if (childType == FileSystemEntityType.file) {
            final file = File(entity.path);
            final size = await file.length();
            files.add(_SourceFile(relative, file, size, await _hash(file)));
            totalBytes += size;
          } else if (childType == FileSystemEntityType.link) {
            // pnpm's node_modules is a tree of relative links; keeping them is
            // what lets a restored engine profile boot. Links that leave the
            // root (or name an absolute path) are not recreated.
            final target = await Link(entity.path).target();
            if (_linkTarget(relative, target) == null) {
              skippedLinks++;
            } else {
              links.add(_SourceLink(relative, target));
            }
          } else {
            skippedLinks++;
          }
        }
      }

      await walk(directory, root);
    }

    files.sort((a, b) => a.path.compareTo(b.path));
    directories.sort();
    final info = AppBackupInfo(
      createdAt: _now().toUtc(),
      fileCount: files.length,
      totalBytes: totalBytes,
      skippedLinks: skippedLinks,
      secretCount: secrets.length,
      secretsSaved: secretsSaved,
    );
    final manifest = utf8.encode(
      jsonEncode({
        'format': _format,
        'version': _version,
        'createdAt': info.createdAt.toIso8601String(),
        'skippedLinks': skippedLinks,
        'roots': presentRoots,
        'directories': directories,
        'preferences': preferences,
        'secrets': secrets,
        'includesSettings': scope.settings,
        'includesSecrets': scope.secrets,
        'files': [
          for (final file in files) {'path': file.path, 'size': file.size, 'sha256': file.hash},
        ],
        'links': [
          for (final link in links) {'path': link.path, 'target': link.target},
        ],
      }),
    );

    final destination = File(destinationPath);
    await destination.parent.create(recursive: true);
    if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
      throw FileSystemException('The backup destination already exists', destination.path);
    }
    final outputWork = await destination.parent.createTemp('.dshgo-app-backup-');
    final temporary = File('${outputWork.path}/backup.zip');
    try {
      final output = OutputFileStream(temporary.path);
      final encoder = ZipFileEncoder();
      var closed = false;
      try {
        encoder.createWithStream(output);
        encoder.addArchiveFile(ArchiveFile.bytes(_manifestName, manifest));
        encoder.addArchiveFile(ArchiveFile.directory('data/'));
        for (final directory in directories) {
          encoder.addArchiveFile(ArchiveFile.directory('data/$directory/'));
        }
        for (final file in files) {
          if (await file.source.length() != file.size) {
            throw FileSystemException('A file changed while the backup was being written', file.source.path);
          }
          final input = InputFileStream(file.source.path);
          try {
            encoder.addArchiveFile(ArchiveFile.stream('data/${file.path}', input));
          } finally {
            await input.close();
          }
        }
        await encoder.close();
        closed = true;
      } finally {
        if (!closed) await output.close();
      }
      await temporary.rename(destination.path);
      return info;
    } finally {
      await _deleteTree(outputWork);
    }
  }

  /// Validates and extracts the whole archive before replacing any live root.
  /// Existing roots are moved aside and put back if a swap, a preference write
  /// or a credential write fails; saved API keys and tokens go back into the
  /// system key store last.
  Future<AppBackupInfo> restore(String archivePath) async {
    final support = await _support();
    await support.create(recursive: true);
    final work = await support.createTemp('.dshgo-app-restore-');
    var preserveWork = false;
    try {
      final incoming = Directory('${work.path}/incoming');
      await incoming.create();
      final manifest = await _extract(archivePath, work, incoming);
      final targets = await _targets();
      if (targets.keys.toSet().difference(_knownRoots.toSet()).isNotEmpty) {
        throw StateError('Unknown backup target');
      }
      for (final target in targets.values) {
        final type = await FileSystemEntity.type(target.path, followLinks: false);
        if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.directory) {
          throw FileSystemException('A restore destination is not a real directory', target.path);
        }
      }

      // Only the slices the backup actually holds are touched: a partial
      // backup must leave every other directory, preference and credential
      // exactly as it is.
      final preferences = manifest.includesSettings ? await _preferences() : null;
      final previousPreferences = manifest.includesSettings
          ? await _readPreferences(preferences!)
          : const <String, Object?>{};
      // Read before anything is replaced: if a key write fails, the old values
      // go back. A key store that cannot be read leaves credentials alone
      // rather than guess, while the chats and settings are still restored.
      Map<String, String>? previousSecrets;
      if (manifest.includesSecrets) {
        try {
          previousSecrets = await _readSecrets();
        } catch (_) {
          previousSecrets = null;
        }
      }
      final writtenSecrets = <String>{};
      final previous = Directory('${work.path}/previous');
      await previous.create();
      final actions = <_RestoreAction>[];
      var mutated = false;
      try {
        for (final (index, root) in _knownRoots.indexed) {
          if (!manifest.roots.contains(root)) continue;
          final target = targets[root]!;
          final source = Directory('${incoming.path}/$root');
          final old = Directory('${previous.path}/$index');
          final hadTarget =
              await FileSystemEntity.type(target.path, followLinks: false) != FileSystemEntityType.notFound;
          final action = _RestoreAction(root, target, old, hadTarget);
          actions.add(action);
          await target.parent.create(recursive: true);
          if (hadTarget) {
            await target.rename(old.path);
            action.movedAside = true;
            mutated = true;
          }
          if (await FileSystemEntity.type(source.path, followLinks: false) != FileSystemEntityType.directory) {
            throw FormatException('The restored root is missing: $root');
          }
          await source.rename(target.path);
          action.installed = true;
          mutated = true;
        }
        if (manifest.includesSettings) await _writePreferences(preferences!, manifest.preferences);
        if (manifest.includesSecrets) await _writeSecrets(manifest.secrets, writtenSecrets);
        // The archive leaves voice models and logs out on purpose; the copies
        // in the old tree are the only ones on the phone, so they move into the
        // restored tree. Failing here costs a download, never the restore.
        await _carryExcluded(actions);
        final info = manifest.info;
        await _deleteTree(work);
        return info;
      } catch (error, stack) {
        if (!mutated) rethrow;
        try {
          if (manifest.includesSettings) await _writePreferences(preferences!, previousPreferences);
          if (manifest.includesSecrets && previousSecrets != null) {
            await _restoreSecrets(previousSecrets, writtenSecrets);
          }
          for (final action in actions.reversed) {
            if (action.installed &&
                await FileSystemEntity.type(action.target.path, followLinks: false) != FileSystemEntityType.notFound) {
              await action.target.delete(recursive: true);
            }
            if (action.movedAside &&
                await FileSystemEntity.type(action.previous.path, followLinks: false) !=
                    FileSystemEntityType.notFound) {
              await action.previous.rename(action.target.path);
            }
          }
        } catch (rollbackError) {
          preserveWork = true;
          throw FileSystemException(
            'Restore failed and its previous data was kept at ${work.path}: $rollbackError',
            archivePath,
          );
        }
        Error.throwWithStackTrace(error, stack);
      }
    } finally {
      if (!preserveWork) await _deleteTree(work);
    }
  }

  Future<void> _carryExcluded(List<_RestoreAction> actions) async {
    for (final action in actions) {
      final names = _excluded[action.root];
      if (names == null || !action.installed || !action.movedAside) continue;
      for (final name in names) {
        final from = Directory('${action.previous.path}/$name');
        final to = Directory('${action.target.path}/$name');
        try {
          if (await FileSystemEntity.type(from.path, followLinks: false) != FileSystemEntityType.directory) continue;
          if (await FileSystemEntity.type(to.path, followLinks: false) != FileSystemEntityType.notFound) continue;
          await from.rename(to.path);
        } catch (_) {
          // Keep the restored data; a missing model is downloaded again.
        }
      }
    }
  }

  Future<Map<String, Object?>> _readPreferences(SharedPreferences preferences) async {
    final result = <String, Object?>{};
    for (final key in preferences.getKeys().toList()..sort()) {
      final value = preferences.get(key);
      _checkPreference(value);
      result[key] = value;
    }
    return result;
  }

  Future<void> _writePreferences(SharedPreferences preferences, Map<String, Object?> values) async {
    final current = preferences.getKeys().toSet();
    for (final key in current.difference(values.keys.toSet())) {
      if (!await preferences.remove(key)) throw StateError('Could not remove a preference');
    }
    for (final entry in values.entries) {
      final value = entry.value;
      final ok = switch (value) {
        String() => preferences.setString(entry.key, value),
        int() => preferences.setInt(entry.key, value),
        double() => preferences.setDouble(entry.key, value),
        bool() => preferences.setBool(entry.key, value),
        List() => preferences.setStringList(entry.key, List<String>.from(value)),
        _ => throw const FormatException('Unsupported preference value'),
      };
      if (!await ok) throw StateError('Could not save a preference');
    }
  }

  /// Writes each saved credential, recording the keys already touched so a
  /// failure halfway can put the previous values back.
  Future<void> _writeSecrets(Map<String, String> values, Set<String> written) async {
    for (final entry in values.entries) {
      await _writeSecret(entry.key, entry.value);
      written.add(entry.key);
    }
  }

  /// Undoes [_writeSecrets]: keys the backup introduced go away, every key the
  /// phone already had gets its old value back. Best effort by design — the
  /// chats and settings rollback must not be lost to a stubborn key store.
  Future<void> _restoreSecrets(Map<String, String> previous, Set<String> written) async {
    for (final key in written.difference(previous.keys.toSet())) {
      try {
        await _deleteSecret(key);
      } catch (_) {}
    }
    for (final entry in previous.entries) {
      try {
        await _writeSecret(entry.key, entry.value);
      } catch (_) {}
    }
  }
}

class _SourceFile {
  const _SourceFile(this.path, this.source, this.size, this.hash);
  final String path;
  final File source;
  final int size;
  final String hash;
}

class _ManifestFile {
  const _ManifestFile(this.path, this.size, this.hash);
  final String path;
  final int size;
  final String hash;
}

class _SourceLink {
  const _SourceLink(this.path, this.target);
  final String path;
  final String target;
}

class _Manifest {
  const _Manifest(this.info, this.roots, this.preferences, this.secrets, this.includesSettings, this.includesSecrets);
  final AppBackupInfo info;
  final Set<String> roots;
  final Map<String, Object?> preferences;
  final Map<String, String> secrets;
  final bool includesSettings;
  final bool includesSecrets;
}

class _RestoreAction {
  _RestoreAction(this.root, this.target, this.previous, this.hadTarget);
  final String root;
  final Directory target;
  final Directory previous;
  final bool hadTarget;
  var movedAside = false;
  var installed = false;
}

Future<_Manifest> _extract(String archivePath, Directory work, Directory incoming) async {
  final input = InputFileStream(archivePath);
  try {
    final names = <String>{};
    final archive = ZipDecoder().decodeStream(
      input,
      verify: true,
      callback: (entry) {
        final path = _archivePath(entry);
        if (!names.add(path)) throw FormatException('Duplicate ZIP entry: $path');
      },
    );
    final byName = <String, ArchiveFile>{for (final entry in archive) _archivePath(entry): entry};
    final manifestEntry = byName[_manifestName];
    if (manifestEntry == null ||
        !manifestEntry.isFile ||
        manifestEntry.size < 0 ||
        manifestEntry.size > _manifestByteCap) {
      throw const FormatException('The app backup manifest is missing or too large');
    }
    final manifestBytes = manifestEntry.readBytes();
    if (manifestBytes == null || manifestBytes.length > _manifestByteCap) {
      throw const FormatException('The app backup manifest is too large');
    }
    final raw = jsonDecode(utf8.decode(manifestBytes));
    if (raw is! Map<String, Object?> || raw['format'] != _format || raw['version'] != _version) {
      throw const FormatException('Unsupported app backup format or version');
    }
    final created = raw['createdAt'];
    final rootsValue = raw['roots'];
    final directoriesValue = raw['directories'];
    final filesValue = raw['files'];
    final preferencesValue = raw['preferences'];
    // Absent in backups written before links were recorded: nothing to keep.
    final linksValue = raw['links'] ?? const <Object?>[];
    // Absent in backups written before credentials were saved: nothing to put
    // back, and the old behaviour (leave the key store alone) is kept.
    final secretsValue = raw['secrets'] ?? const <String, Object?>{};
    // Backups written before ranges could be chosen held everything, so a
    // missing flag means both settings and credentials are in.
    final includesSettings = raw['includesSettings'] ?? true;
    final includesSecrets = raw['includesSecrets'] ?? true;
    final skippedLinks = raw['skippedLinks'];
    if (created is! String ||
        DateTime.tryParse(created) == null ||
        rootsValue is! List ||
        directoriesValue is! List ||
        filesValue is! List ||
        linksValue is! List ||
        preferencesValue is! Map ||
        secretsValue is! Map ||
        includesSettings is! bool ||
        includesSecrets is! bool ||
        skippedLinks is! int ||
        skippedLinks < 0) {
      throw const FormatException('Invalid app backup manifest');
    }
    final roots = <String>{};
    for (final root in rootsValue) {
      if (root is! String || !_knownRoots.contains(root) || !roots.add(root)) {
        throw const FormatException('Invalid app backup roots');
      }
    }
    final preferences = <String, Object?>{};
    for (final entry in preferencesValue.entries) {
      if (entry.key is! String) throw const FormatException('Invalid preference name');
      _checkPreference(entry.value);
      preferences[entry.key as String] = entry.value;
    }
    final secrets = <String, String>{};
    var secretUnits = 0;
    for (final entry in secretsValue.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String ||
          value is! String ||
          key.isEmpty ||
          key.length > _secretKeyCap ||
          value.length > _secretValueCap) {
        throw const FormatException('Invalid credential record');
      }
      secretUnits += key.length + value.length;
      if (secretUnits > _secretByteCap) throw const FormatException('The backup holds too many credentials');
      secrets[key] = value;
    }

    bool insidePresentRoot(String path, {required bool file}) =>
        roots.any((root) => file ? path.startsWith('$root/') : path == root || path.startsWith('$root/'));
    final directories = <String>{};
    for (final value in directoriesValue) {
      if (value is! String) throw const FormatException('Invalid backup directory');
      _checkRelativePath(value);
      if (!insidePresentRoot(value, file: false) || !directories.add(value)) {
        throw const FormatException('Invalid or duplicate backup directory');
      }
    }
    final files = <_ManifestFile>[];
    final filePaths = <String>{};
    var totalBytes = 0;
    for (final value in filesValue) {
      if (value is! Map) throw const FormatException('Invalid backup file');
      final path = value['path'];
      final size = value['size'];
      final hash = value['sha256'];
      if (path is! String || size is! int || size < 0 || hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
        throw const FormatException('Invalid backup file record');
      }
      _checkRelativePath(path);
      if (!insidePresentRoot(path, file: true) || !filePaths.add(path)) {
        throw const FormatException('Invalid or duplicate backup file');
      }
      files.add(_ManifestFile(path, size, hash));
      totalBytes += size;
    }
    final links = <_SourceLink>[];
    final linkPaths = <String>{};
    for (final value in linksValue) {
      if (value is! Map) throw const FormatException('Invalid backup link');
      final path = value['path'];
      final target = value['target'];
      if (path is! String || target is! String) throw const FormatException('Invalid backup link record');
      _checkRelativePath(path);
      if (!insidePresentRoot(path, file: true) ||
          !linkPaths.add(path) ||
          filePaths.contains(path) ||
          directories.contains(path) ||
          _linkTarget(path, target) == null) {
        throw const FormatException('Invalid or duplicate backup link');
      }
      links.add(_SourceLink(path, target));
    }
    final expected = <String>{
      _manifestName,
      'data',
      for (final directory in directories) 'data/$directory',
      for (final file in files) 'data/${file.path}',
    };
    if (names.length != expected.length || !names.containsAll(expected)) {
      throw const FormatException('ZIP entries do not match the app backup manifest');
    }
    if (byName['data']!.isFile) throw const FormatException('The backup data entry is not a directory');
    for (final directory in directories) {
      if (byName['data/$directory']!.isFile) throw const FormatException('A backup directory is encoded as a file');
      await Directory('${incoming.path}/$directory').create(recursive: true);
    }
    for (final file in files) {
      final entry = byName['data/${file.path}']!;
      if (!entry.isFile || entry.size != file.size) throw const FormatException('Backup file size does not match');
      final destination = File('${incoming.path}/${file.path}');
      await destination.parent.create(recursive: true);
      final output = OutputFileStream(destination.path);
      try {
        entry.writeContent(output);
      } finally {
        await output.close();
      }
      if (await destination.length() != file.size || await _hash(destination) != file.hash) {
        throw FormatException('Backup checksum does not match: ${file.path}');
      }
    }
    for (final link in links) {
      final destination = Link('${incoming.path}/${link.path}');
      await destination.parent.create(recursive: true);
      await destination.create(link.target);
    }
    return _Manifest(
      AppBackupInfo(
        createdAt: DateTime.parse(created).toUtc(),
        fileCount: files.length,
        totalBytes: totalBytes,
        skippedLinks: skippedLinks,
        secretCount: secrets.length,
      ),
      roots,
      preferences,
      secrets,
      includesSettings,
      includesSecrets,
    );
  } finally {
    await input.close();
  }
}

String _archivePath(ArchiveFile entry) {
  final fileType = entry.mode & 0xf000;
  if (entry.symbolicLink != null || entry.isHardLink || (fileType != 0 && fileType != 0x8000 && fileType != 0x4000)) {
    throw FormatException('A backup cannot contain linked or special entries: ${entry.name}');
  }
  final path = entry.isDirectory && entry.name.endsWith('/')
      ? entry.name.substring(0, entry.name.length - 1)
      : entry.name;
  _checkRelativePath(path);
  if (path != _manifestName && path != 'data' && !path.startsWith('data/')) {
    throw FormatException('Unexpected ZIP entry: $path');
  }
  return path;
}

void _checkRelativePath(String path) {
  final parts = path.split('/');
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains('\x00') ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw FormatException('Unsafe backup path: $path');
  }
}

/// Where a link stored at [linkPath] lands, or null when it is absolute,
/// malformed, or climbs out of its root (a link must never reach a file the
/// backup does not own).
String? _linkTarget(String linkPath, String target) {
  if (target.isEmpty || target.startsWith('/') || target.contains('\\') || target.contains('\x00')) return null;
  final parts = linkPath.split('/')..removeLast();
  for (final part in target.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.isEmpty ? null : parts.join('/');
}

void _checkPreference(Object? value) {
  final valid =
      value is String ||
      value is int ||
      value is double ||
      value is bool ||
      value is List && value.every((v) => v is String);
  if (!valid) throw const FormatException('Unsupported preference value');
}

Future<String> _hash(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

Future<void> _deleteTree(Directory directory) async {
  if (await FileSystemEntity.type(directory.path, followLinks: false) == FileSystemEntityType.directory) {
    await directory.delete(recursive: true);
  }
}

String appBackupName(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'dshgo-backup-${at.year}${two(at.month)}${two(at.day)}-${two(at.hour)}${two(at.minute)}${two(at.second)}.zip';
}

String appBackupSize(int bytes) =>
    bytes < 1024 * 1024 ? '${(bytes / 1024).ceil()} KB' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
