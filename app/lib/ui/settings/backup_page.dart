// 设置 › 通用 › 备份与恢复: one page for the two rows, so the hub keeps its
// six groups (docs/design/settings-ia.md §4.2) and the note under the rows has
// somewhere to live.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../shell/page_frame.dart';
import 'backup_section.dart';

class BackupPage extends StatelessWidget {
  const BackupPage({super.key});

  @override
  Widget build(BuildContext context) =>
      AppPage.list(title: context.l10n.backupDataTitle, children: const [BackupSettingsSection()]);
}
