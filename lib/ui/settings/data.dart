import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/store.dart';
import '../../services/backup.dart';
import '../../services/notify.dart';
import '../widgets.dart';
import 'shared.dart';

/// Local backup export and import, reached from the Settings menu.
class DataSettingsScreen extends StatelessWidget {
  const DataSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final notify = context.read<NotifyService>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    void snack(String text) => ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));

    return Scaffold(
      appBar: AppBar(title: const Text('Your data')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SectionHeader('Your data'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Text(
                    'Everything lives on this device. Export one JSON backup, or restore from one.',
                    style:
                        t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Export backup'),
                  onPressed: () async {
                    try {
                      final path = await BackupService.export(store);
                      await SharePlus.instance.share(ShareParams(
                          files: [XFile(path)], subject: 'Compounder backup'));
                    } catch (e) {
                      snack('Export failed: $e');
                    }
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('Import backup (replaces local data)'),
                  onPressed: () async {
                    final picked = await FilePicker.pickFile(
                        type: FileType.custom, allowedExtensions: ['json']);
                    final path = picked?.path;
                    if (path == null || !context.mounted) return;
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Import backup?'),
                        content: const Text(importConfirmText),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel')),
                          FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Import')),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    try {
                      await BackupService.import(store, path);
                      // Restored reminders carry no OS notification; schedule
                      // them now so they actually fire (audit backup MINOR-4).
                      // Imported sleep records also change the learned wake-up
                      // time, so refresh that reminder too.
                      await notify.rescheduleReminders(store);
                      await notify.rescheduleMorning(store);
                      if (context.mounted) snack('Backup imported');
                    } on BackupException catch (e) {
                      // Already user-facing copy; never prefix it with a raw
                      // exception type.
                      if (context.mounted) snack(e.message);
                    } catch (e) {
                      if (context.mounted) snack('Import failed: $e');
                    }
                  },
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
