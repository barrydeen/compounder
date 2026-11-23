import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import 'widgets.dart';

/// Range chips on the weight chart. `null` span means every measurement.
enum _WeightRange {
  d30('30 d', Duration(days: 30)),
  d90('90 d', Duration(days: 90)),
  all('All', null);

  const _WeightRange(this.label, this.span);
  final String label;
  final Duration? span;
}

/// Body weight over time: individual measurements as dots, with a 7-day
/// trailing average drawn through them.
///
/// The average is computed over the whole log, then filtered to the selected
/// range, so the leftmost visible average is not biased by the range edge
/// (a 90-day view still sees the weigh-ins before day 90).
class WeightChartScreen extends StatefulWidget {
  /// Injectable clock, so a widget test can pin the visible range without
  /// waiting for a real day to pass.
  final DateTime Function() now;

  const WeightChartScreen({super.key, this.now = DateTime.now});

  @override
  State<WeightChartScreen> createState() => _WeightChartScreenState();
}

class _WeightChartScreenState extends State<WeightChartScreen> {
  _WeightRange _range = _WeightRange.d90;

  Future<void> _logWeight(AppStore store) async {
    final entry = await showModalBottomSheet<WeightEntry>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          LogWeightSheet(unit: store.unit, initialDate: widget.now()),
    );
    if (entry == null || !mounted) return;
    await store.logWeight(entry.weightKg, timestamp: entry.timestamp);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Weight logged: '
            '${trimZero(fromKg(entry.weightKg, store.unit))} '
            '${store.unit.label}')));
  }

  Future<void> _delete(AppStore store, WeightEntry entry) async {
    final unit = store.unit;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this weight?'),
        content:
            Text('${trimZero(fromKg(entry.weightKg, unit))} ${unit.label} on '
                '${formatDateTime(entry.timestamp)} will be removed. '
                'This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await store.deleteWeight(entry.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Weight deleted')));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final unit = store.unit;
    final scheme = Theme.of(context).colorScheme;

    final points = [
      for (final w in store.weights) WeightPoint(w.timestamp, w.weightKg)
    ];
    final averages = rollingWeightAverage(points);
    final cutoff = _range.span == null
        ? null
        : widget.now().subtract(_range.span!).millisecondsSinceEpoch;
    final visible = [
      for (final p in points)
        if (cutoff == null || p.timestamp >= cutoff) p
    ];
    final visibleAverage = [
      for (final p in averages)
        if (cutoff == null || p.timestamp >= cutoff) p
    ];
    final visibleEntries = [
      for (final w in store.weights)
        if (cutoff == null || w.timestamp >= cutoff) w
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Weight')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'log-weight',
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        onPressed: () => _logWeight(store),
        icon: const Icon(Icons.add),
        label: const Text('Log weight'),
      ),
      body: points.isEmpty
          ? const Center(
              child: EmptyState(
                title: 'No weights logged yet',
                subtitle:
                    'Tap "Log weight" here, or Log → Weight on the Diet tab, '
                    'to add your first measurement.',
                icon: Icons.monitor_weight_outlined,
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 96),
              children: [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final range in _WeightRange.values)
                    ChoiceChip(
                      key: ValueKey('weight-range-${range.name}'),
                      label: Text(range.label),
                      selected: _range == range,
                      onSelected: (_) => setState(() => _range = range),
                    ),
                ]),
                const SizedBox(height: 12),
                if (visible.isEmpty)
                  const EmptyState(
                    title: 'Nothing logged in this range',
                    subtitle: 'Pick a wider range, or log a new measurement.',
                    icon: Icons.monitor_weight_outlined,
                  )
                else ...[
                  _chartCard(context, visible, visibleAverage, unit),
                  const SizedBox(height: 12),
                  _statsRow(context, visible, visibleAverage, unit),
                  const SizedBox(height: 20),
                  const SectionHeader('Measurements'),
                  const SizedBox(height: 8),
                  for (final entry in visibleEntries.reversed)
                    CardRow(
                      icon: Icons.monitor_weight_outlined,
                      title:
                          '${trimZero(fromKg(entry.weightKg, unit))} ${unit.label}',
                      subtitle: formatDateTime(entry.timestamp),
                      trailingAction: IconButton(
                        tooltip: 'Delete weight',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(store, entry),
                      ),
                      onLongPress: () => _delete(store, entry),
                    ),
                ],
              ],
            ),
    );
  }

  Widget _chartCard(BuildContext context, List<WeightPoint> points,
      List<WeightPoint> average, WeightUnit unit) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final last = points.last;
    final lastAverage = average.isEmpty ? last : average.last;
    return Card(
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(
            container: true,
            label: 'Weight chart, ${points.length} '
                '${points.length == 1 ? 'measurement' : 'measurements'} over '
                '${_range == _WeightRange.all ? 'all time' : 'the last ${_range.label}'}, '
                'latest ${trimZero(fromKg(last.weightKg, unit))} ${unit.label}, '
                '7-day average '
                '${trimZero(fromKg(lastAverage.weightKg, unit))} ${unit.label}',
            child: ExcludeSemantics(
              child: SizedBox(
                height: 220,
                child:
                    _WeightChart(points: points, average: average, unit: unit),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 16, runSpacing: 6, children: [
            _legendItem(scheme.primary, '7-day average', t),
            _legendItem(scheme.tertiary, 'Measurements', t),
          ]),
        ]),
      ),
    );
  }

  Widget _legendItem(Color color, String label, TextTheme t) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: t.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      );

  Widget _statsRow(BuildContext context, List<WeightPoint> points,
      List<WeightPoint> average, WeightUnit unit) {
    final latest = points.last;
    final avg = average.isEmpty ? latest : average.last;
    final change =
        points.length < 2 ? null : points.last.weightKg - points.first.weightKg;
    final String changeText;
    if (change == null) {
      changeText = '—';
    } else {
      final rounded = fromKg(change, unit);
      final sign = rounded > 0 ? '+' : '';
      changeText = '$sign${trimZero(rounded)} ${unit.label}';
    }
    return Row(children: [
      Expanded(
          child: StatCard(
              label: 'Latest',
              value:
                  '${trimZero(fromKg(latest.weightKg, unit))} ${unit.label}')),
      const SizedBox(width: 8),
      Expanded(
          child: StatCard(
              label: '7-day average',
              value: '${trimZero(fromKg(avg.weightKg, unit))} ${unit.label}')),
      const SizedBox(width: 8),
      Expanded(child: StatCard(label: 'Change', value: changeText)),
    ]);
  }
}

