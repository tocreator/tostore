import 'dart:typed_data';

import '../model/data_store_config.dart';
import '../model/transaction_models.dart';
import 'binary_codec.dart';
import 'meta_file_codec.dart';

/// Stable field IDs for transaction meta. Never reuse IDs.
abstract final class TxnMainMetaFieldId {
  static const int currentPartitionIndex = 1;
  static const int activePartitions = 2;
  // Reserved 10–15 for future top-level fields.
}

abstract final class TxnPartitionMetaFieldId {
  static const int partitionIndex = 1;
  static const int totalCount = 2;
  static const int committedCount = 3;
  static const int rolledBackCount = 4;
  // Reserved 10–15 for future top-level fields.
}

/// Field-tag + TOBF codec for transaction main / partition meta.
final class TxnMetaCodec {
  TxnMetaCodec._();

  static Uint8List encodeMainPayload(TransactionMainMeta meta) {
    final w = BinaryWriter(initialCapacity: 64);
    w.writeFieldTag(TxnMainMetaFieldId.currentPartitionIndex, WireType.varint);
    w.writeVarint(meta.currentPartitionIndex);
    for (final p in meta.activePartitions) {
      w.writeFieldTag(TxnMainMetaFieldId.activePartitions, WireType.varint);
      w.writeVarint(p);
    }
    return w.view;
  }

  static TransactionMainMeta decodeMainPayload(Uint8List bytes) {
    if (bytes.isEmpty) return TransactionMainMeta();

    final r = BinaryReader(bytes);
    var currentPartitionIndex = 0;
    final activePartitions = <int>{};
    var sawActive = false;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case TxnMainMetaFieldId.currentPartitionIndex:
          currentPartitionIndex = r.readVarint();
          break;
        case TxnMainMetaFieldId.activePartitions:
          activePartitions.add(r.readVarint());
          sawActive = true;
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    return TransactionMainMeta(
      currentPartitionIndex: currentPartitionIndex,
      activePartitions: sawActive ? activePartitions : <int>{0},
    );
  }

  static Uint8List encodePartitionPayload(TransactionPartitionMeta meta) {
    final w = BinaryWriter(initialCapacity: 32);
    w.writeFieldTag(TxnPartitionMetaFieldId.partitionIndex, WireType.varint);
    w.writeVarint(meta.partitionIndex);
    w.writeFieldTag(TxnPartitionMetaFieldId.totalCount, WireType.varint);
    w.writeVarint(meta.totalCount);
    w.writeFieldTag(TxnPartitionMetaFieldId.committedCount, WireType.varint);
    w.writeVarint(meta.committedCount);
    w.writeFieldTag(TxnPartitionMetaFieldId.rolledBackCount, WireType.varint);
    w.writeVarint(meta.rolledBackCount);
    return w.view;
  }

  static TransactionPartitionMeta decodePartitionPayload(Uint8List bytes) {
    final r = BinaryReader(bytes);
    var partitionIndex = 0;
    var totalCount = 0;
    var committedCount = 0;
    var rolledBackCount = 0;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case TxnPartitionMetaFieldId.partitionIndex:
          partitionIndex = r.readVarint();
          break;
        case TxnPartitionMetaFieldId.totalCount:
          totalCount = r.readVarint();
          break;
        case TxnPartitionMetaFieldId.committedCount:
          committedCount = r.readVarint();
          break;
        case TxnPartitionMetaFieldId.rolledBackCount:
          rolledBackCount = r.readVarint();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    return TransactionPartitionMeta(
      partitionIndex: partitionIndex,
      totalCount: totalCount,
      committedCount: committedCount,
      rolledBackCount: rolledBackCount,
    );
  }

  static Uint8List encodeMainFile(
    TransactionMainMeta meta, {
    required EncryptionConfig? encryptionConfig,
  }) {
    return MetaFileCodec.encodeFile(
      encodeMainPayload(meta),
      encrypt: MetaFileCodec.shouldEncrypt(encryptionConfig),
      aad: MetaFileCodec.txnMetaAad,
    );
  }

  static TransactionMainMeta decodeMainFile(Uint8List frameBytes) {
    return decodeMainPayload(
      MetaFileCodec.decodeFile(frameBytes, aad: MetaFileCodec.txnMetaAad),
    );
  }

  static Uint8List encodePartitionFile(
    TransactionPartitionMeta meta, {
    required EncryptionConfig? encryptionConfig,
  }) {
    return MetaFileCodec.encodeFile(
      encodePartitionPayload(meta),
      encrypt: MetaFileCodec.shouldEncrypt(encryptionConfig),
      aad: MetaFileCodec.txnMetaAad,
    );
  }

  static TransactionPartitionMeta decodePartitionFile(Uint8List frameBytes) {
    return decodePartitionPayload(
      MetaFileCodec.decodeFile(frameBytes, aad: MetaFileCodec.txnMetaAad),
    );
  }
}
