/// Maps what a person types on a shopping list onto the recommender's
/// vocabulary.
///
/// The model was trained on a synthetic corpus whose spelling is inconsistent —
/// some entries are plural ("onions", "tomatoes"), others singular ("garlic",
/// "bread"), a few are oddly specific ("chicken breasts" but nothing for
/// "chicken breast"), and some everyday items are missing entirely ("coffee").
/// So matching is deliberately forgiving and entirely deterministic:
///
/// 1. fold case, punctuation and whitespace, dropping parenthesised notes such
///    as "milk (organic)" — the note is never part of the vocabulary;
/// 2. strip a leading quantity and unit ("2 kg", "1 lb", "3 x", "500g");
/// 3. try the folded text, then its plural and singular forms (both directions,
///    because the vocabulary is inconsistent about number);
/// 4. fall back to a small hand-checked alias table for known misses.
///
/// Anything still unmatched simply contributes nothing to the recommendation,
/// which is the right failure mode: a wrong match would silently recommend
/// against a different ingredient.
library;

/// Quantity and unit words accepted in front of an item ("2 kg flour").
///
/// Kept narrow on purpose: a word only belongs here if stripping it can never
/// change which ingredient the item is.
const Set<String> groceryQuantityUnits = {
  'kg',
  'kgs',
  'g',
  'gram',
  'grams',
  'lb',
  'lbs',
  'pound',
  'pounds',
  'oz',
  'ounce',
  'ounces',
  'l',
  'liter',
  'liters',
  'litre',
  'litres',
  'ml',
  'x',
  'cup',
  'cups',
  'tbsp',
  'tsp',
  'bunch',
  'bunches',
  'pack',
  'packs',
  'packet',
  'packets',
  'bag',
  'bags',
  'can',
  'cans',
  'jar',
  'jars',
  'box',
  'boxes',
  'piece',
  'pieces',
  'clove',
  'cloves',
  'slice',
  'slices',
  'head',
  'heads',
  'loaf',
  'loaves',
  'bottle',
  'bottles',
};

/// Unambiguous synonyms for items the synthetic vocabulary spells differently.
///
/// Only one-to-one mappings belong here — "tortillas" stays unmatched rather
/// than guessing between corn and flour. Every target must exist in the model
/// vocabulary; `test/grocery_match_test.dart` asserts that for the bundled
/// model, so a future re-export of the model cannot leave dead aliases behind.
const Map<String, String> groceryVocabularyAliases = {
  'yoghurt': 'yogurt',
  'green onions': 'scallions',
  'green onion': 'scallions',
  'spring onions': 'scallions',
  'spring onion': 'scallions',
  'capsicum': 'bell peppers',
  'capsicums': 'bell peppers',
  'aubergine': 'eggplant',
  'aubergines': 'eggplant',
  'courgette': 'zucchini',
  'courgettes': 'zucchini',
  'cumin': 'ground cumin',
  'cumin powder': 'ground cumin',
  'oats': 'rolled oats',
  'porridge oats': 'rolled oats',
  'kidney beans': 'red kidney beans',
  'garbanzo beans': 'chickpeas',
  'rock salt': 'salt',
  'sea salt': 'salt',
  'table salt': 'salt',
  'plain flour': 'all purpose flour',
  'all-purpose flour': 'all purpose flour',
};

