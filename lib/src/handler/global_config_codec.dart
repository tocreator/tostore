import 'dart:convert';
import 'dart:typed_data';

import '../model/applied_encryption.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/global_config.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'aes_gcm.dart';
import 'binary_codec.dart';
import 'chacha20_poly1305.dart';
import 'sha256.dart';
import 'tobf_file_codec.dart';

/// Algorithm id embedded in GlobalConfig ciphertext (auto-detect on decrypt).
enum ConfigCryptoAlgorithm {
  chacha20Poly1305(1),
  aes256Gcm(2);

  final int id;
  const ConfigCryptoAlgorithm(this.id);

  static ConfigCryptoAlgorithm fromId(int id) {
    for (final v in ConfigCryptoAlgorithm.values) {
      if (v.id == id) return v;
    }
    throw DbException([
      GeneralStatus(
        type: ResultType.engError,
        message: 'ConfigCrypto: unknown algorithm id=$id',
      ),
    ]);
  }

  /// Map user [EncryptionType] to GlobalConfig shell algorithm.
  ///
  /// Only [EncryptionType.aes256Gcm] selects AES; all other types (incl. none)
  /// use ChaCha20-Poly1305 for the always-on GlobalConfig KEK shell.
  static ConfigCryptoAlgorithm fromEncryptionType(EncryptionType? type) {
    switch (type) {
      case EncryptionType.aes256Gcm:
        return ConfigCryptoAlgorithm.aes256Gcm;
      case EncryptionType.chacha20Poly1305:
      case EncryptionType.xorObfuscation:
      case EncryptionType.none:
      case null:
        return ConfigCryptoAlgorithm.chacha20Poly1305;
    }
  }
}

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
  static const int appliedEncryption = 14;
}

/// Nested [AppliedEncryption] / [EncryptionKeyInfo] field IDs.
abstract final class AppliedEncryptionFieldId {
  static const int current = 1;
  static const int historyKeys = 2;
}

abstract final class EncryptionKeyInfoFieldId {
  /// UTF-8 plaintext encodingKey bytes.
  static const int key = 1;
  static const int keyId = 2;
  static const int migrationCompletedAtMs = 3;
}

/// TOBF codec for [GlobalConfig]: field-tag payload + encryptionKey (KEK) shell.
///
/// **Public I/O (always encrypted):** [encodeFile], [decodeFile],
/// [decodeFileWithFallback]. Do not persist field bytes without these APIs.
///
/// On-disk body: `[algId:u8][AEAD payload]` where AEAD payload is
/// `nonce(12) || ciphertext || tag(16)` from ChaCha20-Poly1305 or AES-256-GCM.
/// Decrypt always materializes the AEAD payload at buffer offset 0 so crypto
/// engines never see an unaligned view created by the algId prefix.
///
/// Key material: [SHA256.stringToBytes]. Independent of EncodingManager / DEK.
final class GlobalConfigCodec {
  GlobalConfigCodec._();

  static const int _maxBodyBytes = TobfFileCodec.maxBodyBytesDefault;

  static final Uint8List _aad =
      Uint8List.fromList(utf8.encode('tostore.global.cfg.kek.v1'));

  static void _writeKeyInfo(BinaryWriter w, EncryptionKeyInfo info) {
    if (info.key.isNotEmpty) {
      w.writeFieldTag(EncryptionKeyInfoFieldId.key, WireType.lengthDelimited);
      w.writeBytes(Uint8List.fromList(utf8.encode(info.key)));
    }
    w.writeFieldTag(EncryptionKeyInfoFieldId.keyId, WireType.varint);
    w.writeVarint(info.keyId);
    if (info.migrationCompletedAt != null) {
      w.writeFieldTag(
        EncryptionKeyInfoFieldId.migrationCompletedAtMs,
        WireType.fixed64,
      );
      w.writeFixed64(
        info.migrationCompletedAt!.toUtc().millisecondsSinceEpoch,
      );
    }
  }

  static EncryptionKeyInfo _readKeyInfo(BinaryReader r) {
    var key = '';
    var keyId = 0;
    DateTime? completedAt;
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case EncryptionKeyInfoFieldId.key:
          key = utf8.decode(r.readBytes());
          break;
        case EncryptionKeyInfoFieldId.keyId:
          keyId = r.readVarint();
          break;
        case EncryptionKeyInfoFieldId.migrationCompletedAtMs:
          completedAt =
              DateTime.fromMillisecondsSinceEpoch(r.readFixed64(), isUtc: true);
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    return EncryptionKeyInfo(
      key: key,
      keyId: keyId,
      migrationCompletedAt: completedAt,
    );
  }

  static void _writeAppliedEncryption(
      BinaryWriter w, AppliedEncryption applied) {
    w.writeMessage(AppliedEncryptionFieldId.current, (sub) {
      _writeKeyInfo(sub, applied.current);
    });
    for (final hist in applied.historyKeys) {
      w.writeMessage(AppliedEncryptionFieldId.historyKeys, (sub) {
        _writeKeyInfo(sub, hist);
      });
    }
  }

  static AppliedEncryption _readAppliedEncryption(BinaryReader r) {
    EncryptionKeyInfo? current;
    final history = <EncryptionKeyInfo>[];
    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case AppliedEncryptionFieldId.current:
          r.readMessage((child, _) {
            current = _readKeyInfo(child);
          });
          break;
        case AppliedEncryptionFieldId.historyKeys:
          r.readMessage((child, _) {
            history.add(_readKeyInfo(child));
          });
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    return AppliedEncryption(
      current: current ?? const EncryptionKeyInfo(key: '', keyId: 0),
      historyKeys: history,
    );
  }

