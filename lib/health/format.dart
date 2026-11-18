/// Display formatting for health data that is shown to the user and quoted by
/// the coach. Kept free of Flutter imports so coach tools can use it.
library;

/// Sleep durations are always shown as hours and minutes, never as a bare
/// minute count: 150 minutes reads "2H 30M". Whole hours drop the minute part
/// ("8H") and sub-hour durations keep just minutes ("45M"). Fractions of a
/// minute are truncated, matching the app's other counters. Null (and anything
/// non-finite or negative) reads as an em dash, meaning "nothing recorded".
String formatSleepDuration(num? minutes) {
  if (minutes == null || !minutes.isFinite || minutes < 0) return '—';
  final total = minutes.toInt();
  final h = total ~/ 60;
  final m = total % 60;
  if (h == 0) return '${m}M';
  if (m == 0) return '${h}H';
  return '${h}H ${m}M';
}
