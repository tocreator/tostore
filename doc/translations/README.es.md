<h1 align="center">
  <img src="../resource/logo-tostore.svg" width="400" alt="ToStore">
</h1>

<p align="center">
  <a href="https://pub.dev/packages/tostore"><img src="https://img.shields.io/pub/v/tostore.svg" alt="pub package"></a>
  <a href="https://pub.dev/packages/tostore/score"><img src="https://img.shields.io/pub/points/tostore.svg" alt="Pub Points"></a>
  <a href="https://pub.dev/packages/tostore/likes"><img src="https://img.shields.io/pub/likes/tostore.svg" alt="Pub Likes"></a>
  <a href="https://pub.dev/packages/tostore"><img src="https://img.shields.io/pub/dm/tostore.svg" alt="Monthly Downloads"></a>
</p>

<p align="center">
  <a href="https://opensource.org/licenses/Apache-2.0"><img src="https://img.shields.io/badge/License-Apache_2.0-blue.svg" alt="License"></a>
  <a href="https://pub.dev/packages/tostore"><img src="https://img.shields.io/badge/Platform-Multi--Platform-02569B?logo=dart" alt="Platform"></a>
  <img src="https://img.shields.io/badge/Architecture-Neural--Distributed-orange" alt="Architecture">
</p>

<p align="center">
  <a href="../../README.md">English</a> | 
  <a href="README.zh-CN.md">简体中文</a> | 
  <a href="README.ja.md">日本語</a> | 
  <a href="README.ko.md">한국어</a> | 
  Español | 
  <a href="README.pt-BR.md">Português (Brasil)</a> | 
  <a href="README.ru.md">Русский</a> | 
  <a href="README.de.md">Deutsch</a> | 
  <a href="README.fr.md">Français</a> | 
  <a href="README.it.md">Italiano</a> | 
  <a href="README.tr.md">Türkçe</a>
</p>

