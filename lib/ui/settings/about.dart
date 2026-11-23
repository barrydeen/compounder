import 'package:flutter/material.dart';

import '../widgets.dart';
import 'shared.dart';

/// Version and licence information, reached from the Settings menu.
class AboutSettingsScreen extends StatelessWidget {
  const AboutSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SectionHeader('About'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                const CompounderLogo(size: 64),
                const SizedBox(height: 12),
                Text(appVersionLabel, style: t.titleMedium),
                const SizedBox(height: 4),
                Text('MIT · Open source, no tracking, no ads.',
                    style:
                        t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(
                    'Your workouts, meals, health data and notes stay in a '
                    'local database on this device. Nothing is uploaded '
                    'unless you use the AI coach.',
                    style:
                        t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    textAlign: TextAlign.center),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
