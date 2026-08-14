import 'dart:convert';
import 'dart:typed_data';

import '../model/meta_info.dart';
import '../model/system_table.dart';
import '../model/table_identity.dart';
import '../model/table_meta.dart';
import '../model/table_schema.dart';
import 'binary_codec.dart';
import 'binary_map_codec.dart';

/// Stable field IDs for TableSchema binary encoding. Reserved: 20..127.
abstract final class TableSchemaFieldId {
  static const int name = 1;
  static const int primaryKeyConfig = 2;
  static const int fields = 3;
  static const int indexes = 4;
  static const int foreignKeys = 5;
  static const int isGlobal = 6;
  static const int tableId = 7;
  static const int tableUid = 8;
  static const int schemaVersion = 9;
  static const int isSystemTable = 10;
  static const int ttlConfig = 11;
  static const int autoIndexes = 12;
}

abstract final class FieldSchemaFieldId {
  static const int name = 1;
  static const int type = 2;
  static const int nullable = 3;
  static const int defaultValue = 4;
  static const int unique = 5;
  static const int createIndex = 6;
  static const int maxLength = 7;
  static const int minLength = 8;
  static const int minValue = 9;
  static const int maxValue = 10;
  static const int comment = 11;
  static const int fieldId = 12;
  static const int defaultValueType = 13;
  static const int vectorConfig = 14;
}

abstract final class IndexSchemaFieldId {
  static const int indexName = 1;
  static const int fields = 2;
  static const int unique = 3;
  static const int type = 4;
  static const int vectorConfig = 5;
  static const int indexUid = 6;
}

abstract final class PrimaryKeyConfigFieldId {
  static const int name = 1;
  static const int type = 2;
  static const int sequentialConfig = 3;
  static const int isOrdered = 4;
  static const int fromFieldId = 5;
}

abstract final class SequentialIdConfigFieldId {
  static const int initialValue = 1;
  static const int increment = 2;
  static const int useRandomIncrement = 3;
}

abstract final class ForeignKeySchemaFieldId {
  static const int name = 1;
  static const int fields = 2;
  static const int referencedTable = 3;
  static const int referencedFields = 4;
  static const int onDelete = 5;
  static const int onUpdate = 6;
  static const int autoCreateIndex = 7;
  static const int enabled = 8;
  static const int comment = 9;
}

abstract final class TableTtlConfigFieldId {
  static const int ttlMs = 1;
  static const int sourceField = 2;
}

abstract final class VectorFieldConfigFieldId {
  static const int dimensions = 1;
  static const int precision = 2;
}

abstract final class VectorIndexConfigFieldId {
  static const int indexType = 1;
  static const int distanceMetric = 2;
  static const int maxDegree = 3;
  static const int efSearch = 4;
  static const int constructionEf = 5;
  static const int pruneAlpha = 6;
  static const int pqSubspaces = 7;
}

abstract final class FieldStorageLayoutFieldId {
  static const int version = 1;
  static const int nextSlotId = 2;
  static const int slots = 3;
}

abstract final class FieldStorageSlotFieldId {
  static const int slotId = 1;
  static const int fieldId = 2;
  static const int fieldName = 3;
  static const int typeIndex = 4;
  static const int deleted = 5;
}

/// Dynamic default-value wire types for FieldSchema.defaultValue.
abstract final class _DynValueType {
  static const int null_ = 0;
  static const int bool_ = 1;
  static const int int_ = 2;
  static const int double_ = 3;
  static const int string_ = 4;
  static const int bytes_ = 5;

  /// Nested Map/List/other via [BinaryMapCodec] (MessagePack), not JSON text.
  static const int packed_ = 6;
}

/// Engine-internal binary codecs for TableSchema / FieldStorageLayout / TableMeta.
///
/// User-facing [TableSchema.fromJson]/[TableSchema.toJson] remain available.
final class TableMetaCodec {
  TableMetaCodec._();

  // -- TableSchema ----------------------------------------------------------

  static Uint8List encodeTableSchema(TableSchema schema) {
    final w = BinaryWriter(initialCapacity: 512);
    _writeTableSchema(w, schema);
    return w.view;
  }

  static TableSchema decodeTableSchema(Uint8List bytes) {
    final r = BinaryReader(bytes);
    return _readTableSchema(r);
  }

