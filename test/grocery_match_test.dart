import 'package:compounder/domain/grocery_match.dart';
import 'package:compounder/domain/grocery_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Proofs for resolving shopping-list text to the model's vocabulary.
///
/// The synthetic vocabulary the model was trained on is inconsistent in ways a
/// person's input is not — mixed singular/plural, gaps like "coffee", oddly
/// specific entries like "chicken breasts" — so this layer is where a wrong
/// answer would quietly poison the recommendation. Every rule below is
/// deliberately conservative: an unmatched item contributes nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GroceryModel model;

  setUpAll(() async {
    final loaded = await GroceryRecommender.load();
    expect(loaded, isNotNull);
    model = loaded!;
  });

  group('folding', () {
    test('lowercases, drops punctuation and collapses whitespace', () {
      expect(groceryVocabularyText('  Tomatoes  '), 'tomatoes');
      expect(groceryVocabularyText('ONIONS!'), 'onions');
      expect(groceryVocabularyText('all-purpose  flour'), 'all purpose flour');
      expect(groceryVocabularyText("bird's eye chilies"), "bird's eye chilies");
      expect(groceryVocabularyText('Bird\u2019s eye chilies'),
          "bird's eye chilies");
    });

    test('drops parenthesised notes, which are quantity or brand noise', () {
      expect(groceryVocabularyText('milk (organic)'), 'milk');
      expect(groceryVocabularyText('potatoes (2 kg)'), 'potatoes');
    });
  });

  group('quantity prefixes', () {
    test('strips a leading count and unit', () {
      expect(stripGroceryQuantityPrefix('2 kg flour'), 'flour');
      expect(stripGroceryQuantityPrefix('1 lb ground beef'), 'ground beef');
      expect(stripGroceryQuantityPrefix('3 x onions'), 'onions');
      expect(
          stripGroceryQuantityPrefix('500g chicken thighs'), 'chicken thighs');
      expect(stripGroceryQuantityPrefix('1/2 cup sugar'), 'sugar');
      expect(stripGroceryQuantityPrefix('2 bunches cilantro'), 'cilantro');
    });

    test('leaves bare items and all-quantity text alone', () {
      expect(stripGroceryQuantityPrefix('flour'), 'flour');
      expect(stripGroceryQuantityPrefix('2'), '2');
      expect(stripGroceryQuantityPrefix('2 kg'), '2 kg');
    });
  });

  group('singular and plural', () {
    test('singularizes the simple cases', () {
      expect(singularizeGroceryWord('tomatoes'), 'tomato');
      expect(singularizeGroceryWord('berries'), 'berry');
      expect(singularizeGroceryWord('onions'), 'onion');
      expect(singularizeGroceryWord('boxes'), 'box');
      expect(singularizeGroceryWord('dishes'), 'dish');
    });

    test('leaves words that only look plural alone', () {
      expect(singularizeGroceryWord('glass'), 'glass');
      expect(singularizeGroceryWord('hummus'), 'hummus');
      expect(singularizeGroceryWord('asparagus'), 'asparagus');
      expect(singularizeGroceryWord('rice'), 'rice');
    });

    test('pluralizes the simple cases', () {
      expect(pluralizeGroceryWord('onion'), 'onions');
      expect(pluralizeGroceryWord('berry'), 'berries');
      expect(pluralizeGroceryWord('tomato'), 'tomatoes');
      expect(pluralizeGroceryWord('dish'), 'dishes');
      expect(pluralizeGroceryWord('glass'), 'glasses');
      expect(pluralizeGroceryWord('onions'), 'onions');
    });
  });

  group('against the bundled vocabulary', () {
    test('matches exact terms, both numbers and with quantities', () {
      expect(matchGroceryVocabularyTerm('garlic', model.vocabularyTerms),
          'garlic');
      expect(matchGroceryVocabularyTerm('tomatoes', model.vocabularyTerms),
          'tomatoes');
      // Singular input, plural entry.
      expect(matchGroceryVocabularyTerm('tomato', model.vocabularyTerms),
          'tomatoes');
      expect(
          matchGroceryVocabularyTerm('birthday candles', model.vocabularyTerms),
          isNull);
      expect(
          matchGroceryVocabularyTerm('chicken breast', model.vocabularyTerms),
          'chicken breasts');
      expect(matchGroceryVocabularyTerm('2 kg flour', model.vocabularyTerms),
          'flour');
      expect(matchGroceryVocabularyTerm('3 x onions', model.vocabularyTerms),
          'onions');
      expect(matchGroceryVocabularyTerm('Tomatoes', model.vocabularyTerms),
          'tomatoes');
    });

    test('matches the hand-checked aliases', () {
      expect(matchGroceryVocabularyTerm('green onions', model.vocabularyTerms),
          'scallions');
      expect(matchGroceryVocabularyTerm('yoghurt', model.vocabularyTerms),
          'yogurt');
      expect(matchGroceryVocabularyTerm('capsicum', model.vocabularyTerms),
          'bell peppers');
      expect(matchGroceryVocabularyTerm('aubergine', model.vocabularyTerms),
          'eggplant');
      expect(matchGroceryVocabularyTerm('courgettes', model.vocabularyTerms),
          'zucchini');
      expect(matchGroceryVocabularyTerm('cumin', model.vocabularyTerms),
          'ground cumin');
      expect(matchGroceryVocabularyTerm('oats', model.vocabularyTerms),
          'rolled oats');
    });

    test('every alias points at a real vocabulary term', () {
      for (final entry in groceryVocabularyAliases.entries) {
        expect(model.knowsItem(entry.value), isTrue,
            reason: '"${entry.key}" aliases "${entry.value}", which the model '
                'does not know');
        final resolved =
            matchGroceryVocabularyTerm(entry.key, model.vocabularyTerms);
        expect(resolved, isNotNull, reason: entry.key);
        expect(model.knowsItem(resolved!), isTrue, reason: entry.key);
      }
    });

    test('a real vocabulary spelling beats an alias', () {
      // The alias table is a fallback, not an override: if the model already
      // knows the user's words, use them.
      expect(model.knowsItem('spring onions'), isTrue);
      expect(matchGroceryVocabularyTerm('spring onions', model.vocabularyTerms),
          'spring onions');
    });

    test('gaps stay unmatched rather than guessed', () {
      // Documented absences in the synthetic vocabulary; guessing a neighbour
      // ("coffee" -> "cocoa") would recommend against the wrong ingredient.
      for (final word in const ['coffee', 'tea', 'tofu', 'hummus', 'teff']) {
        expect(matchGroceryVocabularyTerm(word, model.vocabularyTerms), isNull,
            reason: word);
      }
    });

    test('matching is deterministic', () {
      const input = '2 KG Chicken Breasts';
      final first = matchGroceryVocabularyTerm(input, model.vocabularyTerms);
      for (var i = 0; i < 5; i++) {
        expect(matchGroceryVocabularyTerm(input, model.vocabularyTerms), first);
      }
      expect(first, 'chicken breasts');
    });

    test('empty input matches nothing', () {
      expect(matchGroceryVocabularyTerm('', model.vocabularyTerms), isNull);
      expect(matchGroceryVocabularyTerm('   ', model.vocabularyTerms), isNull);
      expect(matchGroceryVocabularyTerm('()', model.vocabularyTerms), isNull);
    });
  });

  group('candidate order', () {
    test('exact spelling wins over the guessed variants', () {
      expect(groceryVocabularyCandidates('tomatoes').first, 'tomatoes');
      expect(groceryVocabularyCandidates('2 kg tomatoes'),
          containsAllInOrder(['2 kg tomatoes', 'tomatoes']));
    });

    test('the alias sits between the literal forms and the morphology', () {
      expect(groceryVocabularyCandidates('green onions'),
          containsAllInOrder(['green onions', 'scallions']));
    });
  });
}
