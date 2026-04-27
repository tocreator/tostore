import '../../model/table_schema.dart';

/// Lightweight sendable payload for a unique-key reference planned in pure compute.
class PlannedUniqueKeyRef {
  final String indexName;
  final dynamic compositeKey;

  const PlannedUniqueKeyRef({
    required this.indexName,
    required this.compositeKey,
  });
}

/// Plan insert-time unique refs using only pure computation.
List<PlannedUniqueKeyRef> planInsertUniqueRefsPure({
  required TableSchema schema,
  required List<IndexSchema> uniqueIndexes,
  required Map<String, dynamic> data,
}) {
  final refs = <PlannedUniqueKeyRef>[];
  final pk = schema.primaryKey;
  final pkVal = data[pk];
  if (pkVal != null) {
    refs.add(
      PlannedUniqueKeyRef(
        indexName: 'pk',
        compositeKey: pkVal.toString(),
      ),
    );
  }

  for (final index in uniqueIndexes) {
    final canKey = schema.createCanonicalIndexKey(index.fields, data);
    if (canKey != null) {
      refs.add(
        PlannedUniqueKeyRef(
          indexName: index.actualIndexName,
          compositeKey: canKey,
        ),
      );
    }
  }
  return refs;
}

/// Plan update-time unique refs using only pure computation.
List<PlannedUniqueKeyRef> planUpdateUniqueRefsPure({
  required TableSchema schema,
  required List<IndexSchema> uniqueIndexes,
  required Map<String, dynamic> updatedRecord,
  required List<String> changedFields,
  required bool includePrimaryKey,
  required bool changedOnly,
}) {
  final refs = <PlannedUniqueKeyRef>[];
  final changedFieldSet = changedOnly ? changedFields.toSet() : null;

  if (includePrimaryKey) {
    final pkVal = updatedRecord[schema.primaryKey];
    if (pkVal != null) {
      refs.add(
        PlannedUniqueKeyRef(
          indexName: 'pk',
          compositeKey: pkVal.toString(),
        ),
      );
    }
  }

  for (final index in uniqueIndexes) {
    if (changedFieldSet != null &&
        !index.fields.any((field) => changedFieldSet.contains(field))) {
      continue;
    }

    final canKey = schema.createCanonicalIndexKey(index.fields, updatedRecord);
    if (canKey != null) {
      refs.add(
        PlannedUniqueKeyRef(
          indexName: index.actualIndexName,
          compositeKey: canKey,
        ),
      );
    }
  }

  return refs;
}