  static void _writeTableSchema(BinaryWriter w, TableSchema schema) {
    w.writeFieldTag(TableSchemaFieldId.name, WireType.lengthDelimited);
    w.writeString(schema.name);

    w.writeMessage(TableSchemaFieldId.primaryKeyConfig, (sw) {
      _writePrimaryKeyConfig(sw, schema.primaryKeyConfig);
    });

    for (final f in schema.fields) {
      w.writeMessage(TableSchemaFieldId.fields, (sw) {
        _writeFieldSchema(sw, f);
      });
    }
    for (final i in schema.indexes) {
      w.writeMessage(TableSchemaFieldId.indexes, (sw) {
        _writeIndexSchema(sw, i);
      });
    }
    for (final fk in schema.foreignKeys) {
      w.writeMessage(TableSchemaFieldId.foreignKeys, (sw) {
        _writeForeignKeySchema(sw, fk);
      });
    }

    if (schema.isGlobal) {
      w.writeFieldTag(TableSchemaFieldId.isGlobal, WireType.varint);
      w.writeBool(true);
    }
    if (schema.tableId != null) {
      w.writeFieldTag(TableSchemaFieldId.tableId, WireType.lengthDelimited);
      w.writeString(schema.tableId!);
    }
    if (schema.tableUid.isNotEmpty) {
      w.writeFieldTag(TableSchemaFieldId.tableUid, WireType.lengthDelimited);
      w.writeString(schema.tableUid.value);
    }
    if (schema.schemaVersion != null) {
      w.writeFieldTag(
          TableSchemaFieldId.schemaVersion, WireType.lengthDelimited);
      w.writeString(schema.schemaVersion!);
    }
    if (schema.isSystemTable) {
      w.writeFieldTag(TableSchemaFieldId.isSystemTable, WireType.varint);
      w.writeBool(true);
    }
    if (schema.ttlConfig != null) {
      w.writeMessage(TableSchemaFieldId.ttlConfig, (sw) {
        _writeTtlConfig(sw, schema.ttlConfig!);
      });
    }
    if (schema.autoIndexes != null) {
      for (final i in schema.autoIndexes!) {
        w.writeMessage(TableSchemaFieldId.autoIndexes, (sw) {
          _writeIndexSchema(sw, i);
        });
      }
    }
  }

