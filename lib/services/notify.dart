import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import '../domain/habits.dart';
import '../domain/plan.dart';
import '../llm/routing.dart';

const _channelId = 'compounder_coach';
const _channelName = 'Daily coach';
const _channelDescription = 'A once-a-day message from your Compounder coach';

const _id = 42;

/// Notification details with a [BigTextStyleInformation] payload.
///
/// Android's collapsed notification preview only shows a line or two, which
/// cut the coach check-in off mid-sentence. BigText makes the notification
/// expandable: pulling it down in the shade shows the full message instead of
/// a truncated preview.
NotificationDetails _details(String body,
        {String title = 'Compounder coach'}) =>
    NotifyService.detailsFor(body, title: title);

/// `HH:MM` from minutes after local midnight, matching the app's 24-hour
/// timestamps.
String _clock(int minutes) {
  final h = (minutes ~/ 60).toString().padLeft(2, '0');
  final m = (minutes % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

/// Joins names for a notification sentence, capping the list so one user with
/// a dozen habits cannot produce a wall of text.
String _nameList(List<String> names, {int max = 3}) {
  final shown = names.take(max).toList();
  final joined = shown.length <= 1
      ? shown.join()
      : '${shown.sublist(0, shown.length - 1).join(', ')} and ${shown.last}';
  final extra = names.length - shown.length;
  return extra > 0 ? '$joined, plus $extra more' : joined;
}

/// Start of the 7-day digest window: local midnight six calendar days before
/// [now]. Calendar arithmetic, not `Duration(days: 6)`: a 144-hour subtraction
/// from midnight lands on 23:00/01:00 across a DST boundary.
DateTime digestWindowStart(DateTime now) =>
    DateTime(now.year, now.month, now.day - 6);

/// Whole calendar days between [now] and [then], counted on UTC day keys.
///
/// `now.difference(then).inDays` is elapsed-hours truncated to days, so a
/// 3-calendar-day gap across a DST boundary computes as 2. Local-midnight
/// subtraction has the same defect (the difference is still a Duration);
/// UTC day keys have no transitions, so the count is exact.
int calendarDaysSince(DateTime now, DateTime then) =>
    DateTime.utc(now.year, now.month, now.day)
        .difference(DateTime.utc(then.year, then.month, then.day))
        .inDays;

/// Next delivery time for the daily coach digest.
///
/// Returns today at [coachMinutes] when that is still in the future, otherwise
/// tomorrow at the same wall-clock time. Calendar arithmetic keeps the
/// wall-clock time across DST boundaries; `add(Duration(days: 1))` shifted it
/// by an hour in both directions.
///
/// On a fall-back day the configured wall-clock time can occur twice. The
/// constructor resolves to the first (DST) occurrence, so if that one has
/// already passed but the repeated occurrence is still ahead, the digest is
/// scheduled for the repeated one instead of being pushed to tomorrow
/// (pre-existing observation in the M3 gate).
DateTime nextDigestAt(DateTime now, int coachMinutes) {
  final hour = coachMinutes ~/ 60;
  final minute = coachMinutes % 60;
  final today = DateTime(now.year, now.month, now.day, hour, minute);
  if (today.isAfter(now)) return today;
  // One absolute hour later lands on the same wall-clock time only when the
  // clock went back in between, i.e. this wall-clock time occurs twice today.
  final repeated = today.add(const Duration(hours: 1));
  if (repeated.hour == hour &&
      repeated.minute == minute &&
      repeated.isAfter(now)) {
    return repeated;
  }
  return DateTime(now.year, now.month, now.day + 1, hour, minute);
}

class NotifyService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Builds the platform details for one notification body.
  ///
  /// BigText is what makes the check-in expandable in the shade instead of
  /// truncating at the collapsed preview. Public so the widget/unit tests can
  /// assert the style without driving the platform channel.
  @visibleForTesting
  static NotificationDetails detailsFor(String body,
          {String title = 'Compounder coach'}) =>
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          styleInformation: BigTextStyleInformation(body, contentTitle: title),
        ),
      );

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz
          .getLocation((await FlutterTimezone.getLocalTimezone()).identifier));
    } catch (_) {
      tz.setLocalLocation(tz.UTC);
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _ready = true;
  }

  /// An action-oriented daily check-in: what is still open today, and one clear
  /// next step.
  ///
  /// This deliberately avoids summarizing what the user already did. A digest
  /// that only says "3 workouts, 2200 kcal, mood 4/5" is information the user
  /// already has; the notification earns its place by naming what is
  /// outstanding and nudging a concrete action.
  ///
  /// [plan] is today's planner blocks. Loading them is async, so
  /// [buildCheckIn] fetches them and calls this.
  static String buildDigest(AppStore store,
      {DateTime? now, List<PlanBlock> plan = const []}) {
    final anchor = now ?? DateTime.now();
    final from = digestWindowStart(anchor);
    final fromMs = from.millisecondsSinceEpoch;
    final todayMs =
        DateTime(anchor.year, anchor.month, anchor.day).millisecondsSinceEpoch;

    final finished = store.history.where((h) => h.startedAt >= fromMs).toList();
    final trainedToday = finished.any((h) => h.startedAt >= todayMs);
    final lastWorkout = store.history.isEmpty ? null : store.history.first;
    final daysSinceWorkout = lastWorkout == null
        ? null
        : calendarDaysSince(
            anchor, DateTime.fromMillisecondsSinceEpoch(lastWorkout.startedAt));

    final open = <String>[];

    // Training is the pillar most often skipped, so it leads when overdue.
    if (!trainedToday) {
      if (daysSinceWorkout == null) {
        open.add('No workouts logged yet — start with 20 minutes today.');
      } else if (finished.isEmpty && daysSinceWorkout >= 3) {
        open.add('You have not lifted in $daysSinceWorkout days — get one '
            'session in today, even a short one.');
      } else if (finished.isNotEmpty) {
        open.add('${finished.length} workout${finished.length == 1 ? '' : 's'} '
            'this week — book the next session now so momentum does not stall.');
      }
    }

    final goal = store.goals;
    final todayMeals =
        store.meals.where((m) => m.timestamp >= todayMs).toList();
    if (todayMeals.isEmpty) {
      final anyThisWeek = store.meals.any((m) => m.timestamp >= fromMs);
      open.add(anyThisWeek
          ? 'Nothing logged today yet — log your next meal so your macros '
              'stay honest.'
          : 'No meals logged this week — log the next thing you eat.');
    } else {
      final protein = todayMeals.fold(0.0, (a, m) => a + m.protein);
      final short = goal.protein - protein;
      if (short >= 20) {
        open.add('You are ${short.round()} g short on protein today — make '
            'your next meal protein-first.');
      }
    }

    final recentMoods =
        store.moods.where((m) => m.timestamp >= fromMs).toList();
    final moodToday = store.moods.any((m) => m.timestamp >= todayMs);
    final avgMood = Mind.averageMood(recentMoods.map((m) => m.mood).toList());
    final streak = Mind.moodStreak(
        store.moods
            .map((m) => DateTime.fromMillisecondsSinceEpoch(m.timestamp))
            .toList(),
        today: anchor);

    if (!moodToday) {
      open.add('No mood check-in yet today — ten seconds now keeps the '
          'picture honest.');
    } else if (avgMood != null && avgMood < 2.5) {
      open.add('Your mood has been low this week — a three-minute breathing '
          'session today is a real win.');
    } else if (streak >= 3) {
      open.add('You are on a $streak-day mood streak — keep it going.');
    }

    final openHabits = <String>[];
    for (final habit in store.habits) {
      if (habit.archived) continue;
      final progress = habitProgress(
        habit,
        store.habitCompletions.where((c) => c.habitId == habit.id).toList(),
        today: anchor,
      );
      if (!progress.met) openHabits.add(habit.name);
    }
    if (openHabits.isNotEmpty) {
      open.add('${openHabits.length} habit${openHabits.length == 1 ? '' : 's'} '
          'still open (${_nameList(openHabits)}) — close one out before the '
          'day ends.');
    }

    final left = plan.where((b) => !b.done).toList();
    if (left.isNotEmpty) {
      // Name the next block that has not already ended; if the day's blocks
      // are all in the past, the earliest unfinished one is still the next
      // thing to tick off.
      final nowMinutes = anchor.hour * 60 + anchor.minute;
      final upcoming = left.where((b) => b.endMin > nowMinutes).toList();
      final next = chronological(upcoming.isEmpty ? left : upcoming).first;
      open.add('${left.length} block${left.length == 1 ? '' : 's'} left on '
          'today\'s plan — the next is "${next.title}" at '
          '${_clock(next.startMin)}. Do that one next.');
    }

    if (store.groceryLists.isNotEmpty) {
      final list = store.groceryLists.first;
      final unchecked = store.groceryItems
          .where((i) => i.listId == list.id && !i.checked)
          .length;
      if (unchecked > 0) {
        open.add('$unchecked item${unchecked == 1 ? '' : 's'} still unchecked '
            'on "${list.name}" — finish the shop when you can.');
      }
    }

    if (open.isEmpty) {
      return 'Everything is closed out for today — take the win and rest. '
          'Tomorrow we go again.';
    }
    open.add('Pick the smallest one and start now — one action today '
        'compounds.');
    return open.join(' ');
  }

  /// The check-in used by the scheduler: [buildDigest] plus today's planner
  /// blocks, which have to be loaded from the database first.
  static Future<String> buildCheckIn(AppStore store, {DateTime? now}) async {
    final anchor = now ?? DateTime.now();
    List<PlanBlock> plan = const [];
    try {
      plan = await store.planBlocksForDay(anchor);
    } catch (_) {
      // A planner read must never stop the check-in from being scheduled.
    }
    return buildDigest(store, now: anchor, plan: plan);
  }

  static Future<String> polishDigest(AppStore store) async {
    final facts = await buildCheckIn(store);
    if (!aiConfigured(store)) return facts;
    try {
      final polished = await chatClientFor(store)
          .simple(
            'You are Compounder\'s personal life coach writing the daily '
            'check-in push notification. The input lists what the user still '
            'has open today. Write two to four short sentences (under 400 '
            'characters): call out the most important outstanding item first, '
            'mention at most two more, and finish with one specific, '
            'encouraging action they can take right now. Do not restate what '
            'is already done or dump statistics. Plain text, no markdown.',
            facts,
          )
          .timeout(const Duration(seconds: 15));
      return polished.isEmpty || polished.length > 600 ? facts : polished;
    } catch (_) {
      return facts;
    }
  }

  /// Schedules the next delivery at the configured time with fresh text.
  /// Re-running this on app start keeps the check-in current.
  Future<void> rescheduleDaily(AppStore store) async {
    await init();
    if (!store.coachEnabled) {
      await _plugin.cancel(id: _id);
      return;
    }
    final now = DateTime.now();
    final when = nextDigestAt(now, store.coachMinutes);
    final tzWhen = tz.TZDateTime.from(when, tz.local);

    // Schedule instantly with the on-device check-in; then (never blocking the
    // caller) upgrade the text with an AI polish when the endpoint answers.
    await _scheduleDigest(tzWhen, await NotifyService.buildCheckIn(store));
    unawaited(() async {
      try {
        final polished = await polishDigest(store);
        await _scheduleDigest(tzWhen, polished);
      } catch (_) {}
    }());
  }

  Future<void> _scheduleDigest(tz.TZDateTime when, String body) async {
    try {
      await _plugin.zonedSchedule(
        id: _id,
        title: 'Compounder coach',
        body: body,
        scheduledDate: when,
        notificationDetails: _details(body),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {
      // Exact alarms can be denied by the OS; fall back to an inexact schedule.
      await _plugin.zonedSchedule(
        id: _id,
        title: 'Compounder coach',
        body: body,
        scheduledDate: when,
        notificationDetails: _details(body),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }
  }

  Future<void> _showNow(String body) async {
    await _plugin.show(
      id: _id + 1,
      title: 'Compounder coach',
      body: body,
      notificationDetails: _details(body),
    );
  }

  Future<void> scheduleReminder(Reminder reminder) async {
    await init();
    final when = DateTime.fromMillisecondsSinceEpoch(reminder.dueAt);
    if (!when.isAfter(DateTime.now())) return;
    final details = _details(reminder.text, title: 'Compounder reminder');
    final tzWhen = tz.TZDateTime.from(when, tz.local);
    try {
      await _plugin.zonedSchedule(
        id: 1000 + reminder.id,
        title: 'Compounder reminder',
        body: reminder.text,
        scheduledDate: tzWhen,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    } catch (_) {
      await _plugin.zonedSchedule(
        id: 1000 + reminder.id,
        title: 'Compounder reminder',
        body: reminder.text,
        scheduledDate: tzWhen,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    }
  }

  Future<void> cancelReminder(int reminderId) async {
    await init();
    await _plugin.cancel(id: 1000 + reminderId);
  }

  /// Re-schedules every pending reminder in [store].
  ///
  /// Reminders live in the database, but the OS notification is only created
  /// when the coach tool schedules it. After a backup import the rows are
  /// restored without their notifications, so the user sees them in Settings
  /// and assumes they will fire (audit backup MINOR-4). Idempotent: each
  /// reminder reuses its own notification id.
  Future<void> rescheduleReminders(AppStore store) async {
    await init();
    for (final reminder in store.reminders) {
      try {
        await scheduleReminder(reminder);
      } catch (_) {
        // One bad reminder must not stop the rest from being scheduled.
      }
    }
  }

  Future<void> testNotification(AppStore store) async {
    await init();
    await _showNow(await polishDigest(store));
  }
}
