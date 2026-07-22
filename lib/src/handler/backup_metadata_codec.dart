import 'dart:typed_data';

import '../model/backup_metadata.dart';
import '../model/backup_scope.dart';
import '../model/data_store_config.dart';
import 'binary_codec.dart';
import 'meta_file_codec.dart';

/// Stable field IDs for [BackupMetadata]. Never reuse IDs.
abstract final class BackupMetadataFieldId {
  static const int timestamp = 1;
  static const int backupFormatVersion = 2;
  static const int scope = 3;
  static const int compressed = 4;
  // Reserved 20–31.
}

/// Wire values for [BackupScope]. Never reuse.
abstract final class BackupScopeWire {
  static const int database = 1;
  static const int currentSpace = 2;
  static const int currentSpaceWithGlobal = 3;
}

/// Field-tag + TOBF codec for package-level [BackupMetadata] (`meta.tobf`).
abstract final class BackupMetadataCodec {
  BackupMetadataCodec._();

  static const String fileName = 'meta.tobf';

  static Uint8List encodePayload(BackupMetadata meta) {
    final w = BinaryWriter(initialCapacity: 64);
    w.writeFieldTag(BackupMetadataFieldId.timestamp, WireType.lengthDelimited);
    w.writeString(meta.timestamp);
    w.writeFieldTag(BackupMetadataFieldId.backupFormatVersion, WireType.varint);
    w.writeVarint(meta.backupFormatVersion);
    w.writeFieldTag(BackupMetadataFieldId.scope, WireType.varint);
    w.writeVarint(_scopeToWire(meta.scope));
    if (meta.compressed) {
      w.writeFieldTag(BackupMetadataFieldId.compressed, WireType.varint);
      w.writeVarint(1);
    }
    return w.view;
  }

  static BackupMetadata decodePayload(Uint8List bytes) {
    if (bytes.isEmpty) {
      return const BackupMetadata(
        timestamp: '',
        backupFormatVersion: 0,
        scope: BackupScope.currentSpaceWithGlobal,
        compressed: false,
      );
    }

    final r = BinaryReader(bytes);
    String timestamp = '';
    int backupFormatVersion = 0;
    BackupScope scope = BackupScope.currentSpaceWithGlobal;
    bool compressed = false;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case BackupMetadataFieldId.timestamp:
          timestamp = r.readString();
          break;
        case BackupMetadataFieldId.backupFormatVersion:
          backupFormatVersion = r.readVarint();
          break;
        case BackupMetadataFieldId.scope:
          scope = _scopeFromWire(r.readVarint());
          break;
        case BackupMetadataFieldId.compressed:
          compressed = r.readVarint() != 0;
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    return BackupMetadata(
      timestamp: timestamp,
      backupFormatVersion: backupFormatVersion,
      scope: scope,
      compressed: compressed,
    );
  }

  static Uint8List encodeFile(
    BackupMetadata meta, {
    required EncryptionConfig? encryptionConfig,
  }) {
    return MetaFileCodec.encodeFile(
      encodePayload(meta),
      encrypt: MetaFileCodec.shouldEncrypt(encryptionConfig),
      aad: MetaFileCodec.backupMetaAad,
    );
  }

  static BackupMetadata decodeFile(Uint8List frameBytes) {
    return decodePayload(
      MetaFileCodec.decodeFile(
        frameBytes,
        aad: MetaFileCodec.backupMetaAad,
        maxBodyLimit: MetaFileCodec.maxBodyBytesSmall,
      ),
    );
  }

  static int _scopeToWire(BackupScope scope) {
    switch (scope) {
      case BackupScope.database:
        return BackupScopeWire.database;
      case BackupScope.currentSpace:
        return BackupScopeWire.currentSpace;
      case BackupScope.currentSpaceWithGlobal:
        return BackupScopeWire.currentSpaceWithGlobal;
    }
  }

  static BackupScope _scopeFromWire(int wire) {
    switch (wire) {
      case BackupScopeWire.database:
        return BackupScope.database;
      case BackupScopeWire.currentSpace:
        return BackupScope.currentSpace;
      case BackupScopeWire.currentSpaceWithGlobal:
        return BackupScope.currentSpaceWithGlobal;
      default:
        return BackupScope.currentSpaceWithGlobal;
    }
  }
}
