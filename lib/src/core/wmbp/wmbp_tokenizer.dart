/// Zero-dependency segmenter: Unicode word spans plus CJK unigram/bigram.
abstract final class WmbpTokenizer {
  /// Tokenizes [text] directly into [counts] without buffering CJK runs.
  static void tokenizeCounts(String text, Map<String, int> counts) {
    if (text.isEmpty) return;
    scanTokens(text, (String key) {
      counts[key] = (counts[key] ?? 0) + 1;
    });
  }

  /// Tokenizes [text] into lowercase words and CJK unigrams/bigrams.
  static List<String> tokenize(String text) {
    if (text.isEmpty) return const <String>[];
    final out = <String>[];
    scanTokens(text, out.add);
    return out;
  }

  /// Streams normalized word tokens and CJK unigrams/bigrams from [text]
  /// directly to [onToken] with O(1) scratch state.
  static void scanTokens(String text, void Function(String token) onToken) {
    if (text.isEmpty) return;
    final units = text.codeUnits;
    final int len = units.length;
    var wordStart = -1;
    var hasUpper = false;
    var prevCjk = -1;

    void flushWord(int end) {
      if (wordStart >= 0) {
        final w = text.substring(wordStart, end);
        onToken(hasUpper ? w.toLowerCase() : w);
        wordStart = -1;
        hasUpper = false;
      }
    }

    for (int i = 0; i < len; i++) {
      final int cu = units[i];
      if (cu >= 0xD800 && cu <= 0xDBFF && i + 1 < len) {
        final int cu2 = units[i + 1];
        if (cu2 >= 0xDC00 && cu2 <= 0xDFFF) {
          final int cp = 0x10000 + ((cu - 0xD800) << 10) + (cu2 - 0xDC00);
          flushWord(i);
          i++;
          if (isCjkCodePoint(cp)) {
            onToken(String.fromCharCode(cp));
            if (prevCjk >= 0) {
              onToken(String.fromCharCodes(<int>[prevCjk, cp]));
            }
            prevCjk = cp;
          } else {
            prevCjk = -1;
          }
          continue;
        }
      }
      if (isCjk(cu)) {
        flushWord(i);
        onToken(String.fromCharCode(cu));
        if (prevCjk >= 0) {
          onToken(String.fromCharCodes(<int>[prevCjk, cu]));
        }
        prevCjk = cu;
        continue;
      }
      prevCjk = -1;
      if (isWordUnit(cu)) {
        if (wordStart < 0) {
          wordStart = i;
          hasUpper = cu >= 0x41 && cu <= 0x5A;
        } else if (cu >= 0x41 && cu <= 0x5A) {
          hasUpper = true;
        }
      } else {
        flushWord(i);
      }
    }
    flushWord(len);
  }

  /// Trims whitespace and folds ASCII uppercase characters to lowercase so
  /// pre-tokenized terms match indexed casing without splitting compound terms.
  static String normalizeTerm(String term) {
    final String trimmed = term.trim();
    if (trimmed.isEmpty) return '';
    final int len = trimmed.length;
    for (int i = 0; i < len; i++) {
      final int cu = trimmed.codeUnitAt(i);
      if (cu >= 0x41 && cu <= 0x5A) {
        return trimmed.toLowerCase();
      }
    }
    return trimmed;
  }

  static bool isWordUnit(int cu) {
    return (cu >= 0x30 && cu <= 0x39) ||
        (cu >= 0x41 && cu <= 0x5A) ||
        (cu >= 0x61 && cu <= 0x7A) ||
        (cu == 0x5F) ||
        (cu > 0x7F && !isCjk(cu) && !_isSeparator(cu));
  }

  static bool _isSeparator(int cu) {
    return cu <= 0x20 ||
        (cu >= 0x21 && cu <= 0x2F) ||
        (cu >= 0x3A && cu <= 0x40) ||
        (cu >= 0x5B && cu <= 0x5E) ||
        (cu == 0x60) ||
        (cu >= 0x7B && cu <= 0x7F) ||
        (cu >= 0x00A0 &&
            cu <= 0x00BF &&
            cu != 0x00AA &&
            cu != 0x00B5 &&
            cu != 0x00BA) ||
        cu == 0x00D7 ||
        cu == 0x00F7 ||
        (cu >= 0x2000 && cu <= 0x206F) ||
        (cu >= 0x20A0 && cu <= 0x214F) ||
        (cu >= 0x2190 && cu <= 0x23FF) ||
        (cu >= 0x2500 && cu <= 0x27BF) ||
        (cu >= 0x2E00 && cu <= 0x2E7F) ||
        (cu >= 0x3000 && cu <= 0x303F) ||
        (cu >= 0xD800 && cu <= 0xDFFF) ||
        (cu >= 0xFE10 && cu <= 0xFE1F) ||
        (cu >= 0xFE30 && cu <= 0xFE6F) ||
        (cu >= 0xFF01 && cu <= 0xFF0F) ||
        (cu >= 0xFF1A && cu <= 0xFF20) ||
        (cu >= 0xFF3B && cu <= 0xFF40) ||
        (cu >= 0xFF5B && cu <= 0xFF65);
  }

