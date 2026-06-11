import 'dart:typed_data';

import 'value_ref.dart';
import 'db_exception.dart';
import 'result_status.dart';
import 'result_type.dart';

/// Canonical on-disk value encoding stored in B+Tree leaf `values[]`.
///
/// New format (no legacy compatibility required):
/// - [tag:u8]
///   - 0x00: inline bytes
///     - [data...]
///   - 0x01: overflow ref
///     - [ValueRef bytes...]
final class StoredValue {
  static const int tagInline = 0x00;
  static const int tagOverflowRef = 0x01;

  final int tag;
  final Uint8List inlineBytes;
  final ValueRef? ref;

  const StoredValue._({required this.tag, required this.inlineBytes, this.ref});

  factory StoredValue.inline(Uint8List bytes) =>
      StoredValue._(tag: tagInline, inlineBytes: bytes);

  factory StoredValue.overflow(ValueRef ref) =>
      StoredValue._(tag: tagOverflowRef, inlineBytes: Uint8List(0), ref: ref);

  Uint8List encode() {
    switch (tag) {
      case tagInline:
        if (inlineBytes.isEmpty) {
          // Allow empty but still tag it.
          return Uint8List.fromList(const <int>[tagInline]);
        }
        final out = Uint8List(1 + inlineBytes.length);
        out[0] = tagInline;
        out.setRange(1, out.length, inlineBytes);
        return out;
      case tagOverflowRef:
        final r = ref;
        if (r == null) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'Missing overflow ref: StoredValue tag is tagOverflowRef ($tagOverflowRef), but the ValueRef reference is null.',
            )
          ]);
        }
        final rb = r.encode();
        final out = Uint8List(1 + rb.length);
        out[0] = tagOverflowRef;
        out.setRange(1, out.length, rb);
        return out;
      default:
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Unknown StoredValue tag: Received tag = $tag. Valid tags are tagInline ($tagInline) and tagOverflowRef ($tagOverflowRef).',
          )
        ]);
    }
  }

  static StoredValue decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message:
              'Empty StoredValue: Attempted to decode StoredValue from an empty Uint8List (bytes.length = 0).',
        )
      ]);
    }
    final tag = bytes[0];
    switch (tag) {
      case tagInline:
        return StoredValue.inline(
            bytes.length <= 1 ? Uint8List(0) : bytes.sublist(1));
      case tagOverflowRef:
        final rb = bytes.length <= 1 ? Uint8List(0) : bytes.sublist(1);
        final r = ValueRef.tryDecode(rb);
        if (r == null) {
          throw DbException([
            GeneralStatus(
              type: ResultType.engError,
              message:
                  'Invalid overflow ref: Failed to decode ValueRef from bytes (length = ${rb.length}).',
            )
          ]);
        }
        return StoredValue.overflow(r);
      default:
        throw DbException([
          GeneralStatus(
            type: ResultType.engError,
            message:
                'Unknown StoredValue tag: Received tag = $tag. Valid tags are tagInline ($tagInline) and tagOverflowRef ($tagOverflowRef).',
          )
        ]);
    }
  }
}
