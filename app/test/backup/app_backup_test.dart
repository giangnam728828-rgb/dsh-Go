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

AppBackupStore _store() => AppBackupStore(
  support: () async => _support,
  engineHome: () async => _home,
  preferences: () async => _prefs,
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
  });

  tearDown(() async {
    if (await _temp.exists()) await _temp.delete(recursive: true);
  });

  test('backup then restore returns every file and preference', () async {
    final archive = '${_temp.path}/out/backup.zip';
    final info = await _store().backup(archive);
    expect(info.fileCount, 6);
    expect(info.skippedLinks, 0);
    expect(File(archive).existsSync(), isTrue);

    // What the person does between the backup and the restore.
    _write('root/workspace/notes.txt', 'changed');
    _write('root/.dsh/sessions/s2.jsonl', '{"turn":2}');
    File('${_support.path}/tavern/characters/a.json').deleteSync();
    await _prefs.setString('keep', 'no');
    await _prefs.setBool('extra', true);

    final restored = await _store().restore(archive);
    expect(restored.fileCount, 6);
    expect(_read('root/workspace/notes.txt'), 'original');
    expect(_read('support/tavern/characters/a.json'), '{"name":"A"}');
    expect(File('${_home.path}/.dsh/sessions/s2.jsonl').existsSync(), isFalse);
    expect(_prefs.getString('keep'), 'yes');
    expect(_prefs.getInt('count'), 3);
    expect(_prefs.getBool('extra'), isNull);
    // A folder the archive leaves out was carried over, not deleted.
    expect(_read('root/.dsh/speech-to-text/model.bin'), 'model');
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
    await expectLater(_store().restore('${_temp.path}/out/tampered.zip'), throwsA(isA<Object>()));
    expect(_read('root/workspace/notes.txt'), 'live');
    expect(_prefs.getString('keep'), 'yes');
  });

  test('an existing destination is never overwritten', () async {
    final archive = '${_temp.path}/out/backup.zip';
    await _store().backup(archive);
    await expectLater(_store().backup(archive), throwsA(isA<FileSystemException>()));
  });

  test('the file name and size read the way people expect', () {
    expect(appBackupName(DateTime(2026, 1, 2, 3, 4, 5)), 'dshgo-backup-20260102-030405.zip');
    expect(appBackupSize(2048), '2 KB');
    expect(appBackupSize(3 * 1024 * 1024), '3.0 MB');
  });
}
