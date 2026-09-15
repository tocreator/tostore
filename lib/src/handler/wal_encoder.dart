import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../model/data_store_config.dart';
import 'binary_map_codec.dart';
import 'encryption.dart';

/// High-performance binary encoder for WAL entries
/// Uses MessagePack-style binary serialization + EncoderHandler encryption
class WalEncoder {
  // ========== WAL Binary Format Constants ==========

  /// Magic number for binary WAL format: 0x546F574C ("ToWL" in ASCII)
  static const int _walMagic = 0x546F574C; // "ToWL"

  /// Current WAL binary format version
  /// Version 0x01: Initial binary format with MessagePack serialization
  static const int _walVersion = 0x01;

  /// Minimum size for a valid WAL record (Length:4B + Magic:4B + Version:1B + DataLen:4B + minimal data)
  static const int _minRecordSize = 20;

  /// Maximum legacy JSON payload size (for backward compatibility decode).
  static const int _maxStringLength = 100 * 1024 * 1024; // 100MB

  // ========== Public API ==========

  /// Encode WAL entry to binary format
  ///
  /// Binary format:
  /// [Magic: 4B][Version: 1B][DataLen: 4B][Serialized Data]
  ///
  /// Magic: 0x546F574C ("ToWL")
  /// Version: 0x01
  /// DataLen: Uint32 little-endian (length of serialized / encrypted payload)
  /// Data: MessagePack binary data (will be encrypted by EncoderHandler if enabled)
  ///
  /// [partitionIndex] - WAL partition index for AAD (prevents cross-partition tampering)
  ///
  /// Wire layout is unchanged vs historical writers — only allocation/copy paths
  /// are tightened (especially [EncryptionType.none]).
  static Uint8List encode(Map<String, dynamic> walEntry, int partitionIndex) {
    final payload = _payloadBytes(walEntry, partitionIndex);
    final out = Uint8List(9 + payload.length);
    _writeRecordHeader(out, 0, payload.length);
    out.setRange(9, 9 + payload.length, payload);
    return out;
  }

  /// Decode multiple WAL entries synchronously from a file's binary content.
  ///
  /// Reads records using length-prefix format: [Length: 4B][Binary WAL Entry]
  /// Returns list of decoded entries in order.
  ///
  /// A crash can leave a torn record whose 4-byte length later "fits" because
  /// new records were appended. That length must not swallow following records:
  /// if the frame header is invalid or payload decode fails, resync from the
  /// next byte instead of skipping the claimed length.
  ///
  /// [partitionIndex] - WAL partition index for AAD verification
  static List<Map<String, dynamic>> decodeFile(
      Uint8List fileBytes, int partitionIndex) {
    final List<Map<String, dynamic>> entries = [];
    int offset = 0;

    // Maximum record size to prevent DoS attacks (10MB per record)
    const int maxRecordSize = 10 * 1024 * 1024;

    while (offset < fileBytes.length) {
      if (offset + 4 > fileBytes.length) break;

      final recordStart = offset;
      final recordLength = ByteData.sublistView(fileBytes, offset, offset + 4)
          .getUint32(0, Endian.little);

      if (!isWellFormedBinaryRecordAt(fileBytes, recordStart, maxRecordSize)) {
        // Legacy JSON length-prefixed records have no ToWL header.
        if (recordLength > 0 &&
            recordLength <= maxRecordSize &&
            recordStart + 4 + recordLength <= fileBytes.length) {
          final slice = Uint8List.sublistView(
            fileBytes,
            recordStart + 4,
            recordStart + 4 + recordLength,
          );
          try {
            final jsonEntry = _tryDecodeJson(slice);
            if (jsonEntry != null) {
              entries.add(jsonEntry);
              offset = recordStart + 4 + recordLength;
              continue;
            }
          } catch (_) {}
        }
        final resynced = tryResyncNextRecord(
          fileBytes,
          recordStart + 1,
          maxRecordSize,
          searchWindow: _resyncWindow(
            claimedLength: recordLength,
            maxRecordSize: maxRecordSize,
            remainingBytes: fileBytes.length - recordStart,
          ),
        );
        if (resynced != null) {
          offset = resynced;
          continue;
        }
        break;
      }

      offset = recordStart + 4;
      final recordData =
          Uint8List.sublistView(fileBytes, offset, offset + recordLength);
      offset += recordLength;

      try {
        final entry = decodeSingle(recordData, partitionIndex);
        if (entry != null) {
          entries.add(entry);
          continue;
        }
      } catch (_) {}

      // Header looked complete (length now fits after later appends) but the
      // payload is torn. Do not skip [recordLength] — that window contains
      // subsequently appended valid records.
      final resynced = tryResyncNextRecord(
        fileBytes,
        recordStart + 1,
        maxRecordSize,
        searchWindow: _resyncWindow(
          claimedLength: recordLength,
          maxRecordSize: maxRecordSize,
          remainingBytes: fileBytes.length - recordStart,
        ),
      );
      if (resynced != null) {
        offset = resynced;
        continue;
      }
      break;
    }

    return entries;
  }

