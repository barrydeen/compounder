import 'package:compounder/data/store.dart';
import 'package:compounder/services/rest_sounds.dart';
import 'package:compounder/ui/summary.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Summary celebration (owner request): finishing a workout lands on a summary
/// that bursts confetti and walks through each personal record, highlighting
/// and dinging it.
///
/// The walkthrough is opt-in ([SummaryScreen.celebrate]); browsing an old
/// session from history must stay quiet, so the default is asserted too.
class _FakeWorkoutSounds implements WorkoutSounds {
  final List<WorkoutCue> played = [];
  bool disposed = false;

  @override
  Future<void> play(WorkoutCue cue) async {
    played.add(cue);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  late AppStore store;
  late int workoutId;

  /// Seeds a finished session with [prCount] first-ever sets, so each one is a
  /// baseline personal record. No prior history means every exercise PRs.
  Future<void> seed({int prCount = 1, bool soundsEnabled = true}) async {
    SharedPreferences.setMockInitialValues({
      'restSoundsEnabled': soundsEnabled,
    });
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: inMemoryDatabasePath);
    workoutId = await store.db.insert('workouts', {
      'name': 'Leg day',
      'started_at': 1000,
      'ended_at': 2000,
    });
    for (var i = 0; i < prCount; i++) {
      final exerciseId = await store.db.insert('exercises', {
        'name': i == 0 ? 'Back squat' : 'Bench press',
        'muscle_group': i == 0 ? 'Legs' : 'Chest',
        'equipment': 'Barbell',
        'is_custom': 0,
      });
      final entryId = await store.db.insert('workout_exercises', {
        'workout_id': workoutId,
        'exercise_id': exerciseId,
        'position': i,
      });
      // Through the store so the persisted PR flags are computed exactly as
      // they are during a live workout.
      await store.addSet(entryId, 100.0, 5, completed: true);
    }
    await store.refreshAll();
  }

  tearDown(() async {
    await store.db.close();
  });

  Future<void> pumpSummary(WidgetTester tester, _FakeWorkoutSounds sounds,
      {bool celebrate = true}) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: CompounderTheme.dark(),
        home: SummaryScreen(workoutId, celebrate: celebrate, sounds: sounds),
      ),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump();
    expect(find.text('PERSONAL RECORDS'), findsOneWidget,
        reason: 'the seeded session must show its PR cards');
  }

  testWidgets('celebrating plays fanfare and a ding per PR, with confetti',
      (tester) async {
    await seed(prCount: 1);
    final sounds = _FakeWorkoutSounds();
    await pumpSummary(tester, sounds);

    final confetti = find.byKey(const ValueKey('summary-confetti'));
    expect(confetti, findsOneWidget);
    expect(find.descendant(of: confetti, matching: find.byType(CustomPaint)),
        findsOneWidget,
        reason: 'the burst paints while it runs');

    // Fanfare lands first, then the walkthrough dings the first card.
    await tester.pump(const Duration(milliseconds: 750));
    expect(sounds.played, [WorkoutCue.personalRecord, WorkoutCue.prDing]);
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget,
        reason: 'the active PR card is marked while its ding plays');

    // The highlight clears once the walk is over.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.byIcon(Icons.auto_awesome), findsNothing);

    // The burst ends and stops painting.
    await tester.pump(const Duration(seconds: 3));
    expect(find.descendant(of: confetti, matching: find.byType(CustomPaint)),
        findsNothing,
        reason: 'the confetti must stop instead of ticking forever');

    await tester.pumpWidget(const SizedBox.shrink());
    expect(sounds.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every personal record gets its own highlight and ding',
      (tester) async {
    await seed(prCount: 2);
    final sounds = _FakeWorkoutSounds();
    await pumpSummary(tester, sounds);

    await tester.pump(const Duration(milliseconds: 750));
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    expect(sounds.played.where((c) => c == WorkoutCue.prDing).length, 1,
        reason: 'the first record dings first');

    await tester.pump(const Duration(milliseconds: 1500));
    expect(sounds.played.where((c) => c == WorkoutCue.prDing).length, 2,
        reason: 'the walkthrough dings the second record too');
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget,
        reason: 'only one card is highlighted at a time');

    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.byIcon(Icons.auto_awesome), findsNothing,
        reason: 'the walkthrough ends after the last record');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the mute switch silences the celebration but keeps the visuals',
      (tester) async {
    await seed(prCount: 1, soundsEnabled: false);
    final sounds = _FakeWorkoutSounds();
    await pumpSummary(tester, sounds);

    await tester.pump(const Duration(milliseconds: 750));
    expect(sounds.played, isEmpty,
        reason: 'workout sounds are muted in Settings');
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget,
        reason: 'the visual walkthrough still runs when muted');
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('summary-confetti')),
            matching: find.byType(CustomPaint)),
        findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a summary opened from history does not celebrate',
      (tester) async {
    await seed(prCount: 1);
    final sounds = _FakeWorkoutSounds();
    await pumpSummary(tester, sounds, celebrate: false);

    expect(find.byKey(const ValueKey('summary-confetti')), findsNothing);
    await tester.pump(const Duration(milliseconds: 750));
    expect(sounds.played, isEmpty,
        reason: 'browsing an old session must stay quiet');
    expect(find.byIcon(Icons.auto_awesome), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
