import 'dart:typed_data';

import 'binary_codec.dart';
import '../model/data_store_config.dart';

/// Shared TOBF file-shell encode/decode (frame + checksum + flags).
///
/// Encryption of the body is the caller's responsibility:
/// - Config files: ConfigVault ChaCha via [ConfigFileCodec]
/// - WAL/Txn meta: [EncryptionManager] via [MetaFileCodec] when
///   [EncryptionScope.full]
abstract final class TobfFileCodec {
  TobfFileCodec._();

  /// TOBF flags bit0: body is ciphertext (algorithm decided by caller).
  static const int flagEncrypted = 1 << 0;

  /// Soft DoS cap for typical small engine meta/config frames.
  static const int maxBodyBytesDefault = 1 * 1024 * 1024;

  /// Whether [EncryptionScope.full] is active on the given config.
  ///
  /// GlobalConfig and SpaceConfig files are written as plaintext TOBF frames (flags = 0)
  /// by default or when [encryptionConfig] is null / [EncryptionType.none] / [EncryptionScope.standard].
  /// Shell encryption (flags = 1) is ONLY enabled when [encryptionScope] is explicitly set
  /// to [EncryptionScope.full] with a valid non-none [encryptionType].
  static bool shouldEncryptFullScope(EncryptionConfig? encryptionConfig) {
    if (encryptionConfig == null) return false;
    if (encryptionConfig.encryptionType == EncryptionType.none) return false;
    return encryptionConfig.encryptionScope == EncryptionScope.full;
  }

  /// Wrap [body] in a TOBF frame. [body] must already be plaintext or ciphertext.
  static Uint8List encodeFrame(
    Uint8List body, {
    required bool encrypted,
    int version = 1,
  }) {
    return TOBFHeader.encodeFrame(
      body,
      version: version,
      flags: encrypted ? flagEncrypted : 0,
    );
  }

  /// Unwrap a TOBF frame; returns header + body (still possibly ciphertext).
  static ({TOBFHeader header, Uint8List body}) decodeFrameWithHeader(
    Uint8List frameBytes, {
    int maxBodyLimit = maxBodyBytesDefault,
  }) {
    return TOBFHeader.decodeFrameWithHeader(
      frameBytes,
      maxBodyLimit: maxBodyLimit,
    );
  }

  /// True when flags mark the body as encrypted.
  static bool isEncrypted(TOBFHeader header) =>
      (header.flags & flagEncrypted) != 0;
}
