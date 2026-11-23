/// Version label shown in Settings. Kept as a constant so a test can pin it
/// against `pubspec.yaml` — the literal drifted to v0.3.0 while the package was
/// already at 0.3.2 (audit m8). `package_info_plus` is not a dependency, so
/// there is no runtime source of truth to read.
const String appVersionLabel = 'Compounder v0.6.2';

/// Copy for the import confirmation dialog. Kept as a constant so a test can
/// pin that it names every table the import wipes (review backup MINOR-2).
const String importConfirmText =
    'Importing replaces all workouts, meals, accounts, net-worth history, '
    'reminders, day plans and mind data on this device.';

/// Parses a daily-goal field. Returns null for empty, non-numeric, non-finite
/// (`NaN`, `Infinity`) or non-positive input.
///
/// `double.tryParse('NaN')` returns NaN rather than null, so a pasted "NaN"
/// used to persist as the goal and then assert `LinearProgressIndicator` and
/// poison the chart's `maxY` (review nutrition MINOR-4).
double? parseGoal(String text) {
  final value = double.tryParse(text.trim());
  if (value == null || !value.isFinite || value <= 0) return null;
  return value;
}