/// The chart itself: dots for every measurement, a curved line through the
/// trailing average.
///
/// The dots are a second [LineChartBarData] with `barWidth: 0` — fl_chart
/// paints a zero-width line transparently but still draws the dots, so both
/// series share one axis, one grid and one scale without a second chart.
class _WeightChart extends StatelessWidget {
  final List<WeightPoint> points;
  final List<WeightPoint> average;
  final WeightUnit unit;

  const _WeightChart(
      {required this.points, required this.average, required this.unit});

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];

  static String _shortDate(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${_months[d.month - 1]} ${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final values = [
      for (final p in [...points, ...average]) fromKg(p.weightKg, unit)
    ];
    var minY = values.reduce(math.min);
    var maxY = values.reduce(math.max);
    if (maxY - minY < 1) {
      minY -= 1;
      maxY += 1;
    } else {
      final pad = (maxY - minY) * 0.12;
      minY -= pad;
      maxY += pad;
    }
    final minX = points.first.timestamp.toDouble();
    final maxX = points.last.timestamp.toDouble();
    final span = maxX - minX;
    // A single measurement has no horizontal span: give it a day so the dot
    // is not pinned to the axis edge.
    final padX =
        span == 0 ? const Duration(hours: 12).inMilliseconds : span * 0.04;

    return LineChart(
      LineChartData(
        minX: minX - padX,
        maxX: maxX + padX,
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: scheme.outlineVariant, strokeWidth: 0.5),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (value, meta) => Text(trimZero(value),
                  style:
                      TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: span == 0 ? null : span / 3,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_shortDate(value.round()),
                    style: TextStyle(
                        fontSize: 10, color: scheme.onSurfaceVariant)),
              ),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (final p in average)
                FlSpot(p.timestamp.toDouble(), fromKg(p.weightKg, unit))
            ],
            isCurved: true,
            preventCurveOverShooting: true,
            color: scheme.primary,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
          ),
          LineChartBarData(
            spots: [
              for (final p in points)
                FlSpot(p.timestamp.toDouble(), fromKg(p.weightKg, unit))
            ],
            isCurved: false,
            color: scheme.tertiary,
            barWidth: 0,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                radius: 3.5,
                color: scheme.tertiary,
                strokeWidth: 0,
                strokeColor: scheme.tertiary,
              ),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => [
              for (final spot in spots)
                LineTooltipItem(
                  '${trimZero(spot.y)} ${unit.label}\n'
                  '${_shortDate(spot.x.round())}',
                  TextStyle(color: scheme.onInverseSurface, fontSize: 11),
                )
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet that logs one body-weight measurement. Pops with the new
/// [WeightEntry] (id 0), or null when the user backs out.
///
/// Shared by the Diet tab (Log → Weight) and the weight chart screen, so both
/// entry points validate and store identically.
class LogWeightSheet extends StatefulWidget {
  final WeightUnit unit;

  /// Pre-filled date/time. The Diet tab passes the day it is showing, so a
  /// weigh-in logged while browsing a past day lands on that day.
  final DateTime initialDate;

  const LogWeightSheet(
      {super.key, required this.unit, required this.initialDate});

  @override
  State<LogWeightSheet> createState() => _LogWeightSheetState();
}

class _LogWeightSheetState extends State<LogWeightSheet> {
  final TextEditingController controller = TextEditingController();
  late DateTime timestamp = widget.initialDate;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  double? get _kg => parseWeightKg(controller.text, widget.unit);

  bool get _valid {
    final kg = _kg;
    return kg != null && kg.isFinite && kg > 0;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = timestamp.isAfter(today) ? today : timestamp;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: today,
    );
    if (picked == null || !mounted) return;
    setState(() {
      // Keep the time of day so several weigh-ins on one day still order
      // sensibly; only the calendar day changes.
      timestamp = DateTime(picked.year, picked.month, picked.day,
          timestamp.hour, timestamp.minute);
    });
  }

  void _save() {
    final kg = _kg;
    if (kg == null || !kg.isFinite || kg <= 0) return;
    Navigator.of(context).pop(WeightEntry(
        id: 0, timestamp: timestamp.millisecondsSinceEpoch, weightKg: kg));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Log weight', style: t.titleMedium),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  labelText: 'Weight (${widget.unit.label})',
                  hintText:
                      widget.unit == WeightUnit.kg ? 'e.g. 78.4' : 'e.g. 172.8',
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(12),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Date',
                    suffixIcon: Icon(Icons.calendar_today_outlined),
                  ),
                  child: Text(formatDateTime(timestamp.millisecondsSinceEpoch)),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.save),
                label: const Text('Save weight'),
                onPressed: _valid ? _save : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
