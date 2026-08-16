# ToStore ResultStatus Automated Diagnosis & Status Resolution Specification

To enable automated operations (Ops), AI agents, automated test scripts, and client applications to accurately identify various database execution results and exception states, ToStore introduces a structured `ResultStatus` system in its latest version.

This specification document details the design principles of status codes, semantic identifier key specifications, and the dedicated field structures of various status types to help database users and developers independently implement status resolution.

---

## 1. Core Design Principles

### 1.1 Status Code (code) Numeric Specification

All numeric status codes (`code`) are defined using a fixed length of 5 digits (except for the success state):

- **Success State (Special Success Code)**: Specially fixed to `0`.
- **Other States (Error & Diagnostic Codes)**: Unified as 5 digits.
- **Class Code**: The first two digits of the status code, used to quickly identify the major category.
- **Leaf Code**: The last three digits of the status code, representing the specific error scenario.

> [!TIP]
> When developing automated ops, AI agents, or external test scripts, developers can route to corresponding exception handlers using the first two digits (Class Code) or the range, and then perform fine-grained handling based on the Leaf Code.

> [!IMPORTANT]
> **In-Memory Check Best Practice**:
> When reading database operation results in memory (e.g., in client or Dart/Flutter code), **the most recommended and efficient method is to directly use the built-in read-only properties** of `ResultStatus` or `ResultType` (such as `isBusinessError`, `isCriticalError`, etc., see [Section 3.2](#32-in-memory-helper-getters)), avoiding manual parsing of numeric ranges or string prefix matching.

### 1.2 Semantic State Identifier (codeKey) Specification

Each status corresponds to a unique string identifier `codeKey`:

- **Naming Format**: `[Major Category Prefix]_[Multi-level Detail Identifier]`.
- **Naming Rule**: Composed of uppercase English letters and underscores `_`, containing no spaces or special characters.
- **Major Category Prefix**: Indicates which core business category the state belongs to. If multiple category levels exist, the most generic prefix is placed at the front to facilitate prefix search and range filtering.

---

## 2. Class Code Quick Reference Table

Below is the mapping definition of all Class Codes in ToStore:

| Code Range | Class Code (First 2 Digits) | Semantic Prefix | Category | Exception Strategy |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `00` | `SUCCESS` | **Operation Successful** | Does not throw exception, returns normally. |
| `10000 - 19999` | `10 - 19` | `BIZ_` | **Business Error** (End-user input errors, e.g. constraint violations) | Does not throw exception, always responded via `DbResult` or `QueryResult`. |
| `20000 - 49999` | `20 - 49` | `DEV_` | **Developer Error** (Invalid API parameters, invalid table schema configuration, etc.) | **Throws `DbException` directly in debug environments** to warn developers; **returns normally as results in production environments**. *(Note: Engine version incompatibility and major migration batch execution failures are critical errors, which throw exceptions even in production)* |
| `50000 - 79999` | `50 - 79` | `SYS_` | **System Error** (Disk space full, IO exceptions, lock acquisition timeout, etc.) | Throws exception when normal execution is blocked; others (e.g. transaction conflict) are responded as results. |
| `99000 - 99999` | `99` | `ENG_` | **Engine Error** (Engine logic error, data file corruption, unknown internal error) | Generally does not throw exceptions; throws exceptions for severe cases. |

---

## 3. ResultStatus Common Field Structure and In-Memory Helpers

### 3.1 Common Fields (Serialized JSON Structure)

All types of `ResultStatus`, when serialized to JSON, contain the following 4 basic common fields. Users can read these fields directly for preliminary checks.

| Field | Type | Description |
| :--- | :--- | :--- |
| `index` | `int` | Sequence index in batch operations. For single operations, this is fixed to `0`. |
| `code` | `int` | Numeric status code (`0` for success, 5-digit number for exception). |
| `codeKey` | `String` | Semantic state identifier key, e.g., `BIZ_CONSTRAINT_UNIQUE`. |
| `message` | `String` | Human-readable status detail description. |

### 3.2 In-Memory Helper Getters

In Dart/Flutter, `ResultStatus` and `ResultType` encapsulate highly efficient `O(1)` read-only properties (Getters) for checking category and severity in memory without manual range checks or string matching:

| Property | Type | Description |
| :--- | :--- | :--- |
| `isBusinessError` | `bool` | Whether this is a **Business Error** (e.g. constraint conflict, cast failure; range `10000 - 19999`). |
| `isConstraintError` | `bool` | Whether this maps to **ConstraintStatus** (same numeric range as `isBusinessError`: `10000 - 19999`). |
| `isDeveloperError` | `bool` | Whether this is a **Developer Error** (e.g. invalid Schema, parameter mismatch, table not found; range `20000 - 49999`). |
| `isSystemError` | `bool` | Whether this is a **System Error** (e.g. lock timeout, disk full, file lock; range `50000 - 79999`). |
| `isEngineError` | `bool` | Whether this is an **Engine Error** (range `99000 - 99999`). |
| `isCriticalError` | `bool` | Whether this is a **Critical Error / Disaster-level Event** (requires manual or operations intervention, e.g. disk full, out of memory, severe data file corruption, incompatible migration failure, etc.). |

---

## 4. Detailed Resolution Structures and Dedicated Fields

Depending on the `code` / `codeKey` range and the specific subclass of `ResultStatus`, the serialized JSON structure will carry different **dedicated diagnostic fields**. Below are the field specifications and application mapping for the 5 status subclasses.

### 4.1 SuccessStatus (Operation Successful)

- **Category Range**: `code == 0`, `codeKey == "SUCCESS"`
- **Applicable Scenario**: Records inserted, modified, or deleted successfully.
- **Dedicated Field Definition**:

  | Field | Type | Details |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Optional**. Returned only on single-row writes (e.g., `insert`) or updates (e.g., `update`) representing the physically generated or modified record primary key. |

- **JSON Example**:
  ```json
  {
    "index": 0,
    "code": 0,
    "codeKey": "SUCCESS",
    "message": "Operation successful",
    "primaryKey": "usr_9a8f4c2b"
  }
  ```

---

### 4.2 ConstraintStatus (Data Integrity & Constraint Conflicts)

- **Category Range**: `code` inside `[10000, 19999]` (all Business Error leaf codes: validation, integrity constraints, and record not-found). Matches `ResultType.isConstraintError`.
- **Dedicated Field Definition**:

  | Field | Type | Details |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Required**. Table name where the integrity constraint conflict or not-found error occurred. |
  | `constraintName` | `String?` | **Optional**. The name of the specific constraint that caused the error (e.g., `fk_users_profile` for foreign key, index name for unique conflict, or `null` for non-null/cast errors). |
  | `fields` | `List<String>` | **Required**. List of fields causing the conflict. |
  | `conflictingKeys` | `List<dynamic>` | **Required**. List of input values causing the conflict, mapping 1:1 to `fields`. If a field is null, the corresponding item in the list is `null`. |
  | `primaryKey` | `String?` | **Optional**. Associated record primary key. If not a single-row write, or blocked at memory stage, this will be `null`. |
  | `referencedTable` | `String?` | **Optional**. Parent table name in foreign key conflicts. |

- **Leaf Code Guidelines**:

  | Code & ResultType | Scenario | Field Guidelines |
  | :--- | :--- | :--- |
  | `10000`<br>`bizValidationFailed` | Data format or range validation failed | <ul><li>`tableName`: Affected table</li><li>`constraintName`: `null`</li><li>`fields`: Fields violating validation, e.g. `["email"]`</li><li>`conflictingKeys`: Invalid values causing failure, e.g. `["invalid-email"]`</li><li>`primaryKey`: Record primary key (if any)</li></ul> |
  | `10001`<br>`bizNotNullViolation` | Not null constraint violation | <ul><li>`tableName`: Affected table</li><li>`constraintName`: `null`</li><li>`fields`: Fields violating not-null restriction, e.g. `["email"]`</li><li>`conflictingKeys`: Always `[null]`</li><li>`primaryKey`: Record primary key (if any)</li></ul> |
  | `10002`<br>`bizTypeCastFailed` | Data type conversion or cast failed | <ul><li>`tableName`: Affected table</li><li>`constraintName`: `null`</li><li>`fields`: Fields failing cast, e.g. `["age"]`</li><li>`conflictingKeys`: Invalid values causing failure, e.g. `["not_a_number"]`</li><li>`primaryKey`: Record primary key (if any)</li></ul> |
  | `11001`<br>`bizPrimaryKeyViolation` | Primary key conflict (already exists) | <ul><li>`tableName`: Affected table</li><li>`constraintName`: `"PRIMARY"` or constraint name</li><li>`fields`: Primary key fields, e.g. `["id"]`</li><li>`conflictingKeys`: Duplicate values, e.g. `["usr_101"]`</li><li>`primaryKey`: Conflicting value, e.g. `"usr_101"`</li></ul> |
  | `11002`<br>`bizUniqueViolation` | Unique constraint violation | <ul><li>`tableName`: Affected table</li><li>`constraintName`: Unique index name, e.g. `"uk_email"`</li><li>`fields`: Fields making up uniqueness, e.g. `["email"]`</li><li>`conflictingKeys`: Values causing conflict, e.g. `["test@a.com"]`</li><li>`primaryKey`: Conflicting record primary key (if any)</li></ul> |
  | `11003`<br>`bizForeignKeyViolation` | Foreign key constraint violation (Generic) | <ul><li>`tableName`: Child table</li><li>`constraintName`: Foreign key constraint name</li><li>`fields`: Foreign key columns</li><li>`conflictingKeys`: Input values causing conflict</li><li>`primaryKey`: Record primary key (if any)</li><li>`referencedTable`: Parent table</li></ul> |
  | `11004`<br>`bizCheckViolation` | Check constraint violation | <ul><li>`tableName`: Affected table</li><li>`constraintName`: Check constraint name</li><li>`fields`: Fields checked</li><li>`conflictingKeys`: Values violating check</li><li>`primaryKey`: Record primary key (if any)</li></ul> |
  | `11005`<br>`bizForeignKeyParentNotExist` | Referenced parent key does not exist | <ul><li>`tableName`: Child table</li><li>`constraintName`: Foreign key constraint name</li><li>`fields`: Foreign key columns, e.g. `["userId"]`</li><li>`conflictingKeys`: Non-existent reference value, e.g. `["non_parent"]`</li><li>`primaryKey`: Record primary key (if any)</li><li>`referencedTable`: Parent table</li></ul> |
  | `11006`<br>`bizForeignKeyChildRestrict` | Delete/update restricted by child records | <ul><li>`tableName`: Parent table</li><li>`constraintName`: Foreign key constraint name</li><li>`fields`: Parent referenced columns</li><li>`conflictingKeys`: Parent key values referenced by child table</li><li>`primaryKey`: Parent key values</li><li>`referencedTable`: Child table</li></ul> |
  | `11007`<br>`bizForeignKeyCompositeMismatch` | Incomplete composite foreign key values | <ul><li>`tableName`: Child table</li><li>`constraintName`: Foreign key constraint name</li><li>`fields`: Composite foreign key columns</li><li>`conflictingKeys`: Input values (contains partial nulls)</li><li>`primaryKey`: Record primary key (if any)</li><li>`referencedTable`: Parent table</li></ul> |
  | `11008`<br>`bizForeignKeyTypeMismatch` | Foreign key type mismatch | <ul><li>`tableName`: Child table</li><li>`constraintName`: Foreign key constraint name</li><li>`fields`: Foreign key columns</li><li>`conflictingKeys`: Values failing cast</li><li>`primaryKey`: Record primary key (if any)</li><li>`referencedTable`: Parent table</li></ul> |
  | `11009`<br>`bizValueExceedsMaxLength` | Value length exceeds maximum constraint | <ul><li>`tableName`: Affected table</li><li>`constraintName`: `null`</li><li>`fields`: Fields violating limit, e.g. `["name"]`</li><li>`conflictingKeys`: Transgressing values, e.g. `["a" * 1000]`</li><li>`primaryKey`: Record primary key (if any)</li></ul> |
  | `11010`<br>`bizValueLessThanMinLength` | Value length is less than minimum constraint | <ul><li>`tableName`: Affected table</li><li>`constraintName`: `null`</li><li>`fields`: Fields violating limit, e.g. `["code"]`</li><li>`conflictingKeys`: Values shorter than minimum, e.g. `["ab"]`</li><li>`primaryKey`: Record primary key (if any)</li></ul> |
  | `11011`<br>`bizValueLessThanMinValue` | Numeric value is less than minimum constraint | <ul><li>`tableName`: Affected table</li><li>`constraintName`: `null`</li><li>`fields`: Fields violating limit, e.g. `["age"]`</li><li>`conflictingKeys`: Values less than minimum, e.g. `[-5]`</li><li>`primaryKey`: Record primary key (if any)</li></ul> |
  | `11012`<br>`bizValueExceedsMaxValue` | Numeric value exceeds maximum constraint | <ul><li>`tableName`: Affected table</li><li>`constraintName`: `null`</li><li>`fields`: Fields violating limit, e.g. `["score"]`</li><li>`conflictingKeys`: Values exceeding maximum, e.g. `[105]`</li><li>`primaryKey`: Record primary key (if any)</li></ul> |
  | `12001`<br>`bizRecordNotFound` | Resource does not exist / Record not found | <ul><li>`tableName`: Affected table</li><li>`constraintName`: `null`</li><li>`fields`: Search target fields, e.g. `["id"]`</li><li>`conflictingKeys`: Target keys not found, e.g. `["non_exist_id"]`</li><li>`primaryKey`: Value of missing key, e.g. `"non_exist_id"`</li></ul> |

- **JSON Example** (Foreign key parent record does not exist):
  ```json
  {
    "index": 0,
    "code": 11005,
    "codeKey": "BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST",
    "message": "Foreign key constraint violation on table \"profiles\" (Constraint: \"fk_profiles_userId\"): Referenced record does not exist in table \"users\" for fields (userId) referencing (id). Conflicting values: [usr_999]",
    "tableName": "profiles",
    "constraintName": "fk_profiles_userId",
    "fields": ["userId"],
    "conflictingKeys": ["usr_999"],
    "primaryKey": "prof_112233",
    "referencedTable": "users"
  }
  ```

---

### 4.3 SchemaValidationStatus (Table Schema Validation & Incompatible Migration)

- **Category Range**: `code` inside `[30000, 39999]` — `30000–30013` static schema validation, `31001–31006` migration guards.
- **Dedicated Field Definition**:

  | Field | Type | Details |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Required**. Table name being validated or physically migrated. |
  | `field` | `String?` | **Optional**. The specific field name triggering the schema or migration error. |
  | `wrongValue` | `dynamic` | **Optional**. Invalid configuration value or migration diff config causing the conflict. |

- **Leaf Code Guidelines**:

  | Code & ResultType | Scenario | Field Guidelines |
  | :--- | :--- | :--- |
  | `30000`<br>`devInvalidSchema` | Invalid table schema definition | <ul><li>`tableName`: Table name</li><li>`field`: `null`</li><li>`wrongValue`: Invalid configuration map, or `null`</li></ul> |
  | `30001`<br>`devInvalidSchemaTableName` | Table name validation failed (illegal characters or too long) | <ul><li>`tableName`: Transgressing name</li><li>`field`: `null`</li><li>`wrongValue`: Transgressing string</li></ul> |
  | `30002`<br>`devInvalidSchemaFieldName` | Field name validation failed (illegal characters) | <ul><li>`tableName`: Table name</li><li>`field`: Transgressing field name</li><li>`wrongValue`: Transgressing string</li></ul> |
  | `30003`<br>`devInvalidSchemaDuplicateFieldName` | Duplicate field name in table schema | <ul><li>`tableName`: Table name</li><li>`field`: Duplicate field name</li><li>`wrongValue`: `null`</li></ul> |
  | `30004`<br>`devInvalidSchemaPrimaryKey` | Primary key validation failed (missing or invalid format) | <ul><li>`tableName`: Table name</li><li>`field`: `"primaryKey"` or primary key field name</li><li>`wrongValue`: Primary key config details</li></ul> |
  | `30005`<br>`devInvalidSchemaIndexLimit` | Table index count exceeds the system limit of 16 | <ul><li>`tableName`: Table name</li><li>`field`: `null`</li><li>`wrongValue`: Index configurations list</li></ul> |
  | `30006`<br>`devInvalidSchemaIndexField` | Index references non-existent field | <ul><li>`tableName`: Table name</li><li>`field`: Index name</li><li>`wrongValue`: Field name causing mismatch</li></ul> |
  | `30007`<br>`devInvalidSchemaIndexType` | Index type incompatible with field data type or configuration | <ul><li>`tableName`: Table name</li><li>`field`: Index/field name</li><li>`wrongValue`: Conflicting type info, e.g. `{ "indexType": "btree", "fieldType": "vector" }`</li></ul> |
  | `30008`<br>`devInvalidSchemaForeignKey` | Foreign key definition invalid (e.g. mismatch columns) | <ul><li>`tableName`: Table name</li><li>`field`: Foreign key name</li><li>`wrongValue`: Foreign key config details</li></ul> |
  | `30009`<br>`devInvalidSchemaSpaceMismatch` | Global/Space-specific boundary mismatch | <ul><li>`tableName`: Table name</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30010`<br>`devInvalidSchemaTtlConfig` | TTL configuration validation failed | <ul><li>`tableName`: Table name</li><li>`field`: TTL timestamp field</li><li>`wrongValue`: Invalid TTL config map, e.g., `{ "enabled": true, "fieldName": "expire_at" }`</li></ul> |
  | `30011`<br>`devSchemaTableExists` | Table already exists | <ul><li>`tableName`: Table name</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30012`<br>`devSchemaFieldExists` | Schema upgrade: adding a field that already exists | <ul><li>`tableName`: Table name</li><li>`field`: Conflicting field name</li><li>`wrongValue`: `null`</li></ul> |
  | `30013`<br>`devSchemaIndexExists` | Schema upgrade: adding an index that already exists | <ul><li>`tableName`: Table name</li><li>`field`: Index name</li><li>`wrongValue`: `null`</li></ul> |
  | `31001`<br>`devMigrationNotAllowedWithData` | Migration requires data modification and was not explicitly allowed | <ul><li>`tableName`: Table name</li><li>`field`: `null`</li><li>`wrongValue`: Migration upgrade diffs map</li></ul> |
  | `31002`<br>`devMigrationUnsafeTypeConversion` | Physical migration: unsupported type conversion for field | <ul><li>`tableName`: Table name</li><li>`field`: Field name</li><li>`wrongValue`: Conflicting types map, e.g. `{ "from": "text", "to": "integer" }`</li></ul> |
  | `31003`<br>`devMigrationCannotAddNonNullField` | Cannot add non-nullable field without a default value to non-empty table | <ul><li>`tableName`: Table name</li><li>`field`: Transgressing field name</li><li>`wrongValue`: Migration parameters, e.g. `{ "nullable": false, "defaultValue": null }`</li></ul> |
  | `31004`<br>`devMigrationNullableToNonNullNotAllowed` | Physical migration: changing field from nullable to non-nullable | <ul><li>`tableName`: Table name</li><li>`field`: Field name</li><li>`wrongValue`: Migration parameters, same as 31003</li></ul> |
  | `31005`<br>`devMigrationUniqueTighteningNotAllowed` | Physical migration: tightening field constraint to UNIQUE | <ul><li>`tableName`: Table name</li><li>`field`: Field name</li><li>`wrongValue`: Index definition causing unique constraint</li></ul> |
  | `31006`<br>`devMigrationPromoteLargeOpNotAllowed` | Large-scale ops blocked while promoteFieldToPrimaryKey is running | <ul><li>`tableName`: Table name</li><li>`field`: `null`</li><li>`wrongValue`: Promote phase / task id (if any)</li></ul> |

- **JSON Example** (Adding a non-nullable field without default value to a non-empty table):
  ```json
  {
    "index": 0,
    "code": 31003,
    "codeKey": "DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD",
    "message": "Cannot add non-nullable field \"phone\" without a default value to non-empty table \"users\". This operation is physically impossible and would fail during data write.",
    "tableName": "users",
    "field": "phone",
    "wrongValue": {
      "nullable": false,
      "defaultValue": null
    }
  }
  ```

---

### 4.4 InvalidArgumentStatus (API Arguments & Cursor Pagination Validation)

- **Category Range**: `code` inside `[20000, 20999]` **excluding** `20005` / `20006`, **plus** `22004` (`devFieldNotFound`). Codes `20005` / `20006` and other `2200x` not-found codes use GeneralStatus (§4.6).
- **Dedicated Field Definition**:

  | Field | Type | Details |
  | :--- | :--- | :--- |
  | `parameterName` | `String` | **Required**. Argument name triggering the validation failure (e.g. `"cursor"`, `"orderBy"`, or specific column key). |
  | `passedValue` | `dynamic` | **Optional**. Non-compliant input value passed by the caller. Complex objects are converted to strings. |
  | `primaryKey` | `String?` | **Optional**. Associated record primary key. |

- **Leaf Code Guidelines**:

  | Code & ResultType | Scenario | Field Guidelines |
  | :--- | :--- | :--- |
  | `20001`<br>`devInvalidArgumentFormat` | Argument format error | <ul><li>`parameterName`: Invalid argument name</li><li>`passedValue`: Value passed, e.g. `"twenty"`</li><li>`primaryKey`: Record primary key (if any)</li></ul> |
  | `20002`<br>`devInvalidArgumentType` | Argument type mismatch | <ul><li>`parameterName`: Parameter name</li><li>`passedValue`: Value passed, e.g. `{"foo": "bar"}` (when String expected)</li><li>`primaryKey`: Record primary key (if any)</li></ul> |
  | `20003`<br>`devInvalidArgumentMissing` | Required argument is missing | <ul><li>`parameterName`: Missing parameter name, e.g. `"dbPath"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: Record primary key (if any)</li></ul> |
  | `20004`<br>`devInvalidPrimaryKeyFormat` | Invalid primary key format | <ul><li>`parameterName`: `"primaryKey"` or primary key field</li><li>`passedValue`: Invalid primary key value, e.g., `"invalid_id_value"`</li><li>`primaryKey`: Invalid primary key value</li></ul> |
  | `20007`<br>`devVectorDimensionMismatch` | Vector dimensions mismatch | <ul><li>`parameterName`: `"other"`</li><li>`passedValue`: Transgressing dimension size</li><li>`primaryKey`: `null`</li></ul> |
  | `20008`<br>`devIndexFieldMissing` | Required index field is missing in record for cursor | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Missing index field</li><li>`primaryKey`: `null`</li></ul> |
  | `20101`<br>`devInvalidCursorPagination` | Cursor pagination and offset are mutually exclusive | <ul><li>`parameterName`: `"cursor"` / `"offset"`</li><li>`passedValue`: Conflicting pagination parameters</li><li>`primaryKey`: `null`</li></ul> |
  | `20102`<br>`devInvalidCursorTable` | Cursor does not match target table | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Cursor token</li><li>`primaryKey`: `null`</li></ul> |
  | `20103`<br>`devInvalidCursorSignature` | Mismatched cursor signature (tampered) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Cursor token</li><li>`primaryKey`: `null`</li></ul> |
  | `20104`<br>`devInvalidCursorOrderBy` | Cursor orderBy configuration invalid or mismatched | <ul><li>`parameterName`: `"orderBy"`</li><li>`passedValue`: OrderBy list, e.g. `["-age", "id"]`</li><li>`primaryKey`: `null`</li></ul> |
  | `20105`<br>`devInvalidCursorMode` | Cursor token mode mismatch | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Token mode, e.g., `"sortKey"`</li><li>`primaryKey`: `null`</li></ul> |
  | `20106`<br>`devInvalidCursorPayload` | Invalid cursor payload (undecodable) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: `null`</li></ul> |
  | `20201`<br>`devInvalidQuerySelectField` | Query select field must be String or QueryAggregation | <ul><li>`parameterName`: `"select"`</li><li>`passedValue`: Invalid select field definition</li><li>`primaryKey`: `null`</li></ul> |
  | `20202`<br>`devInvalidQueryForeignKeyJoin` | No foreign key relationship for auto join | <ul><li>`parameterName`: `"join"` / `"tableName"`</li><li>`passedValue`: Target table lacking relation</li><li>`primaryKey`: `null`</li></ul> |
  | `20203`<br>`devInvalidQueryFieldAlias` | Query field alias format invalid | <ul><li>`parameterName`: `"alias"`</li><li>`passedValue`: Invalid alias string</li><li>`primaryKey`: `null`</li></ul> |
  | `20204`<br>`devInvalidExpression` | Invalid expression configuration or execution | <ul><li>`parameterName`: Error aspect (e.g. `"arguments"`, `"functionName"`, `"node"`)</li><li>`passedValue`: Invalid value or count</li><li>`primaryKey`: `null`</li></ul> |
  | `22004`<br>`devFieldNotFound` | Field not found | <ul><li>`parameterName`: Unknown field name, e.g. `"extra"`</li><li>`passedValue`: Input value passed for field</li><li>`primaryKey`: Record primary key (if any)</li></ul> |

- **JSON Example** (Cursor order fields mismatch query order fields):
  ```json
  {
    "index": 0,
    "code": 20104,
    "codeKey": "DEV_INVALID_CURSOR_ORDERBY",
    "message": "Cursor orderBy fields do not match current query orderBy.",
    "parameterName": "orderBy",
    "passedValue": ["age DESC", "id ASC"],
    "primaryKey": null
  }
  ```

---

### 4.5 TransactionOperationStatus (Transaction Conflict & Abort)

- **Category Range**: only `50001` (`sysTransactionAborted`) and `50002` (`sysTransactionConflict`). Other `500xx` codes (e.g. `50003` / `50004`) use GeneralStatus (§4.6).
- **Dedicated Field Definition**:

  | Field | Type | Details |
  | :--- | :--- | :--- |
  | `txId` | `String` | **Required**. Globally unique transaction stream identifier ID. Used to trace txn lifecycle. |

- **Leaf Code Guidelines**:

  | Code & ResultType | Scenario | Field Guidelines |
  | :--- | :--- | :--- |
  | `50001`<br>`sysTransactionAborted` | Transaction aborted (explicit rollback or cascade fail) | <ul><li>`txId`: Active transaction ID</li></ul> |
  | `50002`<br>`sysTransactionConflict` | Transaction conflict (concurrent updates to same key in SSI/WAL) | <ul><li>`txId`: Conflicting transaction ID</li></ul> |

- **JSON Example** (SSI Concurrent Write-Write conflict):
  ```json
  {
    "index": 0,
    "code": 50002,
    "codeKey": "SYS_TRANSACTION_CONFLICT",
    "message": "Transaction conflict, concurrent updates detected on entity version mismatch (record: usr_123456)",
    "txId": "tx_88ff3b2a99c1"
  }
  ```

---

### 4.6 GeneralStatus (Generic & System-level Exceptions)

- **Category Range**: Fallback for codes not covered by §§4.1–4.5 — including `20005` / `20006`, `22001`–`22003`, `230xx` / `240xx`, remaining `50xxx`–`53xxx`, and `99001`.
- **Dedicated Field Definition**:

  | Field | Type | Details |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Optional**. Associated record primary key. |
  | `target` | `String?` | **Optional**. Target physical resource, e.g. physical file paths, locks, or URLs. |
  | `operation` | `String?` | **Optional**. Active system call name, e.g., `'readAsString'`, `'delete'`, `'acquire'`. |

- **Leaf Code Guidelines**:

  | Code & ResultType | Scenario / Level | Field Guidelines |
  | :--- | :--- | :--- |
  | `20005`<br>`devIndexOutOfBounds` | Index or range is out of bounds (Developer Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `20006`<br>`devUnsupportedOperation` | Operation is not supported in the current context (Developer Error) | <ul><li>`primaryKey`: `null`</li><li>`target`: Target table/resource (if any)</li><li>`operation`: Method name (if any)</li></ul> |
  | `22001`<br>`devTableNotFound` | Table not found (Developer Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22002`<br>`devIndexNotFound` | Index not found (Developer Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22003`<br>`devSpaceNotFound` | Space not found (Developer Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23001`<br>`devLargeScaleOperationRequired` | Large-scale data operation requires `allowLargeScaleOperation()` (Developer Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23002`<br>`devLargeScaleOperationNotAllowedInTransaction` | Large-scale data operation is not allowed inside a transaction (Developer Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `24001`<br>`devEngineIncompatible` | **Critical**: Engine version incompatible | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50003`<br>`sysTransactionLimitExceeded` | Transaction buffered data exceeds the safe limit under memory pressure (System Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50004`<br>`sysMigrationBatchExecutionFailed` | Batch migration execution failed (System Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51001`<br>`sysTimeoutLockAcquisition` | Lock acquisition timeout (System Error) | <ul><li>`primaryKey`: Target key (if any)</li><li>`target`: Lock resource ID</li><li>`operation`: `"acquire"`</li></ul> |
  | `51002`<br>`sysTimeout` | Operation timeout (System Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51003`<br>`sysDbClosed` | Database is closed, operation safely cancelled (System Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52001`<br>`sysResourceExhaustedMemory` | Memory resource exhausted (System Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52002`<br>`sysResourceExhausted` | System resources exhausted, e.g. disk full (System Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `53001`<br>`sysIoNotFound` | Physical file or path does not exist (System Error) | <ul><li>`primaryKey`: `null`</li><li>`target`: File or folder path</li><li>`operation`: I/O operation</li></ul> |
  | `53002`<br>`sysIoPermissionDenied` | Permission denied for file access (System Error) | <ul><li>`primaryKey`: `null`</li><li>`target`: File path</li><li>`operation`: I/O operation</li></ul> |
  | `53003`<br>`sysIoDiskFull` | Disk full or storage quota exceeded (System Error) | <ul><li>`primaryKey`: `null`</li><li>`target`: File path</li><li>`operation`: I/O operation</li></ul> |
  | `53004`<br>`sysIoFileLocked` | File is locked or in use by another process (System Error) | <ul><li>`primaryKey`: `null`</li><li>`target`: File path</li><li>`operation`: I/O operation</li></ul> |
  | `53005`<br>`sysIoDeviceFault` | Storage device or media fault (System Error) | <ul><li>`primaryKey`: `null`</li><li>`target`: File path</li><li>`operation`: I/O operation</li></ul> |
  | `53006`<br>`sysIoWebStorageUnavailable` | Web IndexedDB or storage is unavailable (System Error) | <ul><li>`primaryKey`: `null`</li><li>`target`: IndexedDB resource</li><li>`operation`: I/O operation</li></ul> |
  | `53007`<br>`sysBackupCorrupted` | Backup package is corrupted or missing metadata (System Error) | <ul><li>`primaryKey`: `null`</li><li>`target`: Backup path</li><li>`operation`: Backup read/write</li></ul> |
  | `53008`<br>`sysIoDataCorrupted` | Database data file is corrupted or checksum failed (System Error) | <ul><li>`primaryKey`: `null`</li><li>`target`: Data file path</li><li>`operation`: I/O operation</li></ul> |
  | `53009`<br>`sysInvalidDataFormat` | Data stream formatting or parsing failed (System Error) | <ul><li>`primaryKey`: `null`</li><li>`target`: Data stream key</li><li>`operation`: `"decode"` / `"deserialize"`</li></ul> |
  | `53099`<br>`sysIoGeneric` | Generic system IO error (System Error) | <ul><li>`primaryKey`: `null`</li><li>`target`: File path</li><li>`operation`: I/O operation</li></ul> |
  | `99001`<br>`engError` | Engine error (Engine Error) | <ul><li>`primaryKey`: `null`</li></ul> |

- **JSON Example** (Table not found error):
  ```json
  {
    "index": 0,
    "code": 22001,
    "codeKey": "DEV_NOT_FOUND_TABLE",
    "message": "Table \"orders\" not found in database metadata schema.",
    "primaryKey": null
  }
  ```

---

## 5. Database User Resolution & Exception Handling Recommendations (Dart/Flutter Examples)

In ToStore, all core writing operations (Insert, Update, Delete) return `DbResult`. Queries return `QueryResult`, and transaction operations return `TransactionResult`. Structural configuration mistakes throw `DbException`.

Below are code examples illustrating how developer applications should consume, parse, and gracefully handle database statuses:

### 5.1 Handling Write Operation Responses (`DbResult`)

```dart
import 'package:tostore/tostore.dart';

void handleDatabaseWriteResult(DbResult result) {
  // 1. Instantly check if the write completed entirely without errors
  if (!result.hasErrors) {
    print("All write operations succeeded. Affected: ${result.successCount}");

    // For single-row writes, fetch key directly without iterating statuses
    if (result.firstPrimaryKey != null) {
      print("Primary key of the first successful record: ${result.firstPrimaryKey}");
    }
  } else {
    print("🛑 Error detected. Succeeded: ${result.successCount}, Failed: ${result.failedCount}");
    print("First error: ${result.firstType.codeKey} (${result.firstType.code})");

    // 2. Iterate statuses (index aligns 1:1 with input batch array)
    for (final status in result.statuses) {
      final int idx = status.index;

      // 3. Pattern match subclasses to route handling logic
      if (status is SuccessStatus) {
        print("Index [$idx] Succeeded. Primary key: ${status.primaryKey}");
      } 
      else if (status is ConstraintStatus) {
        // Handle constraint violation (primary key, unique, check, foreign key, etc.)
        print("Index [$idx] Constraint violation! Table: ${status.tableName}, Columns: ${status.fields}");
        print("Conflicting values: ${status.conflictingKeys}, PK: ${status.primaryKey}");
        print("Error Message: ${status.message}");
      } 
      else if (status is InvalidArgumentStatus) {
        // Handle parameter failures
        print("Index [$idx] Invalid parameter! Parameter: ${status.parameterName}, Passed Value: ${status.passedValue}");
      } 
      else if (status is GeneralStatus) {
        // Handle lock timeout, disk full, system I/O issues, etc.
        print("Index [$idx] Generic exception! Code: ${status.code} (${status.codeKey})");
        print("Message: ${status.message}");
      }
    }
  }
}
```

### 5.2 Catching Table Schema and Operation Exception (`DbException`)

For table creation (`createTable`) or schema changes (`updateSchema`), or in cases where schema definitions fail code-level checks, ToStore throws a `DbException` in production:

```dart
try {
  // Opening the database with schema updates
  await ToStore.open(schemas: [..]);
} on DbException catch (e) {
  print("❌ Fatal database exception! Aggregated error: \n${e.message}");
  
  // Iterate through individual statuses in exception
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // Schema validator issues
      print("Schema validation failed! Table: ${status.tableName}");
      if (status.field != null) {
        print("Transgressing field: ${status.field}, Invalid configuration: ${status.wrongValue}");
      }
    } else {
      print("Diagnostics: [${status.codeKey}] (Code ${status.code}): ${status.message}");
    }
  }
}
```

### 5.3 Handling Query Operations (`QueryResult`) & Transaction Controls (`TransactionResult`)

- **For Queries**:
  ```dart
  final queryResult = await db.query('users').where('age', '>', 18);
  if (queryResult.hasErrors) {
    // Handle query exceptions (e.g. invalid cursor, missing table)
    print("Query failed! Code: ${queryResult.type.code}, Message: ${queryResult.message}");
  } else {
    // Query executed successfully
    final List<Map<String, dynamic>> users = queryResult.data;
    print("Fetched ${users.length} records. Has more: ${queryResult.hasMore}");
  }
  ```
- **For Transactions**:
  ```dart
  final txnResult = await db.transaction(() async {
    await db.insert('users', newUser);
  });

  if (txnResult.hasErrors) {
    print("Transaction rolled back! TxId: ${txnResult.txId}");
    // Pull detailed sub-operation failures
    for (final status in txnResult.statuses) {
      if (status.type != ResultType.success) {
        print("Failure cause: [${status.codeKey}] ${status.message}");
      }
    }
  }
  ```

---

## 6. Full Leaf Status Codes and Semantic Identifier Reference

Refer to the table below for exact status routing and parsing:

| Status Code (Code) | Identifier (CodeKey) | Memory Enum (ResultType) | Category | Description |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `ResultType.success` | Success | Operation executed successfully |
| **10000** | `BIZ_VALIDATION_FAILED` | `ResultType.bizValidationFailed` | Business Error | Data format or range validation failed |
| **10001** | `BIZ_NOT_NULL_VIOLATION` | `ResultType.bizNotNullViolation` | Business Error | Not null constraint violation |
| **10002** | `BIZ_VALIDATION_TYPE_CAST` | `ResultType.bizTypeCastFailed` | Business Error | Data type conversion or cast failed |
| **11001** | `BIZ_CONSTRAINT_PRIMARY_KEY` | `ResultType.bizPrimaryKeyViolation` | Business Error | Primary key conflict (already exists) |
| **11002** | `BIZ_CONSTRAINT_UNIQUE` | `ResultType.bizUniqueViolation` | Business Error | Unique constraint violation |
| **11003** | `BIZ_CONSTRAINT_FOREIGN_KEY` | `ResultType.bizForeignKeyViolation` | Business Error | Foreign key constraint violation (Generic) |
| **11004** | `BIZ_CONSTRAINT_CHECK` | `ResultType.bizCheckViolation` | Business Error | Check constraint violation |
| **11005** | `BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST` | `ResultType.bizForeignKeyParentNotExist` | Business Error | Referenced parent key does not exist |
| **11006** | `BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT` | `ResultType.bizForeignKeyChildRestrict` | Business Error | Delete/update restricted by child records |
| **11007** | `BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH` | `ResultType.bizForeignKeyCompositeMismatch` | Business Error | Incomplete composite foreign key values |
| **11008** | `BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH` | `ResultType.bizForeignKeyTypeMismatch` | Business Error | Foreign key type mismatch |
| **11009** | `BIZ_CONSTRAINT_MAX_LENGTH` | `ResultType.bizValueExceedsMaxLength` | Business Error | Value length exceeds maximum constraint |
| **11010** | `BIZ_CONSTRAINT_MIN_LENGTH` | `ResultType.bizValueLessThanMinLength` | Business Error | Value length is less than minimum constraint |
| **11011** | `BIZ_CONSTRAINT_MIN_VALUE` | `ResultType.bizValueLessThanMinValue` | Business Error | Numeric value is less than minimum constraint |
| **11012** | `BIZ_CONSTRAINT_MAX_VALUE` | `ResultType.bizValueExceedsMaxValue` | Business Error | Numeric value exceeds maximum constraint |
| **12001** | `BIZ_NOT_FOUND_RECORD` | `ResultType.bizRecordNotFound` | Business Error | Resource does not exist / Record not found |
| **20001** | `DEV_INVALID_ARGUMENT_FORMAT` | `ResultType.devInvalidArgumentFormat` | Developer Error | Argument format error |
| **20002** | `DEV_INVALID_ARGUMENT_TYPE` | `ResultType.devInvalidArgumentType` | Developer Error | Argument type mismatch |
| **20003** | `DEV_INVALID_ARGUMENT_MISSING` | `ResultType.devInvalidArgumentMissing` | Developer Error | Required argument is missing |
| **20004** | `DEV_INVALID_PRIMARY_KEY_FORMAT` | `ResultType.devInvalidPrimaryKeyFormat` | Developer Error | Invalid primary key format |
| **20005** | `DEV_INDEX_OUT_OF_BOUNDS` | `ResultType.devIndexOutOfBounds` | Developer Error | Index or range is out of bounds |
| **20006** | `DEV_UNSUPPORTED_OPERATION` | `ResultType.devUnsupportedOperation` | Developer Error | Operation is not supported in the current context |
| **20007** | `DEV_VECTOR_DIMENSION_MISMATCH` | `ResultType.devVectorDimensionMismatch` | Developer Error | Vector dimensions mismatch |
| **20008** | `DEV_INDEX_FIELD_MISSING` | `ResultType.devIndexFieldMissing` | Developer Error | Required index field is missing in record for cursor |
| **20101** | `DEV_INVALID_CURSOR_PAGINATION` | `ResultType.devInvalidCursorPagination` | Developer Error | Cursor pagination and offset are mutually exclusive |
| **20102** | `DEV_INVALID_CURSOR_TABLE` | `ResultType.devInvalidCursorTable` | Developer Error | Cursor does not match target table |
| **20103** | `DEV_INVALID_CURSOR_SIGNATURE` | `ResultType.devInvalidCursorSignature` | Developer Error | Mismatched cursor signature (tampered) |
| **20104** | `DEV_INVALID_CURSOR_ORDERBY` | `ResultType.devInvalidCursorOrderBy` | Developer Error | Cursor orderBy configuration invalid or mismatched |
| **20105** | `DEV_INVALID_CURSOR_MODE` | `ResultType.devInvalidCursorMode` | Developer Error | Cursor token mode mismatch |
| **20106** | `DEV_INVALID_CURSOR_PAYLOAD` | `ResultType.devInvalidCursorPayload` | Developer Error | Invalid cursor payload (undecodable) |
| **20201** | `DEV_INVALID_QUERY_SELECT_FIELD` | `ResultType.devInvalidQuerySelectField` | Developer Error | Query select field must be String or QueryAggregation |
| **20202** | `DEV_INVALID_QUERY_FOREIGN_KEY_JOIN` | `ResultType.devInvalidQueryForeignKeyJoin` | Developer Error | No foreign key relationship for auto join |
| **20203** | `DEV_INVALID_QUERY_FIELD_ALIAS` | `ResultType.devInvalidQueryFieldAlias` | Developer Error | Query field alias format invalid |
| **20204** | `DEV_INVALID_EXPRESSION` | `ResultType.devInvalidExpression` | Developer Error | Invalid expression configuration or execution |
| **22001** | `DEV_NOT_FOUND_TABLE` | `ResultType.devTableNotFound` | Developer Error | Table not found |
| **22002** | `DEV_NOT_FOUND_INDEX` | `ResultType.devIndexNotFound` | Developer Error | Index not found |
| **22003** | `DEV_NOT_FOUND_SPACE` | `ResultType.devSpaceNotFound` | Developer Error | Space not found |
| **22004** | `DEV_NOT_FOUND_FIELD` | `ResultType.devFieldNotFound` | Developer Error | Field not found |
| **23001** | `DEV_LARGE_SCALE_OPERATION_REQUIRED` | `ResultType.devLargeScaleOperationRequired` | Developer Error | Large-scale data operation requires `allowLargeScaleOperation()` to prevent OOM |
| **23002** | `DEV_LARGE_SCALE_OPERATION_NOT_ALLOWED_IN_TRANSACTION` | `ResultType.devLargeScaleOperationNotAllowedInTransaction` | Developer Error | Large-scale data operation is not allowed inside a transaction |
| **24001** | `DEV_ENGINE_INCOMPATIBLE` | `ResultType.devEngineIncompatible` | Developer Error | **Critical**: Engine version incompatible |
| **30000** | `DEV_INVALID_SCHEMA` | `ResultType.devInvalidSchema` | Developer Error | Invalid table schema definition |
| **30001** | `DEV_INVALID_SCHEMA_TABLE_NAME` | `ResultType.devInvalidSchemaTableName` | Developer Error | Table name validation failed |
| **30002** | `DEV_INVALID_SCHEMA_FIELD_NAME` | `ResultType.devInvalidSchemaFieldName` | Developer Error | Field name validation failed |
| **30003** | `DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME` | `ResultType.devInvalidSchemaDuplicateFieldName` | Developer Error | Duplicate field name in table schema |
| **30004** | `DEV_INVALID_SCHEMA_PRIMARY_KEY` | `ResultType.devInvalidSchemaPrimaryKey` | Developer Error | Primary key validation failed |
| **30005** | `DEV_INVALID_SCHEMA_INDEX_LIMIT` | `ResultType.devInvalidSchemaIndexLimit` | Developer Error | Index count validation failed |
| **30006** | `DEV_INVALID_SCHEMA_INDEX_FIELD` | `ResultType.devInvalidSchemaIndexField` | Developer Error | Index references non-existent field |
| **30007** | `DEV_INVALID_SCHEMA_INDEX_TYPE` | `ResultType.devInvalidSchemaIndexType` | Developer Error | Index type incompatible with field data type or configuration |
| **30008** | `DEV_INVALID_SCHEMA_FOREIGN_KEY` | `ResultType.devInvalidSchemaForeignKey` | Developer Error | Foreign key definition invalid |
| **30009** | `DEV_INVALID_SCHEMA_SPACE_MISMATCH` | `ResultType.devInvalidSchemaSpaceMismatch` | Developer Error | Global/Space-specific boundary mismatch |
| **30010** | `DEV_INVALID_SCHEMA_TTL_CONFIG` | `ResultType.devInvalidSchemaTtlConfig` | Developer Error | TTL configuration validation failed |
| **30011** | `DEV_SCHEMA_TABLE_EXISTS` | `ResultType.devSchemaTableExists` | Developer Error | Table already exists |
| **30012** | `DEV_SCHEMA_FIELD_EXISTS` | `ResultType.devSchemaFieldExists` | Developer Error | Field already exists |
| **30013** | `DEV_SCHEMA_INDEX_EXISTS` | `ResultType.devSchemaIndexExists` | Developer Error | Index already exists |
| **31001** | `DEV_MIGRATION_NOT_ALLOWED_WITH_DATA` | `ResultType.devMigrationNotAllowedWithData` | Developer Error | Migration requires data modification and was not explicitly allowed |
| **31002** | `DEV_MIGRATION_UNSAFE_TYPE_CONVERSION` | `ResultType.devMigrationUnsafeTypeConversion` | Developer Error | Unsupported data type change for field |
| **31003** | `DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD` | `ResultType.devMigrationCannotAddNonNullField` | Developer Error | Cannot add non-nullable field without a default value |
| **31004** | `DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED` | `ResultType.devMigrationNullableToNonNullNotAllowed` | Developer Error | Changing field from nullable to non-nullable is not allowed |
| **31005** | `DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED` | `ResultType.devMigrationUniqueTighteningNotAllowed` | Developer Error | Changing field from non-unique to unique is not allowed |
| **31006** | `DEV_MIGRATION_PROMOTE_LARGE_OP_NOT_ALLOWED` | `ResultType.devMigrationPromoteLargeOpNotAllowed` | Developer Error | Large-scale ops blocked while promoteFieldToPrimaryKey is running |
| **50001** | `SYS_TRANSACTION_ABORTED` | `ResultType.sysTransactionAborted` | System Error | Transaction aborted |
| **50002** | `SYS_TRANSACTION_CONFLICT` | `ResultType.sysTransactionConflict` | System Error | Transaction conflict |
| **50003** | `SYS_TRANSACTION_LIMIT_EXCEEDED` | `ResultType.sysTransactionLimitExceeded` | System Error | Transaction exceeds the safe in-memory limit under memory pressure |
| **50004** | `SYS_MIGRATION_BATCH_EXECUTION_FAILED` | `ResultType.sysMigrationBatchExecutionFailed` | System Error | **Critical**: Batch migration execution failed |
| **51001** | `SYS_TIMEOUT_LOCK_ACQUISITION` | `ResultType.sysTimeoutLockAcquisition` | System Error | Lock acquisition timeout |
| **51002** | `SYS_TIMEOUT` | `ResultType.sysTimeout` | System Error | Operation timeout |
| **51003** | `SYS_DB_CLOSED` | `ResultType.sysDbClosed` | System Error | Database is closed, operation safely cancelled |
| **52001** | `SYS_RESOURCE_EXHAUSTED_MEMORY` | `ResultType.sysResourceExhaustedMemory` | System Error | **Critical**: Memory resource exhausted |
| **52002** | `SYS_RESOURCE_EXHAUSTED` | `ResultType.sysResourceExhausted` | System Error | **Critical**: System resources exhausted |
| **53001** | `SYS_IO_NOT_FOUND` | `ResultType.sysIoNotFound` | System Error | Physical file or path does not exist |
| **53002** | `SYS_IO_PERMISSION_DENIED` | `ResultType.sysIoPermissionDenied` | System Error | Permission denied for file access |
| **53003** | `SYS_IO_DISK_FULL` | `ResultType.sysIoDiskFull` | System Error | **Critical**: Disk full or storage quota exceeded |
| **53004** | `SYS_IO_FILE_LOCKED` | `ResultType.sysIoFileLocked` | System Error | File is locked or in use by another process |
| **53005** | `SYS_IO_DEVICE_FAULT` | `ResultType.sysIoDeviceFault` | System Error | **Critical**: Storage device or media fault |
| **53006** | `SYS_IO_WEB_STORAGE_UNAVAILABLE` | `ResultType.sysIoWebStorageUnavailable` | System Error | Web IndexedDB or storage is unavailable |
| **53007** | `SYS_BACKUP_CORRUPTED` | `ResultType.sysBackupCorrupted` | System Error | Backup package is corrupted or missing metadata |
| **53008** | `SYS_IO_DATA_CORRUPTED` | `ResultType.sysIoDataCorrupted` | System Error | **Critical**: Database data file is corrupted or checksum failed |
| **53009** | `SYS_INVALID_DATA_FORMAT` | `ResultType.sysInvalidDataFormat` | System Error | Data stream formatting or parsing failed |
| **53099** | `SYS_IO_GENERIC` | `ResultType.sysIoGeneric` | System Error | Generic system IO error |
| **99001** | `ENG_ERROR` | `ResultType.engError` | Engine Error | Engine error |
