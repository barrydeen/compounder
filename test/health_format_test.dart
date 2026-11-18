import 'package:compounder/health/format.dart';
import 'package:compounder/ui/health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sleep duration formatting', () {
    test('minutes are shown as hours and minutes', () {
      expect(formatSleepDuration(150), '2H 30M');
      expect(formatSleepDuration(390), '6H 30M');
      expect(formatSleepDuration(61), '1H 1M');
      expect(formatSleepDuration(1439), '23H 59M');
    });

    test('whole hours drop the minute part', () {
      expect(formatSleepDuration(60), '1H');
      expect(formatSleepDuration(480), '8H');
    });

    test('under an hour keeps just minutes', () {
      expect(formatSleepDuration(0), '0M');
      expect(formatSleepDuration(1), '1M');
      expect(formatSleepDuration(45), '45M');
      expect(formatSleepDuration(59), '59M');
    });

    test('fractions of a minute truncate', () {
      expect(formatSleepDuration(150.9), '2H 30M');
      expect(formatSleepDuration(59.9), '59M');
    });

    test('null and invalid values mean nothing recorded', () {
      expect(formatSleepDuration(null), '—');
      expect(formatSleepDuration(-5), '—');
      expect(formatSleepDuration(double.nan), '—');
      expect(formatSleepDuration(double.infinity), '—');
    });
  });

  group('efficiency percent formatting', () {
    test('null means nothing recorded', () {
      expect(formatEfficiencyPercent(null), '—');
    });

    test('values are already 0..100 percentages and are not rescaled', () {
      // Regression: a `value <= 1 ? value * 100 : value` branch used to turn a
      // 1% night into "100%" and a 0.5% night into "50%".
      expect(formatEfficiencyPercent(0), '0%');
      expect(formatEfficiencyPercent(1), '1%');
      expect(formatEfficiencyPercent(0.5), '0%');
      expect(formatEfficiencyPercent(1.5), '1%');
      expect(formatEfficiencyPercent(87), '87%');
      expect(formatEfficiencyPercent(100), '100%');
    });

    test('fractions truncate rather than round, like other counters', () {
      expect(formatEfficiencyPercent(87.4), '87%');
      expect(formatEfficiencyPercent(87.9), '87%');
    });

    test('integers carry thousands separators', () {
      expect(formatEfficiencyPercent(1000), '1,000%');
    });
  });
}
