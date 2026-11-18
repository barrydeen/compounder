import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/grocery.dart';
import '../domain/grocery_match.dart';
import '../domain/grocery_model.dart';
import 'widgets.dart';

/// Grocery lists: their own screen, opened from the Diet top bar.
///
/// [GroceryListsScreen] shows every list with its item and checked counts and
/// opens [GroceryListScreen] on tap, where the shopping happens: add items,
/// tick them off, clear the ticked ones, and quick-add from purchase history.
class GroceryListsScreen extends StatelessWidget {
  const GroceryListsScreen({super.key});

  Future<void> _newList(BuildContext context, AppStore store) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewListDialog(),
    );
    if (name == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await store.createGroceryList(name);
    } on StoreException catch (e) {
      if (!context.mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final lists = store.groceryLists;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Grocery lists'),
        actions: [
          IconButton(
            tooltip: 'New list',
            onPressed: () => _newList(context, store),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: lists.isEmpty
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const EmptyState(
                  title: 'No grocery lists yet',
                  subtitle: 'Create a list to plan your shop — items you '
                      'tick off become quick-add suggestions next time.',
                  icon: Icons.shopping_cart_outlined,
                ),
                FilledButton.icon(
                  key: const Key('grocery-empty-new-list'),
                  onPressed: () => _newList(context, store),
                  icon: const Icon(Icons.add),
                  label: const Text('New list'),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              children: [
                for (final list in lists)
                  CardRow(
                    key: ValueKey('grocery-list-${list.id}'),
                    icon: Icons.shopping_cart_outlined,
                    title: list.name,
                    subtitle: () {
                      final items = store.groceryItemsFor(list.id);
                      final checked = items.where((i) => i.checked).length;
                      if (items.isEmpty) return 'No items yet';
                      return '${items.length} item${items.length == 1 ? '' : 's'}'
                          ' · $checked ticked';
                    }(),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => GroceryListScreen(listId: list.id))),
                  ),
              ],
            ),
    );
  }
}

/// One grocery list: add items, tick them off while shopping, clear the ticked
/// ones, quick-add from purchase history, and delete the list when it is done.
class GroceryListScreen extends StatefulWidget {
  const GroceryListScreen({super.key, required this.listId});

  final int listId;

  @override
  State<GroceryListScreen> createState() => _GroceryListScreenState();
}

class _GroceryListScreenState extends State<GroceryListScreen> {
  final _itemController = TextEditingController();

