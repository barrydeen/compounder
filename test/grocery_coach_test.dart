import 'dart:convert';
import 'dart:io';

import 'package:compounder/coach/agent.dart';
import 'package:compounder/coach/tools.dart';
import 'package:compounder/data/store.dart';
import 'package:compounder/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Feature proofs for the grocery coach tools: every tool is registered in the
/// agent loop and documented in the system prompt, read tools run without
/// approval, write tools pause for one and bad input comes back as a JSON
/// error instead of an exception.

class _ScriptedClient extends ChatClient {
  final List<ChatResult> script;
  final List<List<ChatMessage>> sent = [];
  int calls = 0;

  _ScriptedClient(this.script) : super('http://localhost', 'key', 'model');

  @override
  Future<ChatResult> chat(
      List<ChatMessage> messages, List<ToolSpec> tools) async {
    sent.add(messages);
    calls++;
    return script[calls - 1];
  }
}

List<CoachTool> groceryTools(AppStore store) => [
      CreateGroceryListTool(store),
      AddGroceryItemTool(store),
      RemoveGroceryItemTool(store),
      GroceryHistoryTool(store),
    ];

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppStore store;
  late String path;
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tmp = await Directory.systemTemp.createTemp('compounder_grocery_coach');
    path = '${tmp.path}/grocery_coach_test.db';
    store = await AppStore.open(prefs, path: path);
  });

  tearDown(() async {
    await store.db.close();
    await databaseFactory.deleteDatabase(path);
    await tmp.delete(recursive: true);
  });

  test('every grocery tool is registered and documented', () {
    final agent = CoachAgent(toolList: groceryTools(store));
    expect(
        agent.tools.keys,
        containsAll([
          'create_grocery_list',
          'add_grocery_item',
          'remove_grocery_item',
          'get_grocery_history',
        ]));
    for (final name in [
      'create_grocery_list',
      'add_grocery_item',
      'remove_grocery_item',
      'get_grocery_history',
    ]) {
      expect(CoachAgent.defaultSystemPrompt, contains(name),
          reason: '$name must be documented so the model can call it');
    }
  });

  test('create_grocery_list pauses for approval, then applies', () async {
    final agent = CoachAgent(toolList: groceryTools(store));
    final client = _ScriptedClient([
      ChatResult(null, [
        ToolCall('c1', 'create_grocery_list',
            '{"name":"Weekly shop","items":["Milk","Eggs"]}'),
      ]),
      ChatResult('added your list', const []),
    ]);

    final paused = await agent.replyMessage(client, ChatMessage.user('list'));
    expect(paused.isPaused, isTrue, reason: 'a write must wait for the user');
    expect(agent.pending!.summaries.join(' '), contains('Weekly shop'),
        reason: 'the approval card must say what will be created');

    expect(store.groceryLists, isEmpty,
        reason: 'nothing applied before approval');

    await agent.approve(client);
    expect(store.groceryLists.single.name, 'Weekly shop');
    expect(
        store.groceryItemsFor(store.groceryLists.single.id).map((i) => i.text),
        ['Milk', 'Eggs']);
    expect(client.sent.last.last.content, contains('Weekly shop'),
        reason: 'the tool result is fed back to the model');
  });

  test('get_grocery_history runs without approval and returns live data',
      () async {
    final listId = await store.createGroceryList('Shop');
    final item = await store.addGroceryItem(listId, 'Milk');
    await store.setGroceryItemChecked(item.id, true);

    final agent = CoachAgent(toolList: groceryTools(store));
    final client = _ScriptedClient([
      ChatResult(null, [
        ToolCall('h1', 'get_grocery_history', '{}'),
      ]),
      ChatResult('you last bought milk', const []),
    ]);

    final turn = await agent.replyMessage(client, ChatMessage.user('history'));
    expect(turn.isPaused, isFalse, reason: 'a read needs no approval');
    expect(turn.reply, 'you last bought milk');

    final toolResult = client.sent.last.last.content;
    expect(toolResult, contains('"lists"'));
    expect(toolResult, contains('Shop'));
    expect(toolResult, contains('"timesBought":1'));
  });

  test('write tools report bad input as JSON errors, not exceptions', () async {
    final create = CreateGroceryListTool(store);
    expect(jsonDecode(await create.run({'name': '   '})),
        containsPair('error', isNotEmpty));

    final add = AddGroceryItemTool(store);
    expect(jsonDecode(await add.run({'text': 'Milk'})),
        containsPair('error', isNotEmpty),
        reason: 'no list exists yet');
    final listId = await store.createGroceryList('Shop');
    expect(jsonDecode(await add.run({'text': '', 'listId': listId})),
        containsPair('error', isNotEmpty));

    final remove = RemoveGroceryItemTool(store);
    expect(jsonDecode(await remove.run({'text': 'Absinthe'})),
        containsPair('error', isNotEmpty),
        reason: 'the item is not on any list');
  });

  test('add_grocery_item dedupes against an existing row', () async {
    final listId = await store.createGroceryList('Shop');
    final add = AddGroceryItemTool(store);
    final first = jsonDecode(await add.run({'text': 'Milk', 'listId': listId}));
    expect(first['ok'], isTrue);
    final again =
        jsonDecode(await add.run({'text': '  milk ', 'listId': listId}));
    expect(again['itemId'], first['itemId']);
    expect(store.groceryItemsFor(listId), hasLength(1));
  });

  test('summarize produces user-facing approval text', () async {
    await store.createGroceryList('Shop');
    expect(await CreateGroceryListTool(store).summarize({'name': 'Weekend'}),
        contains('Weekend'));
    expect(await AddGroceryItemTool(store).summarize({'text': 'Milk'}),
        contains('Milk'));
  });
}
