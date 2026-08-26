import '../handler/value_matcher.dart';
import '../model/system_table.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';

/// Virtual PK unique index slot for buffer index trees.
///
/// Must stay aligned with [kBufferPkIndexUid] in `buffer_tree_store.dart`.
const IndexUid kTreeCacheBufferPkIndexUid = IndexUid('pk');

/// Precomputed TreeCache comparators for one table schema.
///
/// Built once when a hot [TableSchema] is cached in [TableMetaManager] and
/// shared by pending/txn buffer trees, table record hotspot cache, and index
/// hotspot cache.
final class TableTreeMatcherEntry {
  final MatcherFunction pkMatcher;
  final Map<String, List<MatcherFunction>> indexMatchersByUid;
  final String? schemaVersion;

  const TableTreeMatcherEntry({
    required this.pkMatcher,
    required this.indexMatchersByUid,
    this.schemaVersion,
  });

  List<MatcherFunction>? matchersFor(IndexUid indexUid) =>
      indexMatchersByUid[indexUid.value];
}

/// Build ordered field matchers for one B+Tree [IndexSchema].
List<MatcherFunction> _matchersForIndex(
  TableSchema schema,
  IndexSchema indexSchema,
  MatcherFunction pkMatcher,
) {
  final matchers = <MatcherFunction>[];
  for (final field in indexSchema.fields) {
    matchers.add(ValueMatcher.getMatcher(schema.getFieldMatcherType(field)));
  }
  if (!indexSchema.unique) {
    matchers.add(pkMatcher);
  }
  return matchers;
}

void _putIndexMatchers(
  Map<String, List<MatcherFunction>> out,
  IndexUid indexUid,
  List<MatcherFunction> matchers,
) {
  if (indexUid.isEmpty || matchers.isEmpty) return;
  out[indexUid.value] = matchers;
}

/// Derive TreeCache matcher registry from [schema].
///
/// When [indexes] is supplied (e.g. from [_IndexListCacheEntry.allIndexes]),
/// avoids a second [TableSchema.getAllIndexes] pass.
TableTreeMatcherEntry buildTableTreeMatcherEntry(
  TableSchema schema, {
  List<IndexSchema>? indexes,
}) {
  final pkMatcher = ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());
  final indexMatchers = <String, List<MatcherFunction>>{};

  _putIndexMatchers(
    indexMatchers,
    kTreeCacheBufferPkIndexUid,
    <MatcherFunction>[pkMatcher],
  );

  final all = indexes ?? schema.getAllIndexes();
  for (final idx in all) {
    if (idx.fields.isEmpty) continue;
    _putIndexMatchers(
      indexMatchers,
      idx.indexUid,
      _matchersForIndex(schema, idx, pkMatcher),
    );
  }

  if (SystemTable.isKeyValueTable(TableName(schema.name))) {
    final kvExpiry = IndexSchema(
      indexName: SystemTable.keyValueExpiryIndexName,
      fields: <String>[SystemTable.keyValueExpiresAtField],
      unique: false,
    ).copyWith(indexUid: SystemTable.keyValueExpiryIndexUid);
    _putIndexMatchers(
      indexMatchers,
      kvExpiry.indexUid,
      _matchersForIndex(schema, kvExpiry, pkMatcher),
    );
  }

  return TableTreeMatcherEntry(
    pkMatcher: pkMatcher,
    indexMatchersByUid: Map<String, List<MatcherFunction>>.unmodifiable(
      indexMatchers,
    ),
    schemaVersion: schema.schemaVersion,
  );
}
