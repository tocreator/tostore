import 'dart:convert';
import 'dart:typed_data';

import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'encryption.dart';
import 'tobf_file_codec.dart';

/// TOBF file shell for WAL / transaction metadata.
///
/// When [EncryptionScope.full] is active, the field-tag payload is encrypted
/// with [EncryptionManager] (user key) before framing — same key domain as
/// ToWL/ToTX logs. Config files continue to use ConfigVault separately.
abstract final class MetaFileCodec {
  MetaFileCodec._();

  /// Soft DoS cap for WAL/Txn meta frames (pending batches can be larger).
  static const int maxBodyBytes = 16 * 1024 * 1024;

  static final Uint8List walMetaAad =
      Uint8List.fromList(utf8.encode('tostore.wal.meta.v1'));

  static final Uint8List txnMetaAad =
      Uint8List.fromList(utf8.encode('tostore.txn.meta.v1'));

  /// Whether meta body should be encrypted under [EncryptionScope.full].
  static bool shouldEncrypt(EncryptionConfig? encryptionConfig) =>
      TobfFileCodec.shouldEncryptFullScope(encryptionConfig);

  /// Encode field-tag [payload] into on-disk TOBF bytes.
  static Uint8List encodeFile(
    Uint8List payload, {
    required bool encrypt,
    required Uint8List aad,
  }) {
    final body =
        encrypt ? EncryptionManager.encodeBytes(payload, aad: aad) : payload;
    return TobfFileCodec.encodeFrame(body, encrypted: encrypt);
  }

  /// Decode on-disk TOBF bytes into field-tag payload.
  static Uint8List decodeFile(
    Uint8List frameBytes, {
    required Uint8List aad,
  }) {
    final decoded = TobfFileCodec.decodeFrameWithHeader(
      frameBytes,
      maxBodyLimit: maxBodyBytes,
    );
    if (!TobfFileCodec.isEncrypted(decoded.header)) {
      return decoded.body;
    }
    try {
      // Copy out of the TOBF frame view for AEAD alignment assumptions.
      final cipherBytes = Uint8List.fromList(decoded.body);
      return EncryptionManager.decodeBytes(cipherBytes, aad: aad);
    } catch (e) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'MetaFileCodec: failed to decrypt meta frame',
        )
      ]);
    }
  }
}
