import 'dart:typed_data';

import 'db_exception.dart';
import 'result_status.dart';
import 'result_type.dart';

/// Strongly typed sparse vector (aligned storage and retrieval).
///
/// [indices] are strictly ascending unique non-zero dimension ids (`uint32`).
/// [values] are the matching feature weights (`float32`).
///
/// Indexing expects doc-side weights in `(0, 1]`; values `>= 1.0` saturate at
/// full stored impact. Query-side weights may use any positive scale; normalize
/// model activations (e.g. raw SPLADE) before insert when they exceed 1.
class SparseVectorData {
  /// Strictly ascending, unique non-zero dimension indices.
  final Uint32List indices;

  /// Corresponding non-zero feature weights.
  final Float32List values;

  /// Primary constructor.
  ///
  /// Requires [indices] to be strictly sorted with no duplicates, and
  /// [indices.length] == [values.length].
  const SparseVectorData(this.indices, this.values);

  /// Number of non-zero elements.
  int get nnz => indices.length;

  /// Builds a sorted [SparseVectorData] from a sparse map, dropping zeros.
  factory SparseVectorData.fromMap(Map<Object, num> map) {
    final entries = <MapEntry<int, double>>[];
    for (final entry in map.entries) {
      if (entry.value == 0) continue;
      final key = entry.key;
      final int k;
      if (key is int) {
        k = key;
      } else if (key is String) {
        final parsed = int.tryParse(key);
        if (parsed == null) {
          throw DbException([
            InvalidArgumentStatus(
              type: ResultType.devInvalidArgumentType,
              message: 'Sparse dimension index is not an integer: $key',
              parameterName: 'indices',
              passedValue: key,
            )
          ]);
        }
        k = parsed;
      } else {
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentType,
            message: 'Sparse dimension index is not an integer: $key',
            parameterName: 'indices',
            passedValue: key,
          )
        ]);
      }
      if (k < 0 || k > 0xFFFFFFFF) {
        throw DbException([
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentType,
            message: 'Sparse dimension index out of uint32 range: $k',
            parameterName: 'indices',
            passedValue: k,
          )
        ]);
      }
      entries.add(MapEntry(k, entry.value.toDouble()));
    }
    entries.sort((a, b) => a.key.compareTo(b.key));

    final indices = Uint32List(entries.length);
    final values = Float32List(entries.length);
    int write = 0;
    int? prev;
    for (final entry in entries) {
      if (prev == entry.key) {
        values[write - 1] = entry.value;
        continue;
      }
      prev = entry.key;
      indices[write] = entry.key;
      values[write] = entry.value;
      write++;
    }
    if (write == entries.length) {
      return SparseVectorData(indices, values);
    }
    return SparseVectorData(
      Uint32List.sublistView(indices, 0, write),
      Float32List.sublistView(values, 0, write),
    );
  }

  /// Inner product via a two-pointer sweep. O(nnzA + nnzB).
  double dot(SparseVectorData other) {
    final idxA = indices;
    final valA = values;
    final idxB = other.indices;
    final valB = other.values;
    final lenA = idxA.length;
    final lenB = idxB.length;

    int i = 0;
    int j = 0;
    double sum = 0.0;

    while (i < lenA && j < lenB) {
      final a = idxA[i];
      final b = idxB[j];
      if (a == b) {
        sum += valA[i] * valB[j];
        i++;
        j++;
      } else if (a < b) {
        i++;
      } else {
        j++;
      }
    }
    return sum;
  }

  /// Encodes this sparse vector into compact binary layout (`nnz * 8` bytes):
  /// `nnz` little-endian uint32 indices followed by `nnz` little-endian float32 values.
  Uint8List toBytes() {
    final int n = indices.length;
    final out = Uint8List(n * 8);
    if (n == 0) return out;
    final bd = ByteData.sublistView(out);
    final int valBase = n * 4;
    for (int i = 0; i < n; i++) {
      bd.setUint32(i * 4, indices[i], Endian.little);
      bd.setFloat32(valBase + i * 4, values[i], Endian.little);
    }
    return out;
  }

  /// Decodes a sparse vector from compact binary bytes produced by [toBytes].
  factory SparseVectorData.fromBytes(Uint8List bytes) {
    if ((bytes.length & 7) != 0) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devInvalidArgumentFormat,
          message:
              'Invalid byte length for SparseVectorData: ${bytes.length} (must be a multiple of 8)',
          parameterName: 'bytes',
          passedValue: bytes.length,
        ),
      ]);
    }
    final int n = bytes.length >> 3;
    final idx = Uint32List(n);
    final val = Float32List(n);
    if (n == 0) return SparseVectorData(idx, val);
    final bd = ByteData.sublistView(bytes);
    final int valBase = n * 4;
    for (int i = 0; i < n; i++) {
      idx[i] = bd.getUint32(i * 4, Endian.little);
      val[i] = bd.getFloat32(valBase + i * 4, Endian.little);
    }
    return SparseVectorData(idx, val);
  }

  Map<String, dynamic> toJson() {
    return {
      'indices': indices.toList(growable: false),
      'values': values.toList(growable: false),
    };
  }

  @override
  String toString() => 'SparseVectorData(nnz: $nnz)';
}