  @override
  void dispose() {
    _itemController.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _addItem(AppStore store, String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    try {
      await store.addGroceryItem(widget.listId, clean);
    } on StoreException catch (e) {
      _snack(e.message);
      return;
    }
    _itemController.clear();
  }

  Future<void> _deleteList(AppStore store, GroceryList list) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete list?'),
        content: Text('"${list.name}" and its items will be removed. '
            'Your purchase history is kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await store.deleteGroceryList(list.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final matches =
        store.groceryLists.where((l) => l.id == widget.listId).toList();
    if (matches.isEmpty) {
      // The list was removed out from under this screen (e.g. by a concurrent
      // edit); there is nothing left to show.
      return const Scaffold(
        body: Center(
          child: EmptyState(
            title: 'List not found',
            subtitle: 'This grocery list no longer exists.',
            icon: Icons.shopping_cart_outlined,
          ),
        ),
      );
    }
    final list = matches.single;
    final items = store.groceryItemsFor(list.id);
    final suggestions = store.grocerySuggestionsFor(list.id);
    final checkedCount = items.where((i) => i.checked).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(list.name),
        actions: [
          IconButton(
            tooltip: 'Delete list',
            onPressed: () => _deleteList(store, list),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('grocery-item-field'),
                controller: _itemController,
                textInputAction: TextInputAction.done,
                maxLength: groceryItemMaxLength,
                decoration: const InputDecoration(
                  labelText: 'Add item',
                  counterText: '',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (text) => _addItem(store, text),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Add item',
              onPressed: () => _addItem(store, _itemController.text),
              icon: const Icon(Icons.add),
            ),
          ]),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Buy again', style: t.labelLarge),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final p in suggestions)
                  ActionChip(
                    label: Text(p.text),
                    onPressed: () => _addItem(store, p.text),
                  ),
              ],
            ),
          ],
          _PairsSection(
            items: items,
            onAdd: (text) => _addItem(store, text),
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const EmptyState(
              title: 'Nothing on this list',
              subtitle: 'Add the first item above.',
              icon: Icons.list_alt,
            )
          else ...[
            for (final item in items)
              CheckboxListTile(
                key: ValueKey('grocery-item-${item.id}'),
                value: item.checked,
                onChanged: (v) =>
                    store.setGroceryItemChecked(item.id, v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  item.text,
                  style: item.checked
                      ? TextStyle(
                          decoration: TextDecoration.lineThrough,
                          color: scheme.onSurfaceVariant,
                        )
                      : null,
                ),
                secondary: IconButton(
                  tooltip: 'Remove ${item.text}',
                  onPressed: () => store.removeGroceryItem(item.id),
                  icon: const Icon(Icons.close),
                ),
              ),
            if (checkedCount > 0)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => store.clearCheckedItems(list.id),
                  icon: const Icon(Icons.done_all),
                  label: Text('Clear checked ($checkedCount)'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Model-driven "Pairs well with your list" chips.
///
/// Suggestions come from the bundled next-item model and run entirely offline.
/// The section stays hidden until at least two items on the list are recognised
/// — a co-occurrence model has nothing useful to say from a single item — and
/// stays hidden for good if the model could not be loaded, so the shopping list
/// never depends on it.
class _PairsSection extends StatefulWidget {
  const _PairsSection({required this.items, required this.onAdd});

  /// The list's current items; only their text is read.
  final List<GroceryItem> items;

  /// Called with the model's term when a chip is tapped.
  final ValueChanged<String> onAdd;

  @override
  State<_PairsSection> createState() => _PairsSectionState();
}

class _PairsSectionState extends State<_PairsSection> {
  GroceryModel? _model;

  @override
  void initState() {
    super.initState();
    _model = GroceryRecommender.cachedModel;
    if (_model == null) _loadModel();
  }

  Future<void> _loadModel() async {
    // Never throws: a failed load resolves to null and the section stays out.
    final model = await GroceryRecommender.load();
    if (!mounted || model == null) return;
    setState(() => _model = model);
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    if (model == null) return const SizedBox.shrink();

    // Resolve each item to a vocabulary term; unmatched items contribute
    // nothing rather than guessing at a near neighbour.
    final matched = <String>{};
    for (final item in widget.items) {
      final term = matchGroceryVocabularyTerm(item.text, model.vocabularyTerms);
      if (term != null) matched.add(term);
    }
    if (matched.length < 2) return const SizedBox.shrink();

    // `predict` already excludes the selected terms, so anything on the list
    // is never echoed back as a suggestion.
    final pairs = model.predict(matched);
    if (pairs.isEmpty) return const SizedBox.shrink();

    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text('Pairs well with your list', style: t.labelLarge),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final pair in pairs)
              ActionChip(
                key: ValueKey('grocery-pair-${pair.item}'),
                label: Text(pair.item),
                onPressed: () => widget.onAdd(pair.item),
              ),
          ],
        ),
      ],
    );
  }
}

/// Owns its text controller in [State] so the field cannot outlive the route
/// while the dialog is animating out.
class _NewListDialog extends StatefulWidget {
  const _NewListDialog();

  @override
  State<_NewListDialog> createState() => _NewListDialogState();
}

class _NewListDialogState extends State<_NewListDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (groceryListError(name) != null) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New grocery list'),
      content: TextField(
        key: const Key('grocery-list-name-field'),
        controller: _controller,
        autofocus: true,
        maxLength: groceryListNameMaxLength,
        decoration: const InputDecoration(
          labelText: 'Name',
          counterText: '',
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              groceryListError(_controller.text) == null ? _submit : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}
