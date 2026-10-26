import 'wmbp_constants.dart';

/// VM / dart2wasm SWAR backend for state-II micro-block masks.
abstract final class WmbpSwar {
  static const int _byteLanes = 0x0101010101010101;
  static const int _highBits = 0x8080808080808080;
  static const int _low7 = 0x7F7F7F7F7F7F7F7F;
  static const int _u64 = 0xFFFFFFFFFFFFFFFF;

  /// Packs 8 micro-block maxima into little-endian lo/hi uint32 limbs.
  static (int lo, int hi) packMicroMaxWord(List<int> laneMax) {
    var lo = 0;
    var hi = 0;
    final int n = laneMax.length < 8 ? laneMax.length : 8;
    for (int i = 0; i < n && i < 4; i++) {
      lo |= (laneMax[i] & 0xFF) << (8 * i);
    }
    for (int i = 4; i < n; i++) {
      hi |= (laneMax[i] & 0xFF) << (8 * (i - 4));
    }
    return (lo, hi);
  }

  static int _combine(int lo, int hi) =>
      (lo & 0xFFFFFFFF) | ((hi & 0xFFFFFFFF) << 32);

  /// Bits 0..7 are set when that micro-block max is >= [reqQ8].
  @pragma('vm:prefer-inline')
  static int evalMicroBlockMask(int lo, int hi, int reqQ8) {
    if (reqQ8 <= 1) return 0xFF;
    if (reqQ8 > 255) return 0x00;
    final int word = _combine(lo, hi) & _u64;
    final int threshold = (reqQ8 & 0xFF) * _byteLanes;
    final int lowWord = word & _low7;
    final int lowThreshold = threshold & _low7;
    final int lowGe =
        (((lowWord | _highBits) - lowThreshold) & _highBits) & _u64;
    final int wordHigh = word & _highBits;
    final int thresholdHigh = threshold & _highBits;
    final int wordOnly = wordHigh & (~thresholdHigh & _u64);
    final int sameHigh = (~(wordHigh ^ thresholdHigh) & _u64) & _highBits;
    final int high = (wordOnly | (sameHigh & lowGe)) & _u64;
    return packMsbToByte(high);
  }

  /// Packs the high bit of each byte into a bit of the result.
  @pragma('vm:prefer-inline')
  static int packMsbToByte(int highBits) {
    int mask = 0;
    int bits = highBits & _u64;
    for (int i = 0; i < 8; i++) {
      if ((bits & 0x80) != 0) mask |= 1 << i;
      bits >>>= 8;
    }
    return mask;
  }

  /// Reference lane mask: bit i is set when byte i >= [reqQ8].
  static int naiveMicroBlockMask(int lo, int hi, int reqQ8) {
    if (reqQ8 <= 1) return 0xFF;
    if (reqQ8 > 255) return 0x00;
    int mask = 0;
    int wordLo = lo & 0xFFFFFFFF;
    int wordHi = hi & 0xFFFFFFFF;
    for (int i = 0; i < 4; i++) {
      if ((wordLo & 0xFF) >= reqQ8) mask |= 1 << i;
      wordLo >>>= 8;
    }
    for (int i = 0; i < 4; i++) {
      if ((wordHi & 0xFF) >= reqQ8) mask |= 1 << (i + 4);
      wordHi >>>= 8;
    }
    return mask;
  }

  static int microBlocksPerPhysBlock() =>
      WmbpConstants.physBlockSize ~/ WmbpConstants.microBlockSize;
}