  /// True when [start] is a complete ToWL frame: length, magic, version, and
  /// inner dataLen all agree and the bytes fit in [fileBytes].
  static bool isWellFormedBinaryRecordAt(
    Uint8List fileBytes,
    int start,
    int maxRecordSize,
  ) {
    if (start < 0 || start + 13 > fileBytes.length) return false;
    final bd = ByteData.sublistView(fileBytes);
    final recordLength = bd.getUint32(start, Endian.little);
    if (recordLength < 9 || recordLength > maxRecordSize) return false;
    if (start + 4 + recordLength > fileBytes.length) return false;
    if (bd.getUint32(start + 4, Endian.little) != _walMagic) return false;
    if (fileBytes[start + 8] != _walVersion) return false;
    final dataLen = bd.getUint32(start + 9, Endian.little);
    return dataLen == recordLength - 9;
  }

  static int _resyncWindow({
    required int claimedLength,
    required int maxRecordSize,
    required int remainingBytes,
  }) {
    const defaultWindow = 65536;
    if (claimedLength <= 0 || claimedLength > maxRecordSize) {
      return defaultWindow;
    }
    final span = min(claimedLength, max(0, remainingBytes));
    return max(defaultWindow, span);
  }

  /// Scan ahead to find the next valid WAL record header if a record was torn
  /// or corrupted mid-file.
  ///
  /// Returns the byte offset of the next length prefix, or null if none.
  /// [searchWindow] defaults to 64KB; pass the torn record's claimed length
  /// when later appends made that length fit, so records inside the swallowed
  /// span are still found.
  static int? tryResyncNextRecord(
    Uint8List fileBytes,
    int searchStart,
    int maxRecordSize, {
    int searchWindow = 65536,
  }) {
    if (searchStart < 0 || searchStart + 8 > fileBytes.length) return null;
    final int searchEnd = min(
      fileBytes.length - 8,
      searchStart + max(0, searchWindow),
    );
    for (int i = searchStart; i <= searchEnd; i++) {
      if (fileBytes[i] != 0x4C ||
          i + 3 >= fileBytes.length ||
          fileBytes[i + 1] != 0x57 ||
          fileBytes[i + 2] != 0x6F ||
          fileBytes[i + 3] != 0x54) {
        continue;
      }
      final candidateStart = i - 4;
      if (candidateStart < searchStart) continue;
      if (isWellFormedBinaryRecordAt(
          fileBytes, candidateStart, maxRecordSize)) {
        return candidateStart;
      }
    }
    return null;
  }

  /// Decode single WAL entry synchronously from binary format.
  ///
  /// [partitionIndex] - WAL partition index for AAD verification (must match encoding)
  static Map<String, dynamic>? decodeSingle(
      Uint8List data, int partitionIndex) {
    if (data.length < 9) return null;

    final header = ByteData.sublistView(data, 0, 9);

    // Check magic
    final magic = header.getUint32(0, Endian.little);
    if (magic != _walMagic) {
      // Not binary WAL format, try legacy JSON
      return _tryDecodeJson(data);
    }

    // Check version
    final version = header.getUint8(4);
    if (version != _walVersion) return null;

    // Get data length
    final dataLen = header.getUint32(5, Endian.little);
    if (data.length != 9 + dataLen) return null;

    // Step 1: Extract encrypted data (zero-copy view)
    final encryptedData = Uint8List.sublistView(data, 9, 9 + dataLen);

    // Step 2/3: Decrypt. AAD only needed for AEAD algorithms.
    final decrypted = _decodePayload(encryptedData, partitionIndex);

    // Step 4: Parse MessagePack binary. Require the map to consume the whole
    // payload so a torn frame whose dataLen later fits (because new records
    // were appended) cannot decode a prefix map and skip those records.
    return BinaryMapCodec.decodeMap(decrypted, requireComplete: true);
  }

