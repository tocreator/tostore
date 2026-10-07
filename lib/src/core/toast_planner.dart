import 'dart:typed_data';

import '../handler/binary_schema_codec.dart';
import '../model/value_ref.dart';
import 'overflow_manager.dart';
import 'overflow_pack_session.dart';

/// Result of planning toast for one record.
final class ToastEncodeResult {
  /// Leaf StoredValue payload bytes (inline tag+bytes OR overflow tag+ValueRef).
  final Uint8List storedValueBytes;

  /// True when the leaf cell is a record-level overflow ref.
  final bool isRecordOverflow;

  const ToastEncodeResult({
    required this.storedValueBytes,
    required this.isRecordOverflow,
  });
}

/// Plan field-level + record-level overflow without reordering slots.
///
/// 1. If full encode &lt; recordThreshold → inline spine.
/// 2. Else externalize largest fields ≥ fieldThreshold one-by-one until spine
///    fits (or no more eligible fields).
/// 3. If spine still ≥ recordThreshold → pack spine as record overflow.
final class ToastPlanner {
  /// Encode one record into a leaf StoredValue, packing blobs into [session].
  static ToastEncodeResult encodeWithSession({
    required Map<String, dynamic> record,
    required List<FieldStructure> fieldStructure,
    required String? nullifyField,
    required int pageSize,
    required OverflowManager overflowManager,
    required OverflowPackSession session,
    required Uint8List Function(ValueRef ref) encodeStoredOverflow,
    required Uint8List Function(Uint8List inline) encodeStoredInline,
  }) {
    final full = BinarySchemaCodec.encodeRecord(
      record,
      fieldStructure,
      nullifyField: nullifyField,
    );
    if (!overflowManager.shouldExternalize(pageSize, full.length)) {
      return ToastEncodeResult(
        storedValueBytes: encodeStoredInline(full),
        isRecordOverflow: false,
      );
    }

    // Measure per-field encoded sizes (slot order preserved).
    final fieldSizes =
        <({int index, String name, int size, Uint8List bytes})>[];
    for (int i = 0; i < fieldStructure.length; i++) {
      final f = fieldStructure[i];
      if (f.deleted) continue;
      if (nullifyField != null && f.name == nullifyField) continue;
      final value = record[f.name];
      if (value == null) continue;
      final bytes = BinarySchemaCodec.encodeFieldValue(value);
      fieldSizes
          .add((index: i, name: f.name, size: bytes.length, bytes: bytes));
    }
    fieldSizes.sort((a, b) => b.size.compareTo(a.size));

    final overrides = <String, dynamic>{};
    var spine = full;

    // Externalize largest eligible fields one at a time; stop once spine fits.
    for (final fs in fieldSizes) {
      if (!overflowManager.shouldExternalize(pageSize, spine.length)) {
        break;
      }
      if (!overflowManager.shouldExternalizeField(pageSize, fs.size)) {
        continue;
      }
      if (overrides.containsKey(fs.name)) continue;
      overrides[fs.name] = session.packValue(fs.bytes);
      spine = BinarySchemaCodec.encodeRecordWithSlotOverrides(
        record,
        fieldStructure,
        slotOverrides: overrides,
        nullifyField: nullifyField,
      );
    }

    if (!overflowManager.shouldExternalize(pageSize, spine.length)) {
      return ToastEncodeResult(
        storedValueBytes: encodeStoredInline(spine),
        isRecordOverflow: false,
      );
    }

    // Spine still too large → record-level overflow (field refs stay inside).
    final spineRef = session.packValue(spine);
    return ToastEncodeResult(
      storedValueBytes: encodeStoredOverflow(spineRef),
      isRecordOverflow: true,
    );
  }
}
