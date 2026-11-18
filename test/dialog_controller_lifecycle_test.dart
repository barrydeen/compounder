import 'package:compounder/data/store.dart';
import 'package:compounder/ui/drawer.dart';
import 'package:compounder/ui/habits.dart';
import 'package:compounder/ui/mind.dart';
import 'package:compounder/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regression guard for the dialog teardown crash the owner hit when saving a
/// habit: "Failed assertion: ... '_dependents.isEmpty': is not true".
///
/// Both dialogs used to create their [TextEditingController]s in the caller,
/// `await showDialog`, then dispose them. The route is still animating out when
/// that future completes, so the still-mounted fields rebuilt against a
/// disposed controller ("A TextEditingController was used after being
/// disposed"), and the framework then deactivated an InheritedElement that
/// still had dependents. The controllers must be owned and disposed by the
/// dialog's own State instead.
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

  Future<void> tallViewport(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// Lets a store write (real async DB work) finish and then rebuilds the UI.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }

  testWidgets('saving a new habit tears the dialog down without an exception',
      (tester) async {
    await tallViewport(tester);
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: const MaterialApp(home: HabitsScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('habits-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('habit-name')), 'Walk');
    await tester.enterText(find.byKey(const ValueKey('habit-target')), '2');
    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(tester.takeException(), isNull,
        reason: 'disposing the controllers after showDialog returned made the '
            'still-mounted dialog fields rebuild against a disposed '
            'TextEditingController');
    expect(store.habits, hasLength(1));
    expect(store.habits.single.name, 'Walk');
    expect(store.habits.single.target, 2);
    expect(find.text('Walk'), findsOneWidget);
  });

  testWidgets('editing a habit tears the dialog down without an exception',
      (tester) async {
    await tester.runAsync(() async {
      await store.createHabit('Read', 'daily', 1);
    });
    await tallViewport(tester);
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: const MaterialApp(home: HabitsScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('habit-menu-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('habit-name')), 'Read more');
    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(store.habits.single.name, 'Read more');
  });

  testWidgets(
      'saving a thought record tears the dialog down without an '
      'exception', (tester) async {
    await tallViewport(tester);
    await tester.pumpWidget(ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: CompounderTheme.light(),
        home: ShellNav(
          openDrawer: () {},
          child: const Scaffold(body: MindTab()),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The Mind tab is a long ListView; the button is below the fold.
    await tester.scrollUntilVisible(
      find.text('New thought record'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('New thought record'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'What happened?'),
        'Missed the deadline');
    await tester.enterText(
        find.widgetWithText(TextField, 'What did you tell yourself?'),
        'I always mess this up');
    await tester.enterText(
        find.widgetWithText(TextField, 'A kinder, truer reply (optional)'),
        'I was overloaded and still shipped most of it');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);

    expect(tester.takeException(), isNull,
        reason: 'the thought-record controllers were disposed while the route '
            'was still animating out');
    expect(store.thoughts, hasLength(1));
    expect(store.thoughts.single.thought, 'I always mess this up');
    expect(store.thoughts.single.reframe,
        'I was overloaded and still shipped most of it');
  });
}