## Navegación rápida
- **Primeros pasos**: [Por qué almacenar](#why-tostore) | [Características clave](#key-features) | [Guía de instalación](#installation) | [Modo KV](#quick-start-kv) | [Modo tabla](#quick-start-table) | [Modo de memoria](#quick-start-memory)
- **Arquitectura y modelo**: [Definición de esquema](#schema-definition) | [Arquitectura distribuida](#distributed-architecture) | [Claves externas en cascada](#foreign-keys) | [Móvil/Escritorio](#mobile-integration) | [Servidor/Agente](#server-integration) | [Algoritmos de clave primaria](#primary-key-examples)
- **Consultas avanzadas**: [Consultas avanzadas (UNIRSE)](#query-advanced) | [Agregación y estadísticas](#aggregation-stats) | [Lógica compleja (Condición de consulta)](#query-condition) | [Consulta reactiva (ver)](#reactive-query) | [Consulta de transmisión](#streaming-query)
- **Avanzado y rendimiento**: [Búsqueda vectorial](#vector-advanced) | [TTL a nivel de tabla](#ttl-config) | [Paginación eficiente](#query-pagination) | [Caché de consultas](#query-cache) | [Expresiones atómicas](#atomic-expressions) | [Transacciones](#transactions)
- **Operaciones y seguridad**: [Administración](#database-maintenance) | [Configuración de seguridad](#security-config) | [Manejo de errores](#error-handling) | [Rendimiento y diagnóstico](#performance) | [Más recursos](#more-resources)

<a id="why-tostore"></a>
## ¿Por qué elegir ToStore?

ToStore es un motor de datos moderno diseñado para la era AGI y los escenarios de inteligencia de vanguardia. Admite de forma nativa sistemas distribuidos, fusión multimodal, datos estructurados relacionales, vectores de alta dimensión y almacenamiento de datos no estructurados. Construido sobre una arquitectura de nodo de autoenrutamiento y un motor inspirado en una red neuronal, brinda a los nodos una alta autonomía y una escalabilidad horizontal elástica al tiempo que desacopla lógicamente el rendimiento de la escala de datos. Incluye transacciones ACID, consultas relacionales complejas (JOIN y claves externas en cascada), TTL a nivel de tabla y agregaciones, junto con múltiples algoritmos de clave primaria distribuidos, expresiones atómicas, reconocimiento de cambios de esquema, cifrado, aislamiento de datos multiespacio, programación de carga inteligente con reconocimiento de recursos y recuperación automática ante desastres/fallos.

A medida que la informática continúa avanzando hacia la inteligencia de punta, los agentes, sensores y otros dispositivos ya no son simplemente "pantallas de contenido". Son nodos inteligentes responsables de la generación local, la conciencia ambiental, la toma de decisiones en tiempo real y los flujos de datos coordinados. Las soluciones de bases de datos tradicionales están limitadas por su arquitectura subyacente y sus extensiones integradas, lo que hace que sea cada vez más difícil satisfacer los requisitos de baja latencia y estabilidad de las aplicaciones inteligentes de nube perimetral en escrituras de alta concurrencia, conjuntos de datos masivos, recuperación de vectores y generación colaborativa.

ToStore brinda capacidades distribuidas de borde lo suficientemente sólidas para conjuntos de datos masivos, generación compleja de IA local y movimiento de datos a gran escala. La colaboración inteligente profunda entre los nodos del borde y de la nube proporciona una base de datos confiable para realidad mixta inmersiva, interacción multimodal, vectores semánticos, modelado espacial y escenarios similares.

<a id="key-features"></a>
## Características clave

- 🌐 **Motor de datos unificado multiplataforma**
  - API unificada en entornos móviles, de escritorio, web y de servidor
  - Admite datos estructurados relacionales, vectores de alta dimensión y almacenamiento de datos no estructurados.
  - Crea un canal de datos desde el almacenamiento local hasta la colaboración en la nube perimetral

- 🧠 **Arquitectura distribuida estilo red neuronal**
  - Arquitectura de nodo de autoenrutamiento que desacopla el direccionamiento físico de la escala
  - Los nodos altamente autónomos colaboran para construir una topología de datos flexible
  - Admite la cooperación de nodos y el escalado horizontal elástico
  - Interconexión profunda entre los nodos inteligentes de borde y la nube

- ⚡ **Ejecución paralela y programación de recursos**
  - Programación de carga inteligente basada en recursos con alta disponibilidad
  - Colaboración paralela de múltiples nodos y descomposición de tareas.
  - La división del tiempo mantiene las animaciones de la interfaz de usuario fluidas incluso bajo cargas pesadas

- 🔍 **Consultas estructuradas y recuperación de vectores**
  - Admite predicados complejos, JOIN, agregaciones y TTL a nivel de tabla
  - Admite campos vectoriales, índices vectoriales y recuperación del vecino más cercano
  - Los datos estructurados y vectoriales pueden trabajar juntos dentro del mismo motor.

- 🔑 **Claves primarias, índices y evolución de esquemas**
  - Algoritmos de clave principal integrados que incluyen estrategias secuenciales, de marca de tiempo, con prefijo de fecha y de código corto
  - Admite índices únicos, índices compuestos, índices vectoriales y restricciones de clave externa
  - Detecta automáticamente cambios de esquema y completa el trabajo de migración

- 🛡️ **Transacciones, seguridad y recuperación**
  - Proporciona transacciones ACID, actualizaciones de expresiones atómicas y claves externas en cascada
  - Admite recuperación de fallos, confirmaciones duraderas y garantías de coherencia
  - Admite cifrado ChaCha20-Poly1305 y AES-256-GCM

- 🔄 **Flujos de trabajo de datos y multiespacio**
  - Admite espacios aislados con datos compartidos globalmente opcionales
  - Admite escuchas de consultas en tiempo real, almacenamiento en caché inteligente de varios niveles y paginación del cursor
  - Se adapta a aplicaciones multiusuario, locales primero y colaborativas fuera de línea

<a id="installation"></a>
## Instalación

> [!IMPORTANT]
> **¿Actualizando desde v2.x?** Lea la [Guía de actualización de v3.x](../UPGRADE_GUIDE_v3.md) para conocer los pasos críticos de migración y los cambios importantes.

Añade `tostore` a tu `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Please use the latest version
```

<a id="quick-start"></a>
## Inicio rápido

> [!TIP]
> **¿Cómo elegir un modo de almacenamiento?**
> 1. [**Modo clave-valor (KV)**](#quick-start-kv): Lo mejor para acceso a la configuración, administración de estados dispersos o almacenamiento de datos JSON. Es la forma más rápida de empezar.
> 2. [**Modo de tabla estructurada**](#quick-start-table): Lo mejor para datos comerciales centrales que necesitan consultas complejas, validación de restricciones o gobernanza de datos a gran escala. Al introducir la lógica de integridad en el motor, puede reducir significativamente los costos de desarrollo y mantenimiento de la capa de aplicaciones.
> 3. [**Modo de memoria**](#quick-start-memory): Ideal para cálculo temporal, pruebas unitarias o **administración de estado global ultrarrápida**. Con consultas globales y oyentes `watch`, puede remodelar la interacción de la aplicación sin mantener un montón de variables globales.

<a id="quick-start-kv"></a>
### Almacenamiento de valores clave (KV)
Este modo es adecuado cuando no necesita tablas estructuradas predefinidas. Es simple, práctico y está respaldado por un motor de almacenamiento de alto rendimiento. **Su arquitectura de indexación eficiente mantiene el rendimiento de las consultas altamente estable y extremadamente receptivo incluso en dispositivos móviles comunes a escalas de datos muy grandes.** Los datos en diferentes espacios están naturalmente aislados, mientras que también se admite el intercambio global.

```dart
// Initialize the database
final db = await ToStore.open();

// Set key-value pairs (supports String, int, bool, double, Map, List, Json, and more)
await db.setValue('user_profile', {
  'name': 'John',
  'age': 25,
});

// Switch space - isolate data for different users
await db.switchSpace(spaceName: 'user_123');

// Set a globally shared variable (isGlobal: true enables cross-space sharing, such as login state)
await db.setValue('current_user', 'John', isGlobal: true);

// Automatic expiration cleanup (TTL)
// Supports either a relative lifetime (ttl) or an absolute expiration time (expiresAt)
await db.setValue('temp_config', 'value', ttl: Duration(hours: 2));
await db.setValue('session_token', 'abc', expiresAt: DateTime(2026, 2, 31));

// Read data
final profile = await db.getValue('user_profile'); // Map<String, dynamic>

// Listen for real-time value changes (useful for refreshing local UI without extra state frameworks)
db.watchValue('current_user', isGlobal: true).listen((value) {
  print('Logged-in user changed to: $value');
});

// Listen to multiple keys at once
db.watchValues(['current_user', 'login_status']).listen((map) {
  print('Multiple config values were updated: $map');
});

// Remove data
await db.removeValue('current_user');
```

#### Ejemplo de actualización automática de la interfaz de usuario de Flutter
En Flutter, `StreamBuilder` más `watchValue` te brinda un flujo de actualización reactiva muy conciso:

```dart
StreamBuilder(
  // When listening to a global variable, remember to set isGlobal: true
  stream: db.watchValue('current_user', isGlobal: true),
  builder: (context, snapshot) {
    // snapshot.data is the latest value of 'current_user' in KV storage
    final user = snapshot.data ?? 'Not logged in';
    return Text('Current user: $user');
  },
)
```

<a id="quick-start-table"></a>
### Modo de tabla estructurada
CRUD en tablas estructuradas requiere que el esquema se cree con anticipación (consulte [Definición de esquema](#schema-definition)). Enfoques de integración recomendados para diferentes escenarios:
- **Móvil/Escritorio**: para [escenarios de inicio frecuentes](#mobile-integration), se recomienda pasar `schemas` durante la inicialización.
- **Servidor/Agente**: Para [escenarios de larga duración](#server-integration), se recomienda crear tablas dinámicamente a través de `createTables`.

```dart
// 1. Initialize the database
final db = await ToStore.open();

// 2. Insert data (prepare some base records)
final result = await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// Unified operation result model: DbResult
// It is recommended to always check isSuccess
if (result.isSuccess) {
  print('Insert succeeded, generated primary key ID: ${result.successKeys.first}');
} else {
  print('Insert failed: ${result.message}');
}

// Chained query (see [Query Operators](#query-operators); supports =, !=, >, <, LIKE, IN, and more)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// Update and delete
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// Real-time listening (see [Reactive Query](#reactive-query) for more details)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Users matching the condition have changed: $users');
});

// Pair with Flutter StreamBuilder for automatic local UI refresh
StreamBuilder(
  stream: db.query('users').where('age', '>', 18).watch(),
  builder: (context, snapshot) {
    final users = snapshot.data ?? [];
    return ListView.builder(
      itemCount: users.length,
      itemBuilder: (context, index) => Text(users[index]['username']),
    );
  },
);
```

<a id="quick-start-memory"></a>
### Modo de memoria

Para escenarios como almacenamiento en caché, cálculo temporal o cargas de trabajo que no necesitan persistencia en el disco, puede inicializar una base de datos pura en memoria a través de `ToStore.memory()`. En este modo, todos los datos, incluidos esquemas, índices y pares clave-valor, residen completamente en la memoria para lograr el máximo rendimiento de lectura/escritura.

#### 💡 También funciona como Gestión del Estado Global
No necesita un montón de variables globales ni un marco de gestión estatal pesado. Al combinar el modo de memoria con `watchValue` o `watch()`, puede lograr una actualización de la interfaz de usuario completamente automática en todos los widgets y páginas. Mantiene las poderosas capacidades de recuperación de una base de datos y al mismo tiempo le brinda una experiencia reactiva mucho más allá de las variables ordinarias, lo que lo hace ideal para el estado de inicio de sesión, la configuración en vivo o los contadores de mensajes globales.

> [!CAUTION]
> **Nota**: Los datos creados en el modo de memoria pura se pierden por completo después de cerrar o reiniciar la aplicación. No lo utilice para datos comerciales principales.

```dart
// Initialize a pure in-memory database
final memDb = await ToStore.memory();

// Set a global state value (for example: unread message count)
await memDb.setValue('unread_count', 5, isGlobal: true);

// Listen from anywhere in the UI without passing parameters around
memDb.watchValue<int>('unread_count', isGlobal: true).listen((count) {
  print('UI automatically sensed the message count change: $count');
});

// All CRUD, KV access, and vector search run at in-memory speed
await memDb.insert('active_users', {'name': 'Marley', 'status': 'online'});
```


<a id="schema-definition"></a>
## Definición del esquema
**Defina una vez y deje que el motor maneje la gobernanza automatizada de extremo a extremo para que su aplicación ya no requiera un mantenimiento de validación pesado.**

Los siguientes ejemplos de dispositivos móviles, del lado del servidor y de agentes reutilizan `appSchemas` definido aquí.


### Descripción general del esquema de tabla

```dart
const userSchema = TableSchema(
  name: 'users', // Table name, required
  tableId: 'users', // Unique identifier of the table, optional
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // Primary key field name, defaults to id
    type: PrimaryKeyType.sequential, // Primary key auto-generation strategy
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, // Initial value for sequential IDs
      increment: 1, // Step size
      useRandomIncrement: false, // Whether to use random step sizes
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username', // Field name, required
      type: DataType.text, // Field data type, required
      nullable: false, // Whether null is allowed
      minLength: 3, // Minimum length
      maxLength: 32, // Maximum length
      unique: true, // Whether it must be unique
      fieldId: 'username', // Stable field identifier, optional, used to detect field renames
      comment: 'Login name', // Optional comment
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0, // Minimum numeric value
      maxValue: 150, // Maximum numeric value
      defaultValue: 0, // Static default value
      createIndex: true, // Shortcut for creating an index
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // Automatically fill with current time
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at', // Optional index name
      fields: ['status', 'created_at'], // Composite index fields
      unique: false, // Whether it is a unique index
      type: IndexType.btree, // Index type: btree/hash/bitmap/vector
    ),
  ],
  foreignKeys: const [], // Optional foreign-key constraints; see "Foreign Keys & Cascading"
  isGlobal: false, // Whether this is a global table; true means it can be shared across spaces
  ttlConfig: null, // Optional table-level TTL; see "Table-level TTL"
);

const appSchemas = [userSchema];
```

- **Asignaciones `DataType` comunes**:
  | Tipo | Tipo de dardo correspondiente | Descripción |
  | :--- | :--- | :--- |
| `integer` | `int` | Entero estándar, adecuado para ID, contadores y datos similares |
  | `bigInt` | `BigInt` / `String` | Enteros grandes; recomendado cuando los números superan los 18 dígitos para evitar pérdida de precisión |
  | `double` | `double` | Número de coma flotante, adecuado para precios, coordenadas y datos similares |
  | `text` | `String` | Cadena de texto con restricciones de longitud opcionales |
  | `blob` | `Uint8List` | Datos binarios sin procesar |
  | `boolean` | `bool` | Valor booleano |
  | `datetime` | `DateTime` / `String` | Fecha/hora; almacenado internamente como ISO8601 |
  | `array` | `List` | Tipo de lista o matriz |
  | `json` | `Map<String, dynamic>` | Objeto JSON, adecuado para datos estructurados dinámicos |
  | `vector` | `VectorData` / `List<num>` | Datos vectoriales de alta dimensión para la recuperación semántica de IA (incrustaciones) |

- **`PrimaryKeyType` estrategias de generación automática**:
  | Estrategia | Descripción | Características |
  | :--- | :--- | :--- |
| `none` | Sin generación automática | Debe proporcionar manualmente la clave principal durante la inserción |
  | `sequential` | Incremento secuencial | Bueno para identificaciones amigables para humanos, pero menos adecuado para rendimiento distribuido |
  | `timestampBased` | Basado en marca de tiempo | Recomendado para entornos distribuidos |
  | `datePrefixed` | Con prefijo de fecha | Útil cuando la legibilidad de la fecha es importante para el negocio |
  | `shortCode` | Clave primaria de código corto | Compacto y adecuado para pantalla externa |

> Todas las claves principales se almacenan como `text` (`String`) de forma predeterminada.


### Restricciones y validación automática

Puede escribir reglas de validación comunes directamente en `FieldSchema`, evitando la lógica duplicada en el código de la aplicación:

- `nullable: false`: restricción no nula
- `minLength` / `maxLength`: restricciones de longitud del texto
- `minValue` / `maxValue`: restricciones de rango de números enteros o de punto flotante
- `defaultValue` / `defaultValueType`: valores predeterminados estáticos y valores predeterminados dinámicos
- `unique`: restricción única
- `createIndex`: crea índices para filtrado, clasificación o relaciones de alta frecuencia
- `fieldId` / `tableId`: ayuda a la detección de cambio de nombre para campos y tablas durante la migración

Además, `unique: true` crea automáticamente un índice único de un solo campo. `createIndex: true` y las claves externas crean automáticamente índices normales de un solo campo. Utilice `indexes` cuando necesite índices compuestos, índices con nombre o índices vectoriales.


### Elegir un método de integración

- **Móvil/Escritorio**: mejor cuando se pasa `appSchemas` directamente a `ToStore.open(...)`
- **Servidor/Agente**: mejor cuando se crean esquemas dinámicamente en tiempo de ejecución a través de `createTables(appSchemas)`


<a id="mobile-integration"></a>
## Integración para dispositivos móviles, de escritorio y otros escenarios de inicio frecuentes

📱 **Ejemplo**: [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// On Android/iOS, resolve the app's writable directory first, then pass dbPath explicitly
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

// Reuse the appSchemas defined above
final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// Multi-space architecture - isolate data for different users
await db.switchSpace(spaceName: 'user_123');
```

### Evolución del esquema

Durante `ToStore.open()`, el motor detecta automáticamente cambios estructurales en `schemas`, como agregar, eliminar, cambiar el nombre o cambiar tablas y campos, así como cambios de índice, y luego completa el trabajo de migración necesario. No es necesario mantener manualmente los números de versión de la base de datos ni escribir scripts de migración.


### Mantener el estado de inicio de sesión y cierre de sesión (espacio activo)

El espacio múltiple es ideal para **aislar datos de usuario**: un espacio por usuario, activado al iniciar sesión. Con **Active Space** y las opciones de cierre, puedes mantener al usuario actual durante los reinicios de la aplicación y admitir un comportamiento de cierre de sesión limpio.

- **Mantener estado de inicio de sesión**: después de cambiar a un usuario a su propio espacio, marque ese espacio como activo. El próximo lanzamiento puede ingresar a ese espacio directamente al abrir la instancia predeterminada, sin un paso de "predeterminado primero, luego cambiar".
- **Cerrar sesión**: Cuando el usuario cierre sesión, cierre la base de datos con `keepActiveSpace: false`. El próximo lanzamiento no ingresará automáticamente al espacio del usuario anterior.

```dart
// After login: switch to the user's space and mark it active
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Optional: strictly stay in default when needed (for example, login screen only)
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// On logout: close and clear the active space so the next launch starts from default
await db.close(keepActiveSpace: false);
```


<a id="server-integration"></a>
## Integración del lado del servidor/agente (escenarios de larga duración)

🖥️ **Ejemplo**: [server_quickstart.dart](../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Create table structures while the process is running
await db.createTables(appSchemas);

// Online schema updates
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // Rename table
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // Modify field attributes
  .renameField('old_name', 'new_name')     // Rename field
  .removeField('deprecated_field')         // Remove field
  .addField('created_at', type: DataType.datetime)  // Add field
  .removeIndex(fields: ['age'])            // Remove index
  .setPrimaryKeyConfig(                    // Change PK type; existing data must be empty or a warning will be issued
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );

// Monitor migration progress
final status = await db.queryMigrationTaskStatus(taskId);
print('Migration progress: ${status?.progressPercentage}%');


// Optional performance tuning for pure server workloads
// yieldDurationMs controls how often long-running work yields time slices.
// The default is tuned to 8ms to keep frontend UI animations smooth.
// In environments without UI, 50ms is recommended for higher throughput.
final dbServer = await ToStore.open(
  config: DataStoreConfig(yieldDurationMs: 50),
);
```


<a id="advanced-usage"></a>
## Uso avanzado

ToStore proporciona un amplio conjunto de capacidades avanzadas para escenarios empresariales complejos:


<a id="vector-advanced"></a>
### Campos vectoriales, índices vectoriales y búsqueda de vectores

```dart
await db.createTables([
  const TableSchema(
    name: 'embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,
    ),
    fields: [
      FieldSchema(
        name: 'document_title',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'embedding',
        type: DataType.vector, // Declare a vector field
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: 128, // Written and queried vectors must match this width
          precision: VectorPrecision.float32, // float32 usually balances precision and storage well
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'], // Field to index
        type: IndexType.vector, // Build a vector index
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh, // Built-in vector index type
          distanceMetric: VectorDistanceMetric.cosine, // Good for normalized embeddings
          maxDegree: 32, // More neighbors usually improve recall at higher memory cost
          efSearch: 64, // Higher recall but slower queries
          constructionEf: 128, // Higher-quality index but slower build time
        ),
      ),
    ],
  ),
]);

final queryVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.01)); // Must match dimensions

// Vector search
final results = await db.vectorSearch(
  'embeddings',
  fieldName: 'embedding',
  queryVector: queryVector,
  topK: 5, // Return the top 5 nearest records
  efSearch: 64, // Override the search expansion factor for this request
);

for (final r in results) {
  print('pk=${r.primaryKey}, score=${r.score}, distance=${r.distance}');
}
```

Notas de parámetros:

- `dimensions`: debe coincidir con el ancho de incrustación real que escribe
- `precision`: las opciones comunes incluyen `float64`, `float32` y `int8`; Una mayor precisión generalmente cuesta más almacenamiento.
- `distanceMetric`: `cosine` es común para incrustaciones semánticas, `l2` se adapta a la distancia euclidiana y `innerProduct` se adapta a la búsqueda de productos escalares.
- `maxDegree`: límite superior de vecinos retenidos por nodo en el gráfico NGH; Los valores más altos generalmente mejoran la recuperación a costa de más memoria y tiempo de construcción.
- `efSearch`: ancho de expansión del tiempo de búsqueda; aumentarlo generalmente mejora la recuperación pero aumenta la latencia
- `constructionEf`: ancho de expansión en tiempo de construcción; aumentarlo generalmente mejora la calidad del índice pero aumenta el tiempo de construcción
- `topK`: número de resultados a devolver

Notas de resultados:

- `score`: puntuación de similitud normalizada, normalmente en el rango `0 ~ 1`; más grande significa más similar
- `distance`: valor de distancia; para `l2` y `cosine`, más pequeño generalmente significa más similar

<a id="ttl-config"></a>
### TTL a nivel de tabla (vencimiento automático basado en tiempo)

Para registros, telemetría, eventos y otros datos que deberían caducar con el tiempo, puede definir TTL a nivel de tabla a través de `ttlConfig`. El motor limpiará automáticamente los registros caducados en segundo plano:

```dart
const TableSchema(
  name: 'event_logs',
  fields: [
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      createIndex: true,
      defaultValueType: DefaultValueType.currentTimestamp,
    ),
  ],
  ttlConfig: TableTtlConfig(
    ttlMs: 7 * 24 * 60 * 60 * 1000, // Keep for 7 days
    // When sourceField is omitted, the engine creates the needed index automatically.
    // Optional custom sourceField requirements:
    // 1) type must be DataType.datetime
    // 2) nullable must be false
    // 3) defaultValueType must be DefaultValueType.currentTimestamp
    // sourceField: 'created_at',
  ),
);
```


### Almacenamiento inteligente (Upsert)
ToStore decide si actualizar o insertar según la clave principal o la clave única incluida en `data`. `where` no es compatible aquí; el objetivo del conflicto está determinado por los propios datos.

```dart
// By primary key
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// By unique key (the record must contain all fields from a unique index plus required fields)
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// Batch upsert (supports atomic mode or partial-success mode)
// allowPartialErrors: true means some rows may fail while others still succeed
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


<a id="query-advanced"></a>
### Consultas avanzadas

ToStore proporciona una API de consulta declarativa encadenable con manejo de campos flexible y relaciones complejas entre tablas múltiples.

#### 1. Selección de campo (`select`)
El método `select` especifica qué campos se devuelven. Si no lo llama, todos los campos se devuelven de forma predeterminada.
- **Aliases**: admite la sintaxis `field as alias` (no distingue entre mayúsculas y minúsculas) para cambiar el nombre de las claves en el conjunto de resultados.
- **Campos calificados para tabla**: en combinaciones de varias tablas, `table.field` evita conflictos de nombres
- **Mezcla de agregación**: los objetos `Agg` se pueden colocar directamente dentro de la lista `select`

```dart
final results = await db.query('orders')
    .select([
      'orders.id',
      'users.name as customer_name',
      'orders.amount',
      Agg.count('id', alias: 'total_items')
    ])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

#### 2. Se une (`join`)
Admite `join` estándar (unión interna), `leftJoin` y `rightJoin`.

#### 3. Uniones inteligentes basadas en claves externas (recomendado)
Si `foreignKeys` está definido correctamente en `TableSchema`, no es necesario escribir a mano las condiciones de unión. El motor puede resolver relaciones de referencia y generar automáticamente la ruta JOIN óptima.

- **`joinReferencedTable(tableName)`**: se une automáticamente a la tabla principal a la que hace referencia la tabla actual
- **`joinReferencingTable(tableName)`**: une automáticamente tablas secundarias que hacen referencia a la tabla actual

```dart
// Assume posts defines a foreign key to users
final posts = await db.query('posts')
    .joinReferencedTable('users') // Automatically resolves to ON posts.user_id = users.id
    .select(['posts.title', 'users.username'])
    .limit(20);
```

---

<a id="aggregation-stats"></a>
### Agregación, agrupación y estadísticas (Agg y GroupBy)

#### 1. Agregación (`Agg` fábrica)
Las funciones agregadas calculan estadísticas sobre un conjunto de datos. Con el parámetro `alias`, puede personalizar los nombres de los campos de resultados.

| Método | Propósito | Ejemplo |
| :--- | :--- | :--- |
| `Agg.count(field)` | Contar registros no nulos | `Agg.count('id', alias: 'total')` |
| `Agg.sum(field)` | Valores de suma | `Agg.sum('amount', alias: 'total_price')` |
| `Agg.avg(field)` | Valor medio | `Agg.avg('score', alias: 'average_score')` |
| `Agg.max(field)` | Valor máximo | `Agg.max('age')` |
| `Agg.min(field)` | Valor mínimo | `Agg.min('price')` |

> [!TIP]
> **Dos estilos de agregación comunes**
> 1. **Métodos de acceso directo (recomendados para métricas individuales)**: llame directamente a la cadena y obtenga el valor calculado inmediatamente.
> `num? totalAge = await db.query('users').sum('age');`
> 2. **Incrustado en `select` (para múltiples métricas o agrupaciones)**: pase objetos `Agg` a la lista `select`.
> `final stats = await db.query('orders').select(['status', Agg.sum('amount')]).groupBy(['status']);`

#### 2. Agrupación y filtrado (`groupBy` / `having`)
Utilice `groupBy` para categorizar registros, luego `having` para filtrar resultados agregados, similar al comportamiento HAVING de SQL.

```dart
final stats = await db.query('orders')
    .select([
      'status',
      Agg.sum('amount', alias: 'sum_amount'),
      Agg.count('id', alias: 'order_count')
    ])
    .groupBy(['status'])
    // having accepts a QueryCondition used to filter aggregated results
    .having(QueryCondition().where(Agg.sum('amount'), '>', 5000))
    .limit(10);
```

#### 3. Métodos de consulta auxiliar
- **`exists()` (alto rendimiento)**: comprueba si algún registro coincide. A diferencia de `count() > 0`, produce un cortocircuito tan pronto como se encuentra una coincidencia, lo cual es excelente para conjuntos de datos muy grandes.
- **`count()`**: devuelve eficientemente el número de registros coincidentes.
- **`first()`**: un método conveniente equivalente a `limit(1)` y que devuelve la primera fila directamente como `Map`.
- **`distinct([fields])`**: deduplica resultados. Si se proporciona `fields`, la unicidad se calcula en función de esos campos.

```dart
// Efficient existence check
if (await db.query('users').whereEqual('email', 'test@test.com').exists()) {
  print('Email is already registered');
}

// Get a deduplicated city list
final cities = await db.query('users').distinct(['city']);
```

<a id="query-condition"></a>
#### 4. Lógica compleja con `QueryCondition`
`QueryCondition` es la herramienta principal de ToStore para la lógica anidada y la construcción de consultas entre paréntesis. Cuando las simples llamadas `where` encadenadas no son suficientes para expresiones como `(A AND B) OR (C AND D)`, esta es la herramienta a utilizar.

- **`condition(QueryCondition sub)`**: abre un grupo anidado `AND`
- **`orCondition(QueryCondition sub)`**: abre un grupo anidado `OR`
- **`or()`**: cambia el siguiente conector a `OR` (el valor predeterminado es `AND`)

##### Ejemplo 1: Condiciones O mixtas
SQL equivalente: `WHERE is_active = true AND (role = 'admin' OR fans >= 1000)`

```dart
final subGroup = QueryCondition()
    .whereEqual('role', 'admin')
    .or()
    .whereGreaterThanOrEqualTo('fans', 1000);

final results = await db.query('users')
    .whereEqual('is_active', true)
    .condition(subGroup);
```

##### Ejemplo 2: Fragmentos de condición reutilizables
Puede definir fragmentos de lógica empresarial reutilizables una vez y combinarlos en diferentes consultas:

```dart
final hotUser = QueryCondition().whereGreaterThan('fans', 5000);
final recentLogin = QueryCondition().whereGreaterThan('last_login', '2024-01-01');

final targetUsers = await db.query('users')
    .condition(hotUser)
    .condition(recentLogin);
```


<a id="streaming-query"></a>
#### 5. Consulta de transmisión
Adecuado para conjuntos de datos muy grandes cuando no desea cargar todo en la memoria a la vez. Los resultados se pueden procesar a medida que se leen.

```dart
db.streamQuery('users').listen((data) {
  print('Processing one record: $data');
});
```

<a id="reactive-query"></a>
#### 6. Consulta reactiva
El método `watch()` le permite monitorear los resultados de la consulta en tiempo real. Devuelve un `Stream` y vuelve a ejecutar automáticamente la consulta cada vez que los datos coincidentes cambian en la tabla de destino.
- **Antirrebote automático**: el antirrebote inteligente integrado evita ráfagas redundantes de consultas
- **Sincronización de UI**: funciona naturalmente con Flutter `StreamBuilder` para listas de actualización en vivo

```dart
// Simple listener
db.query('users').whereEqual('is_online', true).watch().listen((users) {
  print('Online user count changed: ${users.length}');
});

// Flutter StreamBuilder integration example
// Local UI refreshes automatically when data changes
StreamBuilder<List<Map<String, dynamic>>>(
  stream: db.query('messages').orderByDesc('id').limit(50).watch(),
  builder: (context, snapshot) {
    if (snapshot.hasData) {
      return ListView.builder(
        itemCount: snapshot.data!.length,
        itemBuilder: (context, index) => MessageTile(snapshot.data![index]),
      );
    }
    return CircularProgressIndicator();
  },
)
```

---

<a id="query-cache"></a>
### Almacenamiento en caché de resultados de consultas manuales (opcional)

> [!IMPORTANT]
> **ToStore ya incluye internamente un eficiente caché LRU inteligente de múltiples niveles.**
> **No se recomienda la administración de caché manual de rutina.** Considérelo solo en casos especiales:
> 1. Análisis completos costosos de datos no indexados que rara vez cambian
> 2. Requisitos persistentes de latencia ultrabaja incluso para consultas no activas

- `useQueryCache([Duration? expiry])`: habilita el caché y opcionalmente establece una caducidad
- `noQueryCache()`: deshabilita explícitamente el caché para esta consulta
- `clearQueryCache()`: invalida manualmente el caché para este patrón de consulta

```dart
final results = await db.query('heavy_table')
    .where('non_indexed_field', '=', 'value')
    .useQueryCache(const Duration(minutes: 10)); // Manual acceleration for a heavy query only
```


<a id="query-pagination"></a>
### Consulta y paginación eficiente

> [!TIP]
> **Especifique siempre `limit` para obtener el mejor rendimiento**: se recomienda encarecidamente proporcionar `limit` explícitamente en cada consulta. Si se omite, el motor tiene por defecto 1000 filas. El motor de consulta principal es rápido, pero serializar conjuntos de resultados muy grandes en la capa de aplicación aún puede agregar una sobrecarga innecesaria.

ToStore proporciona dos modos de paginación para que pueda elegir según las necesidades de escala y rendimiento:

#### 1. Paginación básica (modo de compensación)
Adecuado para conjuntos de datos relativamente pequeños o casos en los que necesita saltos de página precisos.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Skip the first 40 rows
    .limit(20); // Take 20 rows
```
> [!TIP]
> Cuando `offset` se vuelve muy grande, la base de datos debe escanear y descartar muchas filas, por lo que el rendimiento cae linealmente. Para una paginación profunda, prefiera **Modo Cursor**.

#### 2. Paginación del cursor (modo cursor)
Ideal para conjuntos de datos masivos y desplazamiento infinito. Al utilizar `nextCursor`, el motor continúa desde la posición actual y evita el costo adicional de escaneo que conlleva las compensaciones profundas.

> [!IMPORTANT]
> Para algunas consultas complejas u ordenaciones en campos no indexados, el motor puede recurrir a un escaneo completo y devolver un cursor `null`, lo que significa que la paginación no es compatible actualmente para esa consulta específica.

```dart
// First page
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Use the returned cursor to fetch the next page
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Seek directly to the next position
}

// Likewise, prevCursor enables efficient backward paging
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Característica | Modo de compensación | Modo cursor |
| :--- | :--- | :--- |
| **Rendimiento de consultas** | Se degrada a medida que las páginas se profundizan | Estable para paginación profunda |
| **Mejor para** | Conjuntos de datos más pequeños, saltos de página exactos | **Conjuntos de datos masivos, desplazamiento infinito** |
| **Coherencia bajo cambios** | Los cambios de datos pueden provocar que se omitan filas | Evita duplicados y omisiones provocados por cambios de datos |


<a id="foreign-keys"></a>
### Claves externas y cascada

Las claves externas garantizan la integridad referencial y le permiten configurar actualizaciones y eliminaciones en cascada. Las relaciones se validan al escribir y actualizar. Si las políticas en cascada están habilitadas, los datos relacionados se actualizan automáticamente, lo que reduce el trabajo de coherencia en el código de la aplicación.

```dart
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(name: 'id'),
    fields: [
      FieldSchema(name: 'username', type: DataType.text, nullable: false),
    ],
  ),
  TableSchema(
    name: 'posts',
    primaryKeyConfig: const PrimaryKeyConfig(name: 'id'),
    fields: [
      const FieldSchema(name: 'title', type: DataType.text, nullable: false),
      const FieldSchema(name: 'user_id', type: DataType.integer, nullable: false),
      const FieldSchema(name: 'content', type: DataType.text),
    ],
    foreignKeys: [
        ForeignKeySchema(
          name: 'fk_posts_user',
          fields: ['user_id'],              // Field in the current table
          referencedTable: 'users',         // Referenced table
          referencedFields: ['id'],         // Referenced field
          onDelete: ForeignKeyCascadeAction.cascade,  // Delete posts automatically when the user is deleted
          onUpdate: ForeignKeyCascadeAction.cascade,  // Cascade updates
        ),
    ],
  ),
]);
```


<a id="query-operators"></a>
### Operadores de consulta

Todas las condiciones `where(field, operator, value)` admiten los siguientes operadores (no distingue entre mayúsculas y minúsculas):

| Operador | Descripción | Ejemplo / Rendimiento |
| :--- | :--- | :--- |
| `=` | Igual | `where('status', '=', 'val')` — **[Recomendado]** Búsqueda por índice (Seek) |
| `!=`, `<>` | No es igual | `where('role', '!=', 'val')` — **[Precaución]** Escaneo completo de tabla |
| `>` , `>=`, `<`, `<=` | Comparación de rango | `where('age', '>', 18)` — **[Recomendado]** Escaneo por índice |
| `IN` | Incluido en | `where('id', 'IN', [...])` — **[Recomendado]** Búsqueda por índice (Seek) |
| `NOT IN` | No incluido en | `where('status', 'NOT IN', [...])` — **[Precaución]** Escaneo completo de tabla |
| `BETWEEN` | Rango | `where('age', 'BETWEEN', [18, 65])` — **[Recomendado]** Escaneo por índice |
| `LIKE` | Coincidencia de patrón (`%` = cualquier carácter, `_` = un solo carácter) | `where('name', 'LIKE', 'John%')` — **[Precaución]** Ver nota abajo |
| `NOT LIKE` | Patrón no coincidente | `where('email', 'NOT LIKE', '...')` — **[Precaución]** Escaneo completo de tabla |
| `IS` | Es null | `where('deleted_at', 'IS', null)` — **[Recomendado]** Búsqueda por índice (Seek) |
| `IS NOT` | No es null | `where('email', 'IS NOT', null)` — **[Precaución]** Escaneo completo de tabla |

### Métodos de consulta semántica (recomendados)

Recomendado para evitar cadenas de operadores escritas a mano y para obtener una mejor asistencia IDE.

#### 1. Comparación
Se utiliza para comparaciones directas numéricas o de cadenas.

```dart
db.query('users').whereEqual('username', 'John');           // Equal
db.query('users').whereNotEqual('role', 'guest');          // Not equal
db.query('users').whereGreaterThan('age', 18);             // Greater than
db.query('users').whereGreaterThanOrEqualTo('score', 60);  // Greater than or equal
db.query('users').whereLessThan('price', 100);             // Less than
db.query('users').whereLessThanOrEqualTo('quantity', 10);  // Less than or equal
db.query('users').whereTrue('is_active');                  // Is true
db.query('users').whereFalse('is_banned');                 // Is false
```

#### 2. Colección y gama
Se utiliza para probar si un campo se encuentra dentro de un conjunto o rango.

```dart
db.query('users').whereIn('id', ['id1', 'id2']);                 // In list
db.query('users').whereNotIn('status', ['banned', 'pending']);   // Not in list
db.query('users').whereBetween('age', 18, 65);                   // In range (inclusive)
```

#### 3. Verificación nula
Se utiliza para probar si un campo tiene un valor.

```dart
db.query('users').whereNull('deleted_at');    // Is null
db.query('users').whereNotNull('email');      // Is not null
db.query('users').whereEmpty('nickname');     // Is null or empty string
db.query('users').whereNotEmpty('bio');       // Is not null and not empty
```

#### 4. Coincidencia de patrones
Admite búsqueda con comodines de estilo SQL (`%` coincide con cualquier número de caracteres, `_` coincide con un solo carácter).

```dart
db.query('users').whereLike('name', 'John%');                        // SQL-style pattern match
db.query('users').whereContains('bio', 'flutter');                   // Contains match (LIKE '%value%')
db.query('users').whereStartsWith('name', 'Admin');                  // Prefix match (LIKE 'value%')
db.query('users').whereEndsWith('email', '.com');                    // Suffix match (LIKE '%value')
db.query('users').whereContainsAny('tags', ['dart', 'flutter']);     // Fuzzy match against any item in the list
```

```dart
// Equivalent to: .where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```

> [!CAUTION]
> **Guía de Rendimiento de Consultas (Índice vs Escaneo Completo)**
>
> En escenarios de datos a gran escala (millones de filas o más), siga estos principios para evitar retrasos en el hilo principal y tiempos de espera de consulta:
>
> 1. **Optimizado por índice - [Recomendado]**:
>    *   **Métodos semánticos**: `whereEqual`, `whereGreaterThan`, `whereLessThan`, `whereIn`, `whereBetween`, `whereNull`, `whereTrue`, `whereFalse` y **`whereStartsWith`** (coincidencia de prefijo).
>    *   **Operadores**: `=`, `>`, `<`, `>=`, `<=`, `IN`, `BETWEEN`, `IS null`, `LIKE 'prefix%'`.
>    *   *Explicación: Estas operaciones logran un posicionamiento ultrarrápido a través de índices. Para `whereStartsWith` / `LIKE 'abc%'`, el índice aún puede realizar un escaneo de rango de prefijo.*
>
> 2. **Riesgos de escaneo completo - [Precaución]**:
>    *   **Coincidencia difusa**: `whereContains` (`LIKE '%val%'`), `whereEndsWith` (`LIKE '%val'`), `whereContainsAny`.
>    *   **Consultas de negación**: `whereNotEqual` (`!=`, `<>`), `whereNotIn` (`NOT IN`), `whereNotNull` (`IS NOT null`/`whereNotEmpty`).
>    *   **Patrón no coincidente**: `NOT LIKE`.
>    *   *Explicación: Las operaciones anteriores generalmente requieren recorrer toda el área de almacenamiento de datos incluso si se ha creado un índice. Si bien el impacto es mínimo en dispositivos móviles o conjuntos de datos pequeños, en escenarios de análisis de datos distribuidos o de tamaño ultra grande, deben usarse con precaución, combinadas con otras condiciones de índice (por ejemplo, filtrar por ID o rango de tiempo) y la cláusula `limit`.*

<a id="distributed-architecture"></a>
## Arquitectura distribuida

```dart
// Configure distributed nodes
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,            // Enable distributed mode
      clusterId: 1,                       // Cluster ID
      centralServerUrl: 'https://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// Batch insert
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... efficient one-shot insertion of vector records
]);

// Stream and process large datasets
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Process each result incrementally to avoid loading everything at once
  print(record);
}
```

<a id="primary-key-examples"></a>
## Ejemplos de clave primaria

ToStore proporciona múltiples algoritmos de clave primaria distribuidos para diferentes escenarios comerciales:

- **Clave primaria secuencial** (`PrimaryKeyType.sequential`): `238978991`
- **Clave principal basada en marca de tiempo** (`PrimaryKeyType.timestampBased`): `1306866018836946`
- **Clave principal con prefijo de fecha** (`PrimaryKeyType.datePrefixed`): `20250530182215887631`
- **Clave principal de código corto** (`PrimaryKeyType.shortCode`): `9eXrF0qeXZ`

```dart
// Sequential primary key configuration example
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,      // Starting value
        increment: 50,            // Step size
        useRandomIncrement: true, // Random step size to hide business volume
      ),
    ),
    fields: [/* field definitions */]
  ),
]);
```


<a id="atomic-expressions"></a>
## Expresiones atómicas

El sistema de expresión proporciona actualizaciones de campos atómicos con seguridad de tipos. Todos los cálculos se ejecutan de forma atómica en la capa de la base de datos, evitando conflictos concurrentes:

```dart
// Simple increment: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Complex calculation: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// Multi-layer parentheses: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) *
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Use functions: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Timestamp: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

**Expresiones condicionales (por ejemplo, diferenciar actualización versus inserción en un upsert)**: use `Expr.isUpdate()` / `Expr.isInsert()` junto con `Expr.ifElse` o `Expr.when` para que la expresión se evalúe solo al actualizar o solo al insertar.

```dart
// Upsert: increment on update, set to 1 on insert
// The insert branch can use a plain literal; expressions are only evaluated on the update path
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    1,
  ),
});

// Use Expr.when (single branch, otherwise null)
await db.upsert('orders', {
  'id': orderId,
  'updatedAt': Expr.when(Expr.isUpdate(), Expr.now(), otherwise: Expr.now()),
});
```

<a id="transactions"></a>
## Transacciones

Las transacciones garantizan la atomicidad en múltiples operaciones: o todo tiene éxito o todo se revierte, preservando la coherencia de los datos.

**Características de la transacción**
- múltiples operaciones, todas exitosas o todas revertidas
- el trabajo inacabado se recupera automáticamente después de fallas
- las operaciones exitosas persisten de manera segura

```dart
// Basic transaction - atomically commit multiple operations
final txResult = await db.transaction(() async {
  // Insert a user
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });

  // Atomic update using an expression
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');

  // If any operation fails, all changes are rolled back automatically
});

if (txResult.isSuccess) {
  print('Transaction committed successfully');
} else {
  print('Transaction rolled back: ${txResult.error?.message}');
}

// Automatic rollback on error
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('Business logic error'); // Trigger rollback
}, rollbackOnError: true);
```


<a id="database-maintenance"></a>
### Administración y mantenimiento

Las siguientes API cubren la administración, el diagnóstico y el mantenimiento de bases de datos para el desarrollo de complementos, paneles de administración y escenarios operativos:

- **Gestión de mesa**
  - `createTable(schema)`: crea una única tabla manualmente; útil para la carga de módulos o la creación de tablas de tiempo de ejecución bajo demanda
  - `getTableSchema(tableName)`: recupera la información del esquema definido; útil para la validación automatizada o la generación de modelos de UI
  - `getTableInfo(tableName)`: recupera estadísticas de la tabla de tiempo de ejecución, incluido el recuento de registros, el recuento de índices, el tamaño del archivo de datos, el tiempo de creación y si la tabla es global.
  - `clear(tableName)`: borre todos los datos de la tabla mientras conserva de forma segura el esquema, los índices y las restricciones de claves internas/externas.
  - `dropTable(tableName)`: destruir completamente una tabla y su esquema; no reversible
- **Gestión del espacio**
  - `currentSpaceName`: obtiene el espacio activo actual en tiempo real
  - `listSpaces()`: enumera todos los espacios asignados en la instancia de base de datos actual
  - `getSpaceInfo(useCache: true)`: audita el espacio actual; use `useCache: false` para omitir el caché y leer el estado en tiempo real
  - `deleteSpace(spaceName)`: elimina un espacio específico y todos sus datos, excepto `default` y el espacio activo actual
- **Descubrimiento de instancia**
  - `config`: inspecciona la instantánea `DataStoreConfig` final efectiva de la instancia.
  - `instancePath`: localiza el directorio de almacenamiento físico con precisión
  - `getVersion()` / `setVersion(version)`: control de versiones definido por el negocio para decisiones de migración a nivel de aplicación (no la versión del motor)
- **Mantenimiento**
  - `flush(flushStorage: true)`: fuerza los datos pendientes al disco; si `flushStorage: true`, también se le solicita al sistema que vacíe los buffers de almacenamiento de nivel inferior
  - `deleteDatabase()`: elimina todos los archivos físicos y metadatos de la instancia actual; utilizar con cuidado
- **Diagnóstico**
  - `db.status.memory()`: inspecciona las tasas de aciertos de la caché, el uso de la página de índice y la asignación general del montón
  - `db.status.space()` / `db.status.table(tableName)`: inspeccionar estadísticas en vivo e información de salud para espacios y tablas
  - `db.status.config()`: inspecciona la instantánea de configuración del tiempo de ejecución actual
  - `db.status.migration(taskId)`: realiza un seguimiento del progreso de la migración asincrónica en tiempo real

```dart

final spaces = await db.listSpaces();
final spaceInfo = await db.getSpaceInfo(useCache: false);
final tableSchema = await db.getTableSchema('users');
final tableInfo = await db.getTableInfo('users');

print('spaces: $spaces');
print(spaceInfo.toJson());
print(tableSchema?.toJson());
print(tableInfo?.toJson());

await db.flush();

final memoryInfo = await db.status.memory();
final configInfo = await db.status.config();
print(memoryInfo.toJson());
print(configInfo.toJson());
```


<a id="backup-restore"></a>
### Copia de seguridad y restauración

Especialmente útil para la importación/exportación local de un solo usuario, grandes migraciones de datos fuera de línea y reversión del sistema después de una falla:

- **Copia de seguridad (`backup`)**
  - `compress`: si se habilita la compresión; recomendado y habilitado por defecto
  - `scope`: controla el rango de respaldo
    - `BackupScope.database`: realiza una copia de seguridad de **instancia de base de datos completa**, incluidos todos los espacios y tablas globales
    - `BackupScope.currentSpace`: realiza una copia de seguridad solo del **espacio activo actual**, excluyendo las tablas globales
    - `BackupScope.currentSpaceWithGlobal`: realiza una copia de seguridad del **espacio actual más sus tablas globales relacionadas**, ideal para migración de un solo inquilino o de un solo usuario.
- **Restaurar (`restore`)**
  - `backupPath`: ruta física al paquete de respaldo
  - `cleanupBeforeRestore`: si se deben borrar silenciosamente los datos actuales relacionados antes de la restauración; Se recomienda `true` para evitar estados lógicos mixtos.
  - `deleteAfterRestore`: elimina automáticamente el archivo fuente de la copia de seguridad después de una restauración exitosa

```dart
// Example: export the full data package for the current user
final backupPath = await db.backup(
  compress: true,
  scope: BackupScope.currentSpaceWithGlobal,
);

// Example: restore from a backup package and clean up the source file automatically
final restored = await db.restore(
  backupPath,
  cleanupBeforeRestore: true,
  deleteAfterRestore: true,
);
```

<a id="error-handling"></a>
### Códigos de estado y manejo de errores


ToStore utiliza un modelo de respuesta unificado para operaciones de datos:

- `ResultType`: la enumeración de estado unificada utilizada para la lógica de ramificación
- `result.code`: un código numérico estable correspondiente a `ResultType`
- `result.message`: un mensaje legible que describe el error actual
- `successKeys` / `failedKeys`: listas de claves primarias exitosas y fallidas en operaciones masivas


```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (!result.isSuccess) {
  switch (result.type) {
    case ResultType.notFound:
      print('Target resource does not exist: ${result.message}');
      break;
    case ResultType.notNullViolation:
    case ResultType.validationFailed:
      print('Data validation failed: ${result.message}');
      break;
    case ResultType.primaryKeyViolation:
    case ResultType.uniqueViolation:
      print('Unique constraint conflict: ${result.message}');
      break;
    case ResultType.foreignKeyViolation:
      print('Foreign key constraint failed: ${result.message}');
      break;
    case ResultType.resourceExhausted:
    case ResultType.timeout:
      print('System is busy. Please retry later: ${result.message}');
      break;
    case ResultType.ioError:
    case ResultType.dbError:
      print('Underlying storage error. Please record the logs: ${result.message}');
      break;
    default:
      print('Error type: ${result.type}, code: ${result.code}, message: ${result.message}');
  }
}
```

Ejemplos de códigos de estado comunes:
El éxito regresa `0`; los números negativos indican errores.
- `ResultType.success` (`0`): operación exitosa
- `ResultType.partialSuccess` (`1`): operación masiva parcialmente exitosa
- `ResultType.unknown` (`-1`): error desconocido
- `ResultType.uniqueViolation` (`-2`): conflicto de índice único
- `ResultType.primaryKeyViolation` (`-3`): conflicto de clave primaria
- `ResultType.foreignKeyViolation` (`-4`): la referencia de clave externa no satisface las restricciones
- `ResultType.notNullViolation` (`-5`): falta un campo obligatorio o se pasó un `null` no permitido
- `ResultType.validationFailed` (`-6`): longitud, rango, formato u otra validación fallida
- `ResultType.notFound` (`-11`): la tabla, el espacio o el recurso de destino no existe
- `ResultType.resourceExhausted` (`-15`): recursos del sistema insuficientes; reducir la carga o volver a intentarlo
- `ResultType.dbError` (`-91`): error de base de datos
- `ResultType.ioError` (`-90`): error del sistema de archivos
- `ResultType.timeout` (`-92`): tiempo de espera

### Manejo de resultados de transacciones
```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
  });
});

// txResult.isFailed: transaction failed; txResult.isSuccess: transaction succeeded
if (txResult.isFailed) {
  print('Transaction error type: ${txResult.error?.type}');
  print('Transaction error message: ${txResult.error?.message}');
}
```

Tipos de errores de transacción:
- `TransactionErrorType.operationError`: una operación normal falló dentro de la transacción, como una falla de validación de campo, un estado de recurso no válido u otro error a nivel empresarial
- `TransactionErrorType.integrityViolation`: conflicto de integridad o restricción, como clave primaria, clave única, clave externa o falla no nula
- `TransactionErrorType.timeout`: tiempo de espera
- `TransactionErrorType.io`: error de E/S de almacenamiento subyacente o sistema de archivos
- `TransactionErrorType.conflict`: un conflicto provocó que la transacción fallara
- `TransactionErrorType.userAbort`: cancelación iniciada por el usuario (actualmente no se admite la cancelación manual basada en lanzamientos)
- `TransactionErrorType.unknown`: cualquier otro error


<a id="logging-diagnostics"></a>
### Registrar devolución de llamada y diagnóstico de base de datos

ToStore puede enrutar registros de inicio, recuperación, migración automática y conflictos de restricciones de tiempo de ejecución a la capa empresarial a través de `LogConfig.setConfig(...)`.

- `onLogHandler` recibe todos los registros que pasan los filtros actuales `enableLog` y `logLevel`.
- Llame a `LogConfig.setConfig(...)` antes de la inicialización para que también se capturen los registros generados durante la inicialización y la migración automática.

```dart
  // Configure log parameters or callback
  LogConfig.setConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    publicLabel: 'my_app_db',
    onLogHandler: (message, type, label) {
      // In production, warn/error can be reported to your backend or logging platform
      if (!debugMode && (type == LogType.warn || type == LogType.error)) {
        developer.log(message, name: label);
      }
    },
  );

  final db = await ToStore.open();
