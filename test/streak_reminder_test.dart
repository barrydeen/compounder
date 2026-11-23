import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/activity.dart';
import 'package:compounder/services/notify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Guards the evening streak-rescue reminder.
///
/// The reminder must only exist when there is a live streak to protect: a day
/// with nothing logged on top of a run of logged days. It fires at the
/// configured evening time, moves to tomorrow once today is logged, and is
/// withdrawn entirely when the streak is already broken or has not started.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppStore store;
  late String path;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    path = p.join(
        await databaseFactory.getDatabasesPath(), 'compounder_streak_test.db');
    await databaseFactory.deleteDatabase(path);
    store = await AppStore.open(prefs, path: path);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(path);
  });

  PillarDay logged(String day) => PillarDay(day: day, nutritionCount: 1);

  test('no history means no streak to protect', () {
    final now = DateTime(2026, 11, 18, 10);
    expect(NotifyService.streakReminderFor(const {}, now, 19 * 60), isNull);
  });

  test('a broken streak is not worth an evening nudge', () {
    final now = DateTime(2026, 11, 18, 10);
    // Logged through 11-16, nothing on 11-17 or today: the streak is already 0.
    final days = {
      '2026-11-15': logged('2026-11-15'),
      '2026-11-16': logged('2026-11-16'),
    };
    expect(NotifyService.streakReminderFor(days, now, 19 * 60), isNull);
  });

  test('fires tonight at the configured time when today is unlogged', () {
    final now = DateTime(2026, 11, 18, 10);
    final days = {
      '2026-11-16': logged('2026-11-16'),
      '2026-11-17': logged('2026-11-17'),
    };
    final reminder = NotifyService.streakReminderFor(days, now, 19 * 60);
    expect(reminder, isNotNull);
    expect(reminder!.when, DateTime(2026, 11, 18, 19));
    expect(reminder.streak, 2,
        reason: 'the quoted streak is the run ending yesterday');
  });

  test('a passed evening time moves the reminder to tomorrow', () {
    final now = DateTime(2026, 11, 18, 20, 30);
    final days = {
      '2026-11-17': logged('2026-11-17'),
    };
    final reminder = NotifyService.streakReminderFor(days, now, 19 * 60);
    expect(reminder!.when, DateTime(2026, 11, 19, 19));
    expect(reminder.streak, 1);
  });

  test('logging today moves the reminder to tomorrow, not tonight', () {
    final now = DateTime(2026, 11, 18, 9);
    final days = {
      '2026-11-16': logged('2026-11-16'),
      '2026-11-17': logged('2026-11-17'),
      '2026-11-18': logged('2026-11-18'),
    };
    final reminder = NotifyService.streakReminderFor(days, now, 19 * 60);
    expect(reminder!.when, DateTime(2026, 11, 19, 19),
        reason: 'tonight is already safe; tomorrow is the next risk');
    expect(reminder.streak, 3);
  });

  test('the message names the streak and the smallest ways to keep it', () {
    final text = NotifyService.buildStreakDigest(12);
    expect(text, contains('12-day streak'));
    expect(text, contains('nothing is logged today'));
    for (final action in ['meal', 'mood check-in', 'set', 'habit']) {
      expect(text, contains(action));
    }
    // A streak of one (or none, for the test preview) reads without a number.
    expect(NotifyService.buildStreakDigest(1), contains('Your streak'));
    expect(NotifyService.buildStreakDigest(1), isNot(contains('1-day')));
  });

  test('the reminder is on by default at 19:00 and its settings persist',
      () async {
    expect(store.coachStreakEnabled, isTrue,
        reason:
            'it cannot fire without a live streak, so it is safe to default '
            'on');
    expect(store.coachStreakMinutes, 19 * 60);
    await store.setCoachStreak(enabled: false, minutes: 20 * 60 + 30);
    expect(store.coachStreakEnabled, isFalse);
    expect(store.coachStreakMinutes, 20 * 60 + 30);
    await store.setCoachStreak(enabled: true);
    expect(store.coachStreakEnabled, isTrue);
  });

  test('reads the streak from stored logs and follows today\'s log', () async {
    final now = DateTime(2026, 11, 18, 10);
    await store.addMeal(Meal(
      id: 0,
      timestamp: DateTime(2026, 11, 16, 12).millisecondsSinceEpoch,
      imagePath: '',
      dish: 'Lunch',
      calories: 500,
      protein: 30,
      carbs: 40,
      fat: 15,
    ));
    await store.addMeal(Meal(
      id: 0,
      timestamp: DateTime(2026, 11, 17, 12).millisecondsSinceEpoch,
      imagePath: '',
      dish: 'Lunch',
      calories: 500,
      protein: 30,
      carbs: 40,
      fat: 15,
    ));

    final before = await NotifyService().nextStreakReminder(store, now: now);
    expect(before!.when, DateTime(2026, 11, 18, 19));
    expect(before.streak, 2);

    await store.addMeal(Meal(
      id: 0,
      timestamp: DateTime(2026, 11, 18, 9).millisecondsSinceEpoch,
      imagePath: '',
      dish: 'Breakfast',
      calories: 300,
      protein: 20,
      carbs: 20,
      fat: 10,
    ));

    final after = await NotifyService().nextStreakReminder(store, now: now);
    expect(after!.when, DateTime(2026, 11, 19, 19),
        reason: 'the log today withdraws tonight\'s reminder');
    expect(after.streak, 3);
  });

  test('a habit tick counts as logging, like every other pillar', () async {
    final now = DateTime(2026, 11, 18, 10);
    final habitId = await store.createHabit('Walk', 'daily', 1);
    await store.setHabitCompletion(habitId, DateTime(2026, 11, 16), true);
    await store.setHabitCompletion(habitId, DateTime(2026, 11, 17), true);

    final reminder = await NotifyService().nextStreakReminder(store, now: now);
    expect(reminder!.when, DateTime(2026, 11, 18, 19));
    expect(reminder.streak, 2);
  });

  test('a plan block counts as logging, so an evening plan disarms it',
      () async {
    final now = DateTime(2026, 11, 18, 10);
    await store.addMeal(Meal(
      id: 0,
      timestamp: DateTime(2026, 11, 17, 12).millisecondsSinceEpoch,
      imagePath: '',
      dish: 'Lunch',
      calories: 500,
      protein: 30,
      carbs: 40,
      fat: 15,
    ));
    await store.createPlanBlock(
      day: now,
      title: 'Deep work',
      startMin: 9 * 60,
      endMin: 11 * 60,
    );

    final reminder = await NotifyService().nextStreakReminder(store, now: now);
    expect(reminder!.when, DateTime(2026, 11, 19, 19));
    expect(reminder.streak, 2);
  });
}
