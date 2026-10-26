/// Zero-dependency segmenter: Unicode word spans plus CJK unigram/bigram.
abstract final class WmbpTokenizer {
  /// Tokenizes [text] directly into [counts] without buffering CJK runs.
  static void tokenizeCounts(String text, Map<String, int> counts) {
    if (text.isEmpty) return;
    final units = text.codeUnits;
    final int len = units.length;
    var wordStart = -1;
    var hasUpper = false;
    var prevCjk = -1;

    void bump(String key) {
      counts[key] = (counts[key] ?? 0) + 1;
    }

    void emitCjk(int cu) {
      bump(String.fromCharCode(cu));
      if (prevCjk >= 0) {
        bump(String.fromCharCodes(<int>[prevCjk, cu]));
      }
      prevCjk = cu;
    }

    for (int i = 0; i < len; i++) {
      final int cu = units[i];
      if (_isCjk(cu)) {
        if (wordStart >= 0) {
          final w = text.substring(wordStart, i);
          bump(hasUpper ? w.toLowerCase() : w);
          wordStart = -1;
          hasUpper = false;
        }
        emitCjk(cu);
        continue;
      }
      prevCjk = -1;
      if (_isWordUnit(cu)) {
        if (wordStart < 0) {
          wordStart = i;
          hasUpper = cu >= 0x41 && cu <= 0x5A;
        } else if (cu >= 0x41 && cu <= 0x5A) {
          hasUpper = true;
        }
      } else if (wordStart >= 0) {
        final w = text.substring(wordStart, i);
        bump(hasUpper ? w.toLowerCase() : w);
        wordStart = -1;
        hasUpper = false;
      }
    }
    if (wordStart >= 0) {
      final w = text.substring(wordStart, len);
      bump(hasUpper ? w.toLowerCase() : w);
    }
  }

  /// Tokenizes [text] into lowercase words and CJK unigrams/bigrams.
  static List<String> tokenize(String text) {
    if (text.isEmpty) return const <String>[];
    final out = <String>[];
    final units = text.codeUnits;
    final int len = units.length;
    var wordStart = -1;
    var hasUpper = false;
    var prevCjk = -1;

    void flushWord(int end) {
      if (wordStart >= 0) {
        final w = text.substring(wordStart, end);
        out.add(hasUpper ? w.toLowerCase() : w);
        wordStart = -1;
        hasUpper = false;
      }
    }

    for (int i = 0; i < len; i++) {
      final int cu = units[i];
      if (_isCjk(cu)) {
        flushWord(i);
        out.add(String.fromCharCode(cu));
        if (prevCjk >= 0) {
          out.add(String.fromCharCodes(<int>[prevCjk, cu]));
        }
        prevCjk = cu;
        continue;
      }
      prevCjk = -1;
      if (_isWordUnit(cu)) {
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
    return out;
  }

  static bool isWordUnit(int cu) {
    return (cu >= 0x30 && cu <= 0x39) ||
        (cu >= 0x41 && cu <= 0x5A) ||
        (cu >= 0x61 && cu <= 0x7A) ||
        (cu == 0x5F) ||
        (cu > 0x7F && !isCjk(cu) && !_isSeparator(cu));
  }

  static bool _isWordUnit(int cu) => isWordUnit(cu);

  static bool _isSeparator(int cu) {
    return cu <= 0x20 ||
        (cu >= 0x21 && cu <= 0x2F) ||
        (cu >= 0x3A && cu <= 0x40) ||
        (cu >= 0x5B && cu <= 0x5E) ||
        (cu == 0x60) ||
        (cu >= 0x7B && cu <= 0x7E);
  }

  static bool isCjk(int cu) {
    return (cu >= 0x4E00 && cu <= 0x9FFF) ||
        (cu >= 0x3400 && cu <= 0x4DBF) ||
        (cu >= 0x3040 && cu <= 0x30FF) ||
        (cu >= 0xAC00 && cu <= 0xD7AF);
  }

  static bool _isCjk(int cu) => isCjk(cu);

  /// True when [term] is a single CJK code unit (BMP unigram).
  static bool isCjkUnigram(String term) {
    if (term.length != 1) return false;
    return isCjk(term.codeUnitAt(0));
  }

  /// True when [term] is two consecutive CJK code units (BMP bigram).
  static bool isCjkBigram(String term) {
    if (term.length != 2) return false;
    return isCjk(term.codeUnitAt(0)) && isCjk(term.codeUnitAt(1));
  }
}
