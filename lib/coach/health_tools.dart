import 'dart:convert';

import '../health/analysis.dart';
import '../health/categories.dart';
import '../health/format.dart';
import '../health/models.dart';
import '../health/repository.dart';
import '../health/service.dart';
import '../llm/llm.dart';
import 'agent.dart';
import 'tools.dart';

/// Inclusive day range for a health tool call.
///
/// [now] is injectable so the DST regression tests can pin the default window
/// without depending on the wall clock.
({int from, int to}) healthRange(Map<String, Object?> args,
    {int defaultDays = 7, DateTime? now}) {
  final anchor = now ?? DateTime.now();
  final startRaw = args['start'] as String?;
  final start = DateTime.tryParse(startRaw ?? '') ??
      DateTime(anchor.year, anchor.month, anchor.day - (defaultDays - 1));
  final endRaw = args['end'] as String?;
  final end =
      DateTime.tryParse(endRaw ?? '') ?? (startRaw == null ? anchor : start);
  final lo = end.isBefore(start) ? end : start;
  final hi = end.isBefore(start) ? start : end;
  return (
    from: DateTime(lo.year, lo.month, lo.day).millisecondsSinceEpoch,
    to: DateTime(hi.year, hi.month, hi.day + 1).millisecondsSinceEpoch,
  );
}

/// Sleep durations in coach payloads are display strings ("2H 30M"), never raw
/// minute counts, so the model quotes them the way the app shows them.
Map<String, Object?> _sleepSessionMap(SleepSession s) => {
      'date': s.date,
      'bedtime': _clock(s.start),
      'wake': _clock(s.end),
      'inBed': formatSleepDuration(s.inBedMinutes),
      'asleep': formatSleepDuration(s.asleepMinutes),
      'awake': formatSleepDuration(s.awakeMinutes),
      'efficiencyPercent': s.efficiency,
      'stages': _stagesMap(s.stages),
      'source': s.sourceName,
    };

Map<String, Object?> _stagesMap(Map<String, Object?> stages) => {
      for (final entry in stages.entries)
        entry.key: formatSleepDuration(entry.value as num?),
    };

/// Replaces the minute counters in an overview/aggregated sleep block with
/// display durations, keeping efficiency, stages and provenance.
Map<String, Object?> _displayNight(Map<String, Object?> n) {
  final out = <String, Object?>{
    'date': n['date'],
    'bedtime': n['bedtime'],
    'wake': n['wake'],
    'efficiencyPercent': n['efficiencyPercent'] ?? n['efficiency'],
  };
  for (final pair in const [
    ('inBedMinutes', 'inBed'),
    ('asleepMinutes', 'asleep'),
    ('awakeMinutes', 'awake'),
  ]) {
    final v = n[pair.$1];
    if (v is num) out[pair.$2] = formatSleepDuration(v);
  }
  final stages = n['stages'];
  if (stages is Map) out['stages'] = _stagesMap(stages.cast<String, Object?>());
  if (n['source'] != null) out['source'] = n['source'];
  return out;
}

Map<String, Object?> _displaySleepOverview(Map<String, dynamic>? sleep) {
  if (sleep == null) return const {};
  final out = <String, Object?>{'nights': sleep['nights']};
  final average = sleep['averageAsleepMinutes'];
  if (average is num) out['averageAsleep'] = formatSleepDuration(average);
  final last = sleep['lastNight'];
  if (last is Map) {
    out['lastNight'] = _displayNight(last.cast<String, Object?>());
  }
  return out;
}

/// One day of a sleep metric: the day's total as a display duration plus the
/// per-night breakdown when the row carries one.
Map<String, Object?> _sleepPoint(HealthDayStat d) {
  final out = <String, Object?>{
    'date': d.day,
    'duration': formatSleepDuration(d.sum),
    'count': d.count,
  };
  final night = _displayNight({...d.detail})..remove('date');
  out.addAll(night);
  return out;
}