  static bool isCjk(int cu) {
    return (cu >= 0x4E00 && cu <= 0x9FFF) ||
        (cu >= 0x3400 && cu <= 0x4DBF) ||
        (cu >= 0x3040 && cu <= 0x30FF) ||
        (cu >= 0xAC00 && cu <= 0xD7AF);
  }

  /// True for BMP and supplementary-plane CJK ideographs (Extension B–I).
  static bool isCjkCodePoint(int cp) {
    return isCjk(cp) ||
        (cp >= 0x20000 && cp <= 0x2EBEF) ||
        (cp >= 0x2F800 && cp <= 0x2FA1F) ||
        (cp >= 0x30000 && cp <= 0x323AF);
  }

  /// True when [term] is a single CJK character (BMP or supplementary).
  static bool isCjkUnigram(String term) {
    if (term.length == 1) return isCjk(term.codeUnitAt(0));
    if (term.length == 2) {
      final int cu0 = term.codeUnitAt(0);
      final int cu1 = term.codeUnitAt(1);
      if (cu0 >= 0xD800 && cu0 <= 0xDBFF && cu1 >= 0xDC00 && cu1 <= 0xDFFF) {
        final int cp = 0x10000 + ((cu0 - 0xD800) << 10) + (cu1 - 0xDC00);
        return isCjkCodePoint(cp);
      }
    }
    return false;
  }

  /// True when [term] is two consecutive CJK characters (BMP or supplementary).
  static bool isCjkBigram(String term) {
    final int n = term.length;
    if (n < 2 || n > 4) return false;
    if (n == 2) {
      return isCjk(term.codeUnitAt(0)) && isCjk(term.codeUnitAt(1));
    }
    var count = 0;
    for (final cp in term.runes) {
      if (!isCjkCodePoint(cp)) return false;
      count++;
      if (count > 2) return false;
    }
    return count == 2;
  }

  /// True when [term] is a pure CJK run of `>= 3` characters.
  ///
  /// Pre-tokenized queries expand these with [addOverlappingCjkBigrams] (bigrams
  /// only — no automatic unigrams). Contiguity comes from the caller string.
  static bool isLongPureCjk(String term) {
    if (term.length < 3) return false;
    final units = term.codeUnits;
    final int n = units.length;
    var count = 0;
    for (int i = 0; i < n; i++) {
      final int cu = units[i];
      if (cu >= 0xD800 && cu <= 0xDBFF && i + 1 < n) {
        final int cu2 = units[i + 1];
        if (cu2 >= 0xDC00 && cu2 <= 0xDFFF) {
          final int cp = 0x10000 + ((cu - 0xD800) << 10) + (cu2 - 0xDC00);
          if (!isCjkCodePoint(cp)) return false;
          i++;
          count++;
          continue;
        }
      }
      if (!isCjk(cu)) return false;
      count++;
    }
    return count >= 3;
  }

  /// Adds overlapping CJK bigrams from a pure CJK [term] into [counts].
  ///
  /// Does not emit unigrams. No-op when [term] is not [isLongPureCjk].
  static void addOverlappingCjkBigrams(String term, Map<String, int> counts) {
    if (!isLongPureCjk(term)) return;
    final units = term.codeUnits;
    final int n = units.length;
    var prev = -1;
    for (int i = 0; i < n; i++) {
      int cp = units[i];
      if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < n) {
        final int cu2 = units[i + 1];
        if (cu2 >= 0xDC00 && cu2 <= 0xDFFF) {
          cp = 0x10000 + ((cp - 0xD800) << 10) + (cu2 - 0xDC00);
          i++;
        }
      }
      if (prev >= 0) {
        final key = String.fromCharCodes(<int>[prev, cp]);
        counts[key] = (counts[key] ?? 0) + 1;
      }
      prev = cp;
    }
  }
}
