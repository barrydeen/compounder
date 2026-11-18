import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/services/notify.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Guards the revamped daily check-in.
///
/// 1. The notification must be expandable: Android gets a
///    [BigTextStyleInformation] carrying the full body, so pulling it down in
///    the shade shows everything instead of the truncated collapsed preview.
/// 2. The message must lead with what is still open and end with a concrete
///    action. It must not be a summary of totals the user already knows.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppStore store;
  late String path;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    path = '${await databaseFactory.getDatabasesPath()}/'
        'compounder_coach_checkin_test.db';
    await databaseFactory.deleteDatabase(path);
    store = await AppStore.open(prefs, path: path);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(path);
  });

  Future<void> seedWorkout(DateTime at) async {
    await store.db.insert('workouts', {
      'name': 'Push day',
      'started_at': at.millisecondsSinceEpoch,
      'ended_at': at.millisecondsSinceEpoch + 3600000,
    });
    await store.refreshAll();
  }

  Future<void> seedMeal(
    DateTime at, {
    double protein = 20,
    double calories = 400,
  }) async {
    await store.addMeal(
      Meal(
        id: 0,
        timestamp: at.millisecondsSinceEpoch,
        imagePath: '',
        dish: 'Test meal',
        calories: calories,
        protein: protein,
        carbs: 40,
        fat: 10,
      ),
    );
  }

  test('BigText carries the full body so the notification can be expanded', () {
    const body = 'No mood check-in yet today — ten seconds now keeps the '
        'picture honest. Pick the smallest one and start now — one action '
        'today compounds.';
    final details = NotifyService.detailsFor(body);
    final android = details.android;
    expect(android, isNotNull);
    final style = android!.styleInformation;
    expect(
      style,
      isA<BigTextStyleInformation>(),
      reason: 'without BigText Android truncates the check-in in the shade',
    );
    final big = style as BigTextStyleInformation;
    expect(
      big.bigText,
      body,
      reason: 'the expanded notification must show the whole message',
    );
    expect(big.contentTitle, 'Compounder coach');
    expect(
      NotifyService.detailsFor(
        'Take the bins out',
        title: 'Compounder reminder',
      ).android!.styleInformation,
      isA<BigTextStyleInformation>(),
      reason: 'long reminder text should be expandable too',
    );
  });

  test(
    'an empty week leads with outstanding items, not a data summary',
    () async {
      final digest = NotifyService.buildDigest(
        store,
        now: DateTime(2026, 11, 18, 8),
      );

      expect(digest, contains('No workouts logged yet'));
      expect(digest, contains('No meals logged this week'));
      expect(digest, contains('No mood check-in yet today'));
      expect(
        digest,
        endsWith(
          'Pick the smallest one and start now — one '
          'action today compounds.',
        ),
      );
      expect(
        digest,
        isNot(contains('kcal')),
        reason: 'the old digest dumped calorie averages',
      );
    },
  );

  test(
    'names the overdue workout, protein gap, habits, plan and shopping',
    () async {
      final anchor = DateTime(2026, 11, 18, 8);
      await seedWorkout(DateTime(2026, 11, 8, 18));
      await seedMeal(DateTime(2026, 11, 18, 7, 30));
      await store.logMood(
        2,
        'tired',
        timestamp: DateTime(2026, 11, 18, 7, 45).millisecondsSinceEpoch,
      );
      await store.createHabit('Journal', 'weekly', 3);
      await store.createHabit('Stretch', 'daily', 1);
      await store.createPlanBlock(
        day: anchor,
        title: 'Deep work',
        startMin: 9 * 60,
        endMin: 10 * 60,
      );
      final walkId = await store.createPlanBlock(
        day: anchor,
        title: 'Walk',
        startMin: 7 * 60,
        endMin: 8 * 60,
      );
      await store.setPlanBlockDone(walkId, true);
      final listId = await store.createGroceryList('Weekly shop');
      await store.addGroceryItem(listId, 'Milk');
      await store.addGroceryItem(listId, 'Eggs');

      final digest = await NotifyService.buildCheckIn(store, now: anchor);

      expect(digest, contains('You have not lifted in 10 days'));
      expect(digest, contains('130 g short on protein today'));
      expect(digest, contains('Your mood has been low this week'));
      expect(digest, contains('2 habits still open (Journal and Stretch)'));
      expect(digest, contains('1 block left on today\'s plan'));
      expect(digest, contains('"Deep work" at 09:00'));
      expect(
        digest,
        isNot(contains('"Walk"')),
        reason: 'completed blocks are not outstanding',
      );
      expect(digest, contains('2 items still unchecked on "Weekly shop"'));
      expect(
        digest,
        endsWith(
          'Pick the smallest one and start now — one '
          'action today compounds.',
        ),
      );
      expect(
        digest.indexOf('You have not lifted'),
        lessThan(digest.indexOf('habits still open')),
        reason: 'the most skippable pillar should lead',
      );
    },
  );

  test('a fully closed-out day says so instead of inventing work', () async {
    final anchor = DateTime(2026, 11, 18, 8);
    await seedWorkout(DateTime(2026, 11, 18, 7));
    await seedMeal(DateTime(2026, 11, 18, 7, 30), protein: 200, calories: 2000);
    await store.logMood(
      4,
      'good',
      timestamp: DateTime(2026, 11, 18, 7, 45).millisecondsSinceEpoch,
    );
    final habitId = await store.createHabit('Stretch', 'daily', 1);
    await store.setHabitCompletion(habitId, anchor, true);
    final blockId = await store.createPlanBlock(
      day: anchor,
      title: 'Deep work',
      startMin: 7 * 60,
      endMin: 8 * 60,
    );
    await store.setPlanBlockDone(blockId, true);
    final listId = await store.createGroceryList('Weekly shop');
    final item = await store.addGroceryItem(listId, 'Milk');
    await store.setGroceryItemChecked(item.id, true);

    final digest = await NotifyService.buildCheckIn(store, now: anchor);

    expect(digest, startsWith('Everything is closed out for today'));
    expect(digest, isNot(contains('still open')));
    expect(digest, isNot(contains('book the next session')));
  });
}