  /// Check if data is in binary WAL format
  ///
  /// This performs a quick check by reading only the first 4 bytes (magic number).
  /// For full validation, use [decodeSingle] instead.
  static bool isBinaryFormat(Uint8List data) {
    if (data.length < 4) return false;
    final magic = ByteData.sublistView(data).getUint32(0, Endian.little);
    return magic == _walMagic;
  }

  /// Backward compatible decode method (tries both formats)
  ///
  /// This is kept for compatibility with code that expects single-entry decode.
  /// New code should use decodeFile() for reading entire WAL files.
  ///
  /// [partitionIndex] - WAL partition index for AAD verification
  static Map<String, dynamic>? decode(Uint8List data, int partitionIndex) {
    return decodeSingle(data, partitionIndex);
  }

  /// Encode WAL entry with length prefix for record-based storage
  ///
  /// Format: [Length: 4B][Binary WAL Entry]
  /// Length: Uint32 little-endian (length of binary WAL entry including header)
  ///
  /// [walEntry] should contain 'p' (partition) for AAD
  ///
  /// Hot path for [WalManager]: builds the length-prefixed record in **one**
  /// allocation. Byte layout matches the historical encode()+prepend path.
  static Uint8List encodeAsLine(Map<String, dynamic> walEntry) {
    final partitionIndex = (walEntry['p'] as int?) ?? 0;
    final payload = _payloadBytes(walEntry, partitionIndex);
    final recordLen = 9 + payload.length;
    final out = Uint8List(4 + recordLen);
    final view = ByteData.sublistView(out);
    view.setUint32(0, recordLen, Endian.little);
    _writeRecordHeader(out, 4, payload.length);
    out.setRange(13, 13 + payload.length, payload);
    return out;
  }

  /// MessagePack (+ optional encryption) payload that sits after the 9-byte
  /// ToWL header. Identical to the historical encode() payload bytes.
  static Uint8List _payloadBytes(
    Map<String, dynamic> walEntry,
    int partitionIndex,
  ) {
    final serialized = BinaryMapCodec.encodeMap(walEntry);

    // none: EncryptionManager.encodeBytes returns [serialized] unchanged —
    // skip AAD alloc + encodeBytes call (same on-disk payload).
    if (EncryptionManager.getEncryptionType() == EncryptionType.none) {
      return serialized;
    }

    return EncryptionManager.encodeBytes(
      serialized,
      aad: _partitionAad(partitionIndex),
    );
  }

  static Uint8List _decodePayload(Uint8List encryptedData, int partitionIndex) {
    return EncryptionManager.decodeBytes(
      encryptedData,
      aad: _partitionAad(partitionIndex),
    );
  }

  static final List<Uint8List> _partitionAadCache = List<Uint8List>.generate(
    16,
    (i) {
      final b = ByteData(4);
      b.setInt32(0, i, Endian.little);
      return b.buffer.asUint8List();
    },
    growable: false,
  );

  static Uint8List _partitionAad(int partitionIndex) {
    if (partitionIndex >= 0 && partitionIndex < 16) {
      return _partitionAadCache[partitionIndex];
    }
    final aadData = ByteData(4);
    aadData.setInt32(0, partitionIndex, Endian.little);
    return aadData.buffer.asUint8List();
  }

  /// Write [Magic:4][Version:1][DataLen:4] at [offset] into [out].
  static void _writeRecordHeader(Uint8List out, int offset, int dataLen) {
    final view = ByteData.sublistView(out, offset, offset + 9);
    view.setUint32(0, _walMagic, Endian.little);
    view.setUint8(4, _walVersion);
    view.setUint32(5, dataLen, Endian.little);
  }

  /// Try decode legacy JSON format (for backward compatibility)
  /// This should only be called when binary format magic doesn't match
  static Map<String, dynamic>? _tryDecodeJson(Uint8List data) {
    if (data.isEmpty) return null;

    try {
      // Limit JSON decoding to prevent DoS on malformed input
      // Very large JSON strings could cause memory issues
      if (data.length > _maxStringLength) {
        return null; // Too large for legacy JSON
      }

      final jsonStr = utf8.decode(data, allowMalformed: false);
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return null;
    } catch (e) {
      // Not valid JSON or UTF-8, return null
      return null;
    }
  }

