import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../health/categories.dart';
import '../../health/service.dart';
import '../health.dart';
import '../widgets.dart';

/// Health Connect connection, categories and import controls, reached from the
/// Settings menu.
class HealthConnectSettingsScreen extends StatefulWidget {
  const HealthConnectSettingsScreen({super.key});

  @override
  State<HealthConnectSettingsScreen> createState() =>
      _HealthConnectSettingsScreenState();
}

class _HealthConnectSettingsScreenState
    extends State<HealthConnectSettingsScreen> {
  late Set<HealthCategory> healthCategories;
  late bool healthAutoSync;
  late bool healthHistory;
  HealthAvailability? healthAvailability;
  bool healthBusy = false;

  @override
  void initState() {
    super.initState();
    final health = context.read<HealthService>();
    healthCategories = {...health.categories};
    healthAutoSync = health.autoSync;
    healthHistory = health.historyRequested;
    health.availability().then((value) {
      if (mounted) setState(() => healthAvailability = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final health = context.watch<HealthService>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    void snack(String text) => ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));

    return Scaffold(
      appBar: AppBar(title: const Text('Health Connect')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SectionHeader('Health data (Android)'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Read sleep, heart rate, activity, body and vitals from Google Health Connect. '
                      'The data stays in the local database; only the summaries you ask the coach about '
                      'are sent to your AI endpoint.',
                      style: t.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      switch (healthAvailability) {
                        null => 'Checking Health Connect…',
                        HealthAvailability.unsupported =>
                          'Health Connect is not available on this device.',
                        HealthAvailability.installRequired =>
                          'Health Connect needs to be installed or updated.',
                        HealthAvailability.available =>
                          'Health Connect is available.',
                      },
                      style: t.bodySmall,
                    ),
                    if (healthAvailability ==
                        HealthAvailability.installRequired) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: healthBusy
                            ? null
                            : () async {
                                await health.installHealthConnect();
                                final value = await health.availability();
                                if (mounted) {
                                  setState(() => healthAvailability = value);
                                }
                              },
                        icon: const Icon(Icons.download),
                        label: const Text('Install Health Connect'),
                      ),
                    ],
                    const SizedBox(height: 12),
                    for (final category in HealthCategory.values)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: healthCategories.contains(category),
                        title: Text(category.label),
                        subtitle: Text(category.description),
                        onChanged: healthBusy
                            ? null
                            : (value) async {
                                setState(() {
                                  if (value == true) {
                                    healthCategories.add(category);
                                  } else {
                                    healthCategories.remove(category);
                                  }
                                });
                                await health.saveCategories(healthCategories);
                              },
                      ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Import full history'),
                      subtitle: const Text(
                          'Ask Health Connect for data older than 30 days.'),
                      value: healthHistory,
                      onChanged: healthBusy
                          ? null
                          : (value) async {
                              setState(() => healthHistory = value);
                              if (value && health.enabled) {
                                try {
                                  await health.requestHistoryAccess();
                                  if (context.mounted) {
                                    snack('Full history access granted');
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    setState(() => healthHistory = false);
                                  }
                                  await health.setHistoryRequested(false);
                                  if (context.mounted) snack(e.toString());
                                }
                              } else if (!value) {
                                await health.setHistoryRequested(false);
                              }
                            },
                    ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Sync when the app opens'),
                      subtitle: const Text(
                          'No background worker; syncs on launch/resume and on demand.'),
                      value: healthAutoSync,
                      onChanged: healthBusy
                          ? null
                          : (value) async {
                              setState(() => healthAutoSync = value);
                              await health.setAutoSync(value);
                            },
                    ),
                    const SizedBox(height: 8),
                    if (!health.enabled)
                      FilledButton.icon(
                        onPressed: healthBusy ||
                                healthAvailability !=
                                    HealthAvailability.available
                            ? null
                            : () async {
                                setState(() => healthBusy = true);
                                try {
                                  await health.connect(
                                    categories: healthCategories,
                                    requestHistory: healthHistory,
                                  );
                                  if (context.mounted) {
                                    snack('Health Connect connected');
                                  }
                                } catch (e) {
                                  if (context.mounted) snack(e.toString());
                                } finally {
                                  if (mounted) {
                                    setState(() => healthBusy = false);
                                  }
                                }
                              },
                        icon: const Icon(Icons.link),
                        label: const Text('Connect Health Connect'),
                      )
                    else ...[
                      FutureBuilder<DateTime?>(
                        future: health.repository.lastSync(),
                        builder: (context, snapshot) => Text(
                          snapshot.data == null
                              ? 'Not synced yet.'
                              : 'Last sync: ${formatDateTime(snapshot.data!.millisecondsSinceEpoch)}',
                          style: t.bodySmall,
                        ),
                      ),
                      if (health.lastError != null) ...[
                        const SizedBox(height: 4),
                        Text(health.lastError!,
                            style: t.bodySmall?.copyWith(color: scheme.error)),
                      ],
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        FilledButton.icon(
                          onPressed: healthBusy || health.syncing
                              ? null
                              : () async {
                                  setState(() => healthBusy = true);
                                  try {
                                    final result = await health.syncNow();
                                    if (context.mounted) {
                                      snack(result.ok
                                          ? 'Synced ${result.records} health records'
                                          : 'Synced with ${result.errors.length} error(s)');
                                    }
                                  } catch (e) {
                                    if (context.mounted) snack(e.toString());
                                  } finally {
                                    if (mounted) {
                                      setState(() => healthBusy = false);
                                    }
                                  }
                                },
                          icon: const Icon(Icons.sync),
                          label: const Text('Sync now'),
                        ),
                        OutlinedButton.icon(
                          onPressed: healthBusy
                              ? null
                              : () async {
                                  setState(() => healthBusy = true);
                                  try {
                                    await health.connect(
                                      categories: healthCategories,
                                      requestHistory: healthHistory,
                                    );
                                    if (context.mounted) {
                                      snack('Health permissions updated');
                                    }
                                  } catch (e) {
                                    if (context.mounted) snack(e.toString());
                                  } finally {
                                    if (mounted) {
                                      setState(() => healthBusy = false);
                                    }
                                  }
                                },
                          icon: const Icon(Icons.lock_open),
                          label: const Text('Update permissions'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const HealthDataScreen())),
                          icon: const Icon(Icons.monitor_heart),
                          label: const Text('View data'),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        TextButton.icon(
                          onPressed: healthBusy
                              ? null
                              : () async {
                                  await health.disconnect();
                                  if (context.mounted) {
                                    snack(health.lastError ??
                                        'Health Connect disconnected');
                                  }
                                },
                          icon: const Icon(Icons.link_off),
                          label: const Text('Disconnect'),
                        ),
                        TextButton.icon(
                          onPressed: healthBusy
                              ? null
                              : () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text(
                                          'Delete imported health data?'),
                                      content: const Text(
                                          'This removes every Health Connect record imported into Compounder. '
                                          'Your Health Connect data is not affected.'),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: const Text('Cancel')),
                                        FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: const Text('Delete')),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    await health.deleteAllData();
                                    if (context.mounted) {
                                      snack('Imported health data deleted');
                                    }
                                  }
                                },
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete imported data'),
                        ),
                      ]),
                    ],
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const HealthRationaleScreen())),
                      icon: const Icon(Icons.privacy_tip_outlined),
                      label: const Text('How health data is used'),
                    ),
                  ]),
            ),
          ),
        ],
      ),
    );
  }
}
