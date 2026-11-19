import 'package:compounder/data/store.dart';
import 'package:compounder/services/rest_sounds.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:compounder/ui/workout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Live workout screen layout (owner requests):
///  * only one exercise card is open at a time — opening another collapses the
///    first, and a newly added exercise takes the open slot;
///  * the first exercise opens on load;
///  * the "Add exercise" button sits below the last exercise card;
///  * warm-up sets count toward the session volume, sets and reps totals.
class _FakeWorkoutSounds implements WorkoutSounds {
  @override
  Future<void> play(WorkoutCue cue) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  // No isolate: the widget test's fake-async zone cannot receive messages from
  // a background isolate, so DB futures would never complete.
  databaseFactory = databaseFactoryFfiNoIsolate;

  late AppStore store;
  late int workoutId;

  Future<int> seedExercise(String name, String group,
      {int position = 0}) async {
    final exerciseId = await store.db.insert('exercises', {
      'name': name,
      'muscle_group': group,
      'equipment': 'Barbell',
      'is_custom': 0,
    });
    final entryId = await store.db.insert('workout_exercises', {
      'workout_id': workoutId,
      'exercise_id': exerciseId,
      'position': position,
    });
    await store.db.insert('workout_sets', {
      'workout_exercise_id': entryId,
      'position': 0,
      'weight_kg': 100.0,
      'reps': 5,
      'completed_at': null,
      'is_warmup': 0,
    });
    return entryId;
  }

