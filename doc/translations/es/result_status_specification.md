# Especificación de Diagnóstico Automático & Resolución de Estado de ToStore ResultStatus

Para permitir que las operaciones automatizadas (Ops), los agentes de IA, los scripts de prueba automatizados y las aplicaciones cliente identifiquen con precisión los diferentes resultados de ejecución y estados de excepción de la base de datos, ToStore introduce un sistema estructurado de `ResultStatus` en su última versión.

Este documento de especificación detalla los principios de diseño de los códigos de estado, las especificaciones de claves de identificadores semánticos y las estructuras de campos dedicados de varios tipos de estado para ayudar a los usuarios de bases de datos y a los desarrolleurs a implementar la resolución de estado de forma independiente.

---

## 1. Principios de Diseño Fundamentales

### 1.1 Especificación Numérica del Código de Estado (code)

Todos los códigos de estado numéricos (`code`) se definen con una longitud fija de 5 dígitos (excepto para el estado de éxito):

- **Estado de Éxito (Código de éxito especial)**: Específicamente fijado en `0`.
- **Otros Estados (Códigos de error y diagnóstico)**: Unificados en 5 dígitos.
- **Código de Clase**: Los dos primeros dígitos del código de estado, utilizados para identificar rápidamente la categoría principal.
- **Código de Hoja**: Los últimos tres dígitos del código de estado, que representan el escenario de error específico.

> [!TIP]
> Al desarrollar Ops automatizadas, agentes de IA o scripts de prueba externos, los desarrolladores pueden enrutar a los controladores de excepciones correspondientes utilizando los dos primeros dígitos (Código de clase) o el rango, y luego realizar un manejo detallado basado en el Código de hoja.

