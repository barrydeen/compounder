/// Offline next-item recommender for grocery lists.
///
/// A Dart port of the owner's `grocery.py` reference implementation
/// (huggingface.co/barrydeen/grocery-next-model), bundled as
/// `assets/grocery_next_model.json`. Everything runs on device: the asset is
/// read once, parsed in a background isolate, and cached for the session.
///
/// Scoring, for a candidate `c` and each selected item `s`, is the smoothed
/// pairwise association estimate
///
///     confidence = (pair_count(s, c) + smoothing * P(c)) / (item_count(s) + smoothing)
///
/// averaged over the selected items, then re-ranked by
///
///     score = confidence / (1 + popularity_penalty * P(c))
///
/// with `P(c) = item_count(c) / total_lists`. The popularity penalty keeps
/// ubiquitous pantry staples (salt, oil, onions) from swamping every list by
/// favouring items that are characteristic of *this* selection. Selected items
/// are never returned, and ties are broken alphabetically so output is stable.
library;

import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One recommended item and its score, higher is stronger.
class GroceryPrediction {
  const GroceryPrediction(this.item, this.score);

  /// The vocabulary term, already folded to the model's spelling.
  final String item;

  /// Re-ranked association score in `[0, 1]`.
  final double score;
}

/// The trained model: item frequencies, pairwise co-occurrence counts and the
/// smoothing constant read from the bundled asset.
///
/// Pure data plus arithmetic — no I/O, no platform channels — so it can be
/// built and scored inside an isolate and unit-tested against the Python
/// reference vectors.
class GroceryModel {
  GroceryModel._({
    required this.smoothing,
    required this.totalLists,
    required Map<String, int> itemCounts,
    required Map<String, int> pairCounts,
  })  : _itemCounts = itemCounts,
        _pairCounts = pairCounts,
        vocabulary = (itemCounts.keys.toList()..sort());

  /// Model file format this port understands; anything else is rejected so a
  /// future format bump degrades to no suggestions rather than wrong ones.
  static const int formatVersion = 1;

  /// Smoothing constant used by the reference model.
  final double smoothing;

  /// Number of training baskets the counts were built from.
  final int totalLists;

  final Map<String, int> _itemCounts;
  final Map<String, int> _pairCounts;

  /// Every item the model knows, sorted, so lookups and output are stable.
  final List<String> vocabulary;

  /// [vocabulary] as a set, for the matching layer's membership tests.
  late final Set<String> vocabularyTerms = vocabulary.toSet();

  /// Spelling of [item] as the model stores it, or null when it is unknown.
  ///
  /// Keys are already normalized by the reference trainer, so this is a plain
  /// map hit.
  String? canonicalItem(String item) =>
      _itemCounts.containsKey(item) ? item : null;

  /// Folds one selected item the way `grocery.py` does before scoring:
  /// lowercase, internal whitespace collapsed, trimmed.
  static String normalizeTerm(String item) =>
      item.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// The vocabulary item [term] resolves to, or null. [term] must already be
  /// folded by [groceryVocabularyText] and its singular/plural/alias variants.
  bool knowsItem(String term) => _itemCounts.containsKey(term);

  /// Frequency of [item] across the training baskets (0 when unknown).
  int itemCount(String item) => _itemCounts[item] ?? 0;

  /// Co-occurrence count for the unordered pair ([a], [b]).
  int pairCount(String a, String b) => _pairCounts[pairKey(a, b)] ?? 0;

