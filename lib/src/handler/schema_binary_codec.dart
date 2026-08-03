import 'dart:typed_data';

import '../model/meta_info.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import 'binary_codec.dart';
import 'binary_map_codec.dart';

/// Stable field IDs for [TableSchema] binary encoding. Never reuse IDs.
abstract final class TableSchemaFieldId {
  static const int name = 1;
  static const int primaryKeyConfig = 2;
  static const int fields = 3;
  static const int indexes = 4;
  static const int foreignKeys = 5;
  static const int isGlobal = 6;
  static const int tableId = 7;
  static const int ttlConfig = 8;
  static const int tableUid = 9;
  static const int schemaVersion = 10;
  static const int isSystemTable = 11;
  static const int autoIndexes = 12;
  // Reserved 20–31.
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
  static const int vectorConfig = 13;
  static const int defaultValueType = 14;
  // Reserved 20–31.
}

abstract final class IndexSchemaFieldId {
  static const int indexName = 1;
  static const int fields = 2;
  static const int unique = 3;
  static const int type = 4;
  static const int vectorConfig = 5;
  static const int indexUid = 6;
  // Reserved 20–31.
}

abstract final class PrimaryKeyConfigFieldId {
  static const int name = 1;
  static const int type = 2;
  static const int sequentialConfig = 3;
  static const int isOrdered = 4;
  static const int fromFieldId = 5;
  // Reserved 10–15.
}

abstract final class SequentialIdConfigFieldId {
  static const int initialValue = 1;
  static const int increment = 2;
  static const int useRandomIncrement = 3;
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

/// Field-tag binary codecs for schema domain models (no TOBF frame).
abstract final class SchemaBinaryCodec {
  SchemaBinaryCodec._();

  static T _enumAt<T extends Enum>(List<T> values, int index, T fallback) {
    if (index < 0 || index >= values.length) return fallback;
    return values[index];
  }

  static void writeDynamicValue(BinaryWriter w, int fieldId, dynamic value) {
    w.writeFieldTag(fieldId, WireType.lengthDelimited);
    w.writeBytes(BinaryMapCodec.encodeValue(value));
  }

  static dynamic readDynamicValue(BinaryReader r) {
    return BinaryMapCodec.decodeValue(r.readBytes());
  }

  // ── TableSchema ──────────────────────────────────────────────────────────

