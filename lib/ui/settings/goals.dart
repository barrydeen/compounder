import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/store.dart';
import '../widgets.dart';
import 'shared.dart';

/// Calorie and macro targets, reached from the Settings menu.
class GoalsSettingsScreen extends StatefulWidget {
  const GoalsSettingsScreen({super.key});

  @override
  State<GoalsSettingsScreen> createState() => _GoalsSettingsScreenState();
}

class _GoalsSettingsScreenState extends State<GoalsSettingsScreen> {
  late final TextEditingController goalCal;
  late final TextEditingController goalProtein;
  late final TextEditingController goalCarbs;
  late final TextEditingController goalFat;

  @override
  void initState() {
    super.initState();
    final goals = context.read<AppStore>().goals;
    goalCal = TextEditingController(text: goals.calories.round().toString());
    goalProtein = TextEditingController(text: goals.protein.round().toString());
    goalCarbs = TextEditingController(text: goals.carbs.round().toString());
    goalFat = TextEditingController(text: goals.fat.round().toString());
  }

  @override
  void dispose() {
    for (final c in [goalCal, goalProtein, goalCarbs, goalFat]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;

    void snack(String text) => ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));

    return Scaffold(
      appBar: AppBar(title: const Text('Daily goals')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SectionHeader('Daily goals'),
          const SizedBox(height: 8),
          Card(
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: goalCal,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'kcal'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: goalProtein,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Protein g'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: goalCarbs,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Carbs g'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: TextField(
                          controller: goalFat,
                          keyboardType: TextInputType.number,
                          decoration:
                              const InputDecoration(labelText: 'Fat g'))),
                ]),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    final current = store.goals;
                    await store.saveGoals(MacroGoals(
                      calories: parseGoal(goalCal.text) ?? current.calories,
                      protein: parseGoal(goalProtein.text) ?? current.protein,
                      carbs: parseGoal(goalCarbs.text) ?? current.carbs,
                      fat: parseGoal(goalFat.text) ?? current.fat,
                    ));
                    if (context.mounted) snack('Goals saved');
                  },
                  child: const Text('Save goals'),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