String _clock(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class HealthOverviewTool extends CoachTool {
  final HealthRepository repository;
  final HealthService service;
  HealthOverviewTool(this.repository, this.service);

  @override
  ToolSpec get spec => ToolSpec(
        'getHealthOverview',
        'Health Connect summary for a date range: sleep (last night, averages, stages, durations in '
            'hours and minutes such as "2H 30M"), heart rate/resting HR/HRV, activity (steps, '
            'distance, calories, workouts), body measurements and vitals. Dates YYYY-MM-DD; '
            'omitted = last 7 days.',
        dateRangeSchema,
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final r = healthRange(args);
    final overview = await repository.overview(from: r.from, to: r.to);
    final status = await service.status();
    return jsonEncode({
      ...overview,
      'sleep':
          _displaySleepOverview(overview['sleep'] as Map<String, dynamic>?),
      'sync': {
        'connected': status['enabled'],
        'lastSync': status['lastSync'],
        'lastError': status['lastError'],
      },
    });
  }
}

class SleepTool extends CoachTool {
  final HealthRepository repository;
  SleepTool(this.repository);

  @override
  ToolSpec get spec => ToolSpec(
        'getSleep',
        'Sleep from Health Connect for a date range: per-night bedtime, wake time, time in bed, '
            'asleep/awake durations (hours and minutes, e.g. "2H 30M"), sleep stages and '
            'efficiency. Dates YYYY-MM-DD; omitted = last 14 days.',
        dateRangeSchema,
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final r = healthRange(args, defaultDays: 14);
    final sessions = await repository.sleepSessions(from: r.from, to: r.to);
    final days = await repository.daily(type: 'SLEEP', from: r.from, to: r.to);
    final nights = sessions.map(_sleepSessionMap).toList();
    final asleep = sessions
        .map((s) => s.asleepMinutes.toDouble())
        .where((v) => v > 0)
        .toList();
    // Include compacted/aggregated nights for older history that no longer has
    // raw stage records.
    final known = nights.map((n) => n['date']).toSet();
    for (final d in days) {
      if (known.contains(d.day)) continue;
      if (d.sum > 0) asleep.add(d.sum);
      nights.add({
        ..._displayNight({'asleepMinutes': d.sum, ...d.detail}),
        'aggregated': true,
      });
    }
    nights.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
    final average =
        asleep.isEmpty ? null : asleep.reduce((a, b) => a + b) / asleep.length;
    return jsonEncode({
      'from': dayKey(r.from),
      'to': dayKey(r.to - 1),
      'nights': nights,
      'averageAsleep': average == null ? null : formatSleepDuration(average),
    });
  }
}

class HeartRateTool extends CoachTool {
  final HealthRepository repository;
  HeartRateTool(this.repository);

  @override
  ToolSpec get spec => ToolSpec(
        'getHeartRate',
        'Heart data from Health Connect: daily heart-rate average/min/max, resting heart rate, '
            'HRV, and optional hourly averages. Dates YYYY-MM-DD; omitted = last 14 days.',
        {
          'type': 'object',
          'properties': {
            'start': {'type': 'string', 'description': 'Start date YYYY-MM-DD'},
            'end': {'type': 'string', 'description': 'End date YYYY-MM-DD'},
            'includeHourly': {
              'type': 'boolean',
              'description':
                  'Include hourly heart-rate averages (default false; capped to 7 days).',
            },
          },
        },
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final r = healthRange(args, defaultDays: 14);
    final raw = await repository.records(from: r.from, to: r.to);
    final daily = heartDailyStats(raw);
    final resting = await repository.daily(
        type: 'RESTING_HEART_RATE', from: r.from, to: r.to);
    final hrv = await repository.daily(
        type: 'HEART_RATE_VARIABILITY_RMSSD', from: r.from, to: r.to);
    final includeHourly = args['includeHourly'] == true;
    return jsonEncode({
      'from': dayKey(r.from),
      'to': dayKey(r.to - 1),
      'daily': daily,
      'restingHeartRate': [
        for (final d in resting) {'date': d.day, 'value': d.avg ?? d.sum}
      ],
      'hrvMs': [
        for (final d in hrv) {'date': d.day, 'value': d.avg ?? d.sum}
      ],
      if (includeHourly) 'hourly': hourlyHeartStats(raw),
      if (daily.isEmpty) 'note': 'No heart-rate samples found in this range.',
    });
  }
}

class HealthMetricTool extends CoachTool {
  final HealthRepository repository;
  HealthMetricTool(this.repository);

  @override
  ToolSpec get spec => ToolSpec(
        'getHealthMetric',
        'Query any imported Health Connect metric by name: steps, distance, calories, weight, '
            'body fat, lean mass, BMI, blood oxygen, respiratory rate, temperature, blood pressure, '
            'glucose, sleep stages, nutrition, hydration, menstruation or workouts. Returns daily '
            'aggregates or readings. Dates YYYY-MM-DD; omitted = last 30 days.',
        {
          'type': 'object',
          'properties': {
            'metric': {
              'type': 'string',
              'description':
                  'Health Connect type, e.g. STEPS, WEIGHT, BLOOD_OXYGEN, SLEEP, WORKOUT.',
            },
            'start': {'type': 'string'},
            'end': {'type': 'string'},
          },
          'required': ['metric'],
        },
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final rawMetric = (args['metric'] as String?)?.trim().toUpperCase();
    if (rawMetric == null || rawMetric.isEmpty) {
      return '{"error":"metric is required"}';
    }
    final r = healthRange(args, defaultDays: 30);
    final info = metricInfo(rawMetric);

    if (rawMetric == 'WORKOUT') {
      final workouts = workoutSummaries(
          await repository.records(type: 'WORKOUT', from: r.from, to: r.to));
      return jsonEncode(
          {'metric': rawMetric, 'unit': info.unit, 'workouts': workouts});
    }
    if (rawMetric == 'SLEEP' || isSleepType(rawMetric)) {
      final days =
          await repository.daily(type: rawMetric, from: r.from, to: r.to);
      return jsonEncode({
        'metric': rawMetric,
        'label': info.label,
        'points': [for (final d in days) _sleepPoint(d)],
      });
    }
    if (rawMetric == 'NUTRITION') {
      final records =
          await repository.records(type: 'NUTRITION', from: r.from, to: r.to);
      return jsonEncode({
        'metric': rawMetric,
        'label': info.label,
        'entries': [
          for (final record in records)
            {
              'date': dayKey(record.dateFrom),
              'raw': _nutritionFields(record.rawJson),
            }
        ],
      });
    }

    final days =
        await repository.daily(type: rawMetric, from: r.from, to: r.to);
    if (days.isEmpty) {
      final available = await repository.availableMetrics();
      return jsonEncode({
        'metric': rawMetric,
        'points': [],
        'note': 'No data for this metric in the range.',
        'availableMetrics': [for (final m in available) m['metric']],
      });
    }
    return jsonEncode({
      'metric': rawMetric,
      'label': info.label,
      'unit': info.unit,
      'aggregation': info.aggregation.name,
      'points': [
        for (final d in days)
          {
            'date': d.day,
            'count': d.count,
            'sum': d.sum,
            'avg': d.avg,
            'min': d.min,
            'max': d.max,
            if (d.detail.isNotEmpty) 'detail': d.detail,
          }
      ],
    });
  }

  Map<String, Object?> _nutritionFields(String rawJson) {
    try {
      final raw = jsonDecode(rawJson);
      final value = raw is Map ? raw['value'] : null;
      if (value is Map) {
        return {
          'name': value['name'],
          'mealType': value['meal_type'],
          'calories': value['calories'],
          'protein': value['protein'],
          'carbs': value['carbs'],
          'fat': value['fat'],
        };
      }
    } catch (_) {}
    return const {};
  }
}

class HealthWorkoutsTool extends CoachTool {
  final HealthRepository repository;
  HealthWorkoutsTool(this.repository);

  @override
  ToolSpec get spec => ToolSpec(
        'getHealthWorkouts',
        'Workout/exercise sessions imported from Health Connect: activity, duration, energy, '
            'distance, steps and source. Dates YYYY-MM-DD; omitted = last 30 days.',
        dateRangeSchema,
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final r = healthRange(args, defaultDays: 30);
    final workouts = workoutSummaries(
        await repository.records(type: 'WORKOUT', from: r.from, to: r.to));
    return jsonEncode({
      'from': dayKey(r.from),
      'to': dayKey(r.to - 1),
      'workouts': workouts,
    });
  }
}

class HealthSyncStatusTool extends CoachTool {
  final HealthService service;
  HealthSyncStatusTool(this.service);

  @override
  ToolSpec get spec => const ToolSpec(
        'getHealthSyncStatus',
        'Whether Health Connect is connected, which categories are enabled, last sync time, '
            'errors, and which health metrics are available. No arguments.',
        {'type': 'object'},
      );

  @override
  Future<String> run(Map<String, Object?> args) async {
    final status = await service.status();
    return jsonEncode(status);
  }
}
