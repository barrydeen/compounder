import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/domain.dart';
import 'package:compounder/ui/drawer.dart';
import 'package:compounder/ui/macros.dart';
import 'package:compounder/ui/weight.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Weight tracking: the rolling-average maths, the store round-trip, and the
/// two entry points (the Diet tab's scale button and its Log → Weight menu).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  // No isolate: the widget test's fake-async zone cannot receive messages from
  // a background isolate, so DB futures would never complete.
  databaseFactory = databaseFactoryFfiNoIsolate;

  late AppStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = await AppStore.open(prefs, path: inMemoryDatabasePath);
  });

  tearDown(() async {
    await store.db.close();
  });

  Widget host(Widget child) => ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(home: child),
      );

  group('rollingWeightAverage', () {
    final day = const Duration(days: 1).inMilliseconds;

    test('averages only the trailing seven days', () {
      final avg = rollingWeightAverage([
        WeightPoint(0, 80),
        WeightPoint(day, 82),
        WeightPoint(9 * day, 90),
      ]);
      expect(avg.map((p) => p.weightKg).toList(), [80, 81, 90]);
    });

    test('sorts unordered input and keeps one output per measurement', () {
      final avg = rollingWeightAverage([
        WeightPoint(2 * day, 84),
        WeightPoint(0, 80),
        WeightPoint(day, 82),
      ]);
      expect(avg.map((p) => p.timestamp).toList(), [0, day, 2 * day]);
      expect(avg.map((p) => p.weightKg).toList(), [80, 81, 82]);
    });

    test('skips non-finite weights instead of poisoning the line', () {
      final avg = rollingWeightAverage([
        WeightPoint(0, 80),
        WeightPoint(day, double.nan),
        WeightPoint(2 * day, 84),
      ]);
      expect(avg, hasLength(2));
      expect(avg.last.weightKg, 82);
    });

    test('a single measurement averages to itself', () {
      final avg = rollingWeightAverage([WeightPoint(day, 77.5)]);
      expect(avg.single.weightKg, 77.5);
    });
  });

  test('logWeight stores kilograms and refreshAll lists them ascending',
      () async {
    final start = DateTime(2026, 11, 1, 8).millisecondsSinceEpoch;
    await store.logWeight(81.2, timestamp: start);
    await store.logWeight(80.5,
        timestamp: start + const Duration(days: 1).inMilliseconds);

    expect(store.weights.map((w) => w.weightKg).toList(), [81.2, 80.5]);
    expect(store.weights.first.timestamp, start);

    await store.deleteWeight(store.weights.first.id);
    expect(store.weights.single.weightKg, 80.5);
  });

  test('a v15 database gains the weights table without losing its rows',
      () async {
    final path = '${await databaseFactory.getDatabasesPath()}/'
        'compounder_weights_migration_test.db';
    await databaseFactory.deleteDatabase(path);
    final prefs = await SharedPreferences.getInstance();

    var db = await AppStore.open(prefs, path: path);
    await db.addMeal(Meal(
      id: 0,
      timestamp: DateTime(2026, 10, 1, 12).millisecondsSinceEpoch,
      imagePath: '',
      dish: 'Pre-upgrade bowl',
      calories: 500,
      protein: 20,
      carbs: 50,
      fat: 20,
    ));
    // Roll the file back to exactly what a v15 app left behind: no weights
    // table, version 15.
    await db.db.execute('DROP TABLE IF EXISTS weights');
    await db.db.setVersion(15);
    await db.db.close();

    db = await AppStore.open(prefs, path: path);
    expect(await db.db.getVersion(), 16);
    final table = await db.db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'weights'");
    expect(table, isNotEmpty, reason: 'weights must exist after the upgrade');
    // Nothing outside the additive step was touched.
    expect(db.meals.single.dish, 'Pre-upgrade bowl');
    // The new surface works immediately on the upgraded file.
    await db.logWeight(77.4,
        timestamp: DateTime(2026, 11, 1).millisecondsSinceEpoch);
    expect(db.weights.single.weightKg, 77.4);
    await db.db.close();
    await databaseFactory.deleteDatabase(path);
  });

  testWidgets('the Diet tab opens the weight chart from the app bar',
      (tester) async {
    await tester.pumpWidget(
        host(ShellNav(openDrawer: () {}, child: const MacrosTab())));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Weight'));
    await tester.pumpAndSettle();

    expect(find.byType(WeightChartScreen), findsOneWidget);
    expect(find.text('No weights logged yet'), findsOneWidget);
  });

  testWidgets('Log → Weight saves a measurement on the day being viewed',
      (tester) async {
    // Fixed clock: 20 Nov 2026, a Friday.
    final clock = DateTime(2026, 11, 20, 9, 30);
    await tester.pumpWidget(
        host(ShellNav(openDrawer: () {}, child: MacrosTab(now: () => clock))));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('macros-prev-day')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Log'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weight'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Weight (kg)'), '78.5');
    await tester.pump();
    await tester.tap(find.text('Save weight'));
    await tester.pumpAndSettle();

    expect(store.weights, hasLength(1));
    final entry = store.weights.single;
    expect(entry.weightKg, closeTo(78.5, 1e-9));
    expect(localMidnight(DateTime.fromMillisecondsSinceEpoch(entry.timestamp)),
        DateTime(2026, 11, 19));
  });

  testWidgets('the weight chart draws measurements and a 7-day average',
      (tester) async {
    final base = DateTime(2026, 11, 1, 8);
    await tester.runAsync(() async {
      await store.logWeight(80, timestamp: base.millisecondsSinceEpoch);
      await store.logWeight(82,
          timestamp: base.add(const Duration(days: 2)).millisecondsSinceEpoch);
    });

    await tester
        .pumpWidget(host(WeightChartScreen(now: () => DateTime(2026, 11, 20))));
    await tester.pumpAndSettle();

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.data.lineBarsData, hasLength(2));
    // Series 0 is the 7-day average, series 1 the raw measurements.
    expect(chart.data.lineBarsData[0].spots, hasLength(2));
    expect(chart.data.lineBarsData[1].spots, hasLength(2));
    expect(chart.data.lineBarsData[0].spots[1].y, closeTo(81, 1e-9));
    expect(chart.data.lineBarsData[1].spots[1].y, closeTo(82, 1e-9));

    // Legend names both series, so the dots/line split is not colour-only.
    expect(find.text('7-day average'), findsWidgets);
    expect(find.text('Measurements'), findsWidgets);
  });

  testWidgets('the chart filters to the selected range', (tester) async {
    final now = DateTime(2026, 11, 20);
    await tester.runAsync(() async {
      await store.logWeight(90,
          timestamp: DateTime(2026, 6, 1, 8).millisecondsSinceEpoch);
      await store.logWeight(80,
          timestamp: DateTime(2026, 11, 10, 8).millisecondsSinceEpoch);
    });

    await tester.pumpWidget(host(WeightChartScreen(now: () => now)));
    await tester.pumpAndSettle();

    // Default 90-day range hides the June measurement.
    var chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.data.lineBarsData[1].spots, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('weight-range-all')));
    await tester.pumpAndSettle();

    chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.data.lineBarsData[1].spots, hasLength(2));
  });
}
