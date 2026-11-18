import 'dart:io';

import 'package:compounder/data/models.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/domain/grocery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Feature proofs for the grocery feature's persistence layer: list and item
/// CRUD, the dedup rule, check-off purchase memory, suggestion ranking and the
/// validation boundary shared with the coach tools.

PurchaseRecord _purchase(String text, int timesBought, int lastBoughtAt,
        {int id = 0}) =>
    PurchaseRecord(
      id: id,
      text: text,
      textKey: groceryTextKey(text),
      timesBought: timesBought,
      lastBoughtAt: lastBoughtAt,
    );

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppStore store;
  late String path;
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // A unique directory per test so concurrent `flutter test` processes never
    // collide on a fixed shared path (existing test-hygiene convention).
    tmp = await Directory.systemTemp.createTemp('compounder_grocery_store');
    path = '${tmp.path}/grocery_store_test.db';
    store = await AppStore.open(prefs, path: path);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(path);
    await tmp.delete(recursive: true);
  });

  group('list CRUD', () {
    test('create, read back and delete a list', () async {
      final id = await store.createGroceryList('Weekly shop');
      expect(store.groceryLists.single.id, id);
      expect(store.groceryLists.single.name, 'Weekly shop');

      await store.deleteGroceryList(id);
      expect(store.groceryLists, isEmpty);
    });

    test('newest list sorts first', () async {
      await store.createGroceryList('Older');
      // Same-millisecond timestamps would leave the order to the id tiebreak,
      // so nudge the clock instead of asserting on a race.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await store.createGroceryList('Newest');
      expect(store.groceryLists.map((l) => l.name), ['Newest', 'Older']);
    });

    test('rejects an empty or over-long name', () async {
      expect(store.createGroceryList('   '), throwsA(isA<StoreException>()));
      expect(store.createGroceryList('x' * (groceryListNameMaxLength + 1)),
          throwsA(isA<StoreException>()));
      expect(store.groceryLists, isEmpty,
          reason: 'nothing may be written for rejected input');
    });

    test('deleting a list cascades to its items but keeps purchase memory',
        () async {
      final id = await store.createGroceryList('Shop');
      final item = await store.addGroceryItem(id, 'Milk');
      await store.setGroceryItemChecked(item.id, true);
      expect(store.purchases.single.text, 'Milk');

      await store.deleteGroceryList(id);
      expect(store.groceryLists, isEmpty);
      expect(store.groceryItems, isEmpty);
      expect(store.purchases, hasLength(1),
          reason: 'history is kept: it is memory, not part of the list');
    });
  });

  group('item CRUD', () {
    test('adds items in order and reads them back per list', () async {
      final a = await store.createGroceryList('A');
      final b = await store.createGroceryList('B');
      await store.addGroceryItem(a, 'Milk');
      await store.addGroceryItem(a, 'Eggs');
      await store.addGroceryItem(b, 'Coffee');

      expect(store.groceryItemsFor(a).map((i) => i.text), ['Milk', 'Eggs']);
      expect(store.groceryItemsFor(b).map((i) => i.text), ['Coffee']);
    });

    test('adding the same item twice is a no-op, not a duplicate', () async {
      final id = await store.createGroceryList('Shop');
      final first = await store.addGroceryItem(id, 'Chicken thighs');
      final again = await store.addGroceryItem(id, '  chicken   THIGHS  ');
      expect(again.id, first.id, reason: 'the folded key must dedupe');
      expect(store.groceryItemsFor(id), hasLength(1));
      expect(store.groceryItemsFor(id).single.text, 'Chicken thighs',
          reason: 'the first spelling wins');
    });

    test('rejects an empty or over-long text', () async {
      final id = await store.createGroceryList('Shop');
      expect(store.addGroceryItem(id, ''), throwsA(isA<StoreException>()));
      expect(store.addGroceryItem(id, '   '), throwsA(isA<StoreException>()));
      expect(store.addGroceryItem(id, 'x' * (groceryItemMaxLength + 1)),
          throwsA(isA<StoreException>()));
      expect(store.groceryItemsFor(id), isEmpty);
    });

    test('remove, clear-checked and list deletion behave', () async {
      final id = await store.createGroceryList('Shop');
      final keep = await store.addGroceryItem(id, 'Milk');
      final drop = await store.addGroceryItem(id, 'Eggs');
      final other = await store.addGroceryItem(id, 'Coffee');
      await store.setGroceryItemChecked(drop.id, true);
      await store.setGroceryItemChecked(other.id, true);

      await store.removeGroceryItem(keep.id);
      expect(store.groceryItemsFor(id).map((i) => i.text),
          unorderedEquals(['Eggs', 'Coffee']));

      await store.clearCheckedItems(id);
      expect(store.groceryItemsFor(id), isEmpty,
          reason: 'both remaining items were checked');
      expect(
          store.purchases.map((p) => p.text), containsAll(['Eggs', 'Coffee']),
          reason: 'clearing ticks keeps the purchase memory');
    });
  });

  group('purchase memory', () {
    test('checking an item off records the purchase once', () async {
      final id = await store.createGroceryList('Shop');
      final item = await store.addGroceryItem(id, 'Milk');
      expect(store.purchases, isEmpty, reason: 'adding is not buying');

      await store.setGroceryItemChecked(item.id, true);
      expect(store.purchases.single.text, 'Milk');
      expect(store.purchases.single.timesBought, 1);
    });

    test('un-ticking and re-ticking the same item does not double-count',
        () async {
      final id = await store.createGroceryList('Shop');
      final item = await store.addGroceryItem(id, 'Eggs');
      await store.setGroceryItemChecked(item.id, true);
      await store.setGroceryItemChecked(item.id, false);
      await store.setGroceryItemChecked(item.id, true);

      expect(store.purchases.single.timesBought, 1,
          reason: 'one shop trip, one purchase');
    });

    test('a second trip counts again', () async {
      final id = await store.createGroceryList('Shop');
      final first = await store.addGroceryItem(id, 'Eggs');
      await store.setGroceryItemChecked(first.id, true);
      expect(store.purchases.single.timesBought, 1);

      // The next shop: clear the ticks, add the item again (a fresh row) and
      // tick it off once more.
      await store.clearCheckedItems(id);
      final second = await store.addGroceryItem(id, 'eggs');
      expect(second.id, isNot(first.id));
      await store.setGroceryItemChecked(second.id, true);

      expect(store.purchases.single.timesBought, 2);
    });

    test('case-folded spellings share one purchase record', () async {
      final id = await store.createGroceryList('Shop');
      final a = await store.addGroceryItem(id, 'Chicken Thighs');
      await store.setGroceryItemChecked(a.id, true);

      // Second trip: clear the ticks, re-add under a different spelling (the
      // list no longer holds the row, so this is a fresh one) and tick again.
      await store.clearCheckedItems(id);
      final b = await store.addGroceryItem(id, 'chicken thighs');
      expect(b.id, isNot(a.id));
      await store.setGroceryItemChecked(b.id, true);

      expect(store.purchases, hasLength(1));
      expect(store.purchases.single.textKey, 'chicken thighs');
      expect(store.purchases.single.timesBought, 2);
    });
  });

  group('suggestions', () {
    test('ranks by times bought, then recency, then name', () async {
      final ranked = grocerySuggestions([
        _purchase('Milk', 5, 100),
        _purchase('Tea', 5, 200),
        _purchase('Coffee', 2, 999),
        _purchase('Bread', 1, 500),
      ]);
      expect(ranked.map((p) => p.text), ['Tea', 'Milk', 'Coffee', 'Bread'],
          reason: 'Tea beats Milk on recency at equal counts; '
              'Coffee recency cannot beat a higher count');
    });

    test('alphabetical tiebreak keeps the order stable', () async {
      final ranked = grocerySuggestions([
        _purchase('banana', 1, 100),
        _purchase('Apple', 1, 100),
        _purchase('cherry', 1, 100),
      ]);
      expect(ranked.map((p) => p.text), ['Apple', 'banana', 'cherry']);
    });

    test('excludes items already on the list and honours the limit', () async {
      final history = [
        _purchase('Milk', 9, 1),
        _purchase('Eggs', 8, 2),
        _purchase('Tea', 7, 3),
      ];
      final excluded =
          grocerySuggestions(history, excludeKeys: {groceryTextKey('Milk')});
      expect(excluded.map((p) => p.text), ['Eggs', 'Tea']);

      final limited = grocerySuggestions(history, limit: 2);
      expect(limited.map((p) => p.text), ['Milk', 'Eggs']);
      expect(grocerySuggestions(history, limit: 0), isEmpty);
    });

    test('drops zero-count records', () async {
      expect(grocerySuggestions([_purchase('Milk', 0, 1)]), isEmpty);
    });

    test('store suggestions exclude the list being built', () async {
      final id = await store.createGroceryList('Shop');
      final milk = await store.addGroceryItem(id, 'Milk');
      await store.setGroceryItemChecked(milk.id, true);
      await store.clearCheckedItems(id);
      await store.addGroceryItem(id, 'eggs');

      final suggestions = store.grocerySuggestionsFor(id);
      expect(suggestions.map((p) => p.text), ['Milk'],
          reason: 'Milk was bought before; eggs is already on the list');
    });
  });

  group('text folding and validation', () {
    test('groceryTextKey folds case and whitespace, keeps punctuation', () {
      expect(groceryTextKey('  Chicken   thighs '), 'chicken thighs');
      expect(groceryTextKey('milk!'), 'milk!');
    });

    test('groceryItemError and groceryListError messages', () {
      expect(groceryItemError('  '), isNotNull);
      expect(groceryItemError('Milk'), isNull);
      expect(groceryItemError('x' * (groceryItemMaxLength + 1)), isNotNull);
      expect(groceryItemError('x' * groceryItemMaxLength), isNull);
      expect(groceryListError(''), isNotNull);
      expect(groceryListError('Weekly'), isNull);
      expect(groceryListError('x' * (groceryListNameMaxLength + 1)), isNotNull);
    });
  });
}
