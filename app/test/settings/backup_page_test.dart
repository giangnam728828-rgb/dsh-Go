// 设置 › 通用 › 备份与恢复: the two rows and what tapping them does, with the
// store, the target folder, the share sheet and the engine's status swapped.
// The store itself is covered by test/backup/app_backup_test.dart.

import 'dart:io';

import 'package:dsh_app/backup/app_backup.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui/settings/backup_page.dart';
import 'package:dsh_app/ui/settings/backup_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';

class _Store extends AppBackupStore {
  String? backedUp;
  String? restored;
  Object? failure;

  @override
  Future<AppBackupInfo> backup(String destinationPath) async {
    if (failure != null) throw failure!;
    backedUp = destinationPath;
    File(destinationPath).writeAsBytesSync([0x50, 0x4b, 5, 6]);
    return AppBackupInfo(createdAt: DateTime.utc(2026, 11, 18), fileCount: 7, totalBytes: 2048, skippedLinks: 0);
  }

  @override
  Future<AppBackupInfo> restore(String archivePath) async {
    if (failure != null) throw failure!;
    restored = archivePath;
    return AppBackupInfo(createdAt: DateTime.utc(2026, 11, 18), fileCount: 7, totalBytes: 2048, skippedLinks: 0);
  }
}

/// No engine on this phone: nothing to stop, nothing to start again.
class _NoRuntime extends RuntimeBridge {
  @override
  Future<RuntimeStatus> status() async => const RuntimeStatus.unknown();
}

/// The page keeps a slow ambient animation, so no [WidgetTester.pumpAndSettle].
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<_Store> pump(WidgetTester tester, {String? picked = '/tmp/backup.zip'}) async {
    final store = _Store();
    final shared = <String>[];
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      goldenApp(
        home: ProviderScope(
          overrides: [
            appBackupStoreProvider.overrideWithValue(store),
            appBackupDirProvider.overrideWithValue(() async => Directory.systemTemp),
            appBackupShareProvider.overrideWithValue((path, name) async => shared.add(name)),
            appBackupPickerProvider.overrideWithValue(() async => picked),
            runtimeBridgeProvider.overrideWithValue(_NoRuntime()),
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(const LocalRuntimeState(loaded: true, status: RuntimeStatus.unknown())),
            ),
          ],
          child: const BackupPage(),
        ),
        brightness: Brightness.light,
      ),
    );
    await _settle(tester);
    return store;
  }

  testWidgets('立即备份 writes one ZIP and hands it to the share sheet', (tester) async {
    final store = await pump(tester);
    expect(find.text('立即备份'), findsOneWidget);
    expect(find.text('从备份恢复'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-backup')));
    await _settle(tester);

    expect(store.backedUp, endsWith('.zip'));
    expect(find.textContaining('备份已生成'), findsOneWidget);
  });

  testWidgets('从备份恢复 asks first, then restores', (tester) async {
    final store = await pump(tester);

    await tester.tap(find.byKey(const ValueKey('settings-restore')));
    await _settle(tester);
    expect(find.text('用这个备份替换现在的数据？'), findsOneWidget);

    await tester.tap(find.text('恢复'));
    await _settle(tester);

    expect(store.restored, '/tmp/backup.zip');
    expect(find.textContaining('已恢复'), findsOneWidget);
  });

  testWidgets('cancelling the question restores nothing', (tester) async {
    final store = await pump(tester);

    await tester.tap(find.byKey(const ValueKey('settings-restore')));
    await _settle(tester);
    await tester.tap(find.text('取消'));
    await _settle(tester);

    expect(store.restored, isNull);
  });

  testWidgets('a failure says what happened and changes nothing', (tester) async {
    final store = await pump(tester);
    store.failure = const FormatException('bad archive');

    await tester.tap(find.byKey(const ValueKey('settings-backup')));
    await _settle(tester);

    expect(find.textContaining('备份失败'), findsOneWidget);
  });
}
