import 'dart:io';

import 'package:compounder/data/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Schema v15 (grocery lists, items, purchase memory) must be purely additive:
/// a pre-existing database at version 14 opens, keeps its own data, gains the
/// new tables and works straight away — and the step is safe to re-run on a
/// partially applied migration.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppStore store;
  late String path;
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tmp = await Directory.systemTemp.createTemp('compounder_grocery_migration');
    path = '${tmp.path}/grocery_migration_test.db';
    store = await AppStore.open(prefs, path: path);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(path);
    await tmp.delete(recursive: true);
  });

  test('a v14 database upgrades in place, keeps its rows and gains grocery',
      () async {
    // Seed a row written before the grocery feature existed.
    await store.db.insert('workouts', {
      'name': 'Leg day',
      'started_at': 1000,
      'ended_at': 2000,
    });

    // Roll the file back to exactly what a v14 app left behind: no grocery
    // tables, no purchase memory, version 14.
    await store.db.execute('DROP TABLE IF EXISTS purchases');
    await store.db.execute('DROP TABLE IF EXISTS grocery_items');
    await store.db.execute('DROP TABLE IF EXISTS grocery_lists');
    await store.db.setVersion(14);
    await store.db.close();

    final prefs = await SharedPreferences.getInstance();
    store = await AppStore.open(prefs, path: path);

    expect(await store.db.getVersion(), 16);
    for (final table in ['grocery_lists', 'grocery_items', 'purchases']) {
      final exists = await store.db.rawQuery(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
          [table]);
      expect(exists, isNotEmpty, reason: '$table must exist after upgrade');
    }

    // Nothing outside the additive step was touched.
    final workout = (await store.db.query('workouts')).single;
    expect(workout['name'], 'Leg day');

    // The new surface works immediately on the upgraded file.
    final listId = await store.createGroceryList('Weekly shop');
    final item = await store.addGroceryItem(listId, 'Milk');
    await store.setGroceryItemChecked(item.id, true);
    expect(store.groceryLists.single.name, 'Weekly shop');
    expect(store.groceryItemsFor(listId).single.text, 'Milk');
    expect(store.purchases.single.timesBought, 1);
  });

  test('the 14 -> 15 step is safe to re-run (IF NOT EXISTS)', () async {
    // Simulate a partially applied migration: the tables already exist but the
    // version was never advanced (crash mid-upgrade). Reopening must not
    // duplicate or fail.
    await store.db.setVersion(14);
    await store.db.close();

    final prefs = await SharedPreferences.getInstance();
    store = await AppStore.open(prefs, path: path);
    expect(await store.db.getVersion(), 16);

    // And a full rewind onto a populated database is equally harmless.
    final listId = await store.createGroceryList('Keep');
    await store.addGroceryItem(listId, 'Tea');
    await store.db.setVersion(14);
    await store.db.close();

    store = await AppStore.open(prefs, path: path);
    expect(await store.db.getVersion(), 16);
    expect(store.groceryLists.single.name, 'Keep',
        reason: 'the additive step must not wipe existing grocery data');
    expect(store.groceryItems.single.text, 'Tea');
  });
}
