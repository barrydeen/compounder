import 'dart:convert';
import 'dart:io';

import 'package:compounder/domain/grocery_model.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Proofs for the bundled next-item recommender.
///
/// The scoring port has to agree with the owner's Python reference
/// (`grocery.py` from huggingface.co/barrydeen/grocery-next-model) or the
/// suggestions are fiction, so the goldens in
/// `test/fixtures/grocery_model_reference.json` are that script's own output
/// for seven input sets. The remaining proofs cover the two things that would
/// make the feature dangerous rather than merely wrong: an asset that silently
/// changed, and a load failure that reached the UI as an exception.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GroceryModel model;

  setUpAll(() async {
    final loaded = await GroceryRecommender.load();
    expect(loaded, isNotNull, reason: 'the bundled model must load');
    model = loaded!;
  });

  group('bundled asset', () {
    test('is declared in pubspec and matches the published sha256', () async {
      final data = await rootBundle.load(GroceryRecommender.assetPath);
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      expect(bytes.length, 2368838);
      expect(sha256.convert(bytes).toString(), GroceryRecommender.assetSha256,
          reason: 'the vendored model must be the published file, byte for '
              'byte; re-vendor rather than editing it');
    });

    test('parses to the documented shape', () {
      expect(model.smoothing, 4.0);
      expect(model.totalLists, 28000);
      expect(model.vocabulary, hasLength(1256));
      expect(model.itemCount('bread'), 93);
      expect(model.itemCount('pasta'), 15);
      expect(model.itemCount('cheese'), 12);
      expect(model.itemCount('chicken breasts'), greaterThan(0));
      expect(model.knowsItem('coffee'), isFalse,
          reason: 'documented gap in the synthetic vocabulary');
      // Spot-check the pair index independent of the scoring path.
      expect(model.pairCount('onions', 'garlic'),
          model.pairCount('garlic', 'onions'));
      expect(model.pairCount('onions', 'garlic'), greaterThan(0));
    });
  });

  group('scoring matches the Python reference', () {
    final reference = jsonDecode(
      File('test/fixtures/grocery_model_reference.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final cases = reference['cases']! as List<Object?>;

    test('the fixtures were generated from this exact model', () {
      expect(reference['model_sha256'], GroceryRecommender.assetSha256);
      expect(cases, hasLength(greaterThanOrEqualTo(3)));
    });

    for (final entry in cases.cast<Map<String, Object?>>()) {
      final items = (entry['items']! as List<Object?>).cast<String>();
      final penalty = (entry['popularity_penalty']! as num).toDouble();
      final limit = (entry['limit']! as num).toInt();
      final expected = (entry['expected']! as List<Object?>)
          .cast<List<Object?>>()
          .map((row) => (row[0]! as String, (row[1]! as num).toDouble()))
          .toList();

      test('${items.join(' + ')} (penalty $penalty)', () {
        final actual = model.predict(
          items,
          limit: limit,
          popularityPenalty: penalty,
        );
        expect(actual.map((p) => p.item).toList(),
            expected.map((e) => e.$1).toList(),
            reason: 'ranking and tie-break order must match grocery.py');
        for (var i = 0; i < expected.length; i++) {
          expect(actual[i].score, closeTo(expected[i].$2, 1e-6),
              reason: 'score for ${actual[i].item}');
        }
      });
    }
  });

  group('scoring rules', () {
    test('needs two distinct items', () {
      expect(model.predict(const []), isEmpty);
      expect(model.predict(const ['tomatoes']), isEmpty);
      expect(model.predict(const ['tomatoes', 'tomatoes']), isEmpty);
      expect(model.predict(const ['tomatoes', '  ']), isEmpty);
    });

    test('never returns a selected item', () {
      final items = ['tomatoes', 'onions', 'garlic', 'rice'];
      final predictions = model.predict(items, limit: 20);
      expect(predictions, isNotEmpty);
      for (final prediction in predictions) {
        expect(items, isNot(contains(prediction.item)));
      }
    });

    test('folds case and stray whitespace like the reference', () {
      final plain = model.predict(const ['tomatoes', 'onions']);
      final messy = model.predict(const ['  Tomatoes ', 'ONIONS']);
      expect(messy.map((p) => p.item), plain.map((p) => p.item));
      expect(messy.map((p) => p.score), plain.map((p) => p.score));
    });

    test('an unknown item contributes the prior-only estimate', () {
      final unknown = model.predict(const ['injera', 'unmatched thing']);
      final known = model.predict(const ['injera', 'berbere']);
      expect(unknown, isNotEmpty);
      expect(unknown.first.item, 'berbere',
          reason: 'the unknown half adds only smoothing*prior to every '
              'candidate, favouring items that pair with injera');
      expect(known.first.item, isNot('berbere'));
    });

    test('limit caps the list and stays deterministic', () {
      final five = model.predict(const ['tomatoes', 'onions'], limit: 5);
      final three = model.predict(const ['tomatoes', 'onions'], limit: 3);
      expect(five, hasLength(5));
      expect(three, hasLength(3));
      expect(three.map((p) => p.item), five.take(3).map((p) => p.item));
      expect(model.predict(const ['onions', 'tomatoes']).map((p) => p.item),
          five.map((p) => p.item),
          reason: 'input order must not change the ranking');
    });
  });

  group('parsing', () {
    test('rejects a future format version', () {
      expect(
        () => GroceryModel.parse(
            '{"format_version":2,"smoothing":4,"total_lists":1,"item_counts":{},"pair_counts":[]}'),
        throwsFormatException,
      );
    });

    test('rejects junk', () {
      expect(() => GroceryModel.parse('not json'), throwsFormatException);
      expect(() => GroceryModel.parse('[]'), throwsFormatException);
      expect(() => GroceryModel.parse('{}'), throwsFormatException);
    });

    test('rejects a non-positive smoothing constant', () {
      expect(
        () => GroceryModel.parse(
            '{"format_version":1,"smoothing":0,"total_lists":1,"item_counts":{"a":1},"pair_counts":[]}'),
        throwsFormatException,
      );
    });

    test('builds a working model from a minimal document', () {
      final small = GroceryModel.parse('{"format_version":1,"smoothing":4.0,'
          '"total_lists":10,"item_counts":{"a":5,"b":4,"c":3},'
          '"pair_counts":[["a","b",4]]}');
      expect(small.vocabulary, ['a', 'b', 'c']);
      final predictions = small.predict(const ['a', 'b']);
      expect(predictions.single.item, 'c');
    });
  });

  group('loading is fail-soft', () {
    tearDown(GroceryRecommender.debugReset);

    test('a missing asset degrades to null instead of throwing', () async {
      GroceryRecommender.debugReset();
      final result =
          await GroceryRecommender.load(bundle: _BrokenBundle('no such asset'));
      expect(result, isNull);
    });

    test('a corrupt asset degrades to null instead of throwing', () async {
      GroceryRecommender.debugReset();
      final result = await GroceryRecommender.load(
        bundle: _BytesBundle(Uint8List.fromList(utf8.encode('{"truncated": '))),
      );
      expect(result, isNull);
    });

    test('a load failure is cached so the screen does not retry per frame',
        () async {
      GroceryRecommender.debugReset();
      var reads = 0;
      final bundle = _BrokenBundle('missing', onLoad: () => reads++);
      expect(await GroceryRecommender.load(bundle: bundle), isNull);
      expect(await GroceryRecommender.load(bundle: bundle), isNull);
      expect(reads, 1);
    });

    test('a successful load is reused rather than re-parsed', () async {
      GroceryRecommender.debugReset();
      final first = await GroceryRecommender.load();
      final second = await GroceryRecommender.load();
      expect(first, isNotNull);
      expect(identical(first, second), isTrue);
      expect(identical(GroceryRecommender.cachedModel, first), isTrue);
    });

    test('the test seam pins and clears the model', () async {
      GroceryRecommender.debugSetModel(model);
      expect(identical(GroceryRecommender.cachedModel, model), isTrue);
      expect(identical(await GroceryRecommender.load(), model), isTrue);
      GroceryRecommender.debugReset();
      expect(GroceryRecommender.cachedModel, isNull);
    });
  });
}

class _BrokenBundle extends CachingAssetBundle {
  _BrokenBundle(this.message, {this.onLoad});

  final String message;
  final void Function()? onLoad;

  @override
  Future<ByteData> load(String key) async {
    onLoad?.call();
    throw Exception(message);
  }
}

class _BytesBundle extends CachingAssetBundle {
  _BytesBundle(this.bytes);

  final Uint8List bytes;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(bytes));
}