  static TableSchema _readTableSchema(BinaryReader r) {
    String name = '';
    PrimaryKeyConfig pk = const PrimaryKeyConfig();
    final fields = <FieldSchema>[];
    final indexes = <IndexSchema>[];
    final foreignKeys = <ForeignKeySchema>[];
    bool isGlobal = false;
    String? tableId;
    TableUid tableUid = TableUid.empty;
    String? schemaVersion;
    bool isSystemTable = false;
    TableTtlConfig? ttlConfig;
    List<IndexSchema>? autoIndexes;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case TableSchemaFieldId.name:
          name = r.readString();
          break;
        case TableSchemaFieldId.primaryKeyConfig:
          r.readMessage((sr, _) {
            pk = _readPrimaryKeyConfig(sr);
          });
          break;
        case TableSchemaFieldId.fields:
          r.readMessage((sr, _) {
            fields.add(_readFieldSchema(sr));
          });
          break;
        case TableSchemaFieldId.indexes:
          r.readMessage((sr, _) {
            indexes.add(_readIndexSchema(sr));
          });
          break;
        case TableSchemaFieldId.foreignKeys:
          r.readMessage((sr, _) {
            foreignKeys.add(_readForeignKeySchema(sr));
          });
          break;
        case TableSchemaFieldId.isGlobal:
          isGlobal = r.readBool();
          break;
        case TableSchemaFieldId.tableId:
          tableId = r.readString();
          break;
        case TableSchemaFieldId.tableUid:
          tableUid = TableUid(r.readString());
          break;
        case TableSchemaFieldId.schemaVersion:
          schemaVersion = r.readString();
          break;
        case TableSchemaFieldId.isSystemTable:
          isSystemTable = r.readBool();
          break;
        case TableSchemaFieldId.ttlConfig:
          r.readMessage((sr, _) {
            ttlConfig = _readTtlConfig(sr);
          });
          break;
        case TableSchemaFieldId.autoIndexes:
          autoIndexes ??= <IndexSchema>[];
          r.readMessage((sr, _) {
            autoIndexes!.add(_readIndexSchema(sr));
          });
          break;
        default:
          r.skipField(wireType);
      }
    }

    return TableSchema(
      name: name,
      primaryKeyConfig: pk,
      fields: fields,
      indexes: indexes,
      foreignKeys: foreignKeys,
      isGlobal: isGlobal,
      tableId: tableId,
      ttlConfig: ttlConfig,
    ).copyWith(
      tableUid: tableUid,
      schemaVersion: schemaVersion,
      isSystemTable: isSystemTable,
      autoIndexes: autoIndexes,
    );
  }

  // -- FieldSchema ----------------------------------------------------------

  static void _writeFieldSchema(BinaryWriter w, FieldSchema f) {
    w.writeFieldTag(FieldSchemaFieldId.name, WireType.lengthDelimited);
    w.writeString(f.name);
    w.writeFieldTag(FieldSchemaFieldId.type, WireType.varint);
    w.writeVarint(f.type.index);
    if (!f.nullable) {
      w.writeFieldTag(FieldSchemaFieldId.nullable, WireType.varint);
      w.writeBool(false);
    }
    if (f.defaultValue != null) {
      w.writeMessage(FieldSchemaFieldId.defaultValue, (sw) {
        _writeDynValue(sw, f.defaultValue);
      });
    }
    if (f.unique) {
      w.writeFieldTag(FieldSchemaFieldId.unique, WireType.varint);
      w.writeBool(true);
    }
    if (f.createIndex) {
      w.writeFieldTag(FieldSchemaFieldId.createIndex, WireType.varint);
      w.writeBool(true);
    }
    if (f.maxLength != null) {
      w.writeFieldTag(FieldSchemaFieldId.maxLength, WireType.varint);
      w.writeVarint(f.maxLength!);
    }
    if (f.minLength != null) {
      w.writeFieldTag(FieldSchemaFieldId.minLength, WireType.varint);
      w.writeVarint(f.minLength!);
    }
    if (f.minValue != null) {
      w.writeFieldTag(FieldSchemaFieldId.minValue, WireType.fixed64);
      w.writeDouble(f.minValue!.toDouble());
    }
    if (f.maxValue != null) {
      w.writeFieldTag(FieldSchemaFieldId.maxValue, WireType.fixed64);
      w.writeDouble(f.maxValue!.toDouble());
    }
    if (f.comment != null) {
      w.writeFieldTag(FieldSchemaFieldId.comment, WireType.lengthDelimited);
      w.writeString(f.comment!);
    }
    if (f.fieldId != null) {
      w.writeFieldTag(FieldSchemaFieldId.fieldId, WireType.lengthDelimited);
      w.writeString(f.fieldId!);
    }
    if (f.defaultValueType != DefaultValueType.none) {
      w.writeFieldTag(FieldSchemaFieldId.defaultValueType, WireType.varint);
      w.writeVarint(f.defaultValueType.index);
    }
    if (f.vectorConfig != null) {
      w.writeMessage(FieldSchemaFieldId.vectorConfig, (sw) {
        _writeVectorFieldConfig(sw, f.vectorConfig!);
      });
    }
  }

  static FieldSchema _readFieldSchema(BinaryReader r) {
    String name = '';
    DataType type = DataType.text;
    bool nullable = true;
    dynamic defaultValue;
    bool unique = false;
    bool createIndex = false;
    int? maxLength;
    int? minLength;
    num? minValue;
    num? maxValue;
    String? comment;
    String? fieldId;
    DefaultValueType defaultValueType = DefaultValueType.none;
    VectorFieldConfig? vectorConfig;

    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case FieldSchemaFieldId.name:
          name = r.readString();
          break;
        case FieldSchemaFieldId.type:
          type = DataType
              .values[r.readVarint().clamp(0, DataType.values.length - 1)];
          break;
        case FieldSchemaFieldId.nullable:
          nullable = r.readBool();
          break;
        case FieldSchemaFieldId.defaultValue:
          r.readMessage((sr, _) {
            defaultValue = _readDynValue(sr);
          });
          break;
        case FieldSchemaFieldId.unique:
          unique = r.readBool();
          break;
        case FieldSchemaFieldId.createIndex:
          createIndex = r.readBool();
          break;
        case FieldSchemaFieldId.maxLength:
          maxLength = r.readVarint();
          break;
        case FieldSchemaFieldId.minLength:
          minLength = r.readVarint();
          break;
        case FieldSchemaFieldId.minValue:
          minValue = r.readDouble();
          break;
        case FieldSchemaFieldId.maxValue:
          maxValue = r.readDouble();
          break;
        case FieldSchemaFieldId.comment:
          comment = r.readString();
          break;
        case FieldSchemaFieldId.fieldId:
          fieldId = r.readString();
          break;
        case FieldSchemaFieldId.defaultValueType:
          defaultValueType = DefaultValueType.values[
              r.readVarint().clamp(0, DefaultValueType.values.length - 1)];
          break;
        case FieldSchemaFieldId.vectorConfig:
          r.readMessage((sr, _) {
            vectorConfig = _readVectorFieldConfig(sr);
          });
          break;
        default:
          r.skipField(wireType);
      }
    }

    return FieldSchema(
      name: name,
      type: type,
      nullable: nullable,
      defaultValue: defaultValue,
      unique: unique,
      createIndex: createIndex,
      maxLength: maxLength,
      minLength: minLength,
      minValue: minValue,
      maxValue: maxValue,
      comment: comment,
      fieldId: fieldId,
      defaultValueType: defaultValueType,
      vectorConfig: vectorConfig,
    );
  }

  // -- IndexSchema ----------------------------------------------------------

  static void _writeIndexSchema(BinaryWriter w, IndexSchema i) {
    if (i.indexName != null) {
      w.writeFieldTag(IndexSchemaFieldId.indexName, WireType.lengthDelimited);
      w.writeString(i.indexName!);
    }
    for (final f in i.fields) {
      w.writeFieldTag(IndexSchemaFieldId.fields, WireType.lengthDelimited);
      w.writeString(f);
    }
    if (i.unique) {
      w.writeFieldTag(IndexSchemaFieldId.unique, WireType.varint);
      w.writeBool(true);
    }
    if (i.type != IndexType.btree) {
      w.writeFieldTag(IndexSchemaFieldId.type, WireType.varint);
      w.writeVarint(i.type.index);
    }
    if (i.vectorConfig != null) {
      w.writeMessage(IndexSchemaFieldId.vectorConfig, (sw) {
        _writeVectorIndexConfig(sw, i.vectorConfig!);
      });
    }
    if (i.indexUid.isNotEmpty) {
      w.writeFieldTag(IndexSchemaFieldId.indexUid, WireType.lengthDelimited);
      w.writeString(i.indexUid.value);
    }
  }

  static IndexSchema _readIndexSchema(BinaryReader r) {
    String? indexName;
    final fields = <String>[];
    bool unique = false;
    IndexType type = IndexType.btree;
    VectorIndexConfig? vectorConfig;
    IndexUid indexUid = IndexUid.empty;

    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case IndexSchemaFieldId.indexName:
          indexName = r.readString();
          break;
        case IndexSchemaFieldId.fields:
          fields.add(r.readString());
          break;
        case IndexSchemaFieldId.unique:
          unique = r.readBool();
          break;
        case IndexSchemaFieldId.type:
          type = IndexType
              .values[r.readVarint().clamp(0, IndexType.values.length - 1)];
          break;
        case IndexSchemaFieldId.vectorConfig:
          r.readMessage((sr, _) {
            vectorConfig = _readVectorIndexConfig(sr);
          });
          break;
        case IndexSchemaFieldId.indexUid:
          indexUid = IndexUid(r.readString());
          break;
        default:
          r.skipField(wireType);
      }
    }

    return IndexSchema(
      indexName: indexName,
      fields: fields,
      unique: unique,
      type: type,
      vectorConfig: vectorConfig,
    ).copyWith(indexUid: indexUid);
  }

  // -- PrimaryKeyConfig -----------------------------------------------------

  static void _writePrimaryKeyConfig(BinaryWriter w, PrimaryKeyConfig pk) {
    w.writeFieldTag(PrimaryKeyConfigFieldId.name, WireType.lengthDelimited);
    w.writeString(pk.name);
    w.writeFieldTag(PrimaryKeyConfigFieldId.type, WireType.varint);
    w.writeVarint(pk.type.index);
    if (pk.sequentialConfig != null) {
      w.writeMessage(PrimaryKeyConfigFieldId.sequentialConfig, (sw) {
        final c = pk.sequentialConfig!;
        sw.writeFieldTag(
            SequentialIdConfigFieldId.initialValue, WireType.varint);
        sw.writeVarint(c.initialValue);
        sw.writeFieldTag(SequentialIdConfigFieldId.increment, WireType.varint);
        sw.writeVarint(c.increment);
        if (c.useRandomIncrement) {
          sw.writeFieldTag(
              SequentialIdConfigFieldId.useRandomIncrement, WireType.varint);
          sw.writeBool(true);
        }
      });
    }
    if (pk.isOrdered != null) {
      w.writeFieldTag(PrimaryKeyConfigFieldId.isOrdered, WireType.varint);
      w.writeBool(pk.isOrdered!);
    }
    if (pk.fromFieldId != null) {
      w.writeFieldTag(
          PrimaryKeyConfigFieldId.fromFieldId, WireType.lengthDelimited);
      w.writeString(pk.fromFieldId!);
    }
  }

  static PrimaryKeyConfig _readPrimaryKeyConfig(BinaryReader r) {
    String name = 'id';
    PrimaryKeyType type = PrimaryKeyType.sequential;
    SequentialIdConfig? sequentialConfig;
    bool? isOrdered;
    String? fromFieldId;

    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case PrimaryKeyConfigFieldId.name:
          name = r.readString();
          break;
        case PrimaryKeyConfigFieldId.type:
          type = PrimaryKeyType.values[
              r.readVarint().clamp(0, PrimaryKeyType.values.length - 1)];
          break;
        case PrimaryKeyConfigFieldId.sequentialConfig:
          r.readMessage((sr, _) {
            int initialValue = 1;
            int increment = 1;
            bool useRandomIncrement = false;
            while (!sr.isEOF) {
              final (sfid, swt) = sr.readFieldTag();
              switch (sfid) {
                case SequentialIdConfigFieldId.initialValue:
                  initialValue = sr.readVarint();
                  break;
                case SequentialIdConfigFieldId.increment:
                  increment = sr.readVarint();
                  break;
                case SequentialIdConfigFieldId.useRandomIncrement:
                  useRandomIncrement = sr.readBool();
                  break;
                default:
                  sr.skipField(swt);
              }
            }
            sequentialConfig = SequentialIdConfig(
              initialValue: initialValue,
              increment: increment,
              useRandomIncrement: useRandomIncrement,
            );
          });
          break;
        case PrimaryKeyConfigFieldId.isOrdered:
          isOrdered = r.readBool();
          break;
        case PrimaryKeyConfigFieldId.fromFieldId:
          fromFieldId = r.readString();
          break;
        default:
          r.skipField(wireType);
      }
    }

    return PrimaryKeyConfig(
      name: name,
      type: type,
      sequentialConfig: sequentialConfig,
      isOrdered: isOrdered,
      fromFieldId: fromFieldId,
    );
  }

  // -- ForeignKeySchema -----------------------------------------------------

  static void _writeForeignKeySchema(BinaryWriter w, ForeignKeySchema fk) {
    if (fk.name != null) {
      w.writeFieldTag(ForeignKeySchemaFieldId.name, WireType.lengthDelimited);
      w.writeString(fk.name!);
    }
    for (final f in fk.fields) {
      w.writeFieldTag(ForeignKeySchemaFieldId.fields, WireType.lengthDelimited);
      w.writeString(f);
    }
    w.writeFieldTag(
        ForeignKeySchemaFieldId.referencedTable, WireType.lengthDelimited);
    w.writeString(fk.referencedTable);
    for (final f in fk.referencedFields) {
      w.writeFieldTag(
          ForeignKeySchemaFieldId.referencedFields, WireType.lengthDelimited);
      w.writeString(f);
    }
    w.writeFieldTag(ForeignKeySchemaFieldId.onDelete, WireType.varint);
    w.writeVarint(fk.onDelete.index);
    w.writeFieldTag(ForeignKeySchemaFieldId.onUpdate, WireType.varint);
    w.writeVarint(fk.onUpdate.index);
    if (!fk.autoCreateIndex) {
      w.writeFieldTag(ForeignKeySchemaFieldId.autoCreateIndex, WireType.varint);
      w.writeBool(false);
    }
    if (!fk.enabled) {
      w.writeFieldTag(ForeignKeySchemaFieldId.enabled, WireType.varint);
      w.writeBool(false);
    }
    if (fk.comment != null) {
      w.writeFieldTag(
          ForeignKeySchemaFieldId.comment, WireType.lengthDelimited);
      w.writeString(fk.comment!);
    }
  }

  static ForeignKeySchema _readForeignKeySchema(BinaryReader r) {
    String? name;
    final fields = <String>[];
    String referencedTable = '';
    final referencedFields = <String>[];
    ForeignKeyCascadeAction onDelete = ForeignKeyCascadeAction.restrict;
    ForeignKeyCascadeAction onUpdate = ForeignKeyCascadeAction.restrict;
    bool autoCreateIndex = true;
    bool enabled = true;
    String? comment;

    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case ForeignKeySchemaFieldId.name:
          name = r.readString();
          break;
        case ForeignKeySchemaFieldId.fields:
          fields.add(r.readString());
          break;
        case ForeignKeySchemaFieldId.referencedTable:
          referencedTable = r.readString();
          break;
        case ForeignKeySchemaFieldId.referencedFields:
          referencedFields.add(r.readString());
          break;
        case ForeignKeySchemaFieldId.onDelete:
          onDelete = ForeignKeyCascadeAction.values[r
              .readVarint()
              .clamp(0, ForeignKeyCascadeAction.values.length - 1)];
          break;
        case ForeignKeySchemaFieldId.onUpdate:
          onUpdate = ForeignKeyCascadeAction.values[r
              .readVarint()
              .clamp(0, ForeignKeyCascadeAction.values.length - 1)];
          break;
        case ForeignKeySchemaFieldId.autoCreateIndex:
          autoCreateIndex = r.readBool();
          break;
        case ForeignKeySchemaFieldId.enabled:
          enabled = r.readBool();
          break;
        case ForeignKeySchemaFieldId.comment:
          comment = r.readString();
          break;
        default:
          r.skipField(wireType);
      }
    }

    return ForeignKeySchema(
      name: name,
      fields: fields,
      referencedTable: referencedTable,
      referencedFields: referencedFields,
      onDelete: onDelete,
      onUpdate: onUpdate,
      autoCreateIndex: autoCreateIndex,
      enabled: enabled,
      comment: comment,
    );
  }

  // -- TTL / Vector configs -------------------------------------------------

  static void _writeTtlConfig(BinaryWriter w, TableTtlConfig c) {
    w.writeFieldTag(TableTtlConfigFieldId.ttlMs, WireType.varint);
    w.writeVarint(c.ttlMs);
    if (c.sourceField != null) {
      w.writeFieldTag(
          TableTtlConfigFieldId.sourceField, WireType.lengthDelimited);
      w.writeString(c.sourceField!);
    }
  }

  static TableTtlConfig _readTtlConfig(BinaryReader r) {
    int ttlMs = 0;
    String? sourceField;
    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case TableTtlConfigFieldId.ttlMs:
          ttlMs = r.readVarint();
          break;
        case TableTtlConfigFieldId.sourceField:
          sourceField = r.readString();
          break;
        default:
          r.skipField(wireType);
      }
    }
    return TableTtlConfig(ttlMs: ttlMs, sourceField: sourceField);
  }

  static void _writeVectorFieldConfig(BinaryWriter w, VectorFieldConfig c) {
    w.writeFieldTag(VectorFieldConfigFieldId.dimensions, WireType.varint);
    w.writeVarint(c.dimensions);
    w.writeFieldTag(VectorFieldConfigFieldId.precision, WireType.varint);
    w.writeVarint(c.precision.index);
  }

  static VectorFieldConfig _readVectorFieldConfig(BinaryReader r) {
    int dimensions = 0;
    VectorPrecision precision = VectorPrecision.float64;
    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case VectorFieldConfigFieldId.dimensions:
          dimensions = r.readVarint();
          break;
        case VectorFieldConfigFieldId.precision:
          precision = VectorPrecision.values[
              r.readVarint().clamp(0, VectorPrecision.values.length - 1)];
          break;
        default:
          r.skipField(wireType);
      }
    }
    return VectorFieldConfig(dimensions: dimensions, precision: precision);
  }

  static void _writeVectorIndexConfig(BinaryWriter w, VectorIndexConfig c) {
    w.writeFieldTag(VectorIndexConfigFieldId.indexType, WireType.varint);
    w.writeVarint(c.indexType.index);
    w.writeFieldTag(VectorIndexConfigFieldId.distanceMetric, WireType.varint);
    w.writeVarint(c.distanceMetric.index);
    if (c.maxDegree != null) {
      w.writeFieldTag(VectorIndexConfigFieldId.maxDegree, WireType.varint);
      w.writeVarint(c.maxDegree!);
    }
    if (c.efSearch != null) {
      w.writeFieldTag(VectorIndexConfigFieldId.efSearch, WireType.varint);
      w.writeVarint(c.efSearch!);
    }
    if (c.constructionEf != null) {
      w.writeFieldTag(VectorIndexConfigFieldId.constructionEf, WireType.varint);
      w.writeVarint(c.constructionEf!);
    }
    if (c.pruneAlpha != null) {
      w.writeFieldTag(VectorIndexConfigFieldId.pruneAlpha, WireType.fixed64);
      w.writeDouble(c.pruneAlpha!);
    }
    if (c.pqSubspaces != null) {
      w.writeFieldTag(VectorIndexConfigFieldId.pqSubspaces, WireType.varint);
      w.writeVarint(c.pqSubspaces!);
    }
  }

  static VectorIndexConfig _readVectorIndexConfig(BinaryReader r) {
    VectorIndexType indexType = VectorIndexType.ngh;
    VectorDistanceMetric distanceMetric = VectorDistanceMetric.cosine;
    int? maxDegree;
    int? efSearch;
    int? constructionEf;
    double? pruneAlpha;
    int? pqSubspaces;
    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case VectorIndexConfigFieldId.indexType:
          indexType = VectorIndexType.values[
              r.readVarint().clamp(0, VectorIndexType.values.length - 1)];
          break;
        case VectorIndexConfigFieldId.distanceMetric:
          distanceMetric = VectorDistanceMetric.values[
              r.readVarint().clamp(0, VectorDistanceMetric.values.length - 1)];
          break;
        case VectorIndexConfigFieldId.maxDegree:
          maxDegree = r.readVarint();
          break;
        case VectorIndexConfigFieldId.efSearch:
          efSearch = r.readVarint();
          break;
        case VectorIndexConfigFieldId.constructionEf:
          constructionEf = r.readVarint();
          break;
        case VectorIndexConfigFieldId.pruneAlpha:
          pruneAlpha = r.readDouble();
          break;
        case VectorIndexConfigFieldId.pqSubspaces:
          pqSubspaces = r.readVarint();
          break;
        default:
          r.skipField(wireType);
      }
    }
    return VectorIndexConfig(
      indexType: indexType,
      distanceMetric: distanceMetric,
      maxDegree: maxDegree,
      efSearch: efSearch,
      constructionEf: constructionEf,
      pruneAlpha: pruneAlpha,
      pqSubspaces: pqSubspaces,
    );
  }

  // -- Dynamic default value ------------------------------------------------

  static void _writeDynValue(BinaryWriter w, dynamic value) {
    if (value == null) {
      w.writeFieldTag(1, WireType.varint);
      w.writeVarint(_DynValueType.null_);
      return;
    }
    if (value is bool) {
      w.writeFieldTag(1, WireType.varint);
      w.writeVarint(_DynValueType.bool_);
      w.writeFieldTag(2, WireType.varint);
      w.writeBool(value);
      return;
    }
    if (value is int) {
      w.writeFieldTag(1, WireType.varint);
      w.writeVarint(_DynValueType.int_);
      w.writeFieldTag(2, WireType.varint);
      w.writeZigZag64(value);
      return;
    }
    if (value is double) {
      w.writeFieldTag(1, WireType.varint);
      w.writeVarint(_DynValueType.double_);
      w.writeFieldTag(2, WireType.fixed64);
      w.writeDouble(value);
      return;
    }
    if (value is String) {
      w.writeFieldTag(1, WireType.varint);
      w.writeVarint(_DynValueType.string_);
      w.writeFieldTag(2, WireType.lengthDelimited);
      w.writeString(value);
      return;
    }
    if (value is Uint8List) {
      w.writeFieldTag(1, WireType.varint);
      w.writeVarint(_DynValueType.bytes_);
      w.writeFieldTag(2, WireType.lengthDelimited);
      w.writeBytes(value);
      return;
    }
    // Nested Map/List/other: MessagePack (aligns with SchemaBinaryCodec).
    w.writeFieldTag(1, WireType.varint);
    w.writeVarint(_DynValueType.packed_);
    w.writeFieldTag(2, WireType.lengthDelimited);
    w.writeBytes(BinaryMapCodec.encodeValue(value));
  }

  static dynamic _readDynValue(BinaryReader r) {
    int type = _DynValueType.null_;
    dynamic value;
    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case 1:
          type = r.readVarint();
          break;
        case 2:
          switch (type) {
            case _DynValueType.bool_:
              value = r.readBool();
              break;
            case _DynValueType.int_:
              value = r.readZigZag64();
              break;
            case _DynValueType.double_:
              value = r.readDouble();
              break;
            case _DynValueType.string_:
              value = r.readString();
              break;
            case _DynValueType.bytes_:
              value = r.readBytes();
              break;
            case _DynValueType.packed_:
              value = BinaryMapCodec.decodeValue(r.readBytes());
              break;
            default:
              r.skipField(wireType);
          }
          break;
        default:
          r.skipField(wireType);
      }
    }
    return value;
  }

  // -- FieldStorageLayout ---------------------------------------------------

  static Uint8List encodeFieldStorageLayout(FieldStorageLayout layout) {
    final w = BinaryWriter(initialCapacity: 256);
    w.writeFieldTag(FieldStorageLayoutFieldId.version, WireType.varint);
    w.writeVarint(layout.version);
    w.writeFieldTag(FieldStorageLayoutFieldId.nextSlotId, WireType.varint);
    w.writeVarint(layout.nextSlotId);
    for (final slot in layout.slots) {
      w.writeMessage(FieldStorageLayoutFieldId.slots, (sw) {
        sw.writeFieldTag(FieldStorageSlotFieldId.slotId, WireType.varint);
        sw.writeVarint(slot.slotId);
        if (slot.fieldId != null) {
          sw.writeFieldTag(
              FieldStorageSlotFieldId.fieldId, WireType.lengthDelimited);
          sw.writeString(slot.fieldId!);
        }
        sw.writeFieldTag(
            FieldStorageSlotFieldId.fieldName, WireType.lengthDelimited);
        sw.writeString(slot.fieldName);
        sw.writeFieldTag(FieldStorageSlotFieldId.typeIndex, WireType.varint);
        sw.writeVarint(slot.typeIndex);
        if (slot.deleted) {
          sw.writeFieldTag(FieldStorageSlotFieldId.deleted, WireType.varint);
          sw.writeBool(true);
        }
      });
    }
    return w.view;
  }

  static FieldStorageLayout decodeFieldStorageLayout(Uint8List bytes) {
    final r = BinaryReader(bytes);
    int version = 1;
    int nextSlotId = 0;
    final slots = <FieldStorageSlot>[];
    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case FieldStorageLayoutFieldId.version:
          version = r.readVarint();
          break;
        case FieldStorageLayoutFieldId.nextSlotId:
          nextSlotId = r.readVarint();
          break;
        case FieldStorageLayoutFieldId.slots:
          r.readMessage((sr, _) {
            int slotId = 0;
            String? fieldId;
            String fieldName = '';
            int typeIndex = 0;
            bool deleted = false;
            while (!sr.isEOF) {
              final (sfid, swt) = sr.readFieldTag();
              switch (sfid) {
                case FieldStorageSlotFieldId.slotId:
                  slotId = sr.readVarint();
                  break;
                case FieldStorageSlotFieldId.fieldId:
                  fieldId = sr.readString();
                  break;
                case FieldStorageSlotFieldId.fieldName:
                  fieldName = sr.readString();
                  break;
                case FieldStorageSlotFieldId.typeIndex:
                  typeIndex = sr.readVarint();
                  break;
                case FieldStorageSlotFieldId.deleted:
                  deleted = sr.readBool();
                  break;
                default:
                  sr.skipField(swt);
              }
            }
            slots.add(FieldStorageSlot(
              slotId: slotId,
              fieldId: fieldId,
              fieldName: fieldName,
              typeIndex: typeIndex,
              deleted: deleted,
            ));
          });
          break;
        default:
          r.skipField(wireType);
      }
    }
    if (nextSlotId == 0 && slots.isNotEmpty) {
      int maxId = -1;
      for (final s in slots) {
        if (s.slotId > maxId) maxId = s.slotId;
      }
      nextSlotId = maxId + 1;
    }
    return FieldStorageLayout(
      version: version,
      nextSlotId: nextSlotId,
      slots: slots,
    );
  }

  // -- TableMeta <-> system-table row -----------------------------------------

  /// Encode [TableMeta] as a row map for `_system_table_meta` insert/upsert.
  static Map<String, dynamic> encodeRow(TableMeta meta) {
    final row = <String, dynamic>{
      SystemTable.tableMetaUidField: meta.tableUid.value,
      SystemTable.tableMetaNameField: meta.tableName.value,
      SystemTable.tableMetaIsGlobalField: meta.isGlobal,
      SystemTable.tableMetaSchemaField: encodeTableSchema(meta.schema),
      SystemTable.tableMetaFieldLayoutField:
          encodeFieldStorageLayout(meta.fieldLayout),
      SystemTable.tableMetaDirIndexField: meta.dirIndex,
      SystemTable.tableMetaCreatedAtField: meta.createdAt.toIso8601String(),
      SystemTable.tableMetaUpdatedAtField: meta.updatedAt.toIso8601String(),
    };
    final extraBytes = meta.extra?.toBytesOrNull();
    if (extraBytes != null) {
      row[SystemTable.tableMetaExtraField] = extraBytes;
    }
    return row;
  }

  /// Decode a `_system_table_meta` row into [TableMeta].
  static TableMeta decodeRow(Map<String, dynamic> row) {
    final schemaBytes = _asBytes(row[SystemTable.tableMetaSchemaField]);
    final layoutBytes = _asBytes(row[SystemTable.tableMetaFieldLayoutField]);
    final extraBytes = _asBytesOrNull(row[SystemTable.tableMetaExtraField]);

    return TableMeta(
      tableUid: TableUid(row[SystemTable.tableMetaUidField] as String),
      tableName: TableName(row[SystemTable.tableMetaNameField] as String),
      isGlobal: row[SystemTable.tableMetaIsGlobalField] as bool? ?? false,
      schema: decodeTableSchema(schemaBytes),
      fieldLayout: decodeFieldStorageLayout(layoutBytes),
      dirIndex: (row[SystemTable.tableMetaDirIndexField] as num?)?.toInt() ?? 0,
      extra: TableMetaExtra.fromBytes(extraBytes),
      createdAt: _parseDateTime(row[SystemTable.tableMetaCreatedAtField]),
      updatedAt: _parseDateTime(row[SystemTable.tableMetaUpdatedAtField]),
    );
  }

  static Uint8List _asBytes(dynamic v) {
    if (v is Uint8List) return v;
    if (v is List<int>) return Uint8List.fromList(v);
    if (v is String) return Uint8List.fromList(utf8.encode(v));
    return Uint8List(0);
  }

  static Uint8List? _asBytesOrNull(dynamic v) {
    if (v == null) return null;
    final b = _asBytes(v);
    return b.isEmpty ? null : b;
  }

  static DateTime _parseDateTime(dynamic v) {
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v) ?? DateTime.now();
    return DateTime.now();
  }
}
