import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/store.dart';
import '../../services/notify.dart';
import '../widgets.dart';

/// Coach check-ins, wake-up and streak reminders, and pending reminders,
/// reached from the Settings menu.
class NotificationsSettingsScreen extends StatefulWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  State<NotificationsSettingsScreen> createState() =>
      _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState
    extends State<NotificationsSettingsScreen> {
  int? learnedWakeMinutes;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    context.read<NotifyService>().learnedWakeMinutes(store).then((value) {
      if (mounted) setState(() => learnedWakeMinutes = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final notify = context.read<NotifyService>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    void snack(String text) => ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));

    String clock(int minutes) =>
        '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SectionHeader('Daily coach'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Column(children: [
              SwitchListTile(
                title: const Text('A daily check-in'),
                subtitle: Text(
                    'A daily nudge on what\'s still open across training, food, mind, habits and your plan. Scheduled on this device — no Google services.'),
                value: store.coachEnabled,
                onChanged: (v) async {
                  await store.setCoach(enabled: v);
                  await notify.rescheduleDaily(store);
                },
              ),
              ListTile(
                title: const Text('Delivery time'),
                trailing: Text(clock(store.coachMinutes),
                    style: t.titleMedium?.copyWith(color: scheme.primary)),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                        hour: store.coachMinutes ~/ 60,
                        minute: store.coachMinutes % 60),
                  );
                  if (picked != null) {
                    await store.setCoach(
                        minutes: picked.hour * 60 + picked.minute);
                    await notify.rescheduleDaily(store);
                  }
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: OutlinedButton.icon(
                  icon:
                      const Icon(Icons.notifications_active_outlined, size: 18),
                  label: const Text('Send test notification'),
                  onPressed: () async {
                    await notify.testNotification(store);
                    if (context.mounted) snack('Coach notification sent');
                  },
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Morning planning reminder'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Column(children: [
              SwitchListTile(
                title: const Text('Plan your day when you wake up'),
                subtitle: const Text(
                    'A morning nudge to open the Planner, timed from your usual wake-up learned out of Health Connect sleep. Without enough sleep data it uses the fallback time below. Scheduled on this device.'),
                value: store.coachMorningEnabled,
                onChanged: (v) async {
                  await store.setCoachMorning(enabled: v);
                  await notify.rescheduleMorning(store);
                },
              ),
              ListTile(
                title: const Text('Fallback time'),
                subtitle:
                    const Text('Used until enough sleep nights are imported'),
                trailing: Text(clock(store.coachMorningFallbackMinutes),
                    style: t.titleMedium?.copyWith(color: scheme.primary)),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                        hour: store.coachMorningFallbackMinutes ~/ 60,
                        minute: store.coachMorningFallbackMinutes % 60),
                  );
                  if (picked != null) {
                    await store.setCoachMorning(
                        fallbackMinutes: picked.hour * 60 + picked.minute);
                    await notify.rescheduleMorning(store);
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.bedtime_outlined, size: 20),
                title: const Text('Usual wake-up'),
                trailing: Text(
                    learnedWakeMinutes == null
                        ? 'Not learned yet'
                        : clock(learnedWakeMinutes!),
                    style: t.titleMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.wb_sunny_outlined, size: 18),
                  label: const Text('Send test morning reminder'),
                  onPressed: () async {
                    await notify.testMorningNotification(store);
                    if (context.mounted) snack('Morning reminder sent');
                  },
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Streak rescue reminder'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Column(children: [
              SwitchListTile(
                title: const Text('Protect my streak'),
                subtitle: const Text(
                    'An evening nudge when nothing has been logged today and a streak is on the line — a meal, a mood check-in, a set or a habit tick keeps it alive. Withdrawn automatically once you log something. Scheduled on this device.'),
                value: store.coachStreakEnabled,
                onChanged: (v) async {
                  await store.setCoachStreak(enabled: v);
                  await notify.rescheduleStreak(store);
                },
              ),
              ListTile(
                title: const Text('Delivery time'),
                subtitle: const Text('When the streak is still unlogged'),
                trailing: Text(clock(store.coachStreakMinutes),
                    style: t.titleMedium?.copyWith(color: scheme.primary)),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                        hour: store.coachStreakMinutes ~/ 60,
                        minute: store.coachStreakMinutes % 60),
                  );
                  if (picked != null) {
                    await store.setCoachStreak(
                        minutes: picked.hour * 60 + picked.minute);
                    await notify.rescheduleStreak(store);
                  }
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.local_fire_department_outlined,
                      size: 18),
                  label: const Text('Send test streak reminder'),
                  onPressed: () async {
                    await notify.testStreakNotification(store);
                    if (context.mounted) snack('Streak reminder sent');
                  },
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          const SectionHeader('Reminders'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Column(children: [
              if (store.reminders.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                      'No pending reminders. Ask your coach to set one.',
                      style: TextStyle(fontSize: 13)),
                )
              else
                for (final r in store.reminders)
                  ListTile(
                    leading: const Icon(Icons.notifications_outlined),
                    title: Text(r.text),
                    subtitle: Text(formatDateTime(r.dueAt)),
                    trailing: IconButton(
                      icon: Icon(Icons.delete_outline, color: scheme.outline),
                      onPressed: () async {
                        await notify.cancelReminder(r.id);
                        await store.deleteReminder(r.id);
                      },
                    ),
                  ),
            ]),
          ),
        ],
      ),
    );
  }
}
