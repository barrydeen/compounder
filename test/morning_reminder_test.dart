import 'package:compounder/data/store.dart';
import 'package:compounder/health/models.dart';
import 'package:compounder/services/notify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Guards the wake-up planning reminder.
///
/// The reminder must fire at the user's real wake-up time, learned from the
/// imported Health Connect nights — not at a fixed clock time. The tests pin
/// the estimator's exclusions (naps, unfinished nights, atypical hours), the
/// fallback until enough nights exist, and the planning-first copy.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppStore store;
  late String path;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    path = p.join(
        await databaseFactory.getDatabasesPath(), 'compounder_morning_test.db');
    await databaseFactory.deleteDatabase(path);
    store = await AppStore.open(prefs, path: path);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(path);
  });

  SleepSession night(DateTime wake, {int asleep = 420}) => SleepSession(
        date: '${wake.year}-${wake.month}-${wake.day}',
        start: wake
            .subtract(Duration(minutes: asleep + 60))
            .millisecondsSinceEpoch,
        end: wake.millisecondsSinceEpoch,
        inBedMinutes: asleep + 60,
        asleepMinutes: asleep,
        awakeMinutes: 60,
        efficiency: 87.5,
        stages: const {},
      );

  Future<void> seedNight(DateTime wake, {String uuid = ''}) async {
    await store.db.insert(
      'health_records',
      HealthRecord(
        uuid: uuid.isEmpty ? 'night-${wake.millisecondsSinceEpoch}' : uuid,
        type: 'SLEEP_SESSION',
        unit: 'min',
        dateFrom:
            wake.subtract(const Duration(hours: 8)).millisecondsSinceEpoch,
        dateTo: wake.millisecondsSinceEpoch,
        syncedAt: wake.millisecondsSinceEpoch,
      ).toMap(),
    );
  }

  test('learns the median wake-up time and ignores naps and unfinished nights',
      () {
    final now = DateTime(2026, 11, 18, 9);
    final sessions = [
      night(DateTime(2026, 11, 12, 6, 30)),
      night(DateTime(2026, 11, 13, 6, 45)),
      night(DateTime(2026, 11, 14, 7, 0)),
      night(DateTime(2026, 11, 15, 9, 30)),
      // A nap must not move the wake-up time.
      night(DateTime(2026, 11, 16, 15, 0), asleep: 40),
      // A night that has not finished yet is not a wake-up.
      night(DateTime(2026, 11, 18, 23, 0)),
    ];

    // 390, 405, 420, 570 -> median (405 + 420) / 2 = 412.5 -> 06:53.
    expect(NotifyService.wakeMinutesFromSessions(sessions, now: now), 413);
  });

  test('a fragmented night counts once, at the final wake-up', () {
    final now = DateTime(2026, 11, 18, 9);
    final sessions = [
      // The same night reported as two sessions: 03:30 is a mid-night
      // awakening, 06:45 is the actual wake-up.
      night(DateTime(2026, 11, 16, 3, 30), asleep: 200),
      night(DateTime(2026, 11, 16, 6, 45), asleep: 200),
      night(DateTime(2026, 11, 17, 6, 30)),
      night(DateTime(2026, 11, 18, 6, 40)),
    ];

    // Wakes considered: 405 (11-16), 390 (11-17), 400 (11-18) -> 400.
    expect(NotifyService.wakeMinutesFromSessions(sessions, now: now), 400);
  });

  test('falls back until at least three usable nights exist', () {
    final now = DateTime(2026, 11, 18, 9);
    final sessions = [
      night(DateTime(2026, 11, 17, 6, 30)),
      night(DateTime(2026, 11, 18, 6, 45)),
    ];
    expect(NotifyService.wakeMinutesFromSessions(sessions, now: now), isNull);
    expect(NotifyService.wakeMinutesFromSessions(const [], now: now), isNull);
  });

  test('reads the learned time from stored Health Connect records', () async {
    final now = DateTime(2026, 11, 18, 9);
    await seedNight(DateTime(2026, 11, 16, 6, 30));
    await seedNight(DateTime(2026, 11, 17, 6, 45));
    await seedNight(DateTime(2026, 11, 18, 6, 40));
    await seedNight(DateTime(2026, 11, 17, 15), uuid: 'nap');
    await seedNight(DateTime(2026, 11, 18, 23), uuid: 'unfinished');

    expect(await NotifyService().learnedWakeMinutes(store, now: now), 400);
    expect(await NotifyService().morningMinutes(store, now: now), 400);
  });

  test('uses the configured fallback when no sleep data exists', () async {
    final now = DateTime(2026, 11, 18, 9);
    final notify = NotifyService();

    expect(store.coachMorningFallbackMinutes, 7 * 60);
    expect(await notify.morningMinutes(store, now: now), 7 * 60);

    await store.setCoachMorning(fallbackMinutes: 6 * 60 + 15);
    expect(await notify.morningMinutes(store, now: now), 6 * 60 + 15);
  });

  test('the reminder is opt-in and its settings persist', () async {
    expect(store.coachMorningEnabled, isFalse);
    await store.setCoachMorning(enabled: true, fallbackMinutes: 8 * 60);
    expect(store.coachMorningEnabled, isTrue);
    expect(store.coachMorningFallbackMinutes, 8 * 60);
    await store.setCoachMorning(enabled: false);
    expect(store.coachMorningEnabled, isFalse);
  });

  test('the message asks for a plan when the day has none', () {
    final digest = NotifyService.buildMorningDigest();
    expect(digest, startsWith('Good morning.'));
    expect(digest, contains('no plan yet'));
    expect(digest, contains('Planner'));
    expect(
      digest,
      isNot(contains('kcal')),
      reason: 'the morning reminder is a planning nudge, not a recap',
    );
  });

  test('the message names the next open block from the stored plan', () async {
    final now = DateTime(2026, 11, 18, 6, 50);
    await store.createPlanBlock(
      day: now,
      title: 'Walk',
      startMin: 7 * 60,
      endMin: 8 * 60,
    );
    await store.createPlanBlock(
      day: now,
      title: 'Deep work',
      startMin: 9 * 60,
      endMin: 11 * 60,
    );

    final digest = await NotifyService.buildMorningCheckIn(store, now: now);
    expect(digest, contains('2 blocks are still open'));
    expect(digest, contains('"Walk" at 07:00'));
    expect(digest, isNot(contains('"Deep work"')),
        reason: 'only the next block is named');
  });

  test('the text describes the morning it fires on, not the scheduling day',
      () async {
    final scheduledAt = DateTime(2026, 11, 18, 15);
    final tomorrow = DateTime(2026, 11, 19, 6, 45);
    await store.createPlanBlock(
      day: tomorrow,
      title: 'Gym',
      startMin: 7 * 60,
      endMin: 8 * 60,
    );
    // A block on the scheduling day must not leak into tomorrow's reminder.
    await store.createPlanBlock(
      day: scheduledAt,
      title: 'Today only',
      startMin: 9 * 60,
      endMin: 10 * 60,
    );

    final digest =
        await NotifyService.buildMorningCheckIn(store, now: tomorrow);
    expect(digest, contains('"Gym" at 07:00'));
    expect(digest, isNot(contains('Today only')));
  });

  test('an already-finished plan does not pretend there is work left',
      () async {
    final now = DateTime(2026, 11, 18, 6, 50);
    final id = await store.createPlanBlock(
      day: now,
      title: 'Deep work',
      startMin: 9 * 60,
      endMin: 10 * 60,
    );
    await store.setPlanBlockDone(id, true);

    final digest = NotifyService.buildMorningDigest(
      plan: await store.planBlocksForDay(now),
    );
    expect(digest, contains('already ticked off'));
    expect(digest, contains('Planner'));
  });
}
