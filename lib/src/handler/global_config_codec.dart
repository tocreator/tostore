import 'dart:typed_data';

import '../model/global_config.dart';
import 'binary_codec.dart';
import 'config_file_codec.dart';

/// Stable field IDs for [GlobalConfig] binary encoding. Never reuse IDs.
abstract final class GlobalConfigFieldId {
  static const int version = 1;
  static const int userVersion = 2;
  static const int maxEntriesPerDir = 3;
  static const int pageSize = 4;
  static const int spaceNames = 5;
  static const int activeSpace = 6;
  static const int hasMigrationTask = 7;
  static const int userSchemaHash = 8;
  static const int systemSchemaHash = 9;
  static const int lastGlobalDirIndex = 10;
  static const int lastGlobalDirEntries = 11;
  static const int lastNonGlobalDirIndex = 12;
  static const int lastNonGlobalDirEntries = 13;
}

/// TOBF codec for [GlobalConfig] — no JSON intermediate structures.
final class GlobalConfigCodec {
  GlobalConfigCodec._();

  /// Encode domain model to field-tag payload (no outer frame).
  static Uint8List encodePayload(GlobalConfig config) {
    final w = BinaryWriter(initialCapacity: 128);
    w.writeFieldTag(GlobalConfigFieldId.version, WireType.varint);
    w.writeVarint(config.version);

    w.writeFieldTag(GlobalConfigFieldId.userVersion, WireType.varint);
    w.writeVarint(config.userVersion);

    w.writeFieldTag(GlobalConfigFieldId.maxEntriesPerDir, WireType.varint);
    w.writeVarint(config.maxEntriesPerDir);

    // Always persist pageSize (including 0 = unset) so upgrade probes stay valid.
    w.writeFieldTag(GlobalConfigFieldId.pageSize, WireType.varint);
    w.writeVarint(config.pageSize);

    for (final name in config.spaceNames) {
      w.writeFieldTag(GlobalConfigFieldId.spaceNames, WireType.lengthDelimited);
      w.writeString(name);
    }

    if (config.activeSpace != null) {
      w.writeFieldTag(
          GlobalConfigFieldId.activeSpace, WireType.lengthDelimited);
      w.writeString(config.activeSpace!);
    }

    w.writeFieldTag(GlobalConfigFieldId.hasMigrationTask, WireType.varint);
    w.writeBool(config.hasMigrationTask);

    if (config.userSchemaHash != null) {
      w.writeFieldTag(
          GlobalConfigFieldId.userSchemaHash, WireType.lengthDelimited);
      w.writeString(config.userSchemaHash!);
    }
    if (config.systemSchemaHash != null) {
      w.writeFieldTag(
          GlobalConfigFieldId.systemSchemaHash, WireType.lengthDelimited);
      w.writeString(config.systemSchemaHash!);
    }

    w.writeFieldTag(GlobalConfigFieldId.lastGlobalDirIndex, WireType.varint);
    w.writeVarint(config.lastGlobalDirIndex);
    w.writeFieldTag(GlobalConfigFieldId.lastGlobalDirEntries, WireType.varint);
    w.writeVarint(config.lastGlobalDirEntries);
    w.writeFieldTag(GlobalConfigFieldId.lastNonGlobalDirIndex, WireType.varint);
    w.writeVarint(config.lastNonGlobalDirIndex);
    w.writeFieldTag(
        GlobalConfigFieldId.lastNonGlobalDirEntries, WireType.varint);
    w.writeVarint(config.lastNonGlobalDirEntries);

    return w.view;
  }

  /// Decode field-tag payload into [GlobalConfig].
  static GlobalConfig decodePayload(Uint8List bytes) {
    if (bytes.isEmpty) return GlobalConfig();

    final r = BinaryReader(bytes);
    int? version;
    int? userVersion;
    int? maxEntriesPerDir;
    int pageSize = 0;
    final spaceNames = <String>{};
    String? activeSpace;
    var hasMigrationTask = false;
    String? userSchemaHash;
    String? systemSchemaHash;
    var lastGlobalDirIndex = 0;
    var lastGlobalDirEntries = 0;
    var lastNonGlobalDirIndex = 0;
    var lastNonGlobalDirEntries = 0;
    var sawActiveSpace = false;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case GlobalConfigFieldId.version:
          version = r.readVarint();
          break;
        case GlobalConfigFieldId.userVersion:
          userVersion = r.readVarint();
          break;
        case GlobalConfigFieldId.maxEntriesPerDir:
          maxEntriesPerDir = r.readVarint();
          break;
        case GlobalConfigFieldId.pageSize:
          pageSize = r.readVarint();
          break;
        case GlobalConfigFieldId.spaceNames:
          spaceNames.add(r.readString());
          break;
        case GlobalConfigFieldId.activeSpace:
          activeSpace = r.readString();
          sawActiveSpace = true;
          break;
        case GlobalConfigFieldId.hasMigrationTask:
          hasMigrationTask = r.readBool();
          break;
        case GlobalConfigFieldId.userSchemaHash:
          userSchemaHash = r.readString();
          break;
        case GlobalConfigFieldId.systemSchemaHash:
          systemSchemaHash = r.readString();
          break;
        case GlobalConfigFieldId.lastGlobalDirIndex:
          lastGlobalDirIndex = r.readVarint();
          break;
        case GlobalConfigFieldId.lastGlobalDirEntries:
          lastGlobalDirEntries = r.readVarint();
          break;
        case GlobalConfigFieldId.lastNonGlobalDirIndex:
          lastNonGlobalDirIndex = r.readVarint();
          break;
        case GlobalConfigFieldId.lastNonGlobalDirEntries:
          lastNonGlobalDirEntries = r.readVarint();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    return GlobalConfig(
      version: version,
      userVersion: userVersion,
      maxEntriesPerDir: maxEntriesPerDir,
      pageSize: pageSize,
      spaceNames: spaceNames.isEmpty ? null : spaceNames,
      activeSpace: sawActiveSpace ? activeSpace : 'default',
      hasMigrationTask: hasMigrationTask,
      userSchemaHash: userSchemaHash,
      systemSchemaHash: systemSchemaHash,
      lastGlobalDirIndex: lastGlobalDirIndex,
      lastGlobalDirEntries: lastGlobalDirEntries,
      lastNonGlobalDirIndex: lastNonGlobalDirIndex,
      lastNonGlobalDirEntries: lastNonGlobalDirEntries,
    );
  }

  /// Encode full on-disk file bytes (TOBF frame ± ConfigVault encryption).
  static Uint8List encodeFile(GlobalConfig config, {required bool encrypt}) {
    return ConfigFileCodec.encodeFile(encodePayload(config), encrypt: encrypt);
  }

  /// Decode full on-disk file bytes.
  static GlobalConfig decodeFile(Uint8List frameBytes) {
    return decodePayload(ConfigFileCodec.decodeFile(frameBytes));
  }
}
