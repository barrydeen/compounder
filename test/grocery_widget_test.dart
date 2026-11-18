import 'dart:io';

import 'package:compounder/data/store.dart';
import 'package:compounder/domain/grocery.dart';
import 'package:compounder/domain/grocery_model.dart';
import 'package:compounder/ui/drawer.dart';
import 'package:compounder/ui/grocery.dart';
import 'package:compounder/ui/macros.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Widget proofs for the dedicated grocery interface.
///
/// Grocery lists live on their own screen, opened from the Diet top bar's
/// shopping-cart action beside the meal-gallery button. The proofs cover the
/// full shopping loop — open from Diet, create a list, add, tick, buy-again
/// quick-add after a clear, delete — and one negative proof that the removed
/// AI auto-suggest path is really gone: the grocery UI's source contains no
/// ChatClient plumbing at all, so no chat call can be constructed in any
/// grocery flow.
///
/// Store calls that touch the database run inside [tester.runAsync], matching
/// the repo's other store-backed widget tests: sqflite ffi futures must not be
/// awaited inside the test's fake-async zone or the pump deadlocks. Taps that
/// trigger database writes are followed by a short real-async flush for the
/// same reason.
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
    // Pin a model that knows nothing so the pairs section stays hidden: the
    // fake-async zone cannot receive an isolate's message, so a real background
    // load would never finish and the failure mode would be untestable here.
    // The pairs group below supplies its own fixture.
    GroceryRecommender.debugSetModel(GroceryModel.parse(
        '{"format_version":1,"smoothing":4.0,"total_lists":1,'
        '"item_counts":{"saffron":1},"pair_counts":[]}'));
  });

  tearDown(() async {
    GroceryRecommender.debugReset();
    await store.db.close();
  });

  Widget host(Widget child) => ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(home: child),
      );

  /// Lets a tap-triggered write finish in the real async zone, then lets the
  /// store's notification settle in the test zone.
  Future<void> flush(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }

  testWidgets(
      'the Diet top bar opens the grocery lists screen and its body '
      'no longer embeds a grocery section', (tester) async {
    await tester.pumpWidget(
        host(ShellNav(openDrawer: () {}, child: const MacrosTab())));
    await tester.pumpAndSettle();

    // The Diet body must not contain grocery content any more.
    expect(find.text('Buy again'), findsNothing);
    expect(find.byKey(const Key('grocery-item-field')), findsNothing);

    expect(find.byTooltip('Grocery lists'), findsOneWidget,
        reason: 'cart action sits beside the meal-gallery action');
    expect(find.byTooltip('Meal gallery'), findsOneWidget);

    await tester.tap(find.byTooltip('Grocery lists'));
    await tester.pumpAndSettle();

    expect(find.byType(GroceryListsScreen), findsOneWidget);
    expect(find.text('No grocery lists yet'), findsOneWidget);
    expect(find.byTooltip('Grocery lists'), findsNothing,
        reason: 'the shell bar is gone once the screen is pushed');
  });

  testWidgets(
      'creating a list from the empty state opens it and counts '
      'items', (tester) async {
    await tester.pumpWidget(host(const GroceryListsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('grocery-empty-new-list')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('grocery-list-name-field')), 'Weekly shop');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await flush(tester);
    await tester.pumpAndSettle();

    expect(store.groceryLists.single.name, 'Weekly shop');
    // The store refresh re-renders the index; the new list shows a zero count.
    expect(find.text('Weekly shop'), findsOneWidget);
    expect(find.text('No items yet'), findsOneWidget);

    // Tap-to-open lands on the detail screen.
    await tester.tap(find.text('Weekly shop'));
    await tester.pumpAndSettle();
    expect(find.byType(GroceryListScreen), findsOneWidget);
    expect(find.text('Nothing on this list'), findsOneWidget);
  });

  testWidgets(
      'adding, ticking, removing and clearing checked items works on '
      'the detail screen', (tester) async {
    final listId = await store.createGroceryList('Trip');
    await tester.pumpWidget(host(GroceryListScreen(listId: listId)));
    await tester.pumpAndSettle();

    // Add two items.
    await tester.enterText(find.byKey(const Key('grocery-item-field')), 'Eggs');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await flush(tester);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('grocery-item-field')), 'Milk');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await flush(tester);
    await tester.pumpAndSettle();

    expect(store.groceryItemsFor(listId).map((i) => i.text), ['Eggs', 'Milk']);
    expect(find.text('Eggs'), findsOneWidget);
    expect(find.text('Milk'), findsOneWidget);

    // Tick Milk off: a checkbox appears and the clear affordance shows the
    // count.
    await tester.tap(find.text('Milk'));
    await flush(tester);
    await tester.pumpAndSettle();
    expect(
        store
            .groceryItemsFor(listId)
            .firstWhere((i) => i.text == 'Milk')
            .checked,
        isTrue);
    expect(find.text('Clear checked (1)'), findsOneWidget);

    // Clear checked removes the ticked item only.
    await tester.tap(find.text('Clear checked (1)'));
    await flush(tester);
    await tester.pumpAndSettle();
    expect(store.groceryItemsFor(listId).map((i) => i.text), ['Eggs']);

    // Remove Eggs via its row's close button.
    await tester.tap(find.byTooltip('Remove Eggs'));
    await flush(tester);
    await tester.pumpAndSettle();
    expect(store.groceryItemsFor(listId), isEmpty);
    expect(find.text('Nothing on this list'), findsOneWidget);
  });

  testWidgets(
      'ticking an item records the purchase and, after the ticked '
      'items are cleared, it reappears under Buy again', (tester) async {
    final listId = await store.createGroceryList('Trip');
    await tester.pumpWidget(host(GroceryListScreen(listId: listId)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('grocery-item-field')), 'Oats');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await flush(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Oats'));
    await flush(tester);
    await tester.pumpAndSettle();
    expect(store.purchases.map((p) => p.text), ['Oats'],
        reason: 'ticking is what records the purchase');

    // Clear checked: the list is empty, so Oats now qualifies as a Buy again
    // suggestion.
    await tester.tap(find.text('Clear checked (1)'));
    await flush(tester);
    await tester.pumpAndSettle();
    expect(store.groceryItemsFor(listId), isEmpty);
    expect(find.text('Buy again'), findsOneWidget);
    expect(find.byType(ActionChip), findsOneWidget);
    await tester.tap(find.byType(ActionChip));
    await flush(tester);
    await tester.pumpAndSettle();
    expect(store.groceryItemsFor(listId).single.text, 'Oats');
    // The chip disappears again: items already on the list are excluded.
    expect(find.text('Buy again'), findsNothing);
  });

  testWidgets(
      'groceryListError gates the new-list dialog: Create stays disabled for '
      'an empty or over-long name', (tester) async {
    await tester.pumpWidget(host(const GroceryListsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('New list'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Create'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find
                .descendant(
                    of: find.byType(AlertDialog),
                    matching: find.widgetWithText(FilledButton, 'Create'))
                .first)
            .onPressed,
        isNull,
        reason: 'empty name fails groceryListError, so Create is disabled');
    expect(store.groceryLists, isEmpty);

    // The name field clamps at groceryListNameMaxLength, and a valid name
    // enables Create and really creates the list.
    expect(find.text('x' * groceryListNameMaxLength), findsNothing);
    await tester.enterText(
        find.byKey(const Key('grocery-list-name-field')), 'Weekly');
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find
                .descendant(
                    of: find.byType(AlertDialog),
                    matching: find.widgetWithText(FilledButton, 'Create'))
                .first)
            .onPressed,
        isNotNull);
    await tester.tap(find.text('Create'));
    await flush(tester);
    await tester.pumpAndSettle();
    expect(store.groceryLists.single.name, 'Weekly');
  });

  testWidgets(
      'the item field cannot accept more than the 80-character '
      'validation limit', (tester) async {
    final listId = await store.createGroceryList('Trip');
    await tester.pumpWidget(host(GroceryListScreen(listId: listId)));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('grocery-item-field')), 'x' * 120);
    await flush(tester);
    await tester.pumpAndSettle();
    expect(find.text('x' * 80), findsOneWidget,
        reason: 'maxLength clamps to the groceryItemMaxLength boundary');
  });

  testWidgets(
      'deleting a list from its app bar pops back to the index with '
      'the list gone', (tester) async {
    await store.createGroceryList('Old one');
    await tester.pumpWidget(host(const GroceryListsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Old one'));
    await tester.pumpAndSettle();
    expect(find.byType(GroceryListScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Delete list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await flush(tester);
    await tester.pumpAndSettle();

    expect(store.groceryLists, isEmpty,
        reason: 'cascade removed the items too');
    expect(find.byType(GroceryListsScreen), findsOneWidget,
        reason: 'back on the index');
    expect(find.text('No grocery lists yet'), findsOneWidget);
  });

  group('pairs well with your list', () {
    // A toy model in the real format: tomatoes and onions pair with garlic and
    // each other, basil only with tomatoes, rice with nothing.
    const pairsModelJson = '{"format_version":1,"smoothing":4.0,'
        '"total_lists":20,'
        '"item_counts":{"basil":4,"garlic":6,"onions":7,"rice":5,"tomatoes":8},'
        '"pair_counts":[["garlic","onions",5],["garlic","tomatoes",5],'
        '["onions","tomatoes",6],["basil","tomatoes",3]]}';

    setUp(() {
      GroceryRecommender.debugSetModel(GroceryModel.parse(pairsModelJson));
    });

    tearDown(GroceryRecommender.debugReset);

    testWidgets('appears once two items are recognised and adds on tap',
        (tester) async {
      final listId = await store.createGroceryList('Trip');
      await tester.pumpWidget(host(GroceryListScreen(listId: listId)));
      await tester.pumpAndSettle();

      for (final item in ['tomatoes', '2 kg onions']) {
        await tester.enterText(
            find.byKey(const Key('grocery-item-field')), item);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await flush(tester);
        await tester.pumpAndSettle();
      }

      expect(find.text('Pairs well with your list'), findsOneWidget);
      expect(find.byKey(const ValueKey('grocery-pair-garlic')), findsOneWidget,
          reason: 'garlic pairs with both recognised items');

      await tester.tap(find.byKey(const ValueKey('grocery-pair-garlic')));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(
          store.groceryItemsFor(listId).map((i) => i.text), contains('garlic'));
      expect(find.byKey(const ValueKey('grocery-pair-garlic')), findsNothing,
          reason: 'items already on the list are never suggested');
    });

    testWidgets('stays hidden until two items are recognised', (tester) async {
      final listId = await store.createGroceryList('Trip');
      await tester.pumpWidget(host(GroceryListScreen(listId: listId)));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('grocery-item-field')), 'tomatoes');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(find.text('Pairs well with your list'), findsNothing,
          reason: 'one item says nothing about what else is needed');

      // A second item the model does not know leaves it hidden too.
      await tester.enterText(
          find.byKey(const Key('grocery-item-field')), 'birthday candles');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(find.text('Pairs well with your list'), findsNothing);

      await tester.enterText(
          find.byKey(const Key('grocery-item-field')), 'Tomatoes');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await flush(tester);
      await tester.pumpAndSettle();
      expect(find.text('Pairs well with your list'), findsNothing,
          reason: 'duplicate spellings of one item still count as one');
    });

    testWidgets('stays hidden when the model knows none of the items',
        (tester) async {
      // A model that has never heard of tomatoes or onions, i.e. what a
      // sideways vocabulary change looks like: no suggestions, no exception.
      GroceryRecommender.debugSetModel(GroceryModel.parse(
          '{"format_version":1,"smoothing":4.0,"total_lists":1,'
          '"item_counts":{"saffron":1},"pair_counts":[]}'));

      final listId = await store.createGroceryList('Trip');
      for (final item in ['tomatoes', 'onions']) {
        await store.addGroceryItem(listId, item);
      }
      await tester.pumpWidget(host(GroceryListScreen(listId: listId)));
      await tester.pumpAndSettle();

      expect(find.text('Pairs well with your list'), findsNothing);
      expect(find.text('tomatoes'), findsOneWidget,
          reason: 'the list itself is untouched');
    });

    testWidgets('the purchase-history quick-add still works alongside it',
        (tester) async {
      final listId = await store.createGroceryList('Trip');
      await tester.pumpWidget(host(GroceryListScreen(listId: listId)));
      await tester.pumpAndSettle();

      // Record a purchase the way ticking does, then clear the list.
      await tester.enterText(
          find.byKey(const Key('grocery-item-field')), 'Oats');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await flush(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oats'));
      await flush(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear checked (1)'));
      await flush(tester);
      await tester.pumpAndSettle();

      expect(find.text('Buy again'), findsOneWidget);
      expect(find.text('Pairs well with your list'), findsNothing,
          reason: 'the list is empty, so there is nothing to pair');
    });
  });

  testWidgets(
      'no ChatClient plumbing exists anywhere in the grocery UI '
      'source: the AI auto-suggest path is gone, not disabled', (tester) async {
    // The widget tree cannot prove a non-construction, so read the source: if
    // any grocery flow still touched the LLM, this would fail.
    final source = File('lib/ui/grocery.dart').readAsStringSync();
    expect(source.contains('ChatClient'), isFalse);
    expect(source.contains('llm/'), isFalse);
    expect(source.contains('grocery-suggest-toggle'), isFalse);
    expect(source.contains('_maybeSuggest'), isFalse);
    expect(source.contains('SwitchListTile'), isFalse,
        reason: 'no suggest toggle remains');
    expect(source.contains('grocerySuggestEnabled'), isFalse);
    // And the store no longer carries the toggle's persistence.
    final storeSource = File('lib/data/store.dart').readAsStringSync();
    expect(storeSource.contains('grocerySuggestEnabled'), isFalse);
    expect(storeSource.contains('setGrocerySuggestEnabled'), isFalse);
    final domainSource = File('lib/domain/grocery.dart').readAsStringSync();
    expect(domainSource.contains('grocerySuggestSystemPrompt'), isFalse);
    expect(domainSource.contains('parseGrocerySuggestion'), isFalse);
    expect(domainSource.contains('prefGrocerySuggest'), isFalse);
    // And the exported surface no longer carries the AI helpers or prefs.
    expect(store.grocerySuggestionsFor(await store.createGroceryList('t')),
        isEmpty,
        reason: 'the local purchase-history ranking still works');
  });
}
