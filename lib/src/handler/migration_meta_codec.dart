import 'dart:typed_data';

import '../model/data_store_config.dart';
import '../model/key_migration_info.dart';
import '../model/meta_info.dart';
import '../model/migration_meta.dart';
import 'binary_codec.dart';
import 'meta_file_codec.dart';

/// Stable field IDs for [MigrationMeta]. Never reuse IDs.
abstract final class MigrationMetaFieldId {
  static const int directoryMapping = 1;
  static const int keyMigrationInfo = 2;
  // Reserved 20–31.
}

abstract final class MigrationDirMappingFieldId {
  static const int idToDir = 1;
  static const int dirToFileCount = 2;
}

abstract final class StringIntPairFieldId {
  static const int key = 1;
  static const int value = 2;
}

abstract final class IntPairFieldId {
  static const int key = 1;
  static const int value = 2;
}

abstract final class KeyMigrationInfoFieldId {
  static const int targetKeyId = 1;
  static const int status = 2;
  static const int createdAtUs = 3;
  // Reserved 10–15.
}

/// Field-tag + TOBF codec for [MigrationMeta].
final class MigrationMetaCodec {
  MigrationMetaCodec._();

  static Uint8List encodePayload(MigrationMeta meta) {
    final w = BinaryWriter(initialCapacity: 128);
    w.writeMessage(MigrationMetaFieldId.directoryMapping, (sw) {
      _writeDirectoryMapping(sw, meta.directoryMapping);
    });
    if (meta.keyMigrationInfo != null) {
      w.writeMessage(MigrationMetaFieldId.keyMigrationInfo, (sw) {
        _writeKeyMigrationInfo(sw, meta.keyMigrationInfo!);
      });
    }
    return w.view;
  }

  static MigrationMeta decodePayload(Uint8List bytes) {
    if (bytes.isEmpty) return MigrationMeta.initial();

    final r = BinaryReader(bytes);
    DirectoryMappingString? directoryMapping;
    KeyMigrationInfo? keyMigrationInfo;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case MigrationMetaFieldId.directoryMapping:
          r.readMessage((nr, _) {
            directoryMapping = _readDirectoryMapping(nr);
          });
          break;
        case MigrationMetaFieldId.keyMigrationInfo:
          r.readMessage((nr, _) {
            keyMigrationInfo = _readKeyMigrationInfo(nr);
          });
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    return MigrationMeta(
      directoryMapping: directoryMapping ?? DirectoryMappingString(),
      keyMigrationInfo: keyMigrationInfo,
    );
  }

  static Uint8List encodeFile(
    MigrationMeta meta, {
    required EncryptionConfig? encryptionConfig,
  }) {
    return MetaFileCodec.encodeFile(
      encodePayload(meta),
      encrypt: MetaFileCodec.shouldEncrypt(encryptionConfig),
      aad: MetaFileCodec.migrationMetaAad,
    );
  }

  static MigrationMeta decodeFile(Uint8List frameBytes) {
    return decodePayload(
      MetaFileCodec.decodeFile(
        frameBytes,
        aad: MetaFileCodec.migrationMetaAad,
        maxBodyLimit: MetaFileCodec.maxBodyBytesSmall,
      ),
    );
  }

  static void _writeDirectoryMapping(
    BinaryWriter w,
    DirectoryMappingString mapping,
  ) {
    mapping.idToDir.forEach((id, dir) {
      w.writeMessage(MigrationDirMappingFieldId.idToDir, (sw) {
        sw.writeFieldTag(StringIntPairFieldId.key, WireType.lengthDelimited);
        sw.writeString(id);
        sw.writeFieldTag(StringIntPairFieldId.value, WireType.varint);
        sw.writeVarint(dir);
      });
    });
    mapping.dirToFileCount.forEach((dir, count) {
      w.writeMessage(MigrationDirMappingFieldId.dirToFileCount, (sw) {
        sw.writeFieldTag(IntPairFieldId.key, WireType.varint);
        sw.writeVarint(dir);
        sw.writeFieldTag(IntPairFieldId.value, WireType.varint);
        sw.writeVarint(count);
      });
    });
  }

  static DirectoryMappingString _readDirectoryMapping(BinaryReader r) {
    final idToDir = <String, int>{};
    final dirToFileCount = <int, int>{};
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case MigrationDirMappingFieldId.idToDir:
          r.readMessage((nr, _) {
            String? key;
            var value = 0;
            while (!nr.isEOF) {
              final (fid, wt) = nr.readFieldTag();
              switch (fid) {
                case StringIntPairFieldId.key:
                  key = nr.readString();
                  break;
                case StringIntPairFieldId.value:
                  value = nr.readVarint();
                  break;
                default:
                  nr.skipField(wt);
                  break;
              }
            }
            if (key != null) idToDir[key] = value;
          });
          break;
        case MigrationDirMappingFieldId.dirToFileCount:
          r.readMessage((nr, _) {
            var key = 0;
            var value = 0;
            while (!nr.isEOF) {
              final (fid, wt) = nr.readFieldTag();
              switch (fid) {
                case IntPairFieldId.key:
                  key = nr.readVarint();
                  break;
                case IntPairFieldId.value:
                  value = nr.readVarint();
                  break;
                default:
                  nr.skipField(wt);
                  break;
              }
            }
            dirToFileCount[key] = value;
          });
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    return DirectoryMappingString(
      idToDir: idToDir,
      dirToFileCount: dirToFileCount,
    );
  }

  static void _writeKeyMigrationInfo(BinaryWriter w, KeyMigrationInfo info) {
    w.writeFieldTag(KeyMigrationInfoFieldId.targetKeyId, WireType.varint);
    w.writeVarint(info.targetKeyId);
    w.writeFieldTag(KeyMigrationInfoFieldId.status, WireType.varint);
    w.writeVarint(info.status.index);
    w.writeFieldTag(KeyMigrationInfoFieldId.createdAtUs, WireType.fixed64);
    w.writeFixed64(_createdAtToMicros(info.createdAt));
  }

  static KeyMigrationInfo _readKeyMigrationInfo(BinaryReader r) {
    var targetKeyId = 0;
    var status = KeyMigrationStatus.running;
    var createdAtUs = 0;
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case KeyMigrationInfoFieldId.targetKeyId:
          targetKeyId = r.readVarint();
          break;
        case KeyMigrationInfoFieldId.status:
          final idx = r.readVarint();
          status = (idx >= 0 && idx < KeyMigrationStatus.values.length)
              ? KeyMigrationStatus.values[idx]
              : KeyMigrationStatus.running;
          break;
        case KeyMigrationInfoFieldId.createdAtUs:
          createdAtUs = r.readFixed64();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    return KeyMigrationInfo(
      targetKeyId: targetKeyId,
      status: status,
      createdAt: DateTime.fromMicrosecondsSinceEpoch(createdAtUs, isUtc: true)
          .toIso8601String(),
    );
  }

  /// Accept ISO8601 (legacy domain) or numeric micros string; persist as micros.
  static int _createdAtToMicros(String createdAt) {
    final parsed = DateTime.tryParse(createdAt);
    if (parsed != null) return parsed.toUtc().microsecondsSinceEpoch;
    final asInt = int.tryParse(createdAt);
    if (asInt != null) return asInt;
    return DateTime.now().toUtc().microsecondsSinceEpoch;
  }
}