  Future<void> seed({bool secondExercise = true}) async {
    SharedPreferences.setMockInitialValues({
      'unit': 'kg',
      'restSeconds': 120,
      'restSoundsEnabled': true,
    });
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: inMemoryDatabasePath);
    workoutId = await store.db.insert('workouts', {
      'name': 'Leg day',
      'started_at': DateTime.now().millisecondsSinceEpoch,
      'ended_at': null,
    });
    await seedExercise('Back squat', 'Legs');
    if (secondExercise) {
      await seedExercise('Bench press', 'Chest', position: 1);
    }
    await store.refreshAll();
  }

  tearDown(() async {
    await store.db.close();
  });

  Future<void> pumpWorkout(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: CompounderTheme.dark(),
        home: WorkoutScreen(workoutId: workoutId, sounds: _FakeWorkoutSounds()),
      ),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Back squat'), findsOneWidget,
        reason:
            'the workout detail must be loaded before the layout tests run');
  }

  Finder cardOf(String exerciseName) =>
      find.ancestor(of: find.text(exerciseName), matching: find.byType(Card));

  Finder fieldsIn(String exerciseName) => find.descendant(
      of: cardOf(exerciseName), matching: find.byType(TextField));

  testWidgets('the first exercise opens and later cards start collapsed',
      (tester) async {
    await seed();
    await pumpWorkout(tester);

    expect(fieldsIn('Back squat'), findsNWidgets(2),
        reason: 'the first exercise opens on load (weight and reps fields)');
    expect(fieldsIn('Bench press'), findsNothing,
        reason: 'later exercises stay collapsed until tapped');
    expect(find.text('Add set'), findsOneWidget,
        reason: 'only the open card offers Add set');

    // The collapsed card still names the exercise and its logged work.
    expect(find.text('Chest · 0 sets · 0 reps'), findsOneWidget);
  });

  testWidgets('opening one card collapses the other', (tester) async {
    final semantics = tester.ensureSemantics();
    await seed();
    await pumpWorkout(tester);

    final expandBench = find.bySemanticsLabel('Expand sets for Bench press');
    expect(expandBench, findsOneWidget);
    await tester.ensureVisible(expandBench);
    await tester.pump();
    await tester.tap(expandBench);
    await tester.pumpAndSettle();

    expect(fieldsIn('Bench press'), findsNWidgets(2),
        reason: 'the tapped exercise opens');
    expect(fieldsIn('Back squat'), findsNothing,
        reason: 'only one card may be open at a time');
    expect(
        find.bySemanticsLabel('Collapse sets for Bench press'), findsOneWidget);

    // Tapping the open card again closes it; the list can be all-collapsed.
    await tester.tap(find.bySemanticsLabel('Collapse sets for Bench press'));
    await tester.pumpAndSettle();
    expect(fieldsIn('Bench press'), findsNothing,
        reason: 'the open card collapses when tapped again');
    expect(find.text('Add set'), findsNothing);

    semantics.dispose();
  });

  testWidgets('adding an exercise opens it and collapses the previous card',
      (tester) async {
    await seed(secondExercise: false);
    // Available in the library but not yet in this workout.
    await store.db.insert('exercises', {
      'name': 'Bench press',
      'muscle_group': 'Chest',
      'equipment': 'Barbell',
      'is_custom': 0,
    });
    await store.refreshAll();
    await pumpWorkout(tester);
    expect(fieldsIn('Back squat'), findsNWidgets(2));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Add exercise'));
    await tester.pumpAndSettle();

    // The picker lists the exercise twice ("Most used" and its group), so pick
    // the first match.
    final benchTile = find.widgetWithText(ListTile, 'Bench press').first;
    await tester.ensureVisible(benchTile);
    await tester.pumpAndSettle();
    await tester.tap(benchTile);
    await tester.pump();
    // The store insert and the detail reload hit sqflite_common_ffi, which
    // needs real async time.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(find.text('Bench press'), findsOneWidget,
        reason: 'the picked exercise is added to the workout');
    expect(fieldsIn('Bench press'), findsNWidgets(2),
        reason: 'the new exercise opens');
    expect(fieldsIn('Back squat'), findsNothing,
        reason: 'adding an exercise collapses the previously open card');
  });

  testWidgets('the Add exercise button sits below the last exercise card',
      (tester) async {
    await seed();
    await pumpWorkout(tester);

    final button = find.widgetWithText(OutlinedButton, 'Add exercise');
    expect(button, findsOneWidget);
    final buttonTop = tester.getTopLeft(button).dy;
    final lastCardBottom = tester.getBottomLeft(cardOf('Bench press')).dy;
    expect(buttonTop, greaterThan(lastCardBottom),
        reason: 'the Add exercise button belongs under the latest card');
  });

  testWidgets('the list clears the Android navigation bar at the bottom',
      (tester) async {
    await seed(secondExercise: false);
    // Three-button navigation is ~72dp tall and, in edge-to-edge mode, is drawn
    // over the app's body.
    tester.view.padding = const FakeViewPadding(bottom: 72);
    addTearDown(tester.view.resetPadding);
    await pumpWorkout(tester);

    final list = tester.widget<ListView>(find.byType(ListView));
    expect((list.padding as EdgeInsets).bottom, 20 + 72,
        reason: 'the Add exercise button must scroll above the system bar, '
            'not sit underneath it');
  });

  testWidgets('warm-up sets count toward the session volume and rep totals',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'unit': 'kg',
      'restSeconds': 120,
      'restSoundsEnabled': true,
    });
    store = await AppStore.open(await SharedPreferences.getInstance(),
        path: inMemoryDatabasePath);
    workoutId = await store.db.insert('workouts', {
      'name': 'Leg day',
      'started_at': DateTime.now().millisecondsSinceEpoch,
      'ended_at': null,
    });
    final entryId = await seedExercise('Back squat', 'Legs');
    // A completed working set and a completed warm-up set.
    await store.db.update('workout_sets', {'completed_at': 1234},
        where: 'workout_exercise_id = ? AND position = 0',
        whereArgs: [entryId]);
    await store.db.insert('workout_sets', {
      'workout_exercise_id': entryId,
      'position': 1,
      'weight_kg': 60.0,
      'reps': 8,
      'completed_at': 4321,
      'is_warmup': 1,
    });
    await store.refreshAll();
    await pumpWorkout(tester);

    // 100x5 working + 60x8 warm-up = 980 kg over 2 sets and 13 reps.
    StatCard card(String label) => tester.widget<StatCard>(
        find.byWidgetPredicate((w) => w is StatCard && w.label == label));
    expect(card('Volume (kg)').value, '980',
        reason: 'work-up sets contribute to the session total');
    expect(card('Sets · reps').value, '2 · 13',
        reason: 'work-up sets count as sets and reps in the session total');
  });
}