> [!IMPORTANT]
> **Mejor Práctica para la Comprobación en Memoria**:
> Al leer los resultados de las operaciones de la base de datos en memoria (por ejemplo, en el código cliente o Dart/Flutter), **el método más recomendado y eficiente es utilizar directamente las propiedades de solo lectura (getters) integradas** de `ResultStatus` o `ResultType` (como `isBusinessError`, `isCriticalError`, etc., consulte la [Sección 3.2](#32-getters-auxiliares-en-memoria)), evitando el análisis manual de rangos numéricos o la comparación de prefijos de cadenas.

### 1.2 Especificación del Identificador Semántico de Estado (codeKey)

Cada estado corresponde a un identificador de cadena único `codeKey`:

- **Format de Nombre**: `[Prefijo_Categoría_Principal]_[Identificador_Detalle_Multinivel]`.
- **Regla de Nombre**: Compuesto por letras mayúsculas en inglés y guiones bajos `_`, sin espacios ni caracteres especiales.
- **Prefijo de Categoría Principal**: Indica a qué categoría de negocio principal pertenece el estado. Si existen varios niveles de categoría, el prefijo más genérico se coloca al principio para facilitar la búsqueda de prefijos y el filtrado por rango.

---

## 2. Tabla de Referencia Rápida de Códigos de Clase

A continuación se presenta la definición de asignación de todos los Códigos de clase en ToStore:

| Rango de Código | Código de Clase (Primeros 2 dígitos) | Prefijo Semántico | Categoría | Estrategia de Excepción |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `00` | `SUCCESS` | **Operación exitosa** | No lanza excepciones, retorna normalmente. |
| `10000 - 19999` | `10 - 19` | `BIZ_` | **Error de Negocio** (Errores de entrada del usuario final, por ejemplo, violación de restricciones) | No lanza excepciones, siempre se responde a través de `DbResult` o `QueryResult`. |
| `20000 - 49999` | `20 - 49` | `DEV_` | **Error de Desarrollador** (Parámetros de API no válidos, configuración de esquema de tabla no válida, etc.) | **Lanza `DbException` directamente en entornos de depuración** para advertir a los desarrolladores; **retorna normalmente como resultado en entornos de producción**. *(Nota: la incompatibilidad de la versión del motor y los fallos de ejecución de lotes de migración principales son errores críticos, que lanzan excepciones incluso en producción)* |
| `50000 - 79999` | `50 - 79` | `SYS_` | **Error de Sistema** (Disco lleno, excepciones de E/S, tiempo de espera de adquisición de bloqueo, etc.) | Lanza excepciones cuando se bloquea la ejecución normal; otros (por ejemplo, conflicto de transacciones) se responden como resultados. |
| `99000 - 99999` | `99` | `ENG_` | **Error de Motor** (Error lógico del motor, corrupción de archivos de datos, error interno desconocido) | Generalmente no lanza excepciones; lanza excepciones en casos graves. |

---

## 3. Estructura de Campos Comunes de ResultStatus y Ayudas en Memoria

### 3.1 Campos Comunes (Estructura JSON Serializada)

Todos los tipos de `ResultStatus`, cuando se serializan a JSON, contienen los siguientes 4 campos comunes básicos. Los usuarios pueden leer estos campos directamente para comprobaciones preliminares.

| Campo | Tipo | Descripción |
| :--- | :--- | :--- |
| `index` | `int` | Índice de secuencia en operaciones por lotes. Para operaciones individuales, este valor se fija en `0`. |
| `code` | `int` | Código de estado numérico (`0` para éxito, número de 5 dígitos para excepciones). |
| `codeKey` | `String` | Clave del identificador semántico del estado, por ejemplo, `CONSTRAINT_VIOLATION_UNIQUE`. |
| `message` | `String` | Descripción detallada del estado legible por humanos. |

### 3.2 Getters Auxiliares en Memoria

En Dart/Flutter, `ResultStatus` y `ResultType` encapsulan propiedades de solo lectura (Getters) altamente eficientes de `O(1)` para comprobar la categoría y la gravedad en memoria sin comprobaciones manuales de rango o comparación de cadenas:

| Propiedad | Tipo | Descripción |
| :--- | :--- | :--- |
| `isBusinessError` | `bool` | Indica si se trata de un **Error de Negocio** (por ejemplo, conflicto de restricciones, fallo de conversión de tipo; rango `10000 - 19999`). |
| `isDeveloperError` | `bool` | Indica si se trata de un **Error de Desarrollador** (por ejemplo, esquema no válido, discrepancia de parámetros, tabla no encontrada; rango `20000 - 49999`). |
| `isSystemError` | `bool` | Indica si se trata de un **Error de Sistema** (por ejemplo, tiempo de espera de bloqueo, disco lleno, bloqueo de archivos; rango `50000 - 79999`). |
| `isEngineError` | `bool` | Indica si se trata de un **Error de Motor** (rango `99000 - 99999`). |
| `isCriticalError` | `bool` | Indica si se trata de un **Error Crítico / Evento a nivel de desastre** (requiere intervención manual o de operaciones, por ejemplo, disco lleno, memoria insuficiente, corrupción grave de archivos de datos, fallo de migración incompatible, etc.). |

---

## 4. Estructuras de Resolución Detalladas y Campos Dedicados

Dependiendo del rango de `code` / `codeKey` y la subclase específica de `ResultStatus`, la estructura JSON serializada llevará diferentes **campos de diagnóstico dedicados**. A continuación se presentan las especificaciones de los campos y el mapeo de aplicaciones para las 5 subclases de estado.

### 4.1 SuccessStatus (Operación exitosa)

- **Rango de Categoría**: `code == 0`, `codeKey == "SUCCESS"`
- **Escenario Aplicable**: Registros insertados, modificados o eliminados con éxito.
- **Definición de Campo Dedicado**:

  | Campo | Typo | Detalles |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Opcional**. Se devuelve solo en escrituras de una sola fila (por ejemplo, `insert`) o actualizaciones (por ejemplo, `update`) que representan la clave primaria del registro generado o modificado físicamente. |

- **Ejemplo JSON**:
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

### 4.2 ConstraintStatus (Integridad de datos & conflictos de restricciones)

- **Rango de Categoría**: `code` dentro de `[10000, 19999]` (principalmente conflictos de validación y restricciones de integridad).
- **Definición de Campo Dedicado**:

  | Campo | Tipo | Detalles |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Requerido**. Nombre de la tabla donde ocurrió el conflicto de restricción de integridad o el error de no encontrado. |
  | `constraintName` | `String?` | **Opcional**. El nombre de la restricción específica que causó el error (por ejemplo, `fk_users_profile` para clave externa, el nombre del índice para conflicto de unicidad, o `null` para errores de not-null o conversión de tipo). |
  | `fields` | `List<String>` | **Requerido**. Lista de campos que causan el conflicto. |
  | `conflictingKeys` | `List<dynamic>` | **Requerido**. Lista de valores de entrada que causan el conflicto, que se mapean 1:1 con `fields`. Si un campo es nulo, el elemento correspondiente en la lista es `null`. |
  | `primaryKey` | `String?` | **Opcional**. Clave primaria del registro asociado. Si no es una escritura de una sola fila, o si se bloqueó en la etapa de memoria, será `null`. |
  | `referencedTable` | `String?` | **Opcional**. Nombre de la tabla principal en conflictos de clave externa. |

- **Directrices para los Códigos de Hoja**:

  | Código & ResultType | Escenario | Directrices de Campos |
  | :--- | :--- | :--- |
  | `10000`<br>`bizValidationFailed` | Error de validación del rango o formato de datos | <ul><li>`tableName`: Tabla afectada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violan la validación, por ejemplo, `["email"]`</li><li>`conflictingKeys`: Valores no válidos que causan el error, por ejemplo, `["invalid-email"]`</li><li>`primaryKey`: Clé primaria del registro (si existe)</li></ul> |
  | `10001`<br>`bizNotNullViolation` | Violación de la restricción not null | <ul><li>`tableName`: Tabla afectada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violan la restricción not-null, por ejemplo, `["email"]`</li><li>`conflictingKeys`: Siempre `[null]`</li><li>`primaryKey`: Clave primaria del registro (si existe)</li></ul> |
  | `10002`<br>`bizTypeCastFailed` | Error de conversión de tipo de datos o cast | <ul><li>`tableName`: Tabla afectada</li><li>`constraintName`: `null`</li><li>`fields`: Campos donde falló la conversión, por ejemplo, `["age"]`</li><li>`conflictingKeys`: Valores no válidos que causan el error, por ejemplo, `["not_a_number"]`</li><li>`primaryKey`: Clave primaria del registro (si existe)</li></ul> |
  | `11001`<br>`bizPrimaryKeyViolation` | Conflicto de clave primaria (ya existe) | <ul><li>`tableName`: Tabla afectada</li><li>`constraintName`: `"PRIMARY"` o el nombre de la restricción</li><li>`fields`: Campos de clave primaria, por ejemplo, `["id"]`</li><li>`conflictingKeys`: Valores duplicados, por ejemplo, `["usr_101"]`</li><li>`primaryKey`: Valor en conflicto, por ejemplo, `"usr_101"`</li></ul> |
  | `11002`<br>`bizUniqueViolation` | Violación de restricción de unicidad | <ul><li>`tableName`: Tabla afectada</li><li>`constraintName`: Nombre del índice único, por ejemplo, `"uk_email"`</li><li>`fields`: Campos que componen la unicidad, por ejemplo, `["email"]`</li><li>`conflictingKeys`: Valores que causan el conflicto, por ejemplo, `["test@a.com"]`</li><li>`primaryKey`: Clave primaria del registro en conflicto (si existe)</li></ul> |
  | `11003`<br>`bizForeignKeyViolation` | Violación de restricción de clave externa (Genérico) | <ul><li>`tableName`: Tabla secundaria (hijo)</li><li>`constraintName`: Nombre de la restricción de clave externa</li><li>`fields`: Columnas de clave externa</li><li>`conflictingKeys`: Valores de entrada que causan el conflicto</li><li>`primaryKey`: Clave primaria del registro (si existe)</li><li>`referencedTable`: Tabla principal (padre)</li></ul> |
  | `11004`<br>`bizCheckViolation` | Violación de restricción check | <ul><li>`tableName`: Tabla afectada</li><li>`constraintName`: Nombre de la restricción check</li><li>`fields`: Campos verificados</li><li>`conflictingKeys`: Valores que violan el check</li><li>`primaryKey`: Clave primaria del registro (si existe)</li></ul> |
  | `11005`<br>`bizForeignKeyParentNotExist` | La clave principal referenciada no existe | <ul><li>`tableName`: Tabla secundaria (hijo)</li><li>`constraintName`: Nombre de la restricción de clave externa</li><li>`fields`: Columnas de clave externa, por ejemplo, `["userId"]`</li><li>`conflictingKeys`: Valor de referencia inexistente, por ejemplo, `["non_parent"]`</li><li>`primaryKey`: Clave primaria del registro (si existe)</li><li>`referencedTable`: Tabla principal (padre)</li></ul> |
  | `11006`<br>`bizForeignKeyChildRestrict` | Eliminación/actualización restringida por registros secundarios | <ul><li>`tableName`: Tabla principal (padre)</li><li>`constraintName`: Nombre de la restricción de clave externa</li><li>`fields`: Columnas referenciadas de la tabla principal</li><li>`conflictingKeys`: Valores de clave principal referenciados por la tabla secundaria</li><li>`primaryKey`: Valores de clave principal</li><li>`referencedTable`: Tabla secundaria (hijo)</li></ul> |
  | `11007`<br>`bizForeignKeyCompositeMismatch` | Valores de clave externa compuesta incompletos | <ul><li>`tableName`: Tabla secundaria (hijo)</li><li>`constraintName`: Nombre de la restricción de clave externa</li><li>`fields`: Columnas de clave externa compuesta</li><li>`conflictingKeys`: Valores de entrada (contiene nulos parciales)</li><li>`primaryKey`: Clave primaria del registro (si existe)</li><li>`referencedTable`: Tabla principal (padre)</li></ul> |
  | `11008`<br>`bizForeignKeyTypeMismatch` | Discrepancia de tipo de clave externa | <ul><li>`tableName`: Tabla secundaria (hijo)</li><li>`constraintName`: Nombre de la restricción de clave externa</li><li>`fields`: Columnas de clave externa</li><li>`conflictingKeys`: Valores donde falló la conversión</li><li>`primaryKey`: Clave primaria del registro (si existe)</li><li>`referencedTable`: Tabla principal (padre)</li></ul> |
  | `11009`<br>`bizValueExceedsMaxLength` | La longitud del valor supera la restricción máxima | <ul><li>`tableName`: Tabla afectada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violan el límite, por ejemplo, `["name"]`</li><li>`conflictingKeys`: Valores que exceden el límite, por ejemplo, `["a" * 1000]`</li><li>`primaryKey`: Clave primaria del registro (si existe)</li></ul> |
  | `11010`<br>`bizValueLessThanMinLength` | La longitud del valor es menor que la restricción mínima | <ul><li>`tableName`: Tabla afectada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violan el límite, por ejemplo, `["code"]`</li><li>`conflictingKeys`: Valores más cortos que el mínimo, por ejemplo, `["ab"]`</li><li>`primaryKey`: Clave primaria del registro (si existe)</li></ul> |
  | `11011`<br>`bizValueLessThanMinValue` | El valor numérico es menor que la restricción mínima | <ul><li>`tableName`: Tabla afectada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violan el límite, por ejemplo, `["age"]`</li><li>`conflictingKeys`: Valores menores que el mínimo, por ejemplo, `[-5]`</li><li>`primaryKey`: Clave primaria del registro (si existe)</li></ul> |
  | `11012`<br>`bizValueExceedsMaxValue` | El valor numérico supera la restricción máxima | <ul><li>`tableName`: Tabla afectada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violan el límite, por ejemplo, `["score"]`</li><li>`conflictingKeys`: Valores que exceden el máximo, por ejemplo, `[105]`</li><li>`primaryKey`: Clave primaria del registro (si existe)</li></ul> |
  | `12002`<br>`bizRecordNotFound` | El recurso no existe / Registro no encontrado | <ul><li>`tableName`: Tabla afectada</li><li>`constraintName`: `null`</li><li>`fields`: Campos de búsqueda objetivo, por ejemplo, `["id"]`</li><li>`conflictingKeys`: Claves objetivo no encontradas, por ejemplo, `["non_exist_id"]`</li><li>`primaryKey`: Valor de la clave faltante, por ejemplo, `"non_exist_id"`</li></ul> |

- **Ejemplo JSON** (El registro principal de la clave externa no existe):
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

### 4.3 SchemaValidationStatus (Validación de esquema de tabla & migración incompatible)

- **Rango de Categoría**: `code` dentro de `[30000, 39999]` (errores de validación de configuración de esquema e incoherencias de migración física).
- **Definición de Campo Dedicado**:

  | Campo | Tipo | Detalles |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Requerido**. Nombre de la tabla que se está validando o migrando físicamente. |
  | `field` | `String?` | **Opcional**. El nombre del campo específico que provocó el error de esquema o migración. |
  | `wrongValue` | `dynamic` | **Opcional**. Valor de configuración no válido o configuración de diferencia de migración que causa el conflicto. |

- **Directrices para los Códigos de Hoja**:

  | Código & ResultType | Escenario | Directrices de Campos |
  | :--- | :--- | :--- |
  | `30000`<br>`devInvalidSchema` | Definición de esquema de tabla no válida | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: `null`</li><li>`wrongValue`: Map de configuración no válida, o `null`</li></ul> |
  | `30001`<br>`devInvalidSchemaTableName` | Fallo de validación del nombre de la tabla (caracteres no válidos o demasiado largo) | <ul><li>`tableName`: Nombre no válido</li><li>`field`: `null`</li><li>`wrongValue`: Cadena no válida</li></ul> |
  | `30002`<br>`devInvalidSchemaFieldName` | Fallo de validación del nombre del campo (caracteres no válidos) | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: Nombre del campo no válido</li><li>`wrongValue`: Cadena no válida</li></ul> |
  | `30003`<br>`devInvalidSchemaPrimaryKey` | Fallo de validación de la clave primaria (faltante o formato no válido) | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: `"primaryKey"` o nombre del campo de clave primaria</li><li>`wrongValue`: Detalles de configuración de clave primaria</li></ul> |
  | `30004`<br>`devInvalidSchemaIndexLimit` | El número de índices de tabla supera el límite del sistema de 16 | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: `null`</li><li>`wrongValue`: Lista de configuraciones de índices</li></ul> |
  | `30005`<br>`devSchemaTableExists` | La tabla ya existe | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30006`<br>`devSchemaFieldExists` | Actualización de esquema: agregar un campo que ya existe | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: Nombre del campo en conflicto</li><li>`wrongValue`: `null`</li></ul> |
  | `30007`<br>`devSchemaIndexExists` | Actualización de esquema: agregar un índice que ya existe | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: Nombre del índice</li><li>`wrongValue`: `null`</li></ul> |
  | `30008`<br>`devInvalidSchemaForeignKey` | Definición de clave externa no válida (por ejemplo, discrepancia de columnas) | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: Nombre de la clave externa</li><li>`wrongValue`: Detalles de configuración de clave externa</li></ul> |
  | `30009`<br>`devInvalidSchemaSpaceMismatch` | Discrepancia de límite global/específico del espacio | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30010`<br>`devMigrationNotAllowedWithData` | La migración requiere la modificación de datos y no fue explícitamente permitida | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: `null`</li><li>`wrongValue`: Map de diferencias de actualización de migración</li></ul> |
  | `30011`<br>`devMigrationUnsafeTypeConversion` | Migración física: conversión de tipo no admitida para el campo | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: Nombre del campo</li><li>`wrongValue`: Map de tipos en conflicto, por ejemplo `{ "from": "text", "to": "integer" }`</li></ul> |
  | `30013`<br>`devMigrationCannotAddNonNullField` | No se puede agregar un campo no-nullable sin un valor predeterminado a una tabla no vacía | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: Nombre del campo no válido</li><li>`wrongValue`: Parámetros de migración, por ejemplo `{ "nullable": false, "defaultValue": null }`</li></ul> |
  | `30014`<br>`devMigrationNullableToNonNullNotAllowed` | Migración física: cambiar un campo de nullable a no-nullable | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: Nombre del campo</li><li>`wrongValue`: Parámetros de migración, idéntico a 30013</li></ul> |
  | `30015`<br>`devMigrationUniqueTighteningNotAllowed` | Migración física: endurecimiento de la restricción del campo a UNIQUE | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: Nombre del campo</li><li>`wrongValue`: Definición del índice que causa la restricción única</li></ul> |
  | `30016`<br>`devInvalidSchemaTtlConfig` | Fallo de validación de la configuración TTL | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: Campo de marca de tiempo TTL</li><li>`wrongValue`: Map de configuración TTL no válida, por ejemplo, `{ "enabled": true, "fieldName": "expire_at" }`</li></ul> |
  | `30017`<br>`devInvalidSchemaDuplicateFieldName` | Nombre de campo duplicado en el esquema de la tabla | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: Nombre de campo duplicado</li><li>`wrongValue`: `null`</li></ul> |
  | `30018`<br>`devInvalidSchemaIndexField` | El índice hace referencia a un campo que no existe | <ul><li>`tableName`: Nombre de la tabla</li><li>`field`: Nombre del índice</li><li>`wrongValue`: Nombre del campo que causa la discrepancia</li></ul> |

- **Ejemplo JSON** (Agregar un campo no-nullable sin valor predeterminado a una tabla no vacía):
  ```json
  {
    "index": 0,
    "code": 30013,
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

### 4.4 InvalidArgumentStatus (Argumentos de API & validación de paginación por cursor)

- **Rango de Categoría**: `code` dentro de `[20000, 20999]` (fallos de validación de parámetros de API, estructuras de consulta o tokens de paginación).
- **Definición de Campo Dedicado**:

  | Campo | Tipo | Detalles |
  | :--- | :--- | :--- |
  | `parameterName` | `String` | **Requerido**. Nombre del argumento que causó el fallo de validación (por ejemplo, `"cursor"`, `"orderBy"`, o una clave de columna específica). |
  | `passedValue` | `dynamic` | **Opcional**. Valor de entrada no conforme pasado por el llamador. Los objetos complejos se convierten en cadenas. |
  | `primaryKey` | `String?` | **Opcional**. Clave primaria del registro asociado. |

- **Directrices para los Códigos de Hoja**:

  | Código & ResultType | Escenario | Directrices de Campos |
  | :--- | :--- | :--- |
  | `20001`<br>`devInvalidArgumentFormat` | Error de formato de argumento | <ul><li>`parameterName`: Nombre del argumento no válido</li><li>`passedValue`: Valor pasado, por ejemplo, `"twenty"`</li><li>`primaryKey`: Clave primaria del registro (si existe)</li></ul> |
  | `20002`<br>`devInvalidArgumentType` | Discrepancia de tipo de argumento | <ul><li>`parameterName`: Nombre del parámetro</li><li>`passedValue`: Valor pasado, por ejemplo `{"foo": "bar"}` (cuando se espera String)</li><li>`primaryKey`: Clave primaria del registro (si existe)</li></ul> |
  | `20003`<br>`devInvalidArgumentMissing` | Falta el argumento requerido | <ul><li>`parameterName`: Nombre del parámetro faltante, por ejemplo, `"dbPath"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: Clave primaria del registro (si existe)</li></ul> |
  | `20005`<br>`devInvalidPrimaryKeyFormat` | Formato de clave primaria no válido | <ul><li>`parameterName`: `"primaryKey"` o campo de clave primaria</li><li>`passedValue`: Valor de clave primaria no válido, por ejemplo, `"invalid_id_value"`</li><li>`primaryKey`: Valor de clave primaria no válido</li></ul> |
  | `20010`<br>`devVectorDimensionMismatch` | Discrepancia en las dimensiones del vector | <ul><li>`parameterName`: `"other"`</li><li>`passedValue`: Tamaño de la dimensión no válida</li><li>`primaryKey`: `null`</li></ul> |
  | `20011`<br>`devIndexFieldMissing` | Falta el campo de índice requerido en el registro para el cursor | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Campo de índice faltante</li><li>`primaryKey`: `null`</li></ul> |
  | `20201`<br>`devInvalidCursorPagination` | La paginación por cursor y el offset son mutuamente excluyentes | <ul><li>`parameterName`: `"cursor"` / `"offset"`</li><li>`passedValue`: Parámetros de paginación en conflicto</li><li>`primaryKey`: `null`</li></ul> |
  | `20202`<br>`devInvalidCursorTable` | El cursor no coincide con la tabla objetivo | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Token de cursor</li><li>`primaryKey`: `null`</li></ul> |
  | `20203`<br>`devInvalidCursorSignature` | Discrepancia en la firma del cursor (manipulado) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Token de cursor</li><li>`primaryKey`: `null`</li></ul> |
  | `20204`<br>`devInvalidCursorOrderBy` | Configuración orderBy del cursor no válida o no coincidente | <ul><li>`parameterName`: `"orderBy"`</li><li>`passedValue`: Lista orderBy, por ejemplo `["-age", "id"]`</li><li>`primaryKey`: `null`</li></ul> |
  | `20205`<br>`devInvalidCursorMode` | Discrepancia en el modo del token de cursor | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Modo del token, por ejemplo, `"sortKey"`</li><li>`primaryKey`: `null`</li></ul> |
  | `20206`<br>`devInvalidCursorPayload` | Carga útil del cursor no válida (no descodificable) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: `null`</li></ul> |
  | `20301`<br>`devInvalidQuerySelectField` | El campo de selección de consulta debe ser String o QueryAggregation | <ul><li>`parameterName`: `"select"`</li><li>`passedValue`: Definición de campo select no válida</li><li>`primaryKey`: `null`</li></ul> |
  | `20302`<br>`devInvalidQueryForeignKeyJoin` | No hay relación de clave externa para el auto-join | <ul><li>`parameterName`: `"join"` / `"tableName"`</li><li>`passedValue`: Tabla objetivo sin relación</li><li>`primaryKey`: `null`</li></ul> |
  | `20303`<br>`devInvalidQueryFieldAlias` | Formato de alias de campo de consulta no válido | <ul><li>`parameterName`: `"alias"`</li><li>`passedValue`: Cadena de alias no válida</li><li>`primaryKey`: `null`</li></ul> |
  | `20304`<br>`devInvalidExpression` | Configuración de expresión no válida o excepción de ejecución | <ul><li>`parameterName`: Aspecto del error (por ejemplo, `"arguments"`, `"functionName"`, `"node"`)</li><li>`passedValue`: Valor o recuento no válido</li><li>`primaryKey`: `null`</li></ul> |
  | `22005`<br>`devFieldNotFound` | Campo no encontrado | <ul><li>`parameterName`: Nombre de campo desconocido, por ejemplo, `"extra"`</li><li>`passedValue`: Valor de entrada pasado para el campo</li><li>`primaryKey`: Clave primaria del registro (si existe)</li></ul> |

- **Ejemplo JSON** (Los campos orderBy del cursor no coinciden con la consulta actual orderBy):
  ```json
  {
    "index": 0,
    "code": 20204,
    "codeKey": "DEV_INVALID_CURSOR_ORDERBY",
    "message": "Cursor orderBy fields do not match current query orderBy.",
    "parameterName": "orderBy",
    "passedValue": ["age DESC", "id ASC"],
    "primaryKey": null
  }
  ```

---

### 4.5 TransactionOperationStatus (Conflicto y aborto de transacción)

- **Rango de Categoría**: `code` dentro de `[50000, 50999]` (rollback de transacción, aborto explícito o conflictos de serializabilidad).
- **Definición de Campo Dedicado**:

  | Campo | Tipo | Detalles |
  | :--- | :--- | :--- |
  | `txId` | `String` | **Requerido**. Identificador de flujo de transacción único a nivel global. Se utiliza para rastrear el ciclo de vida de la transacción. |

- **Directrices para los Códigos de Hoja**:

  | Código & ResultType | Escenario | Directrices de Campos |
  | :--- | :--- | :--- |
  | `50001`<br>`sysTransactionAborted` | Transacción abortada (rollback explícito o fallo en cascada) | <ul><li>`txId`: ID de transacción activa</li></ul> |
  | `50002`<br>`sysTransactionConflict` | Conflicto de transacción (actualizaciones simultáneas en la misma clave en SSI/WAL) | <ul><li>`txId`: ID de transacción en conflicto</li></ul> |

- **Ejemplo JSON** (Conflicto de escritura-escritura concurrente SSI):
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

### 4.6 GeneralStatus (Excepciones genéricas y a nivel de sistema)

- **Rango de Categoría**: Fallback para cualquier otro código de estado (E/S de bajo nivel, errores de hardware, tiempos de espera del sistema, etc.).
- **Definición de Campo Dedicado**:

  | Campo | Tipo | Detalles |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Opcional**. Clave primaria del registro asociado. |
  | `target` | `String?` | **Opcional**. Recurso físico objetivo, por ejemplo, rutas de archivos físicos, bloqueos o URL. |
  | `operation` | `String?` | **Opcional**. Nombre de la llamada al sistema activa, por ejemplo, `'readAsString'`, `'delete'`, `'acquire'`. |

- **Directrices para los Códigos de Hoja**:

  | Código & ResultType | Escenario / Nivel | Directrices de Campos |
  | :--- | :--- | :--- |
  | `20007`<br>`devIndexOutOfBounds` | El índice o rango está fuera de los límites (Error de desarrollador) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `20008`<br>`devUnsupportedOperation` | La operación no es compatible en el contexto actual (Error de desarrollador) | <ul><li>`primaryKey`: `null`</li><li>`target`: Tabla/recurso objetivo (si existe)</li><li>`operation`: Nombre del método (si existe)</li></ul> |
  | `22001`<br>`devTableNotFound` | Tabla no encontrada (Error de desarrollador) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22003`<br>`devIndexNotFound` | Índice no encontrado (Error de desarrollador) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22004`<br>`devSpaceNotFound` | Espacio no encontrado (Error de desarrollador) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23001`<br>`devLargeScaleOperationBypassRequired` | Se requiere omitir los detalles para evitar OOM (Error de desarrollador) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `24001`<br>`devEngineIncompatible` | **Crítico**: Versión del motor incompatible | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50003`<br>`sysMigrationBatchExecutionFailed` | Fallo de ejecución de migración por lotes (Error de sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51001`<br>`sysTimeoutLockAcquisition` | Tiempo de espera de adquisición de bloqueo agotado (Error de sistema) | <ul><li>`primaryKey`: Clave objetivo (si existe)</li><li>`target`: ID del recurso de bloqueo</li><li>`operation`: `"acquire"`</li></ul> |
  | `51002`<br>`sysTimeout` | Tiempo de espera de la operación agotado (Error de sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51003`<br>`sysCancellation` | La operación fue cancelada (Error de sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52001`<br>`sysResourceExhaustedMemory` | Recursos de memoria agotados (Error de sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52002`<br>`sysResourceExhausted` | Recursos del sistema agotados, por ejemplo, disco lleno (Error de sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `53001`<br>`sysIoNotFound` | El archivo o la ruta física no existe (Error de sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ruta de archivo o carpeta</li><li>`operation`: Operación de E/S</li></ul> |
  | `53002`<br>`sysIoPermissionDenied` | Permiso denegado para el acceso al archivo (Error de sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ruta del archivo</li><li>`operation`: Operación de E/S</li></ul> |
  | `53003`<br>`sysIoDiskFull` | Disco lleno o cuota de almacenamiento excedida (Error de sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ruta del archivo</li><li>`operation`: Operación de E/S</li></ul> |
  | `53004`<br>`sysIoFileLocked` | El archivo está bloqueado o en uso por otro proceso (Error de sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ruta del archivo</li><li>`operation`: Operación de E/S</li></ul> |
  | `53005`<br>`sysIoDeviceFault` | Fallo del dispositivo o medio de almacenamiento (Error de sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ruta del archivo</li><li>`operation`: Operación de E/S</li></ul> |
  | `53006`<br>`sysIoWebStorageUnavailable` | IndexedDB web o almacenamiento no disponible (Error de sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Recurso de IndexedDB</li><li>`operation`: Operación de E/S</li></ul> |
  | `53007`<br>`sysBackupCorrupted` | El paquete de respaldo está dañado o faltan metadatos (Error de sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ruta de respaldo</li><li>`operation`: Lectura/escritura de respaldo</li></ul> |
  | `53008`<br>`sysIoDataCorrupted` | El archivo de datos de la base de datos está dañado o falló la suma de comprobación (Error de sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ruta del archivo de datos</li><li>`operation`: Operación de E/S</li></ul> |
  | `53009`<br>`sysInvalidDataFormat` | Error de formato o análisis de flujo de datos (Error de sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Clave de flujo de datos</li><li>`operation`: `"decode"` / `"deserialize"`</li></ul> |
  | `53099`<br>`sysIoGeneric` | Error general de E/S del sistema (Error de sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ruta del archivo</li><li>`operation`: Operación de E/S</li></ul> |
  | `99001`<br>`engError` | Error del motor (Error de motor) | <ul><li>`primaryKey`: `null`</li></ul> |

- **Ejemplo JSON** (Error de tabla no encontrada):
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

## 5. Recomendaciones de Resolución de Estado & Manejo de Excepciones para Usuarios (Ejemplos de Dart/Flutter)

En ToStore, todas las operaciones de escritura principales (Insert, Update, Delete) devuelven un `DbResult`. Las consultas devuelven un `QueryResult`, y las operaciones de transacción devuelven un `TransactionResult`. Los errores de configuración estructural lanzan una `DbException`.

A continuación se muestran ejemplos de código que ilustran cómo las aplicaciones cliente deben consumir, analizar y manejar de manera limpia los estados de la base de datos:

### 5.1 Manejo de Respuestas de Escritura (`DbResult`)

```dart
import 'package:tostore/tostore.dart';

void handleDatabaseWriteResult(DbResult result) {
  // 1. Comprobar instantáneamente si la escritura se completó por completo sin errores
  if (!result.hasErrors) {
    print("Todas las operaciones de escritura tuvieron éxito. Afectados: ${result.successCount}");

    // Para escrituras de una sola fila, obtener la clave directamente sin iterar los estados
    if (result.firstPrimaryKey != null) {
      print("Clave primaria del primer registro exitoso: ${result.firstPrimaryKey}");
    }
  } else {
    print("🛑 Error detectado. Exitosos: ${result.successCount}, Fallidos: ${result.failedCount}");
    print("Primer error: ${result.firstType.codeKey} (${result.firstType.code})");

    // 2. Iterar los estados (el índice se alinea 1:1 con el arreglo por lotes de entrada)
    for (final status in result.statuses) {
      final int idx = status.index;

      // 3. Pattern matching en subclases para enrutar la lógica de manejo
      if (status is SuccessStatus) {
        print("Index [$idx] Exitoso. Clave primaria: ${status.primaryKey}");
      } 
      else if (status is ConstraintStatus) {
        // Manejar la violación de restricciones (clave primaria, unicidad, check, clave externa, etc.)
        print("Index [$idx] ¡Violación de restricción! Tabla: ${status.tableName}, Columnas: ${status.fields}");
        print("Valores en conflicto: ${status.conflictingKeys}, PK: ${status.primaryKey}");
        print("Mensaje de error: ${status.message}");
      } 
      else if (status is InvalidArgumentStatus) {
        // Manejar errores de parámetros
        print("Index [$idx] ¡Parámetro no válido! Parámetro: ${status.parameterName}, Valor pasado: ${status.passedValue}");
      } 
      else if (status is GeneralStatus) {
        // Manejar tiempo de espera de bloqueo, disco lleno, problemas de E/S del sistema, etc.
        print("Index [$idx] ¡Excepción genérica! Código: ${status.code} (${status.codeKey})");
        print("Mensaje: ${status.message}");
      }
    }
  }
}
```

### 5.2 Captura de Esquema de Tabla y Excepción de Operación (`DbException`)

Para la creación de tablas (`createTable`) o cambios de esquema (`updateSchema`), o en casos donde las definiciones de esquema fallan en las comprobaciones a nivel de código, ToStore lanza una `DbException` en producción:

```dart
try {
  // Apertura de la base de datos con actualizaciones de esquema
  await ToStore.open(schemas: [..]);
} on DbException catch (e) {
  print("❌ ¡Excepción de base de datos fatal! Error agregado: \n${e.message}");
  
  // Iterar a través de los estados individuales en la excepción
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // Problemas del validador de esquema
      print("¡Fallo en la validación del esquema! Tabla: ${status.tableName}");
      if (status.field != null) {
        print("Campo no válido: ${status.field}, Configuración no válida: ${status.wrongValue}");
      }
    } else {
      print("Diagnósticos: [${status.codeKey}] (Code ${status.code}): ${status.message}");
    }
  }
}
```

### 5.3 Manejo de Operaciones de Consulta (`QueryResult`) & Controles de Transacción (`TransactionResult`)

- **Para Consultas**:
  ```dart
  final queryResult = await db.query('users').where('age', '>', 18);
  if (queryResult.hasErrors) {
    // Manejar excepciones de consulta (por ejemplo, cursor no válido, tabla faltante)
    print("¡Consulta fallida! Código: ${queryResult.type.code}, Mensaje: ${queryResult.message}");
  } else {
    // Consulta ejecutada con éxito
    final List<Map<String, dynamic>> users = queryResult.data;
    print("Se recuperaron ${users.length} registros. Tiene más: ${queryResult.hasMore}");
  }
  ```
- **Para Transacciones**:
  ```dart
  final txnResult = await db.transaction(() async {
    await db.insert('users', newUser);
  });

  if (txnResult.hasErrors) {
    print("¡Transacción revertida! TxId: ${txnResult.txId}");
    // Obtener detalles de fallos de suboperaciones individuales
    for (final status in txnResult.statuses) {
      if (status.type != ResultType.success) {
        print("Causa del fallo: [${status.codeKey}] ${status.message}");
      }
    }
  }
  ```

---

## 6. Referencia Completa de Códigos de Estado de Hoja y Identificadores Semánticos

Consulte la siguiente tabla para conocer el enrutamiento y análisis de estado exactos:

| Código de Estado (Code) | Identificador (CodeKey) | Enum en Memoria (ResultType) | Categoría | Descripción |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `ResultType.success` | Éxito | Operación ejecutada con éxito |
| **10000** | `BIZ_VALIDATION_FAILED` | `ResultType.bizValidationFailed` | Error de Negocio | Error de validación del rango o formato de datos |
| **10001** | `BIZ_NOT_NULL_VIOLATION` | `ResultType.bizNotNullViolation` | Error de Negocio | Violación de la restricción not null |
| **10002** | `BIZ_VALIDATION_TYPE_CAST` | `ResultType.bizTypeCastFailed` | Error de Negocio | Error de conversión de tipo de datos o cast |
| **11001** | `BIZ_CONSTRAINT_PRIMARY_KEY` | `ResultType.bizPrimaryKeyViolation` | Error de Negocio | Conflicto de clave primaria (ya existe) |
| **11002** | `BIZ_CONSTRAINT_UNIQUE` | `ResultType.bizUniqueViolation` | Error de Negocio | Violación de restricción de unicidad |
| **11003** | `BIZ_CONSTRAINT_FOREIGN_KEY` | `ResultType.bizForeignKeyViolation` | Error de Negocio | Violación de restricción de clave externa (Genérico) |
| **11004** | `BIZ_CONSTRAINT_CHECK` | `ResultType.bizCheckViolation` | Error de Negocio | Violación de restricción check |
| **11005** | `BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST` | `ResultType.bizForeignKeyParentNotExist` | Error de Negocio | La clave principal referenciada no existe |
| **11006** | `BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT` | `ResultType.bizForeignKeyChildRestrict` | Error de Negocio | Eliminación/actualización restringida por registros secundarios |
| **11007** | `BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH` | `ResultType.bizForeignKeyCompositeMismatch` | Error de Negocio | Valores de clave externa compuesta incompletos |
| **11008** | `BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH` | `ResultType.bizForeignKeyTypeMismatch` | Error de Negocio | Discrepancia de tipo de clave externa |
| **11009** | `BIZ_CONSTRAINT_MAX_LENGTH` | `ResultType.bizValueExceedsMaxLength` | Error de Negocio | La longitud del valor supera la restricción máxima |
| **11010** | `BIZ_CONSTRAINT_MIN_LENGTH` | `ResultType.bizValueLessThanMinLength` | Error de Negocio | La longitud del valor es menor que la restricción mínima |
| **11011** | `BIZ_CONSTRAINT_MIN_VALUE` | `ResultType.bizValueLessThanMinValue` | Error de Negocio | El valor numérico es menor que la restricción mínima |
| **11012** | `BIZ_CONSTRAINT_MAX_VALUE` | `ResultType.bizValueExceedsMaxValue` | Error de Negocio | El valor numérico supera la restricción máxima |
| **12002** | `BIZ_NOT_FOUND_RECORD` | `ResultType.bizRecordNotFound` | Error de Negocio | El recurso no existe / Registro no encontrado |
| **20001** | `DEV_INVALID_ARGUMENT_FORMAT` | `ResultType.devInvalidArgumentFormat` | Error de Desarrollador | Error de formato de argumento |
| **20002** | `DEV_INVALID_ARGUMENT_TYPE` | `ResultType.devInvalidArgumentType` | Error de Desarrollador | Discrepancia de tipo de argumento |
| **20003** | `DEV_INVALID_ARGUMENT_MISSING` | `ResultType.devInvalidArgumentMissing` | Error de Desarrollador | Falta el argumento requerido |
| **20005** | `DEV_INVALID_PRIMARY_KEY_FORMAT` | `ResultType.devInvalidPrimaryKeyFormat` | Error de Desarrollador | Formato de clave primaria no válido |
| **20007** | `DEV_INDEX_OUT_OF_BOUNDS` | `ResultType.devIndexOutOfBounds` | Error de Desarrollador | El índice o rango está fuera de los límites |
| **20008** | `DEV_UNSUPPORTED_OPERATION` | `ResultType.devUnsupportedOperation` | Error de Desarrollador | La operación no es compatible en el contexto actual |
| **20010** | `DEV_VECTOR_DIMENSION_MISMATCH` | `ResultType.devVectorDimensionMismatch` | Error de Desarrollador | Discrepancia en las dimensiones del vector |
| **20011** | `DEV_INDEX_FIELD_MISSING` | `ResultType.devIndexFieldMissing` | Error de Desarrollador | Falta el campo de índice requerido en el registro para el cursor |
| **20201** | `DEV_INVALID_CURSOR_PAGINATION` | `ResultType.devInvalidCursorPagination` | Error de Desarrollador | La paginación por cursor y el offset son mutuamente excluyentes |
| **20202** | `DEV_INVALID_CURSOR_TABLE` | `ResultType.devInvalidCursorTable` | Error de Desarrollador | El cursor no coincide con la tabla objetivo |
| **20203** | `DEV_INVALID_CURSOR_SIGNATURE` | `ResultType.devInvalidCursorSignature` | Error de Desarrollador | Discrepancia en la firma del cursor (manipulado) |
| **20204** | `DEV_INVALID_CURSOR_ORDERBY` | `ResultType.devInvalidCursorOrderBy` | Error de Desarrollador | Configuración orderBy del cursor no válida o no coincidente |
| **20205** | `DEV_INVALID_CURSOR_MODE` | `ResultType.devInvalidCursorMode` | Error de Desarrollador | Discrepancia en el modo del token de cursor |
| **20206** | `DEV_INVALID_CURSOR_PAYLOAD` | `ResultType.devInvalidCursorPayload` | Error de Desarrollador | Carga útil del cursor no válida (no descodificable) |
| **20301** | `DEV_INVALID_QUERY_SELECT_FIELD` | `ResultType.devInvalidQuerySelectField` | Error de Desarrollador | El campo de selección de consulta debe ser String o QueryAggregation |
| **20302** | `DEV_INVALID_QUERY_FOREIGN_KEY_JOIN` | `ResultType.devInvalidQueryForeignKeyJoin` | Error de Desarrollador | No hay relación de clave externa para el auto-join |
| **20303** | `DEV_INVALID_QUERY_FIELD_ALIAS` | `ResultType.devInvalidQueryFieldAlias` | Error de Desarrollador | Formato de alias de campo de consulta no válido |
| **20304** | `DEV_INVALID_EXPRESSION` | `ResultType.devInvalidExpression` | Error de Desarrollador | Configuración de expresión no válida o excepción de ejecución |
| **22001** | `DEV_NOT_FOUND_TABLE` | `ResultType.devTableNotFound` | Error de Desarrollador | Tabla no encontrada |
| **22003** | `DEV_NOT_FOUND_INDEX` | `ResultType.devIndexNotFound` | Error de Desarrollador | Índice no encontrado |
| **22004** | `DEV_NOT_FOUND_SPACE` | `ResultType.devSpaceNotFound` | Error de Desarrollador | Espacio no encontrado |
| **22005** | `DEV_NOT_FOUND_FIELD` | `ResultType.devFieldNotFound` | Error de Desarrollador | Campo no encontrado |
| **23001** | `DEV_LARGE_SCALE_OPERATION_REQUIRED_BYPASS` | `ResultType.devLargeScaleOperationBypassRequired` | Error de Desarrollador | La operación a gran escala requiere omitir detalles para evitar OOM |
| **24001** | `DEV_ENGINE_INCOMPATIBLE` | `ResultType.devEngineIncompatible` | Error de Desarrollador | **Crítico**: Versión del motor incompatible |
| **30000** | `DEV_INVALID_SCHEMA` | `ResultType.devInvalidSchema` | Error de Desarrollador | Definición de esquema de tabla no válida |
| **30001** | `DEV_INVALID_SCHEMA_TABLE_NAME` | `ResultType.devInvalidSchemaTableName` | Error de Desarrollador | Fallo de validación del nombre de la tabla |
| **30002** | `DEV_INVALID_SCHEMA_FIELD_NAME` | `ResultType.devInvalidSchemaFieldName` | Error de Desarrollador | Fallo de validación del nombre del campo |
| **30003** | `DEV_INVALID_SCHEMA_PRIMARY_KEY` | `ResultType.devInvalidSchemaPrimaryKey` | Error de Desarrollador | Fallo de validación de la clave primaria |
| **30004** | `DEV_INVALID_SCHEMA_INDEX_LIMIT` | `ResultType.devInvalidSchemaIndexLimit` | Error de Desarrollador | Fallo de validación del número de índices |
| **30005** | `DEV_SCHEMA_TABLE_EXISTS` | `ResultType.devSchemaTableExists` | Error de Desarrollador | La tabla ya existe |
| **30006** | `DEV_SCHEMA_FIELD_EXISTS` | `ResultType.devSchemaFieldExists` | Error de Desarrollador | El campo ya existe |
| **30007** | `DEV_SCHEMA_INDEX_EXISTS` | `ResultType.devSchemaIndexExists` | Error de Desarrollador | El índice ya existe |
| **30008** | `DEV_INVALID_SCHEMA_FOREIGN_KEY` | `ResultType.devInvalidSchemaForeignKey` | Error de Desarrollador | Definición de clave externa no válida |
| **30009** | `DEV_INVALID_SCHEMA_SPACE_MISMATCH` | `ResultType.devInvalidSchemaSpaceMismatch` | Error de Desarrollador | Discrepancia de límite global/específico del espacio |
| **30010** | `DEV_MIGRATION_NOT_ALLOWED_WITH_DATA` | `ResultType.devMigrationNotAllowedWithData` | Error de Desarrollador | La migración requiere la modificación de datos y no fue explícitamente permitida |
| **30011** | `DEV_MIGRATION_UNSAFE_TYPE_CONVERSION` | `ResultType.devMigrationUnsafeTypeConversion` | Error de Desarrollador | Tipo de cambio no admitido para el campo |
| **30013** | `DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD` | `ResultType.devMigrationCannotAddNonNullField` | Error de Desarrollador | No se permite agregar un campo no-nullable sin un valor predeterminado |
| **30014** | `DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED` | `ResultType.devMigrationNullableToNonNullNotAllowed` | Error de Desarrollador | No se permite cambiar un campo de nullable a no-nullable |
| **30015** | `DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED` | `ResultType.devMigrationUniqueTighteningNotAllowed` | Error de Desarrollador | No se permite el endurecimiento a UNIQUE |
| **30016** | `DEV_INVALID_SCHEMA_TTL_CONFIG` | `ResultType.devInvalidSchemaTtlConfig` | Error de Desarrollador | Fallo de validación de la configuración TTL |
| **30017** | `DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME` | `ResultType.devInvalidSchemaDuplicateFieldName` | Error de Desarrollador | Nombre de campo duplicado en el esquema de la tabla |
| **30018** | `DEV_INVALID_SCHEMA_INDEX_FIELD` | `ResultType.devInvalidSchemaIndexField` | Error de Desarrollador | El índice hace referencia a un campo que no existe |
| **50001** | `SYS_TRANSACTION_ABORTED` | `ResultType.sysTransactionAborted` | Error de Sistema | Transacción abortada |
| **50002** | `SYS_TRANSACTION_CONFLICT` | `ResultType.sysTransactionConflict` | Error de Sistema | Conflicto de transacción |
| **50003** | `SYS_MIGRATION_BATCH_EXECUTION_FAILED` | `ResultType.sysMigrationBatchExecutionFailed` | Error de Sistema | **Crítico**: Fallo de ejecución de migración por lotes |
| **51001** | `SYS_TIMEOUT_LOCK_ACQUISITION` | `ResultType.sysTimeoutLockAcquisition` | Error de Sistema | Tiempo de espera de adquisición de bloqueo agotado |
| **51002** | `SYS_TIMEOUT` | `ResultType.sysTimeout` | Error de Sistema | Tiempo de espera de la operación agotado |
| **51003** | `SYS_CANCELLATION` | `ResultType.sysCancellation` | Error de Sistema | La operación fue cancelada |
| **52001** | `SYS_RESOURCE_EXHAUSTED_MEMORY` | `ResultType.sysResourceExhaustedMemory` | Error de Sistema | **Crítico**: Recursos de memoria agotados |
| **52002** | `SYS_RESOURCE_EXHAUSTED` | `ResultType.sysResourceExhausted` | Error de Sistema | **Crítico**: Recursos del sistema agotados |
| **53001** | `SYS_IO_NOT_FOUND` | `ResultType.sysIoNotFound` | Error de Sistema | El archivo o la ruta física no existe |
| **53002** | `SYS_IO_PERMISSION_DENIED` | `ResultType.sysIoPermissionDenied` | Error de Sistema | Permiso denegado para el acceso al archivo |
| **53003** | `SYS_IO_DISK_FULL` | `ResultType.sysIoDiskFull` | Error de Sistema | **Crítico**: Disco lleno o cuota de almacenamiento excedida |
| **53004** | `SYS_IO_FILE_LOCKED` | `ResultType.sysIoFileLocked` | Error de Sistema | El archivo está bloqueado o en uso por otro proceso |
| **53005** | `SYS_IO_DEVICE_FAULT` | `ResultType.sysIoDeviceFault` | Error de Sistema | **Crítico**: Fallo del dispositivo o medio de almacenamiento |
| **53006** | `SYS_IO_WEB_STORAGE_UNAVAILABLE` | `ResultType.sysIoWebStorageUnavailable` | Error de Sistema | IndexedDB web o almacenamiento no disponible |
| **53007** | `SYS_BACKUP_CORRUPTED` | `ResultType.sysBackupCorrupted` | Error de Sistema | El paquete de respaldo está dañado o faltan metadatos |
| **53008** | `SYS_IO_DATA_CORRUPTED` | `ResultType.sysIoDataCorrupted` | Error de Sistema | **Crítico**: El archivo de datos de la base de datos está dañado o falló la suma de comprobación |
| **53009** | `SYS_INVALID_DATA_FORMAT` | `ResultType.sysInvalidDataFormat` | Error de Sistema | Error de formato o análisis de flujo de datos |
| **53099** | `SYS_IO_GENERIC` | `ResultType.sysIoGeneric` | Error de Sistema | Error general de E/S del sistema |
| **99001** | `ENG_ERROR` | `ResultType.engError` | Error de Motor | Error del motor |