```


<a id="security-config"></a>
## Configuración de seguridad

> [!WARNING]
> **Administración de claves**: **`encodingKey`** se puede cambiar libremente y el motor migrará los datos automáticamente, por lo que los datos siguen siendo recuperables. **`encryptionKey`** no debe cambiarse casualmente. Una vez modificados, los datos antiguos no se pueden descifrar a menos que los migre explícitamente. Nunca codifique claves sensibles; Se recomienda obtenerlos de un servicio seguro.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Supported encryption algorithms: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305,

      // Encoding key (can be changed; data will be migrated automatically)
      encodingKey: 'Your-32-Byte-Long-Encoding-Key...',

      // Encryption key for critical data (do not change casually unless you are migrating data)
      encryptionKey: 'Your-Secure-Encryption-Key...',

      // Device binding (path-based binding)
      // When enabled, the key is deeply bound to the database path and device characteristics.
      // Data cannot be decrypted when moved to a different physical path.
      // Advantage: better protection if database files are copied directly.
      // Drawback: if the install path or device characteristics change, data may become unrecoverable.
      deviceBinding: false,
    ),
    // Enable crash recovery logging (Write-Ahead Logging), enabled by default
    enableJournal: true,
    // Whether transactions force data to disk on commit; set false to reduce sync overhead
    persistRecoveryOnCommit: true,
  ),
);
```

