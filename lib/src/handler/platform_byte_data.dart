import 'dart:typed_data';

/// Optimized cross-platform ByteData accessors for 64-bit integers.
///
/// On the VM (native), this uses [ByteData]'s efficient native methods.
/// On the Web (dart2js), this uses manual bit manipulation to avoid
/// "Unsupported operation: Int64 accessor not supported by dart2js".
///
/// The platform check constant is resolved at compile time, allowing the
/// unused branch to be removed by the compiler (Dead Code Elimination),
/// ensuring there is NO performance penalty on native platforms.
class PlatformByteData {
  static const bool _isWeb = identical(0, 0.0);

  static void setInt64(ByteData bd, int byteOffset, int value, Endian endian) {
    if (_isWeb) {
      _setInt64Web(bd, byteOffset, value, endian);
    } else {
      bd.setInt64(byteOffset, value, endian);
    }
  }

  static void setUint64(ByteData bd, int byteOffset, int value, Endian endian) {
    if (_isWeb) {
      _setUint64Web(bd, byteOffset, value, endian);
    } else {
      bd.setUint64(byteOffset, value, endian);
    }
  }

  static int getInt64(ByteData bd, int byteOffset, Endian endian) {
    if (_isWeb) {
      return _getInt64Web(bd, byteOffset, endian);
    } else {
      return bd.getInt64(byteOffset, endian);
    }
  }

  static int getUint64(ByteData bd, int byteOffset, Endian endian) {
    if (_isWeb) {
      return _getUint64Web(bd, byteOffset, endian);
    } else {
      return bd.getUint64(byteOffset, endian);
    }
  }

  // --- Web Implementations ---

  static void _setInt64Web(
      ByteData bd, int byteOffset, int value, Endian endian) {
    // JavaScript bitwise operations map to 32-bit integers.
    // For 64-bit, we must split manually.
    // Note: JS numbers are doubles. Precision > 2^53 is lost.
    // We assume the caller handles potential safe integer limits.

    // Low 32 bits
    final int lo = value & 0xFFFFFFFF;
    // High 32 bits (shift by division to avoid 32-bit truncate)
    final int hi = (value / 0x100000000).floor() & 0xFFFFFFFF;

    if (endian == Endian.little) {
      bd.setUint32(byteOffset, lo, Endian.little);
      bd.setUint32(byteOffset + 4, hi, Endian.little);
    } else {
      bd.setUint32(byteOffset, hi, Endian.big);
      bd.setUint32(byteOffset + 4, lo, Endian.big);
    }
  }

  static void _setUint64Web(
      ByteData bd, int byteOffset, int value, Endian endian) {
    // Uint64 behaves effectively the same as Int64 for bit patterns in JS
    // because we write raw bytes.
    if (value < 0) {
      // Handle negative inputs if mistakenly passed as unsigned
      _setInt64Web(bd, byteOffset, value, endian);
      return;
    }

    final int lo = value & 0xFFFFFFFF;
    final int hi = (value / 0x100000000).floor() & 0xFFFFFFFF;

    if (endian == Endian.little) {
      bd.setUint32(byteOffset, lo, Endian.little);
      bd.setUint32(byteOffset + 4, hi, Endian.little);
    } else {
      bd.setUint32(byteOffset, hi, Endian.big);
      bd.setUint32(byteOffset + 4, lo, Endian.big);
    }
  }

  static int _getInt64Web(ByteData bd, int byteOffset, Endian endian) {
    final int p1 = bd.getUint32(byteOffset, endian);
    final int p2 = bd.getUint32(byteOffset + 4, endian);

    int hi, lo;
    if (endian == Endian.little) {
      lo = p1;
      hi = p2;
    } else {
      hi = p1;
      lo = p2;
    }

    // Combine: hi * 2^32 + lo.
    // BUT we must interpret 'hi' as signed 32-bit if this is Int64.
    // In JS/Dart Web, bitwise ops are 32-bit signed.
    // So 'hi | 0' forces signed 32-bit interpretation if we wanted it.
    // But getUint32 returns unsigned range 0..2^32-1.

    // If 'hi' has the high bit set (>= 0x80000000), the 64-bit number is negative.
    // We can simulate 2's complement.
    if (hi >= 0x80000000) {
      // Negative number reconstruction
      // value = - ( (~hi << 32) + (~lo) + 1 ) ?? Tricky with doubles.
      // Easiest: (hi - 2^32) * 2^32 + lo ?
      // If hi=0xFFFFFFFF (-1), lo=0xFFFFFFFF.
      // (0xFFFFFFFF - 0x100000000) * 0x100000000 + 0xFFFFFFFF
      // = (-1) * 2^32 + (2^32 - 1) = -1. Correct.
      return (hi - 0x100000000) * 0x100000000 + lo;
    }

    return hi * 0x100000000 + lo;
  }

  static int _getUint64Web(ByteData bd, int byteOffset, Endian endian) {
    final int p1 = bd.getUint32(byteOffset, endian);
    final int p2 = bd.getUint32(byteOffset + 4, endian);

    int hi, lo;
    if (endian == Endian.little) {
      lo = p1;
      hi = p2;
    } else {
      hi = p1;
      lo = p2;
    }

    return hi * 0x100000000 + lo;
  }
}