  /// Field-tag serialization only — never write this to disk directly.
  static Uint8List _encodeFields(GlobalConfig config) {
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

    if (config.appliedEncryption != null) {
      w.writeMessage(GlobalConfigFieldId.appliedEncryption, (sub) {
        _writeAppliedEncryption(sub, config.appliedEncryption!);
      });
    }

    return w.view;
  }

  /// Field-tag deserialization only — input must already be decrypted.
  static GlobalConfig _decodeFields(Uint8List bytes) {
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
    AppliedEncryption? appliedEncryption;

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
        case GlobalConfigFieldId.appliedEncryption:
          r.readMessage((child, _) {
            appliedEncryption = _readAppliedEncryption(child);
          });
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
      appliedEncryption: appliedEncryption,
    );
  }

  /// Encode full on-disk file bytes (TOBF + encryptionKey shell).
  ///
  /// This is the only supported write path for `global_config.tobf`.
  static Uint8List encodeFile(
    GlobalConfig config, {
    required String encryptionKey,
    ConfigCryptoAlgorithm algorithm = ConfigCryptoAlgorithm.chacha20Poly1305,
  }) {
    final cipher = _aeadEncrypt(
      _encodeFields(config),
      encryptionKey: encryptionKey,
      algorithm: algorithm,
    );
    final body = Uint8List(1 + cipher.length);
    body[0] = algorithm.id;
    body.setAll(1, cipher);
    return TobfFileCodec.encodeFrame(body, encrypted: true);
  }

  /// Decode full on-disk file bytes; algorithm auto-detected from body prefix.
  ///
  /// This is the only supported single-key read path for `global_config.tobf`.
  static GlobalConfig decodeFile(
    Uint8List frameBytes, {
    required String encryptionKey,
  }) {
    return _decodeFields(
      _unwrapAndDecrypt(frameBytes, encryptionKey: encryptionKey),
    );
  }

  /// Decode with preferred + fallback KEKs (null→user key auto-migration).
  static ({GlobalConfig config, String usedKey}) decodeFileWithFallback(
    Uint8List frameBytes, {
    required String preferredKey,
    List<String> fallbackKeys = const [],
  }) {
    final candidates = <String>[
      preferredKey,
      for (final k in fallbackKeys)
        if (k.isNotEmpty && k != preferredKey) k,
    ];

    Object? lastError;
    for (final key in candidates) {
      try {
        return (
          config: decodeFile(frameBytes, encryptionKey: key),
          usedKey: key,
        );
      } catch (e) {
        lastError = e;
      }
    }

    throw DbException([
      GeneralStatus(
        type: ResultType.devInvalidArgumentFormat,
        message:
            'GlobalConfigCodec: failed to decrypt with provided encryptionKey',
      ),
      if (lastError is DbException) ...lastError.statuses,
    ]);
  }

  static Uint8List _unwrapAndDecrypt(
    Uint8List frameBytes, {
    required String encryptionKey,
  }) {
    final decoded = TobfFileCodec.decodeFrameWithHeader(
      frameBytes,
      maxBodyLimit: _maxBodyBytes,
    );

    // GlobalConfig is always KEK-encrypted; plaintext TOBF is never valid.
    if (!TobfFileCodec.isEncrypted(decoded.header)) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'GlobalConfigCodec: expected encrypted TOBF frame',
        ),
      ]);
    }

    final body = decoded.body;
    if (body.length < 1 + 12 + 16) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'GlobalConfigCodec: encrypted body too short',
        ),
      ]);
    }

    final algorithm = ConfigCryptoAlgorithm.fromId(body[0]);
    // Materialize ciphertext at offset 0. Body may be a TOBF zero-copy view,
    // and algId shifts the AEAD payload to an unaligned offset — ChaCha's
    // asUint32List path requires 4-byte alignment; AES-GCM mis-reads nonce
    // when buffer.asByteData() ignores view offset.
    final cipher = Uint8List.fromList(
      body.buffer.asUint8List(body.offsetInBytes + 1, body.length - 1),
    );
    return _aeadDecrypt(
      cipher,
      encryptionKey: encryptionKey,
      algorithm: algorithm,
    );
  }

  static Uint8List _key32(String encryptionKey) =>
      SHA256.stringToBytes(encryptionKey);

  static Uint8List _aeadEncrypt(
    Uint8List plaintext, {
    required String encryptionKey,
    required ConfigCryptoAlgorithm algorithm,
  }) {
    final key = _key32(encryptionKey);
    switch (algorithm) {
      case ConfigCryptoAlgorithm.chacha20Poly1305:
        return ChaCha20Poly1305.encryptBytes(
          plaintext: plaintext,
          key: key,
          aad: _aad,
        );
      case ConfigCryptoAlgorithm.aes256Gcm:
        return AESGCM.encryptBytes(
          plaintext: plaintext,
          key: key,
          aad: _aad,
        );
    }
  }

  static Uint8List _aeadDecrypt(
    Uint8List cipher, {
    required String encryptionKey,
    required ConfigCryptoAlgorithm algorithm,
  }) {
    final key = _key32(encryptionKey);
    try {
      switch (algorithm) {
        case ConfigCryptoAlgorithm.chacha20Poly1305:
          return ChaCha20Poly1305.decryptBytes(
            encryptedData: cipher,
            key: key,
            aad: _aad,
          );
        case ConfigCryptoAlgorithm.aes256Gcm:
          return AESGCM.decryptBytes(
            encryptedData: cipher,
            key: key,
            aad: _aad,
          );
      }
    } catch (e) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'GlobalConfigCodec: decrypt failed (alg=${algorithm.id})',
        ),
      ]);
    }
  }
}
