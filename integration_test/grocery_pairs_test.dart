import 'package:compounder/data/store.dart';
import 'package:compounder/domain/grocery_model.dart';
import 'package:compounder/main.dart' as app;
import 'package:compounder/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On-device proof that the bundled next-item recommender really loads and
/// drives the grocery screen's "Pairs well with your list" section.
///
/// Widget tests pin a fixture model, because a fake-async zone cannot receive an
/// isolate's message. This is the only place the shipped 2.3 MB asset is read,
/// parsed off the UI isolate, cached and scored on a real device:
///
///  * injera + berbere (the owner's own example) surfaces niter kibbeh, and
///    tapping the chip puts it on the list;
///  * tomatoes + "2 kg onions" surfaces garlic (and exercises quantity
///    stripping on device);
///  * one recognised item plus an unrecognised one keeps the section hidden.
///
/// Every COORD line is the physical-pixel centre of a control, printed so the
/// same flow can be replayed by hand with `adb shell input tap` against the
/// release build for screenshots.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AppStore cleaner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    cleaner = await AppStore.open(prefs);
    for (final list in List.of(cleaner.groceryLists)) {
      await cleaner.deleteGroceryList(list.id);
    }
    await cleaner.db.delete('purchases');
  });

  /// Pumps real frames until [finder] matches: the model is parsed on a
  /// background isolate, so nothing about the section is synchronous and the
  /// clock has to move in real time for the isolate to answer.
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    fail('timed out waiting for $finder');
  }

  void report(WidgetTester tester, String label, Finder finder) {
    final centre = tester.getCenter(finder);
    final ratio = tester.view.devicePixelRatio;
    debugPrint('COORD $label '
        '${(centre.dx * ratio).round()} ${(centre.dy * ratio).round()}');
  }

  Future<void> addItem(WidgetTester tester, String text) async {
    // Submitting unfocuses the field, so re-focus it before typing again.
    await tester.tap(find.byKey(const Key('grocery-item-field')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('grocery-item-field')), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  testWidgets('the bundled model suggests pairs for a real list on device',
      (tester) async {
    app.bootstrapForTest();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final store = Provider.of<AppStore>(
        tester.element(find.byType(ShellScreen)),
        listen: false);

    // The asset and the isolate parse are the two things no widget test can
    // prove, so put them under the test's own timeout first: a silently
    // degraded recommender must not be mistaken for a slow one.
    final raw = await rootBundle.load(GroceryRecommender.assetPath);
    expect(raw.lengthInBytes, 2368838);
    final stopwatch = Stopwatch()..start();
    final model = await GroceryRecommender.load()
        .timeout(const Duration(seconds: 60), onTimeout: () => null);
    expect(model, isNotNull,
        reason: 'the bundled model must load on device, not degrade silently');
    debugPrint('model loaded in ${stopwatch.elapsedMilliseconds} ms '
        'with ${model!.vocabularyTerms.length} terms');

    final menu = find.byTooltip('Open menu');
    report(tester, 'menu', menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final diet =
        find.descendant(of: find.byType(Drawer), matching: find.text('Diet'));
    report(tester, 'diet', diet);
    await tester.tap(diet);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final groceryIcon = find.byTooltip('Grocery lists');
    report(tester, 'grocery_icon', groceryIcon);
    await tester.tap(groceryIcon);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final newList = find.byKey(const Key('grocery-empty-new-list'));
    report(tester, 'new_list', newList);
    await tester.tap(newList);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('grocery-list-name-field')), 'Pairs Run');
    await tester.pumpAndSettle();
    final create = find.text('Create');
    report(tester, 'create', create);
    await tester.tap(create);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    report(tester, 'list_tile', find.text('Pairs Run'));
    await tester.tap(find.text('Pairs Run'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final listId = store.groceryLists.single.id;
    report(tester, 'item_field', find.byKey(const Key('grocery-item-field')));

    // One recognised item is not enough to say anything.
    await addItem(tester, 'injera');
    await addItem(tester, 'birthday candles');
    expect(find.text('Pairs well with your list'), findsNothing,
        reason: 'one recognised item plus an unknown one proves nothing');

    // Two recognised items.
    await addItem(tester, 'berbere');
    final header = find.text('Pairs well with your list');
    await pumpUntil(tester, header);
    final niterKibbeh = find.byKey(const ValueKey('grocery-pair-niter kibbeh'));
    await pumpUntil(tester, niterKibbeh);
    report(tester, 'pairs_header', header);
    report(tester, 'chip_niter_kibbeh', niterKibbeh);

    await tester.ensureVisible(niterKibbeh);
    await tester.tap(niterKibbeh);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(store.groceryItemsFor(listId).map((i) => i.text),
        contains('niter kibbeh'));
    expect(
        find.byKey(const ValueKey('grocery-pair-niter kibbeh')), findsNothing,
        reason: 'a suggested item joins the list and stops being suggested');
    expect(find.text('Pairs well with your list'), findsOneWidget,
        reason: 'the new item is itself recognised, so suggestions continue');

    // A second, unrelated list of two staples, one with a quantity prefix.
    for (final item in [
      'injera',
      'berbere',
      'niter kibbeh',
      'birthday candles'
    ]) {
      await tester.tap(find.byTooltip('Remove $item'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
    }
    expect(store.groceryItemsFor(listId), isEmpty);

    await addItem(tester, 'tomatoes');
    await addItem(tester, '2 kg onions');
    final garlic = find.byKey(const ValueKey('grocery-pair-garlic'));
    await pumpUntil(tester, garlic);
    report(tester, 'chip_garlic', garlic);

    await tester.ensureVisible(garlic);
    await tester.tap(garlic);
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(
        store.groceryItemsFor(listId).map((i) => i.text), contains('garlic'));

    // Clean up so the next run starts from an empty screen.
    await tester.tap(find.byTooltip('Delete list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(store.groceryLists, isEmpty);
  });
}
