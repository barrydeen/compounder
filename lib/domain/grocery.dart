import '../data/models.dart';

/// Longest accepted grocery item text. Long enough for "2 kg chicken thighs,
/// boneless", short enough that a shopping row stays readable at accessibility
/// text scales.
const int groceryItemMaxLength = 80;

/// Longest accepted list name.
const int groceryListNameMaxLength = 60;

/// How many purchase-history suggestions the quick-add row offers.
const int grocerySuggestionLimit = 8;

/// Canonical form of an item text, used to match a typed item against purchase
/// history and to stop the same item being added twice to one list.
///
/// Case, surrounding whitespace and repeated internal whitespace are folded so
/// "Chicken  Thighs" and "chicken thighs" are one purchase record rather than
/// two. Punctuation is kept: "milk" and "milk!" are close enough that folding
/// them would be surprising, and the ranking already prefers the most-bought
/// spelling.
String groceryTextKey(String text) =>
    text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Validation boundary shared by the grocery screen and the coach tools.
///
/// Returns null when [text] is acceptable, otherwise a message safe to show the
/// user as-is.
String? groceryItemError(String text) {
  final clean = text.trim();
  if (clean.isEmpty) return 'Item cannot be empty.';
  if (clean.length > groceryItemMaxLength) {
    return 'Item is too long (max $groceryItemMaxLength characters).';
  }
  return null;
}

/// Validation boundary for a list name; null when [name] is acceptable.
String? groceryListError(String name) {
  final clean = name.trim();
  if (clean.isEmpty) return 'List name cannot be empty.';
  if (clean.length > groceryListNameMaxLength) {
    return 'List name is too long (max $groceryListNameMaxLength characters).';
  }
  return null;
}

/// Ranks purchase history into quick-add suggestions.
///
/// Ordered by how often the item was bought, then by recency, then
/// alphabetically so the order is stable across identical histories. Items
/// already on the list being built ([excludeKeys]) are dropped: suggesting
/// something the user just typed is noise.
///
/// Pure so the ranking is testable without a database.
List<PurchaseRecord> grocerySuggestions(
  Iterable<PurchaseRecord> purchases, {
  Set<String> excludeKeys = const {},
  int limit = grocerySuggestionLimit,
}) {
  final ranked = purchases
      .where((p) => p.timesBought > 0 && !excludeKeys.contains(p.textKey))
      .toList()
    ..sort((a, b) {
      final byCount = b.timesBought.compareTo(a.timesBought);
      if (byCount != 0) return byCount;
      final byRecency = b.lastBoughtAt.compareTo(a.lastBoughtAt);
      if (byRecency != 0) return byRecency;
      return a.text.toLowerCase().compareTo(b.text.toLowerCase());
    });
  return ranked.take(limit < 0 ? 0 : limit).toList();
}
