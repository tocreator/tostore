import 'db_exception.dart';
import 'result_status.dart';
import 'result_type.dart';

/// How query terms combine in a text retrieval.
enum TextMatchOperator {
  /// Union of query terms, ranked by additive exact score.
  or,

  /// A document must carry every query term. Rank uses the same additive score.
  and,
}

/// One pre-tokenized query term and its weight.
///
/// [weight] is a multiplier. The default is 1. Non-positive weights are dropped
/// when the query is built.
class TextTerm {
  /// Term string. Matched exactly against indexed terms.
  final String term;

  /// Per-term multiplier.
  final double weight;

  const TextTerm(this.term, {this.weight = 1});
}

/// Query input for [IndexType.text] retrieval.
///
/// [TextQuery.text] is tokenized by the engine.
/// [TextQuery.terms] and [TextQuery.termsWeighted] are already tokenized.
/// The engine does not segment, expand, or change the case of those terms.
/// Indexed Latin terms from the built-in segmenter are lowercase, so a
/// pre-tokenized `Kernel` does not match an indexed `kernel`.
class TextQuery {
  /// Raw text. Null when [weightedTerms] is set.
  final String? text;

  /// Normalized pre-tokenized term weights. Null when [text] is set.
  ///
  /// Duplicate terms are summed. This is the form the retrieval kernel reads.
  final Map<String, double>? weightedTerms;
  final int _hashCode;

  TextQuery._(this.text, this.weightedTerms)
      : _hashCode = _computeHashCode(text, weightedTerms);

  /// Tokenize [text] with the built-in Unicode / CJK segmenter.
  factory TextQuery.text(String text) => TextQuery._(text, null);

  /// Pre-tokenized terms, each with weight 1.
  ///
  /// Repeated strings add weight, matching the built-in segmenter's term counts.
  /// The engine does not segment these strings again.
  factory TextQuery.terms(List<String> terms) => TextQuery._(
        null,
        _normalize(terms.map((term) => TextTerm(term))),
      );

  /// Pre-tokenized terms with explicit weights.
  ///
  /// Weights of the same [TextTerm.term] are summed. The engine does not
  /// segment these strings again.
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
