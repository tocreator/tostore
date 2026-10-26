import 'wmbp_constants.dart';

/// dart2js backend: byte-wise micro-block masks (no 64-bit SWAR / literals).
abstract final class WmbpSwar {
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

  /// Bits 0..7 are set when that micro-block max is >= [reqQ8].
  static int evalMicroBlockMask(int lo, int hi, int reqQ8) =>
      naiveMicroBlockMask(lo, hi, reqQ8);

  /// Reference lane mask: bit i is set when byte i >= [reqQ8].
  static int naiveMicroBlockMask(int lo, int hi, int reqQ8) {
    if (reqQ8 <= 1) return 0xFF;
    if (reqQ8 > 255) return 0x00;
    int mask = 0;
    int wordLo = lo & 0xFFFFFFFF;
    int wordHi = hi & 0xFFFFFFFF;
    for (int i = 0; i < 4; i++) {
      if ((wordLo & 0xFF) >= reqQ8) mask |= 1 << i;
      wordLo = (wordLo >>> 8) & 0xFFFFFFFF;
    }
    for (int i = 0; i < 4; i++) {
      if ((wordHi & 0xFF) >= reqQ8) mask |= 1 << (i + 4);
      wordHi = (wordHi >>> 8) & 0xFFFFFFFF;
    }
    return mask;
  }

  static int microBlocksPerPhysBlock() =>
      WmbpConstants.physBlockSize ~/ WmbpConstants.microBlockSize;
}
