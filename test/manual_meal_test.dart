import 'dart:convert';
import 'dart:io';

import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/domain.dart';
import 'package:compounder/llm/llm.dart';
import 'package:compounder/ui/drawer.dart';
import 'package:compounder/ui/macros.dart';
import 'package:compounder/ui/meal_entry.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Feature 1: manual meal logging and the macro→calorie calculator.
///
/// These are widget-level proofs: the manual path must work with no AI
/// endpoint configured, the calorie readout must track the macros live, and
/// edit mode must show a stored estimate next to the computed value instead of
/// silently replacing it.
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

  testWidgets(
      'the Log menu offers Meal and Weight, and Meal opens with AI unconfigured',
      (tester) async {
    // No endpoint is configured: the manual path must not depend on it.
    expect(store.ai.configured, isFalse);

    await tester.pumpWidget(
        host(ShellNav(openDrawer: () {}, child: const MacrosTab())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Log'));
    await tester.pumpAndSettle();

    expect(find.text('Meal'), findsOneWidget);
    expect(find.text('Weight'), findsOneWidget);

    await tester.tap(find.text('Meal'));
    await tester.pumpAndSettle();

    expect(find.text('Take a photo'), findsOneWidget);
    expect(find.text('Choose from gallery'), findsOneWidget);
    expect(find.text('Enter manually'), findsOneWidget);

    await tester.tap(find.text('Enter manually'));
    await tester.pumpAndSettle();

    expect(find.text('Log meal manually'), findsOneWidget);
    expect(find.byType(ManualMealScreen), findsOneWidget);
  });

  testWidgets(
      'typing macros updates the derived calories and saves a photo-less meal',
      (tester) async {
    await tester.pumpWidget(host(Builder(
        builder: (context) => Scaffold(
            body: Center(
                child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ManualMealScreen())),
                    child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Dish'), 'Chicken bowl');
    await tester.enterText(find.widgetWithText(TextField, 'Protein g'), '40');
    await tester.enterText(find.widgetWithText(TextField, 'Carbs g'), '50');
    await tester.enterText(find.widgetWithText(TextField, 'Fat g'), '20');
    await tester.pump();

    // 40*4 + 50*4 + 20*9 = 540
    expect(find.text('540 kcal'), findsOneWidget);

    // Changing one macro recomputes the display: 60*4 + 50*4 + 20*9 = 620.
    await tester.enterText(find.widgetWithText(TextField, 'Protein g'), '60');
    await tester.pump();
    expect(find.text('620 kcal'), findsOneWidget);

    await tester.ensureVisible(find.text('Save meal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save meal'));
    await tester.pumpAndSettle();

    expect(store.meals, hasLength(1));
    final meal = store.meals.single;
    expect(meal.dish, 'Chicken bowl');
    expect(meal.imagePath, '');
    expect(meal.isAuto, isFalse);
    expect(meal.protein, 60);
    expect(meal.carbs, 50);
    expect(meal.fat, 20);
    expect(meal.calories, 620);

    // It lands in today's list, which is the filter MacrosTab applies.
    final now = DateTime.now();
    final startOfDay =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    expect(meal.timestamp >= startOfDay, isTrue);

    await tester.pumpWidget(
        host(ShellNav(openDrawer: () {}, child: const MacrosTab())));
    await tester.pumpAndSettle();
    // The weekly tracker card sits above the day's meal list, so on the test
    // viewport the list starts below the fold.
    await tester.scrollUntilVisible(find.text('Chicken bowl'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Chicken bowl'), findsOneWidget);
  });

  testWidgets('a non-numeric macro field does not throw and reads as zero',
      (tester) async {
    await tester.pumpWidget(host(Builder(
        builder: (context) => Scaffold(
            body: Center(
                child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ManualMealScreen())),
                    child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Protein g'), 'abc');
    await tester.enterText(find.widgetWithText(TextField, 'Carbs g'), '50');
    await tester.enterText(find.widgetWithText(TextField, 'Fat g'), '20');
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 0 + 50*4 + 20*9 = 380
    expect(find.text('380 kcal'), findsOneWidget);
  });

  testWidgets(
      'edit mode shows stored and computed calories, hides the photo block, '
      'and saves the computed value without duplicating the row',
      (tester) async {
    // Real sqflite work must run outside the widget test's fake-async zone.
    await tester.runAsync(() async {
      await store.addMeal(Meal(
        id: 0,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        imagePath: '',
        dish: 'Pizza',
        calories: 620,
        protein: 48,
        carbs: 61,
        fat: 18,
        isAuto: true,
      ));
    });
    final stored = store.meals.single;

    await tester.pumpWidget(host(ReviewScreen.edit(stored)));
    await tester.pumpAndSettle();

    // 48*4 + 61*4 + 18*9 = 598, which disagrees with the stored 620.
    expect(find.text('598 kcal'), findsOneWidget);
    expect(find.text('stored 620 kcal · 4/4/9 gives 598 kcal'), findsOneWidget);

    // Calories are not an editable field any more.
    expect(find.widgetWithText(TextField, 'kcal'), findsNothing);

    // A manual meal has no photo, so the 240px placeholder block is gone.
    expect(find.byType(MealPhoto), findsNothing);

    // Editing a macro recomputes live: 50*4 + 61*4 + 18*9 = 606.
    await tester.enterText(find.widgetWithText(TextField, 'Protein g'), '50');
    await tester.pump();
    expect(find.text('606 kcal'), findsOneWidget);
    expect(find.text('stored 620 kcal · 4/4/9 gives 606 kcal'), findsOneWidget);

    await tester.ensureVisible(find.text('Save changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(store.meals, hasLength(1));
    expect(store.meals.single.calories, 606);
    expect(store.meals.single.protein, 50);
    // Editing never re-dates the meal: the stored timestamp survives a save.
    expect(store.meals.single.timestamp, stored.timestamp);
  });

  testWidgets(
      'a meal logged from a past day lands on that day, not today',
      (tester) async {
    // Fixed clock: 20 Nov 2026, a Friday.
    final clock = DateTime(2026, 11, 20, 9, 30);
    final viewedDay = DateTime(2026, 11, 19);

    await tester.pumpWidget(host(
        ShellNav(openDrawer: () {}, child: MacrosTab(now: () => clock))));
    await tester.pumpAndSettle();

    // Step back one day, then Log → Meal → Enter manually.
    await tester.tap(find.byKey(const ValueKey('macros-prev-day')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Meal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter manually'));
    await tester.pumpAndSettle();

    // The date field is pre-filled with the day being viewed.
    expect(find.text(formatDateTime(viewedDay.millisecondsSinceEpoch)),
        findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Dish'), 'Leftover stew');
    await tester.pump();
    await tester.ensureVisible(find.text('Save meal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save meal'));
    await tester.pumpAndSettle();

    expect(store.meals, hasLength(1));
    final meal = store.meals.single;
    expect(
        localMidnight(DateTime.fromMillisecondsSinceEpoch(meal.timestamp)),
        viewedDay);
  });

  testWidgets('a reviewed meal keeps the passed date instead of today',
      (tester) async {
    final day = DateTime(2026, 11, 19, 12, 30);
    await tester.pumpWidget(host(ReviewScreen(
      draft: const Draft('Toast', [], 90, 3, 10, 4),
      imagePath: '',
      initialTimestamp: day,
    )));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save meal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save meal'));
    await tester.pumpAndSettle();

    expect(store.meals, hasLength(1));
    expect(store.meals.single.timestamp, day.millisecondsSinceEpoch);
  });

  testWidgets('the meal gallery only shows meals that have a photo',
      (tester) async {
    // A real 1x1 PNG, so MealPhoto decodes it instead of hitting errorBuilder.
    const pngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
        '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('compounder-gallery-');
      final file = File(p.join(dir.path, 'meal.png'));
      await file.writeAsBytes(base64Decode(pngBase64));
      await store.addMeal(Meal(
        id: 0,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        imagePath: file.path,
        dish: 'Photo bowl',
        calories: 400,
        protein: 20,
        carbs: 40,
        fat: 10,
      ));
      await store.addMeal(Meal(
        id: 0,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        imagePath: '',
        dish: 'Manual bowl',
        calories: 300,
        protein: 10,
        carbs: 30,
        fat: 10,
      ));
    });

    await tester.pumpWidget(host(const GalleryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Photo bowl'), findsOneWidget);
    expect(find.text('Manual bowl'), findsNothing);
  });

  testWidgets('a gallery with only photo-less meals shows the empty state',
      (tester) async {
    await tester.runAsync(() async {
      await store.addMeal(Meal(
        id: 0,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        imagePath: '',
        dish: 'Manual bowl',
        calories: 300,
        protein: 10,
        carbs: 30,
        fat: 10,
      ));
    });

    await tester.pumpWidget(host(const GalleryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Manual bowl'), findsNothing);
    expect(find.text('No meal photos yet'), findsOneWidget);
  });
}