  static void writeTableSchema(BinaryWriter w, TableSchema schema) {
    w.writeFieldTag(TableSchemaFieldId.name, WireType.lengthDelimited);
    w.writeString(schema.name);

    w.writeMessage(TableSchemaFieldId.primaryKeyConfig, (sw) {
      writePrimaryKeyConfig(sw, schema.primaryKeyConfig);
    });

    for (final field in schema.fields) {
      w.writeMessage(TableSchemaFieldId.fields, (sw) {
        writeFieldSchema(sw, field);
      });
    }
    for (final index in schema.indexes) {
      w.writeMessage(TableSchemaFieldId.indexes, (sw) {
        writeIndexSchema(sw, index);
      });
    }
    for (final fk in schema.foreignKeys) {
      w.writeMessage(TableSchemaFieldId.foreignKeys, (sw) {
        writeForeignKeySchema(sw, fk);
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
    if (schema.ttlConfig != null) {
      w.writeMessage(TableSchemaFieldId.ttlConfig, (sw) {
        writeTableTtlConfig(sw, schema.ttlConfig!);
      });
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
    if (schema.autoIndexes != null) {
      for (final index in schema.autoIndexes!) {
        w.writeMessage(TableSchemaFieldId.autoIndexes, (sw) {
          writeIndexSchema(sw, index);
        });
      }
    }
  }

  static TableSchema readTableSchema(BinaryReader r) {
    var name = '';
    PrimaryKeyConfig primaryKeyConfig = const PrimaryKeyConfig();
    final fields = <FieldSchema>[];
    final indexes = <IndexSchema>[];
    final foreignKeys = <ForeignKeySchema>[];
    var isGlobal = false;
    String? tableId;
    TableTtlConfig? ttlConfig;
    var tableUid = TableUid.empty;
    String? schemaVersion;
    var isSystemTable = false;
    List<IndexSchema>? autoIndexes;
    var sawAutoIndexes = false;

    while (!r.isEOF) {
      final (fieldId, wireType) = r.readFieldTag();
      switch (fieldId) {
        case TableSchemaFieldId.name:
          name = r.readString();
          break;
        case TableSchemaFieldId.primaryKeyConfig:
          r.readMessage((nr, _) {
            primaryKeyConfig = readPrimaryKeyConfig(nr);
          });
          break;
        case TableSchemaFieldId.fields:
          r.readMessage((nr, _) {
            fields.add(readFieldSchema(nr));
          });
          break;
        case TableSchemaFieldId.indexes:
          r.readMessage((nr, _) {
            indexes.add(readIndexSchema(nr));
          });
          break;
        case TableSchemaFieldId.foreignKeys:
          r.readMessage((nr, _) {
            foreignKeys.add(readForeignKeySchema(nr));
          });
          break;
        case TableSchemaFieldId.isGlobal:
          isGlobal = r.readBool();
          break;
        case TableSchemaFieldId.tableId:
          tableId = r.readString();
          break;
        case TableSchemaFieldId.ttlConfig:
          r.readMessage((nr, _) {
            ttlConfig = readTableTtlConfig(nr);
          });
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
        case TableSchemaFieldId.autoIndexes:
          sawAutoIndexes = true;
          autoIndexes ??= <IndexSchema>[];
          r.readMessage((nr, _) {
            autoIndexes!.add(readIndexSchema(nr));
          });
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    return TableSchema.rehydrate(
      name: name,
      primaryKeyConfig: primaryKeyConfig,
      fields: fields,
      indexes: indexes,
      foreignKeys: foreignKeys,
      isGlobal: isGlobal,
      tableId: tableId,
      ttlConfig: ttlConfig,
      tableUid: tableUid,
      schemaVersion: schemaVersion,
      isSystemTable: isSystemTable,
      autoIndexes: sawAutoIndexes ? (autoIndexes ?? const []) : null,
    );
  }

  static Uint8List encodeTableSchema(TableSchema schema) {
    final w = BinaryWriter(initialCapacity: 512);
    writeTableSchema(w, schema);
    return w.view;
  }

  static TableSchema decodeTableSchema(Uint8List bytes) {
    if (bytes.isEmpty) {
      return TableSchema.rehydrate(
        name: '',
        primaryKeyConfig: const PrimaryKeyConfig(),
        fields: const [],
      );
    }
    return readTableSchema(BinaryReader(bytes));
  }

  // ── FieldSchema ──────────────────────────────────────────────────────────

  static void writeFieldSchema(BinaryWriter w, FieldSchema field) {
    w.writeFieldTag(FieldSchemaFieldId.name, WireType.lengthDelimited);
    w.writeString(field.name);
    w.writeFieldTag(FieldSchemaFieldId.type, WireType.varint);
    w.writeVarint(field.type.index);

    if (!field.nullable) {
      w.writeFieldTag(FieldSchemaFieldId.nullable, WireType.varint);
      w.writeBool(false);
    }
    if (field.defaultValue != null) {
      writeDynamicValue(w, FieldSchemaFieldId.defaultValue, field.defaultValue);
    }
    if (field.unique) {
      w.writeFieldTag(FieldSchemaFieldId.unique, WireType.varint);
      w.writeBool(true);
    }
    if (field.createIndex) {
      w.writeFieldTag(FieldSchemaFieldId.createIndex, WireType.varint);
      w.writeBool(true);
    }
    if (field.maxLength != null) {
      w.writeFieldTag(FieldSchemaFieldId.maxLength, WireType.varint);
      w.writeVarint(field.maxLength!);
    }
    if (field.minLength != null) {
      w.writeFieldTag(FieldSchemaFieldId.minLength, WireType.varint);
      w.writeVarint(field.minLength!);
    }
    if (field.minValue != null) {
      writeDynamicValue(w, FieldSchemaFieldId.minValue, field.minValue);
    }
    if (field.maxValue != null) {
      writeDynamicValue(w, FieldSchemaFieldId.maxValue, field.maxValue);
    }
    if (field.comment != null) {
      w.writeFieldTag(FieldSchemaFieldId.comment, WireType.lengthDelimited);
      w.writeString(field.comment!);
    }
    if (field.fieldId != null) {
      w.writeFieldTag(FieldSchemaFieldId.fieldId, WireType.lengthDelimited);
      w.writeString(field.fieldId!);
    }
    if (field.vectorConfig != null) {
      w.writeMessage(FieldSchemaFieldId.vectorConfig, (sw) {
        writeVectorFieldConfig(sw, field.vectorConfig!);
      });
    }
    if (field.defaultValueType != DefaultValueType.none) {
      w.writeFieldTag(FieldSchemaFieldId.defaultValueType, WireType.varint);
      w.writeVarint(field.defaultValueType.index);
    }
  }

  static FieldSchema readFieldSchema(BinaryReader r) {
    var name = '';
    var type = DataType.text;
    var nullable = true;
    dynamic defaultValue;
    var unique = false;
    var createIndex = false;
    int? maxLength;
    int? minLength;
    num? minValue;
    num? maxValue;
    String? comment;
    String? fieldId;
    VectorFieldConfig? vectorConfig;
    var defaultValueType = DefaultValueType.none;

    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case FieldSchemaFieldId.name:
          name = r.readString();
          break;
        case FieldSchemaFieldId.type:
          type = _enumAt(DataType.values, r.readVarint(), DataType.text);
          break;
        case FieldSchemaFieldId.nullable:
          nullable = r.readBool();
          break;
        case FieldSchemaFieldId.defaultValue:
          defaultValue = readDynamicValue(r);
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
          final v = readDynamicValue(r);
          minValue = v is num ? v : null;
          break;
        case FieldSchemaFieldId.maxValue:
          final v = readDynamicValue(r);
          maxValue = v is num ? v : null;
          break;
        case FieldSchemaFieldId.comment:
          comment = r.readString();
          break;
        case FieldSchemaFieldId.fieldId:
          fieldId = r.readString();
          break;
        case FieldSchemaFieldId.vectorConfig:
          r.readMessage((nr, _) {
            vectorConfig = readVectorFieldConfig(nr);
          });
          break;
        case FieldSchemaFieldId.defaultValueType:
          defaultValueType = _enumAt(
            DefaultValueType.values,
            r.readVarint(),
            DefaultValueType.none,
          );
          break;
        default:
          r.skipField(wireType);
          break;
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
      vectorConfig: vectorConfig,
      defaultValueType: defaultValueType,
    );
  }

  // ── IndexSchema ──────────────────────────────────────────────────────────

  static void writeIndexSchema(BinaryWriter w, IndexSchema index) {
    if (index.indexName != null) {
      w.writeFieldTag(IndexSchemaFieldId.indexName, WireType.lengthDelimited);
      w.writeString(index.indexName!);
    }
    for (final f in index.fields) {
      w.writeFieldTag(IndexSchemaFieldId.fields, WireType.lengthDelimited);
      w.writeString(f);
    }
    if (index.unique) {
      w.writeFieldTag(IndexSchemaFieldId.unique, WireType.varint);
      w.writeBool(true);
    }
    if (index.type != IndexType.btree) {
      w.writeFieldTag(IndexSchemaFieldId.type, WireType.varint);
      w.writeVarint(index.type.index);
    }
    if (index.vectorConfig != null) {
      w.writeMessage(IndexSchemaFieldId.vectorConfig, (sw) {
        writeVectorIndexConfig(sw, index.vectorConfig!);
      });
    }
    if (index.indexUid.isNotEmpty) {
      w.writeFieldTag(IndexSchemaFieldId.indexUid, WireType.lengthDelimited);
      w.writeString(index.indexUid.value);
    }
  }

  static IndexSchema readIndexSchema(BinaryReader r) {
    String? indexName;
    final fields = <String>[];
    var unique = false;
    var type = IndexType.btree;
    VectorIndexConfig? vectorConfig;
    var indexUid = IndexUid.empty;

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
          type = _enumAt(IndexType.values, r.readVarint(), IndexType.btree);
          break;
        case IndexSchemaFieldId.vectorConfig:
          r.readMessage((nr, _) {
            vectorConfig = readVectorIndexConfig(nr);
          });
          break;
        case IndexSchemaFieldId.indexUid:
          indexUid = IndexUid(r.readString());
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }

    return IndexSchema.rehydrate(
      indexName: indexName,
      fields: fields,
      unique: unique,
      type: type,
      vectorConfig: vectorConfig,
      indexUid: indexUid,
    );
  }

  // ── PrimaryKeyConfig ─────────────────────────────────────────────────────

  static void writePrimaryKeyConfig(BinaryWriter w, PrimaryKeyConfig config) {
    w.writeFieldTag(PrimaryKeyConfigFieldId.name, WireType.lengthDelimited);
    w.writeString(config.name);
    w.writeFieldTag(PrimaryKeyConfigFieldId.type, WireType.varint);
    w.writeVarint(config.type.index);
    if (config.sequentialConfig != null) {
      w.writeMessage(PrimaryKeyConfigFieldId.sequentialConfig, (sw) {
        writeSequentialIdConfig(sw, config.sequentialConfig!);
      });
    }
    if (config.isOrdered != null) {
      w.writeFieldTag(PrimaryKeyConfigFieldId.isOrdered, WireType.varint);
      w.writeBool(config.isOrdered!);
    }
    if (config.fromFieldId != null) {
      w.writeFieldTag(
          PrimaryKeyConfigFieldId.fromFieldId, WireType.lengthDelimited);
      w.writeString(config.fromFieldId!);
    }
  }

  static PrimaryKeyConfig readPrimaryKeyConfig(BinaryReader r) {
    var name = 'id';
    var type = PrimaryKeyType.sequential;
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
          type = _enumAt(
            PrimaryKeyType.values,
            r.readVarint(),
            PrimaryKeyType.sequential,
          );
          break;
        case PrimaryKeyConfigFieldId.sequentialConfig:
          r.readMessage((nr, _) {
            sequentialConfig = readSequentialIdConfig(nr);
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
          break;
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

  static void writeSequentialIdConfig(
      BinaryWriter w, SequentialIdConfig config) {
    w.writeFieldTag(SequentialIdConfigFieldId.initialValue, WireType.varint);
    w.writeVarint(config.initialValue);
    w.writeFieldTag(SequentialIdConfigFieldId.increment, WireType.varint);
    w.writeVarint(config.increment);
    if (config.useRandomIncrement) {
      w.writeFieldTag(
          SequentialIdConfigFieldId.useRandomIncrement, WireType.varint);
      w.writeBool(true);
    }
  }

  static SequentialIdConfig readSequentialIdConfig(BinaryReader r) {
    var initialValue = 1;
    var increment = 1;
    var useRandomIncrement = false;
    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case SequentialIdConfigFieldId.initialValue:
          initialValue = r.readVarint();
          break;
        case SequentialIdConfigFieldId.increment:
          increment = r.readVarint();
          break;
        case SequentialIdConfigFieldId.useRandomIncrement:
          useRandomIncrement = r.readBool();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    return SequentialIdConfig(
      initialValue: initialValue,
      increment: increment,
      useRandomIncrement: useRandomIncrement,
    );
  }

  // ── TableTtlConfig ───────────────────────────────────────────────────────

  static void writeTableTtlConfig(BinaryWriter w, TableTtlConfig config) {
    w.writeFieldTag(TableTtlConfigFieldId.ttlMs, WireType.varint);
    w.writeVarint(config.ttlMs);
    if (config.sourceField != null) {
      w.writeFieldTag(
          TableTtlConfigFieldId.sourceField, WireType.lengthDelimited);
      w.writeString(config.sourceField!);
    }
  }

  static TableTtlConfig readTableTtlConfig(BinaryReader r) {
    var ttlMs = 0;
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
          break;
      }
    }
    return TableTtlConfig(ttlMs: ttlMs, sourceField: sourceField);
  }

  // ── Vector configs ───────────────────────────────────────────────────────

  static void writeVectorFieldConfig(BinaryWriter w, VectorFieldConfig config) {
    w.writeFieldTag(VectorFieldConfigFieldId.dimensions, WireType.varint);
    w.writeVarint(config.dimensions);
    if (config.precision != VectorPrecision.float64) {
      w.writeFieldTag(VectorFieldConfigFieldId.precision, WireType.varint);
      w.writeVarint(config.precision.index);
    }
  }

  static VectorFieldConfig readVectorFieldConfig(BinaryReader r) {
    var dimensions = 0;
    var precision = VectorPrecision.float64;
    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case VectorFieldConfigFieldId.dimensions:
          dimensions = r.readVarint();
          break;
        case VectorFieldConfigFieldId.precision:
          precision = _enumAt(
            VectorPrecision.values,
            r.readVarint(),
            VectorPrecision.float64,
          );
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    return VectorFieldConfig(dimensions: dimensions, precision: precision);
  }

  static void writeVectorIndexConfig(BinaryWriter w, VectorIndexConfig config) {
    if (config.indexType != VectorIndexType.ngh) {
      w.writeFieldTag(VectorIndexConfigFieldId.indexType, WireType.varint);
      w.writeVarint(config.indexType.index);
    }
    if (config.distanceMetric != VectorDistanceMetric.cosine) {
      w.writeFieldTag(VectorIndexConfigFieldId.distanceMetric, WireType.varint);
      w.writeVarint(config.distanceMetric.index);
    }
    if (config.maxDegree != null) {
      w.writeFieldTag(VectorIndexConfigFieldId.maxDegree, WireType.varint);
      w.writeVarint(config.maxDegree!);
    }
    if (config.efSearch != null) {
      w.writeFieldTag(VectorIndexConfigFieldId.efSearch, WireType.varint);
      w.writeVarint(config.efSearch!);
    }
    if (config.constructionEf != null) {
      w.writeFieldTag(VectorIndexConfigFieldId.constructionEf, WireType.varint);
      w.writeVarint(config.constructionEf!);
    }
    if (config.pruneAlpha != null) {
      w.writeFieldTag(VectorIndexConfigFieldId.pruneAlpha, WireType.fixed64);
      w.writeDouble(config.pruneAlpha!);
    }
    if (config.pqSubspaces != null) {
      w.writeFieldTag(VectorIndexConfigFieldId.pqSubspaces, WireType.varint);
      w.writeVarint(config.pqSubspaces!);
    }
  }

  static VectorIndexConfig readVectorIndexConfig(BinaryReader r) {
    var indexType = VectorIndexType.ngh;
    var distanceMetric = VectorDistanceMetric.cosine;
    int? maxDegree;
    int? efSearch;
    int? constructionEf;
    double? pruneAlpha;
    int? pqSubspaces;

    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case VectorIndexConfigFieldId.indexType:
          indexType = _enumAt(
            VectorIndexType.values,
            r.readVarint(),
            VectorIndexType.ngh,
          );
          break;
        case VectorIndexConfigFieldId.distanceMetric:
          distanceMetric = _enumAt(
            VectorDistanceMetric.values,
            r.readVarint(),
            VectorDistanceMetric.cosine,
          );
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
          break;
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

  // ── ForeignKeySchema ─────────────────────────────────────────────────────

  static void writeForeignKeySchema(BinaryWriter w, ForeignKeySchema fk) {
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
    if (fk.onDelete != ForeignKeyCascadeAction.restrict) {
      w.writeFieldTag(ForeignKeySchemaFieldId.onDelete, WireType.varint);
      w.writeVarint(fk.onDelete.index);
    }
    if (fk.onUpdate != ForeignKeyCascadeAction.restrict) {
      w.writeFieldTag(ForeignKeySchemaFieldId.onUpdate, WireType.varint);
      w.writeVarint(fk.onUpdate.index);
    }
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

  static ForeignKeySchema readForeignKeySchema(BinaryReader r) {
    String? name;
    final fields = <String>[];
    var referencedTable = '';
    final referencedFields = <String>[];
    var onDelete = ForeignKeyCascadeAction.restrict;
    var onUpdate = ForeignKeyCascadeAction.restrict;
    var autoCreateIndex = true;
    var enabled = true;
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
          onDelete = _enumAt(
            ForeignKeyCascadeAction.values,
            r.readVarint(),
            ForeignKeyCascadeAction.restrict,
          );
          break;
        case ForeignKeySchemaFieldId.onUpdate:
          onUpdate = _enumAt(
            ForeignKeyCascadeAction.values,
            r.readVarint(),
            ForeignKeyCascadeAction.restrict,
          );
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
          break;
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

  // ── FieldStorageLayout ───────────────────────────────────────────────────

  static void writeFieldStorageLayout(
      BinaryWriter w, FieldStorageLayout layout) {
    w.writeFieldTag(FieldStorageLayoutFieldId.version, WireType.varint);
    w.writeVarint(layout.version);
    w.writeFieldTag(FieldStorageLayoutFieldId.nextSlotId, WireType.varint);
    w.writeVarint(layout.nextSlotId);
    for (final slot in layout.slots) {
      w.writeMessage(FieldStorageLayoutFieldId.slots, (sw) {
        writeFieldStorageSlot(sw, slot);
      });
    }
  }

  static FieldStorageLayout readFieldStorageLayout(BinaryReader r) {
    var version = 1;
    var nextSlotId = 0;
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
          r.readMessage((nr, _) {
            slots.add(readFieldStorageSlot(nr));
          });
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    return FieldStorageLayout(
      version: version,
      nextSlotId: nextSlotId,
      slots: slots,
    );
  }

  static void writeFieldStorageSlot(BinaryWriter w, FieldStorageSlot slot) {
    w.writeFieldTag(FieldStorageSlotFieldId.slotId, WireType.varint);
    w.writeVarint(slot.slotId);
    if (slot.fieldId != null) {
      w.writeFieldTag(
          FieldStorageSlotFieldId.fieldId, WireType.lengthDelimited);
      w.writeString(slot.fieldId!);
    }
    w.writeFieldTag(
        FieldStorageSlotFieldId.fieldName, WireType.lengthDelimited);
    w.writeString(slot.fieldName);
    w.writeFieldTag(FieldStorageSlotFieldId.typeIndex, WireType.varint);
    w.writeVarint(slot.typeIndex);
    if (slot.deleted) {
      w.writeFieldTag(FieldStorageSlotFieldId.deleted, WireType.varint);
      w.writeBool(true);
    }
  }

  static FieldStorageSlot readFieldStorageSlot(BinaryReader r) {
    var slotId = 0;
    String? fieldId;
    var fieldName = '';
    var typeIndex = 0;
    var deleted = false;
    while (!r.isEOF) {
      final (fid, wireType) = r.readFieldTag();
      switch (fid) {
        case FieldStorageSlotFieldId.slotId:
          slotId = r.readVarint();
          break;
        case FieldStorageSlotFieldId.fieldId:
          fieldId = r.readString();
          break;
        case FieldStorageSlotFieldId.fieldName:
          fieldName = r.readString();
          break;
        case FieldStorageSlotFieldId.typeIndex:
          typeIndex = r.readVarint();
          break;
        case FieldStorageSlotFieldId.deleted:
          deleted = r.readBool();
          break;
        default:
          r.skipField(wireType);
          break;
      }
    }
    return FieldStorageSlot(
      slotId: slotId,
      fieldId: fieldId,
      fieldName: fieldName,
      typeIndex: typeIndex,
      deleted: deleted,
    );
  }
}
