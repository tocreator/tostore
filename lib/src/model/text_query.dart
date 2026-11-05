import 'db_exception.dart';
import 'result_status.dart';
import 'result_type.dart';

/// How query terms combine in a text retrieval.
enum TextMatchOperator {
  /// Match any query term; results are ranked by relevance.
  or,

  /// Require every query term; results are ranked by relevance.
  and,
}

/// One pre-tokenized query term and its weight.
///
/// [weight] is a multiplier. The default is 1. Non-positive weights are dropped
/// when the query is built.
class TextTerm {
  /// Query term string.
  final String term;

  /// Per-term multiplier.
  final double weight;

  const TextTerm(this.term, {this.weight = 1});
}

/// Query input for [IndexType.text] retrieval.
///
/// Use [TextQuery.text] for raw text (the engine tokenizes it).
/// Use [TextQuery.terms] or [TextQuery.termsWeighted] when terms are already
/// split. Pre-tokenized terms are matched as given — built-in indexing stores
/// Latin tokens in lowercase, so `Kernel` does not match `kernel`.
class TextQuery {
  /// Raw text. Null when [weightedTerms] is set.
  final String? text;

  /// Pre-tokenized term weights. Null when [text] is set.
  ///
  /// Duplicate terms are summed.
  final Map<String, double>? weightedTerms;
  final int _hashCode;

  TextQuery._(this.text, this.weightedTerms)
      : _hashCode = _computeHashCode(text, weightedTerms);

  /// Raw query text; tokenized by the engine.
  factory TextQuery.text(String text) => TextQuery._(text, null);

  /// Pre-tokenized terms, each with weight 1.
  ///
  /// Repeated strings add weight.
  factory TextQuery.terms(List<String> terms) => TextQuery._(
        null,
        _normalize(terms.map((term) => TextTerm(term))),
      );

  /// Pre-tokenized terms with explicit weights.
  ///
  /// Weights of the same [TextTerm.term] are summed.
  factory TextQuery.termsWeighted(List<TextTerm> terms) =>
      TextQuery._(null, _normalize(terms));

  /// Whether this query carries pre-tokenized terms.
  bool get isPreTokenized => weightedTerms != null;

  static Map<String, double> _normalize(Iterable<TextTerm> terms) {
    final weights = <String, double>{};
    for (final item in terms) {
      if (item.term.trim().isEmpty) {
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentFormat,
            message: 'Text term must not be empty.',
            parameterName: 'terms',
            passedValue: item.term,
          ),
        ]);
      }
      if (item.weight <= 0) continue;
      if (!item.weight.isFinite) {
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentFormat,
            message: 'Text term weight must be finite.',
            parameterName: 'weight',
            passedValue: item.weight,
          ),
        ]);
      }
      weights[item.term] = (weights[item.term] ?? 0) + item.weight;
    }
    return Map<String, double>.unmodifiable(weights);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TextQuery) return false;
    if (text != null) return text == other.text;
    if (other.text != null) return false;
    final w1 = weightedTerms;
    final w2 = other.weightedTerms;
    if (w1 == null || w2 == null) return w1 == w2;
    if (w1.length != w2.length) return false;
    for (final entry in w1.entries) {
      if (w2[entry.key] != entry.value) return false;
    }
    return true;
  }

  static int _computeHashCode(
      String? text, Map<String, double>? weightedTerms) {
    if (text != null) return text.hashCode;
    // Order-independent: [==] compares by key, so hash must not depend on
    // map insertion order.
    var h = 0;
    if (weightedTerms != null) {
      for (final entry in weightedTerms.entries) {
        h ^= Object.hash(entry.key, entry.value);
      }
    }
    return h;
  }

  @override
  int get hashCode => _hashCode;
}
