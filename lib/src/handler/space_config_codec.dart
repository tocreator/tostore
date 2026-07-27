import 'dart:convert';
import 'dart:typed_data';

import '../model/space_config.dart';
import 'binary_codec.dart';
import 'config_file_codec.dart';

/// Stable field IDs for [SpaceConfig] binary encoding. Never reuse IDs.
abstract final class SpaceConfigFieldId {
  static const int current = 1;
  static const int historyKeys = 2;
  static const int version = 3;
  static const int totalTableCount = 4;
  static const int totalRecordCount = 5;
  static const int totalDataSizeBytes = 6;
  static const int lastStatisticsTime = 7;
}

/// Nested [EncryptionKeyInfo] field IDs.
abstract final class EncryptionKeyInfoFieldId {
  /// Raw wrapped key bytes (not base64).
  static const int key = 1;
  static const int keyId = 2;
}

/// TOBF codec for [SpaceConfig] — no JSON intermediate structures.
final class SpaceConfigCodec {
  SpaceConfigCodec._();

  static void _writeKeyInfo(BinaryWriter w, EncryptionKeyInfo info) {
    final keyBytes = _keyToBytes(info.key);
    if (keyBytes.isNotEmpty) {
      w.writeFieldTag(EncryptionKeyInfoFieldId.key, WireType.lengthDelimited);
      w.writeBytes(keyBytes);
    }
    w.writeFieldTag(EncryptionKeyInfoFieldId.keyId, WireType.varint);
    w.writeVarint(info.keyId);
  }

  static EncryptionKeyInfo _readKeyInfo(BinaryReader r) {
    var key = '';
    var keyId = 0;
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case EncryptionKeyInfoFieldId.key:
          key = _bytesToKey(r.readBytes());
          break;
        case EncryptionKeyInfoFieldId.keyId:
          keyId = r.readVarint();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    return EncryptionKeyInfo(key: key, keyId: keyId);
  }

  /// Persist as raw bytes; in-memory model still holds base64 for KeyManager.
  static Uint8List _keyToBytes(String key) {
    if (key.isEmpty) return Uint8List(0);
    try {
      return Uint8List.fromList(base64.decode(key));
    } catch (_) {
      // Legacy / unexpected plaintext — store UTF-8 so round-trip is possible.
      return Uint8List.fromList(utf8.encode(key));
    }
  }

  static String _bytesToKey(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    return base64.encode(bytes);
  }

  /// Encode domain model to field-tag payload (no outer frame).
  static Uint8List encodePayload(SpaceConfig config) {
    final w = BinaryWriter(initialCapacity: 128);

    w.writeMessage(SpaceConfigFieldId.current, (sub) {
      _writeKeyInfo(sub, config.current);
    });

    for (final hist in config.historyKeys) {
      w.writeMessage(SpaceConfigFieldId.historyKeys, (sub) {
        _writeKeyInfo(sub, hist);
      });
    }

    w.writeFieldTag(SpaceConfigFieldId.version, WireType.varint);
    w.writeVarint(config.version);
    w.writeFieldTag(SpaceConfigFieldId.totalTableCount, WireType.varint);
    w.writeVarint(config.totalTableCount);
    w.writeFieldTag(SpaceConfigFieldId.totalRecordCount, WireType.varint);
    w.writeVarint(config.totalRecordCount);
    w.writeFieldTag(SpaceConfigFieldId.totalDataSizeBytes, WireType.varint);
    w.writeVarint(config.totalDataSizeBytes);

    if (config.lastStatisticsTime != null) {
      w.writeFieldTag(SpaceConfigFieldId.lastStatisticsTime, WireType.fixed64);
      w.writeFixed64(config.lastStatisticsTime!.millisecondsSinceEpoch);
    }

    return w.view;
  }

  /// Decode field-tag payload into [SpaceConfig].
  static SpaceConfig decodePayload(Uint8List bytes) {
    EncryptionKeyInfo? current;
    final historyKeys = <EncryptionKeyInfo>[];
    int? version;
    var totalTableCount = 0;
    var totalRecordCount = 0;
    var totalDataSizeBytes = 0;
    DateTime? lastStatisticsTime;

    if (bytes.isNotEmpty) {
      final r = BinaryReader(bytes);
      while (!r.isEOF) {
        final (fieldId, wireType) = r.readFieldTag();
        switch (fieldId) {
          case SpaceConfigFieldId.current:
            r.readMessage((child, _) {
              current = _readKeyInfo(child);
            });
            break;
          case SpaceConfigFieldId.historyKeys:
            r.readMessage((child, _) {
              historyKeys.add(_readKeyInfo(child));
            });
            break;
          case SpaceConfigFieldId.version:
            version = r.readVarint();
            break;
          case SpaceConfigFieldId.totalTableCount:
            totalTableCount = r.readVarint();
            break;
          case SpaceConfigFieldId.totalRecordCount:
            totalRecordCount = r.readVarint();
            break;
          case SpaceConfigFieldId.totalDataSizeBytes:
            totalDataSizeBytes = r.readVarint();
            break;
          case SpaceConfigFieldId.lastStatisticsTime:
            lastStatisticsTime =
                DateTime.fromMillisecondsSinceEpoch(r.readFixed64());
            break;
          default:
            r.skipField(wireType);
            break;
        }
      }
    }

    return SpaceConfig(
      current: current ?? const EncryptionKeyInfo(key: '', keyId: 0),
      historyKeys: historyKeys,
      version: version,
      totalTableCount: totalTableCount,
      totalRecordCount: totalRecordCount,
      totalDataSizeBytes: totalDataSizeBytes,
      lastStatisticsTime: lastStatisticsTime,
    );
  }

  /// Encode full on-disk file bytes (TOBF frame ± ConfigVault encryption).
  static Uint8List encodeFile(SpaceConfig config, {required bool encrypt}) {
    return ConfigFileCodec.encodeFile(encodePayload(config), encrypt: encrypt);
  }

  /// Decode full on-disk file bytes.
  static SpaceConfig decodeFile(Uint8List frameBytes) {
    return decodePayload(ConfigFileCodec.decodeFile(frameBytes));
  }
}
