import 'dart:convert';
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

  /// Decode multiple WAL entries from a file's binary content
  ///
  /// Reads records using length-prefix format: [Length: 4B][Binary WAL Entry]
  /// Returns list of decoded entries in order
  ///
  /// [partitionIndex] - WAL partition index for AAD verification
  static Future<List<Map<String, dynamic>>> decodeFile(
      Uint8List fileBytes, int partitionIndex) async {
    final List<Map<String, dynamic>> entries = [];
    int offset = 0;

    // Maximum record size to prevent DoS attacks (10MB per record)
    const int maxRecordSize = 10 * 1024 * 1024;

    while (offset < fileBytes.length) {
      // Need at least 4 bytes for length prefix
      if (offset + 4 > fileBytes.length) break;

      // Read length prefix
      final lengthHeader = ByteData.sublistView(fileBytes, offset, offset + 4);
      final recordLength = lengthHeader.getUint32(0, Endian.little);
      offset += 4;

      // Validate record length: must be positive, reasonable size, and fit in remaining data
      if (recordLength == 0 ||
          recordLength > maxRecordSize ||
          offset + recordLength > fileBytes.length) {
        // Invalid record length, stop parsing to avoid reading garbage
        break;
      }

      // Extract and decode this record (view — decodeSingle does not retain the slice)
      final recordData =
          Uint8List.sublistView(fileBytes, offset, offset + recordLength);
      offset += recordLength;

      try {
        final entry = await decodeSingle(recordData, partitionIndex);
        if (entry != null) {
          entries.add(entry);
        }
      } catch (e) {
        // Skip corrupted record, continue with next
        // In production, you might want to log this for debugging
        continue;
      }
    }

    return entries;
  }

  /// Decode single WAL entry from binary format
  ///
  /// [partitionIndex] - WAL partition index for AAD verification (must match encoding)
  static Future<Map<String, dynamic>?> decodeSingle(
      Uint8List data, int partitionIndex) async {
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
    if (data.length < 9 + dataLen) return null;

    // Step 1: Extract encrypted data (zero-copy view)
    final encryptedData = Uint8List.sublistView(data, 9, 9 + dataLen);

    // Step 2/3: Decrypt. AAD only needed for AEAD algorithms.
    final decrypted = _decodePayload(encryptedData, partitionIndex);

    // Step 4: Parse MessagePack binary
    return BinaryMapCodec.decodeMap(decrypted);
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
  static Future<Map<String, dynamic>?> decode(
      Uint8List data, int partitionIndex) async {
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
    // Headerless none payloads ignore AAD; AEAD still needs partition AAD.
    if (EncryptionManager.getEncryptionType() == EncryptionType.none) {
      // Still run decodeBytes: files may contain prefixed ciphertext from an
      // older key/type while the process default is none (prefix dispatch).
      return EncryptionManager.decodeBytes(encryptedData);
    }
    return EncryptionManager.decodeBytes(
      encryptedData,
      aad: _partitionAad(partitionIndex),
    );
  }

  static Uint8List _partitionAad(int partitionIndex) {
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
  static Future<Map<String, dynamic>?> decodeLastEntryFromTail(
      Uint8List tailBytes, int partitionIndex) async {
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

      // Quick validation: length must be reasonable and record must end at tail end
      if (recordLength < _minRecordSize ||
          recordLength >=
              10 * 1024 * 1024 || // Sanity check: max 10MB per record
          candidateStart + 4 + recordLength != offset) {
        continue; // Skip invalid length
      }

      // Extract the Binary WAL Entry (without length prefix)
      final recordDataStart = candidateStart + 4;
      if (recordDataStart + recordLength > tailBytes.length) continue;

      final recordData =
          Uint8List.sublistView(tailBytes, recordDataStart, offset);

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
        final entry = await decodeSingle(recordData, partitionIndex);
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
