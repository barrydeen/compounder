import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/store.dart';
import '../../domain/domain.dart';
import '../widgets.dart';

/// Weight units, the rest timer and workout sounds, reached from the Settings
/// menu.
class TrainingSettingsScreen extends StatelessWidget {
  const TrainingSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Training & units')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SectionHeader('Training'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Row(children: [
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Kilograms (kg)'),
                      selected: store.unit == WeightUnit.kg,
                      onSelected: (_) => store.setUnit(WeightUnit.kg),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ChoiceChip(
                      label: const Text('Pounds (lb)'),
                      selected: store.unit == WeightUnit.lb,
                      onSelected: (_) => store.setUnit(WeightUnit.lb),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                      child: Text(
                          'Default rest between sets: ${store.restSeconds}s',
                          style: t.bodyMedium)),
                  SizedBox(
                    width: 180,
                    child: Slider(
                      value: store.restSeconds.toDouble(),
                      max: 600,
                      divisions: 39,
                      label: '${store.restSeconds}s',
                      onChanged: (v) => store.setRestSeconds(v.round()),
                    ),
                  ),
                ]),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Workout sounds'),
                  subtitle: const Text(
                      'A quiet tick at 5 seconds left, a "go" tone when rest '
                      'ends, and a short fanfare when you set a personal '
                      'record.'),
                  value: store.restSoundsEnabled,
                  onChanged: (v) => store.setRestSoundsEnabled(v),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
