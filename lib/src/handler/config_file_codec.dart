import 'dart:convert';
import 'dart:typed_data';

import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'chacha20_poly1305.dart';
import 'tobf_file_codec.dart';

/// Shared TOBF frame wrap/unwrap for GlobalConfig / SpaceConfig files.
///
/// File-shell encryption (when [EncryptionScope.full]) uses a hardcoded engine
/// ConfigVaultKey — independent of user [EncryptionConfig.encryptionKey] /
/// [EncryptionConfig.encodingKey] to avoid bootstrap circularity.
/// Wrapped encoding keys inside SpaceConfig remain protected by the user KEK.
abstract final class ConfigFileCodec {
  ConfigFileCodec._();

  /// Soft DoS cap for config frames (configs are small).
  static const int maxBodyBytes = TobfFileCodec.maxBodyBytesDefault;

  /// Engine-default vault passphrase (open-source obfuscation for metadata only).
  static const String _vaultPassphrase = 'ToStore.ConfigVault.v1.DefaultKey';

  static final Uint8List _vaultKey =
      ChaCha20Poly1305.generateKeyFromString(_vaultPassphrase);

  static final Uint8List _vaultAad =
      Uint8List.fromList(utf8.encode('tostore.cfg.vault.v1'));

  /// Encode payload into a TOBF file frame.
  static Uint8List encodeFile(Uint8List payload, {required bool encrypt}) {
    final body = encrypt
        ? ChaCha20Poly1305.encryptBytes(
            plaintext: payload,
            key: _vaultKey,
            aad: _vaultAad,
          )
        : payload;
    return TobfFileCodec.encodeFrame(body, encrypted: encrypt);
  }

  /// Decode a TOBF file frame into the inner field-tag payload.
  static Uint8List decodeFile(Uint8List frameBytes) {
    final decoded = TobfFileCodec.decodeFrameWithHeader(
      frameBytes,
      maxBodyLimit: maxBodyBytes,
    );
    if (!TobfFileCodec.isEncrypted(decoded.header)) return decoded.body;

    // Copy out of the TOBF frame view: ChaCha20 assumes 4-byte-aligned offsets.
    final cipherBytes = Uint8List.fromList(decoded.body);
    try {
      return ChaCha20Poly1305.decryptBytes(
        encryptedData: cipherBytes,
        key: _vaultKey,
        aad: _vaultAad,
      );
    } catch (e) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'ConfigFileCodec: failed to decrypt config frame',
        )
      ]);
    }
  }

  /// Whether [EncryptionScope.full] is active on the given config.
  static bool shouldEncrypt(EncryptionConfig? encryptionConfig) =>
      TobfFileCodec.shouldEncryptFullScope(encryptionConfig);
}