/// Folds free text to the shape the model's vocabulary uses.
///
/// Lowercase; parenthesised asides dropped; apostrophes kept (the vocabulary
/// has "bird's eye chilies"); every other punctuation character becomes a
/// space, so "all-purpose" and "all purpose" fold together; whitespace
/// collapsed and trimmed.
String groceryVocabularyText(String text) {
  final withoutNotes = text.replaceAll(RegExp(r'\([^)]*\)'), ' ');
  final folded = withoutNotes
      .toLowerCase()
      .replaceAll('\u2019', "'")
      .replaceAll('\u2018', "'")
      .replaceAll(RegExp(r"[^a-z0-9']+"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return folded;
}

/// Drops leading quantity/unit tokens: "2 kg flour" -> "flour", "3 x onions"
/// -> "onions", "500g chicken thighs" -> "chicken thighs".
///
/// Returns the input unchanged when stripping would leave nothing, so an item
/// that is *only* a number ("2") is never treated as empty.
String stripGroceryQuantityPrefix(String folded) {
  final tokens = folded.split(' ');
  var index = 0;
  while (index < tokens.length) {
    final token = tokens[index];
    final isCount = RegExp(r'^\d+([./]\d+)?$').hasMatch(token);
    final isCountWithUnit =
        RegExp(r'^\d+([./]\d+)?(kg|kgs|g|lbs?|oz|ml|l)$').hasMatch(token);
    if (!isCount && !isCountWithUnit && !groceryQuantityUnits.contains(token)) {
      break;
    }
    index++;
  }
  if (index == 0 || index == tokens.length) return folded;
  return tokens.sublist(index).join(' ');
}

/// Candidate vocabulary spellings for [text], most literal first.
///
/// Callers take the first candidate that exists in the vocabulary, which is
/// why order matters: an exact match always beats a guessed variant.
List<String> groceryVocabularyCandidates(String text) {
  final folded = groceryVocabularyText(text);
  if (folded.isEmpty) return const <String>[];
  final stripped = stripGroceryQuantityPrefix(folded);
  final candidates = <String>[folded];
  void add(String candidate) {
    if (candidate.isNotEmpty && !candidates.contains(candidate)) {
      candidates.add(candidate);
    }
  }

  add(stripped);
  final alias =
      groceryVocabularyAliases[stripped] ?? groceryVocabularyAliases[folded];
  if (alias != null) {
    add(alias);
  }
  // The vocabulary mixes numbers, so try both directions around the last word:
  // "apple" -> "apples", "onions" -> "onion", "green onions" -> "green onion".
  add(_lastWord(stripped, pluralizeGroceryWord));
  add(_lastWord(stripped, singularizeGroceryWord));
  return candidates;
}

/// Resolves [text] to a vocabulary term, or null when nothing matches.
String? matchGroceryVocabularyTerm(String text, Set<String> vocabulary) {
  for (final candidate in groceryVocabularyCandidates(text)) {
    if (vocabulary.contains(candidate)) return candidate;
  }
  return null;
}

/// Best-effort singular of one word ("tomatoes" -> "tomato", "berries" ->
/// "berry"). Short and irregular words are returned unchanged rather than
/// mangled.
String singularizeGroceryWord(String word) {
  if (word.length < 4) return word;
  if (word.endsWith('ies') && word.length > 4) {
    return '${word.substring(0, word.length - 3)}y';
  }
  if (word.endsWith('oes')) return word.substring(0, word.length - 2);
  for (final suffix in const ['ses', 'xes', 'zes', 'ches', 'shes']) {
    if (word.endsWith(suffix)) return word.substring(0, word.length - 2);
  }
  if (word.endsWith('s') &&
      !word.endsWith('ss') &&
      !word.endsWith('us') &&
      !word.endsWith('is')) {
    return word.substring(0, word.length - 1);
  }
  return word;
}

/// Best-effort plural of one word ("onion" -> "onions", "berry" -> "berries",
/// "tomato" -> "tomatoes"). Words that already end in "s" are left alone.
String pluralizeGroceryWord(String word) {
  if (word.isEmpty) return word;
  // A double-s word ("glass") is singular despite the s; every other s-ending
  // word is treated as already plural, because guessing otherwise mangles
  // "onions" and "tomatoes" is handled below.
  if (word.endsWith('ss')) return '${word}es';
  if (word.endsWith('s')) return word;
  if (word.endsWith('y') &&
      word.length > 1 &&
      !'aeiou'.contains(word[word.length - 2])) {
    return '${word.substring(0, word.length - 1)}ies';
  }
  for (final suffix in const ['ch', 'sh', 'x', 'z', 'o']) {
    if (word.endsWith(suffix)) return '${word}es';
  }
  return '${word}s';
}

String _lastWord(String text, String Function(String) transform) {
  final words = text.split(' ');
  if (words.isEmpty || words.last.isEmpty) return text;
  words[words.length - 1] = transform(words.last);
  return words.join(' ');
}
