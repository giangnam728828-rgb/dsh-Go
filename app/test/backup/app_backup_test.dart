import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dsh_app/backup/app_backup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A phone-shaped store: the app support folder and the engine's user home,
/// both under one temporary directory.
late Directory _temp;
late Directory _support;
late Directory _home;
late SharedPreferences _prefs;

/// The system key store, in memory: model API keys and account tokens.
late Map<String, String> _secrets;

AppBackupStore _store({
  Future<Map<String, String>> Function()? readSecrets,
  Future<void> Function(String key, String value)? writeSecret,
}) => AppBackupStore(
  support: () async => _support,
  engineHome: () async => _home,
  preferences: () async => _prefs,
  readSecrets: readSecrets ?? () async => Map.of(_secrets),
  writeSecret: writeSecret ?? (key, value) async => _secrets[key] = value,
  deleteSecret: (key) async => _secrets.remove(key),
  now: () => DateTime.utc(2026, 11, 18, 9, 30),
);

void _write(String path, String text) {
  final file = File('${_temp.path}/$path');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text);
}

String _read(String path) => File('${_temp.path}/$path').readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _temp = await Directory.systemTemp.createTemp('app-backup-test-');
    _support = Directory('${_temp.path}/support');
    _home = Directory('${_temp.path}/root');
    _write('support/tavern/characters/a.json', '{"name":"A"}');
    _write('support/tavern/backgrounds/b.png', 'png');
    _write('root/.dsh/sessions/s1.jsonl', '{"turn":1}');
    _write('root/.dsh/dsh-go/ui.json', '{}');
    _write('root/.agents/skills/x/SKILL.md', '# x');
    _write('root/workspace/notes.txt', 'original');
    // A download and a log: neither is user data, both stay out of the ZIP.
    _write('root/.dsh/speech-to-text/model.bin', 'model');
    _write('root/.dsh/logs/app.log', 'log');
    SharedPreferences.setMockInitialValues({'keep': 'yes', 'count': 3});
    _prefs = await SharedPreferences.getInstance();
    _secrets = {'provider.anthropic': 'sk-ant-1', 'tavern.channel.a': 'tv-1'};
  });

  tearDown(() async {
    if (await _temp.exists()) await _temp.delete(recursive: true);
  });

  test('backup then restore returns every file, preference and API key', () async {
    final archive = '${_temp.path}/out/backup.zip';
    final info = await _store().backup(archive);
    expect(info.fileCount, 6);
    expect(info.skippedLinks, 0);
    expect(info.secretCount, 2);
    expect(info.secretsSaved, isTrue);
    expect(File(archive).existsSync(), isTrue);

    // What the person does between the backup and the restore.
    _write('root/workspace/notes.txt', 'changed');
    _write('root/.dsh/sessions/s2.jsonl', '{"turn":2}');
    File('${_support.path}/tavern/characters/a.json').deleteSync();
    await _prefs.setString('keep', 'no');
    await _prefs.setBool('extra', true);
    _secrets['provider.anthropic'] = 'sk-changed';
    _secrets.remove('tavern.channel.a');

    final restored = await _store().restore(archive);
    expect(restored.fileCount, 6);
    expect(_read('root/workspace/notes.txt'), 'original');
    expect(_read('support/tavern/characters/a.json'), '{"name":"A"}');
    expect(File('${_home.path}/.dsh/sessions/s2.jsonl').existsSync(), isFalse);
    expect(_prefs.getString('keep'), 'yes');
    expect(_prefs.getInt('count'), 3);
    expect(_prefs.getBool('extra'), isNull);
    // The model key and the channel token come back with the chats.
    expect(_secrets, {'provider.anthropic': 'sk-ant-1', 'tavern.channel.a': 'tv-1'});
    // A folder the archive leaves out was carried over, not deleted.
    expect(_read('root/.dsh/speech-to-text/model.bin'), 'model');
  });

  test('relative links inside a root are recreated; links leaving it are not', () async {
    Link('${_home.path}/workspace/note-link').createSync('notes.txt');
    Link('${_home.path}/workspace/outside').createSync('/etc/hostname');
    final archive = '${_temp.path}/out/backup.zip';
    final info = await _store().backup(archive);
    expect(info.skippedLinks, 1);

    await File('${_home.path}/workspace/notes.txt').delete();
    await Link('${_home.path}/workspace/note-link').delete();
    await _store().restore(archive);

    expect(Link('${_home.path}/workspace/note-link').existsSync(), isTrue);
    expect(File('${_home.path}/workspace/note-link').readAsStringSync(), 'original');
    expect(Link('${_home.path}/workspace/outside').existsSync(), isFalse);
  });

  test('a key store that cannot be read costs the keys, not the chats', () async {
    final archive = '${_temp.path}/out/backup.zip';
    final info = await _store(readSecrets: () async => throw StateError('keystore unavailable')).backup(archive);
    expect(info.secretsSaved, isFalse);
    expect(info.secretCount, 0);
    expect(info.fileCount, 6);

    // Restoring such a backup must not blank the keys already on the phone.
    _secrets['provider.anthropic'] = 'sk-live';
    _write('root/workspace/notes.txt', 'live');
    await _store().restore(archive);
    expect(_secrets['provider.anthropic'], 'sk-live');
    expect(_secrets['tavern.channel.a'], 'tv-1');
    expect(_read('root/workspace/notes.txt'), 'original');
  });

  test('a failed credential write puts files, settings and keys back', () async {
    final archive = '${_temp.path}/out/backup.zip';
    await _store().backup(archive);

    _write('root/workspace/notes.txt', 'live');
    await _prefs.setString('keep', 'no');
    _secrets['provider.anthropic'] = 'sk-live';

    // The first key is written, the second fails: both must end up as they were.
    final restoration = _store(
      writeSecret: (key, value) async {
        if (key == 'tavern.channel.a') throw StateError('keystore full');
        _secrets[key] = value;
      },
    );
    await expectLater(restoration.restore(archive), throwsA(isA<StateError>()));

    expect(_read('root/workspace/notes.txt'), 'live');
    expect(_prefs.getString('keep'), 'no');
    expect(_secrets['provider.anthropic'], 'sk-live');
    expect(_secrets['tavern.channel.a'], 'tv-1');
  });

  test('a damaged archive changes nothing', () async {
    final archive = '${_temp.path}/out/backup.zip';
    await _store().backup(archive);

    // Rebuild the same archive with one file's bytes changed but the manifest
    // still naming the original checksum: the checksum is what must catch it.
    final input = InputFileStream(archive);
    final source = ZipDecoder().decodeStream(input);
    final output = OutputFileStream('${_temp.path}/out/tampered.zip');
    final encoder = ZipFileEncoder();
    encoder.createWithStream(output);
    for (final entry in source) {
      if (entry.name == 'data/engine/workspace/notes.txt') {
        encoder.addArchiveFile(ArchiveFile.bytes(entry.name, utf8.encode('tampered')));
      } else if (entry.isFile) {
        encoder.addArchiveFile(ArchiveFile.bytes(entry.name, entry.readBytes() ?? const []));
      } else {
        encoder.addArchiveFile(ArchiveFile.directory(entry.name));
      }
    }
    await encoder.close();
    await input.close();

    _write('root/workspace/notes.txt', 'live');
    _secrets['provider.anthropic'] = 'sk-live';
    await expectLater(_store().restore('${_temp.path}/out/tampered.zip'), throwsA(isA<Object>()));
    expect(_read('root/workspace/notes.txt'), 'live');
    expect(_prefs.getString('keep'), 'yes');
    expect(_secrets['provider.anthropic'], 'sk-live');
  });

  test('an existing destination is never overwritten', () async {
    final archive = '${_temp.path}/out/backup.zip';
    await _store().backup(archive);
    await expectLater(_store().backup(archive), throwsA(isA<FileSystemException>()));
  });

  test('a partial backup restores only the selected directories', () async {
    final archive = '${_temp.path}/out/partial.zip';
    final info = await _store().backup(
      archive,
      selection: const BackupSelection(roots: {'engine/workspace'}, settings: true, secrets: false),
    );
    expect(info.fileCount, 1);

    // Change everything, then restore the workspace-only backup.
    _write('root/workspace/notes.txt', 'changed');
    _write('root/.dsh/sessions/s2.jsonl', '{"turn":2}');
    _write('support/tavern/characters/a.json', '{"name":"changed"}');
    await _prefs.setString('keep', 'no');
    _secrets['provider.anthropic'] = 'sk-live';

    await _store().restore(archive);

    expect(_read('root/workspace/notes.txt'), 'original');
    // What the backup did not hold is left exactly as it was.
    expect(_read('root/.dsh/sessions/s2.jsonl'), '{"turn":2}');
    expect(_read('support/tavern/characters/a.json'), '{"name":"changed"}');
    expect(_prefs.getString('keep'), 'yes');
    expect(_secrets['provider.anthropic'], 'sk-live');
  });

  test('leaving settings out keeps the settings already on the phone', () async {
    final archive = '${_temp.path}/out/no-settings.zip';
    await _store().backup(
      archive,
      selection: const BackupSelection(roots: {'engine/workspace'}, settings: false, secrets: false),
    );

    await _prefs.setString('keep', 'no');
    await _prefs.setBool('extra', true);

    await _store().restore(archive);

    expect(_prefs.getString('keep'), 'no');
    expect(_prefs.getBool('extra'), isTrue);
  });

  test('the file name and size read the way people expect', () {
    expect(appBackupName(DateTime(2026, 1, 2, 3, 4, 5)), 'dshgo-backup-20260102-030405.zip');
    expect(appBackupSize(2048), '2 KB');
    expect(appBackupSize(3 * 1024 * 1024), '3.0 MB');
  });
}
