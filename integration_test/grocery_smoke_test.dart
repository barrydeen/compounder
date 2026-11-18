import 'package:compounder/data/store.dart';
import 'package:compounder/main.dart' as app;
import 'package:compounder/ui/grocery.dart';
import 'package:compounder/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Emulator smoke proof for the dedicated grocery interface, run on a real
/// Android device (`flutter test integration_test`): open Diet from the
/// drawer, push the grocery lists screen from the top bar, create a list, add
/// an item, tick it, confirm it reappears under Buy again after clearing, and
/// delete the list.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AppStore cleaner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    cleaner = await AppStore.open(prefs);
    // Start from a clean grocery slate so the flow is deterministic. The app
    // under test opens its own AppStore later in the same database.
    for (final list in List.of(cleaner.groceryLists)) {
      await cleaner.deleteGroceryList(list.id);
    }
    await cleaner.db.delete('purchases');
  });

  testWidgets(
      'grocery lists: open from Diet, create, add, tick, buy again, '
      'delete', (tester) async {
    app.bootstrapForTest();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The app owns the store; assert on the instance the UI actually writes
    // to rather than a second handle that never sees its notifications.
    final store = Provider.of<AppStore>(
        tester.element(find.byType(ShellScreen)),
        listen: false);

    // Open the drawer and switch to the Diet tab.
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();
    await tester.tap(
        find.descendant(of: find.byType(Drawer), matching: find.text('Diet')));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // The Diet body must not embed a grocery section any more.
    expect(find.text('Buy again'), findsNothing);
    expect(find.text('Add item'), findsNothing);

    // The top bar's cart action sits beside the meal-gallery action.
    expect(find.byTooltip('Grocery lists'), findsOneWidget);
    expect(find.byTooltip('Meal gallery'), findsOneWidget);
    await tester.tap(find.byTooltip('Grocery lists'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Empty state (we cleared the store) with its New list action.
    expect(find.text('No grocery lists yet'), findsOneWidget);
    await tester.tap(find.byKey(const Key('grocery-empty-new-list')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('grocery-list-name-field')), 'Smoke Run');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(store.groceryLists.single.name, 'Smoke Run');
    expect(find.text('Smoke Run'), findsOneWidget);
    expect(find.text('No items yet'), findsOneWidget);

    // Tap-to-open lands on the detail screen.
    await tester.tap(find.text('Smoke Run'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Add an item via the field's keyboard action.
    await tester.enterText(find.byKey(const Key('grocery-item-field')), 'Oats');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(store.groceryLists.single.name, 'Smoke Run');
    expect(find.text('Oats'), findsOneWidget);

    // Tick it off: records the purchase and shows the clear affordance.
    await tester.tap(find.text('Oats'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(store.purchases.map((p) => p.text), ['Oats']);
    expect(find.text('Clear checked (1)'), findsOneWidget);

    // Clear checked: the item leaves the list and qualifies as Buy again.
    await tester.tap(find.text('Clear checked (1)'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.text('Buy again'), findsOneWidget);
    expect(find.byType(ActionChip), findsOneWidget);

    // Quick-add from the Buy again chip.
    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(store.groceryItemsFor(store.groceryLists.single.id).single.text,
        'Oats');

    // Remove the item, then delete the list from its app bar.
    await tester.tap(find.byTooltip('Remove Oats'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await tester.tap(find.byTooltip('Delete list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(store.groceryLists, isEmpty);
    expect(find.byType(GroceryListsScreen), findsOneWidget,
        reason: 'popped back to the index');
    expect(find.text('No grocery lists yet'), findsOneWidget);
  });
}
