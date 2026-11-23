import 'package:flutter/material.dart';

import 'settings/about.dart';
import 'settings/ai.dart';
import 'settings/data.dart';
import 'settings/goals.dart';
import 'settings/health.dart';
import 'settings/notifications.dart';
import 'settings/training.dart';
import 'widgets.dart';

// Re-exported so existing imports of `ui/settings.dart` keep resolving the
// constants and helpers tests pin (version label, import copy, goal parsing).
export 'settings/shared.dart';

/// Settings hub. Each category opens its own page so the screen is a short,
/// scannable menu instead of one long scroll of every control.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void open(Widget page) =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          CardRow(
            icon: Icons.smart_toy_outlined,
            title: 'AI & coaching',
            subtitle: 'Compounder AI subscription or your own endpoint',
            onTap: () => open(const AiSettingsScreen()),
          ),
          const SizedBox(height: 8),
          CardRow(
            icon: Icons.notifications_outlined,
            title: 'Notifications',
            subtitle:
                'Daily check-in, wake-up plan, streak rescue and reminders',
            onTap: () => open(const NotificationsSettingsScreen()),
          ),
          const SizedBox(height: 8),
          CardRow(
            icon: Icons.monitor_heart_outlined,
            title: 'Health Connect',
            subtitle: 'Import sleep, heart rate, activity and body data',
            onTap: () => open(const HealthConnectSettingsScreen()),
          ),
          const SizedBox(height: 8),
          CardRow(
            icon: Icons.fitness_center,
            title: 'Units & training',
            subtitle: 'Weight units (kg or lb), rest timer and workout sounds',
            onTap: () => open(const TrainingSettingsScreen()),
          ),
          const SizedBox(height: 8),
          CardRow(
            icon: Icons.restaurant_outlined,
            title: 'Daily goals',
            subtitle: 'Calorie and macro targets',
            onTap: () => open(const GoalsSettingsScreen()),
          ),
          const SizedBox(height: 8),
          CardRow(
            icon: Icons.folder_outlined,
            title: 'Your data',
            subtitle: 'Export or import a local backup',
            onTap: () => open(const DataSettingsScreen()),
          ),
          const SizedBox(height: 8),
          CardRow(
            icon: Icons.info_outline,
            title: 'About',
            subtitle: 'Version, licence and privacy',
            onTap: () => open(const AboutSettingsScreen()),
          ),
        ],
      ),
    );
  }
}