  /// Unordered pair key. The reference implementation sorts the pair before
  /// hashing, so the key is order-independent.
  static String pairKey(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a\u0000$b' : '$b\u0000$a';

  /// Ranks candidates for [selected] (already folded vocabulary terms).
  ///
  /// Mirrors `GroceryModel.predict` from `grocery.py`: unknown selected items
  /// contribute the prior-only estimate, and at least two distinct items are
  /// required — fewer returns an empty list instead of the reference
  /// implementation's exception, because an app screen must not throw.
  List<GroceryPrediction> predict(
    Iterable<String> selected, {
    int limit = 5,
    double popularityPenalty = 8.0,
  }) {
    final chosen = selected
        .map(normalizeTerm)
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (chosen.length < 2 || limit < 1 || totalLists < 1) {
      return const <GroceryPrediction>[];
    }
    final chosenSet = chosen.toSet();
    final predictions = <GroceryPrediction>[];
    for (final candidate in vocabulary) {
      if (chosenSet.contains(candidate)) continue;
      final prior = _itemCounts[candidate]! / totalLists;
      var total = 0.0;
      for (final item in chosen) {
        final itemCount = _itemCounts[item] ?? 0;
        final pairCount = _pairCounts[pairKey(item, candidate)] ?? 0;
        total += (pairCount + smoothing * prior) / (itemCount + smoothing);
      }
      final confidence = total / chosen.length;
      predictions.add(GroceryPrediction(
        candidate,
        confidence / (1 + popularityPenalty * prior),
      ));
    }
    predictions.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.item.compareTo(b.item);
    });
    return predictions.length > limit
        ? predictions.sublist(0, limit)
        : predictions;
  }

  /// Parses the bundled model JSON.
  ///
  /// Throws [FormatException] on anything unexpected (wrong format version,
  /// missing or malformed fields) so the caller can fall back to no
  /// suggestions.
  static GroceryModel parse(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('model root is not an object');
    }
    final version = decoded['format_version'];
    if (version != formatVersion) {
      throw FormatException('unsupported model format: $version');
    }
    final smoothing = (decoded['smoothing'] as num?)?.toDouble();
    final totalLists = (decoded['total_lists'] as num?)?.toInt();
    final rawItems = decoded['item_counts'];
    final rawPairs = decoded['pair_counts'];
    if (smoothing == null ||
        smoothing <= 0 ||
        !smoothing.isFinite ||
        totalLists == null ||
        totalLists < 1 ||
        rawItems is! Map<String, Object?> ||
        rawPairs is! List<Object?>) {
      throw const FormatException('model file is empty or invalid');
    }
    final itemCounts = <String, int>{};
    for (final entry in rawItems.entries) {
      final count = (entry.value as num?)?.toInt();
      if (count == null) {
        throw FormatException('bad item count for ${entry.key}');
      }
      itemCounts[entry.key] = count;
    }
    if (itemCounts.isEmpty) {
      throw const FormatException('model has no items');
    }
    final pairCounts = <String, int>{};
    for (final entry in rawPairs) {
      if (entry is! List<Object?> || entry.length != 3) {
        throw const FormatException('bad pair entry');
      }
      final first = entry[0];
      final second = entry[1];
      final count = (entry[2] as num?)?.toInt();
      if (first is! String || second is! String || count == null) {
        throw const FormatException('bad pair entry');
      }
      pairCounts[pairKey(first, second)] = count;
    }
    return GroceryModel._(
      smoothing: smoothing,
      totalLists: totalLists,
      itemCounts: itemCounts,
      pairCounts: pairCounts,
    );
  }

  /// Decodes and parses [bytes] off the UI isolate.
  ///
  /// [bytes] are the raw asset contents; the decode and parse happen on a
  /// worker isolate so a 2.3 MB model does not jank the first grocery screen.
  static Future<GroceryModel> parseInBackground(Uint8List bytes) =>
      Isolate.run(() => parse(utf8.decode(bytes)));
}

/// Loads and caches the bundled model, once per app session.
///
/// Every failure path — missing asset, corrupt JSON, an isolate that will not
/// spawn — resolves to null, and callers show no suggestions. A recommender is
/// a nicety; it must never break the shopping list.
class GroceryRecommender {
  GroceryRecommender._();

  /// Asset path declared in `pubspec.yaml`.
  static const String assetPath = 'assets/grocery_next_model.json';

  /// sha256 of the vendored file, as published on Hugging Face. The test suite
  /// re-checks it, so a silent re-export cannot slip in unnoticed.
  static const String assetSha256 =
      'd55de601a87a05c1f9f3d5b58379ac9f3617d0c2560a1745699bf162bab66884';

  static Future<GroceryModel?>? _pending;
  static GroceryModel? _loaded;
  static GroceryModel? _override;

  /// The model if it is already loaded, so a rebuild never waits on the asset.
  static GroceryModel? get cachedModel => _override ?? _loaded;

  /// Loads the model, reusing the in-flight or completed load.
  ///
  /// [bundle] is overridable for tests; production always reads [rootBundle].
  static Future<GroceryModel?> load({AssetBundle? bundle}) {
    final override = _override;
    if (override != null) return Future<GroceryModel?>.value(override);
    final loaded = _loaded;
    if (loaded != null) return Future<GroceryModel?>.value(loaded);
    return _pending ??= _load(bundle ?? rootBundle);
  }

  static Future<GroceryModel?> _load(AssetBundle bundle) async {
    try {
      final data = await bundle.load(assetPath);
      final model = await GroceryModel.parseInBackground(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      _loaded = model;
      return model;
    } catch (error, stack) {
      // Deliberately swallowed: the grocery list works without suggestions.
      debugPrint('grocery recommender unavailable: $error\n$stack');
      return null;
    }
  }

  /// Test seam: pins the model without touching the asset bundle.
  @visibleForTesting
  static void debugSetModel(GroceryModel? model) {
    _override = model;
    _pending = null;
    _loaded = null;
  }

  /// Test seam: drops the cached model and any in-flight load.
  @visibleForTesting
  static void debugReset() {
    _override = null;
    _pending = null;
    _loaded = null;
  }
}