### Cifrado de nivel de valor (ToCrypto)

El cifrado de base de datos completa protege todos los datos de tablas e índices, pero puede afectar el rendimiento general. Si solo necesita proteger algunos valores confidenciales, utilice **ToCrypto** en su lugar. Está desacoplado de la base de datos, no requiere ninguna instancia `db` y permite que su aplicación codifique/decodifique valores antes de escribir o después de leer. La salida es Base64, que encaja naturalmente en columnas JSON o TEXTO.

- **`key`** (obligatorio): `String` o `Uint8List`. Si no son 32 bytes, se utiliza SHA-256 para derivar una clave de 32 bytes.
- **`type`** (opcional): tipo de cifrado de `ToCryptoType`, como `ToCryptoType.chacha20Poly1305` o `ToCryptoType.aes256Gcm`. El valor predeterminado es `ToCryptoType.chacha20Poly1305`.
- **`aad`** (opcional): datos adicionales autenticados de tipo `Uint8List`. Si se proporcionan durante la codificación, también se deben proporcionar exactamente los mismos bytes durante la decodificación.

```dart
const key = 'my-secret-key';
// Encode: plaintext -> Base64 ciphertext (can be stored in DB or JSON)
final cipher = ToCrypto.encode('sensitive data', key: key);
// Decode when reading
final plain = ToCrypto.decode(cipher, key: key);

// Optional: bind contextual data with aad (must match during decode)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```