  /// Efficiently decode the last entry from a WAL file by reading only the tail
  ///
  /// This method reads only the last 64KB of the file and scans backwards to find
  /// the last complete record, avoiding the need to read and decode the entire file.
  ///
  /// Optimization: Uses Magic number check before attempting decryption to avoid
  /// expensive decryption operations on invalid candidate positions.
  ///
  /// [tailBytes] - The last portion of the file (typically 64KB)
  /// [partitionIndex] - WAL partition index for AAD verification
  ///
  /// Returns null if no valid record found or the tail is insufficient.
  static Map<String, dynamic>? decodeLastEntryFromTail(
      Uint8List tailBytes, int partitionIndex) {
    if (tailBytes.length < 4) return null;

    // Start from the end and scan backwards to find the last complete record
    // Format: [Length: 4B][Binary WAL Entry]
    // Binary WAL Entry format: [Magic: 4B][Version: 1B][DataLen: 4B][Encrypted Data]
    // We need to find a valid [Length: 4B] prefix whose record ends exactly at tail end

    int offset = tailBytes.length;

    // Scan backwards byte-by-byte to find the last complete record
    //
    // Note: While records are normally 4-byte aligned (Length:4B + data), we scan
    // byte-by-byte for robustness. This handles edge cases like:
    // - Corrupted files with partial writes
    // - Files read from non-zero offsets
    // - Misaligned data due to file system issues
    //
    // Performance: Magic check (O(1)) quickly filters most invalid positions,
    // so the byte-by-byte scan is still efficient despite checking 4x more positions.
    // Limit search to last 64KB to avoid excessive scanning
    final int searchStart = offset > 65536 ? offset - 65536 : 0;

    for (int candidateStart = offset - 4;
        candidateStart >= searchStart;
        candidateStart--) {
      if (candidateStart < 0) break;
      if (candidateStart + 4 > tailBytes.length) continue;

      // Read potential length prefix
      final lengthHeader =
          ByteData.sublistView(tailBytes, candidateStart, candidateStart + 4);
      final recordLength = lengthHeader.getUint32(0, Endian.little);

      // Quick validation: length must be reasonable and fit within the tail buffer.
      // Notice: candidateStart + 4 + recordLength may be <= offset because a crash
      // during write may leave a few partial/truncated bytes at the very end of the file!
      if (recordLength < _minRecordSize ||
          recordLength >=
              10 * 1024 * 1024 || // Sanity check: max 10MB per record
          candidateStart + 4 + recordLength > offset) {
        continue; // Skip invalid length
      }

      // Extract the Binary WAL Entry (without length prefix)
      final recordDataStart = candidateStart + 4;
      final recordDataEnd = recordDataStart + recordLength;
      if (recordDataEnd > tailBytes.length) continue;

      final recordData =
          Uint8List.sublistView(tailBytes, recordDataStart, recordDataEnd);

      // CRITICAL OPTIMIZATION: Check Magic number before attempting expensive decryption
      // This avoids decrypting data at every position that happens to have a valid-looking
      // length prefix. Magic check is O(1) vs decryption which is O(n).
      if (recordData.length < 4) continue;

      final magicHeader = ByteData.sublistView(recordData, 0, 4);
      final magic = magicHeader.getUint32(0, Endian.little);

      if (magic != _walMagic) {
        continue; // Not a valid WAL record, skip decryption attempt
      }

      // Magic matches! This is very likely a valid record. Now attempt full decode.
      // The decodeSingle will verify version, decrypt, and parse the entry.
      try {
        final entry = decodeSingle(recordData, partitionIndex);
        if (entry != null) {
          return entry; // Found the last valid entry
        }
      } catch (_) {
        // Decryption/parsing failed, this wasn't a valid record despite matching magic
        // This could happen if:
        // 1. Magic match was coincidental (very rare with 32-bit magic "ToWL")
        // 2. Record is corrupted
        // 3. Encryption key mismatch
        // Continue searching backwards
      }
    }

    return null; // No valid record found in the tail
  }
}