<a id="advanced-config"></a>
## Configuración avanzada explicada (DataStoreConfig)

> [!TIP]
> **Inteligencia de configuración cero**
> ToStore detecta automáticamente la plataforma, las características de rendimiento, la memoria disponible y el comportamiento de E/S para optimizar parámetros como la simultaneidad, el tamaño del fragmento y el presupuesto de caché. **En el 99% de los escenarios empresariales comunes, no es necesario ajustar `DataStoreConfig` manualmente.** Los valores predeterminados ya proporcionan un rendimiento excelente para la plataforma actual.


| Parámetro | Predeterminado | Propósito y recomendación |
| :--- | :--- | :--- |
| **`yieldDurationMs`** | **8ms** | **Recomendación principal.** El intervalo de tiempo utilizado cuando las tareas largas dan resultados. `8ms` se alinea bien con el renderizado de 120 fps/60 fps y ayuda a mantener la interfaz de usuario fluida durante consultas o migraciones grandes. |
| **`maxQueryOffset`** | **10000** | **Protección de consultas.** Cuando `offset` supera este umbral, se genera un error. Esto evita E/S patológicas debido a una paginación con desplazamiento profundo. |
| **`defaultQueryLimit`** | **1000** | **Guarda de recursos.** Se aplica cuando una consulta no especifica `limit`, lo que evita la carga accidental de conjuntos de resultados masivos y posibles problemas de OOM. |
| **`cacheMemoryBudgetMB`** | (automático) | **Gestión de memoria detallada.** Presupuesto total de memoria caché. El motor lo utiliza para impulsar la recuperación de LRU automáticamente. |
| **`enableJournal`** | **verdadero** | **Autorreparación de accidentes.** Cuando está habilitado, el motor puede recuperarse automáticamente después de accidentes o cortes de energía. |
| **`persistRecoveryOnCommit`** | **verdadero** | **Sólida garantía de durabilidad.** Cuando es cierto, las transacciones confirmadas se sincronizan con el almacenamiento físico. Cuando es falso, el vaciado se realiza de forma asíncrona en segundo plano para mejorar la velocidad, con un pequeño riesgo de perder una pequeña cantidad de datos en caso de fallos extremos. |
| **`ttlCleanupIntervalMs`** | **300000** | **Encuesta TTL global.** El intervalo en segundo plano para escanear datos caducados cuando el motor no está inactivo. Los valores más bajos eliminan los datos caducados antes pero cuestan más gastos generales. |
| **`maxConcurrency`** | (automático) | **Control de simultaneidad de cálculo.** Establece el recuento máximo de trabajadores paralelos para tareas intensivas como el cálculo de vectores y el cifrado/descifrado. Generalmente es mejor mantenerlo automático. |

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    yieldDurationMs: 8, // Excellent for frontend UI smoothness; for servers, 50ms is often better
    defaultQueryLimit: 50, // Force a maximum result-set size
    enableJournal: true, // Ensure crash self-healing
  ),
);
```

---

<a id="performance"></a>
## Rendimiento y experiencia

### Puntos de referencia

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore Basic Performance Demo" width="320" />
</p>

- **Demostración de rendimiento básico** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4" target="_blank" rel="noopener">basic-demo.mp4</a>): es posible que la vista previa del GIF no muestre todo. Abra el vídeo para ver la demostración completa. Incluso en dispositivos móviles comunes, el inicio, la paginación y la recuperación permanecen estables y fluidos incluso cuando el conjunto de datos supera los 100 millones de registros.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore Disaster Recovery Stress Test" width="320" />
</p>

- **Prueba de estrés de recuperación ante desastres** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4" target="_blank" rel="noopener">disaster-recovery.mp4</a>): durante las escrituras de alta frecuencia, el proceso se interrumpe intencionalmente una y otra vez para simular fallas y cortes de energía. ToStore puede recuperarse rápidamente.


### Consejos de experiencia

- 📱 **Proyecto de ejemplo**: el directorio `example` incluye una aplicación Flutter completa
- 🚀 **Compilaciones de producción**: empaquetar y probar en modo de lanzamiento; el rendimiento de la versión va mucho más allá del modo de depuración
- ✅ **Pruebas estándar**: las capacidades principales están cubiertas por pruebas estandarizadas


Si ToStore te ayuda, por favor danos un ⭐️
Es una de las mejores formas de apoyar el proyecto. Muchas gracias.


> **Recomendación**: Para el desarrollo de aplicaciones frontend, considere el [marco ToApp](https://github.com/tocreator/toapp), que proporciona una solución completa que automatiza y unifica las solicitudes de datos, la carga, el almacenamiento, el almacenamiento en caché y la presentación.


<a id="more-resources"></a>
## Más recursos

- 📖 **Documentación**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Informe de problemas**: [Problemas de GitHub](https://github.com/tocreator/tostore/issues)
- 💬 **Discusión técnica**: [Discusiones de GitHub](https://github.com/tocreator/tostore/discussions)



