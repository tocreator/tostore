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


## Navegación Rápida

- [¿Por qué ToStore?](#why-tostore) | [Características](#key-features) | [Instalación](#installation) | [Inicio Rápido](#quick-start)
- [Definición de Esquema](#schema-definition) | [Integración Móvil/Escritorio](#mobile-integration) | [Integración Servidor](#server-integration)
- [Vectores y Búsqueda ANN](#vector-advanced) | [TTL a Nivel de Tabla](#ttl-config) | [Consulta y Paginación](#query-pagination) | [Claves Foráneas](#foreign-keys) | [Operadores de Consulta](#query-operators)
- [Arquitectura Distribuida](#distributed-architecture) | [Ejemplos de Claves Primarias](#primary-key-examples) | [Operaciones Atómicas](#atomic-expressions) | [Transacciones](#transactions) | [Administración y Mantenimiento de la Base de Datos](#database-maintenance) | [Respaldo y Restauración](#backup-restore) | [Manejo de Errores](#error-handling) | [Callback de Logs y Diagnóstico de Base de Datos](#logging-diagnostics)
- [Configuración de Seguridad](#security-config) | [Rendimiento](#performance) | [Más Recursos](#more-resources)


<a id="why-tostore"></a>
## ¿Por qué elegir ToStore?

ToStore es un motor de datos moderno diseñado para la era de la AGI y escenarios de inteligencia en el borde (edge intelligence). Soporta de forma nativa sistemas distribuidos, fusión multimodal, datos relacionales estructurados, vectores de alta dimensión y almacenamiento de datos no estructurados. Basado en una arquitectura subyacente similar a una red neuronal, los nodos poseen alta autonomía y escalabilidad horizontal elástica, construyendo una red de topología de datos flexible para una colaboración fluida entre el borde y la nube en múltiples plataformas. Ofrece transacciones ACID, consultas relacionales complejas (JOIN, claves foráneas en cascada), TTL a nivel de tabla y cálculos de agregación. Incluye múltiples algoritmos de claves primarias distribuidas, expresiones atómicas, identificación de cambios en el esquema, protección mediante cifrado, aislamiento de datos en múltiples espacios, programación inteligente de carga sensible a los recursos y recuperación automática ante desastres o fallos.

A medida que el centro de gravedad de la computación continúa desplazándose hacia la inteligencia en el borde, diversos terminales como agentes y sensores ya no son meros "visualizadores de contenido", sino nodos inteligentes responsables de la generación local, percepción del entorno, toma de decisiones en tiempo real y colaboración de datos. Las soluciones de bases de datos tradicionales, limitadas por su arquitectura subyacente y extensiones de tipo "complemento", tienen dificultades para cumplir con los requisitos de baja latencia y estabilidad de las aplicaciones inteligentes en el borde y la nube cuando se enfrentan a escrituras de alta concurrencia, datos masivos, búsqueda vectorial y generación colaborativa.

ToStore empodera al borde con capacidades distribuidas suficientes para soportar datos masivos, generación compleja de IA local y flujos de datos a gran escala. La colaboración inteligente profunda entre los nodos del borde y la nube proporciona una base de datos confiable para escenarios como la fusión inmersiva AR/VR, interacción multimodal, vectores semánticos y modelado espacial.


<a id="key-features"></a>
## Características Clave

- 🌐 **Motor de Datos Multiplataforma Unificado**
  - API unificada para Móvil, Escritorio, Web y Servidor.
  - Soporta datos estructurados relacionales, vectores de alta dimensión y almacenamiento de datos no estructurados.
  - Ideal para ciclos de vida de datos desde el almacenamiento local hasta la colaboración entre el borde y la nube.

- 🧠 **Arquitectura Distribuida Similar a una Red Neuronal**
  - Alta autonomía de los nodos; la colaboración interconectada construye topologías de datos flexibles.
  - Soporta colaboración de nodos y escalabilidad horizontal elástica.
  - Interconexión profunda entre nodos inteligentes en el borde y la nube.

- ⚡ **Ejecución Paralela y Programación de Recursos**
  - Programación inteligente de carga sensible a los recursos con alta disponibilidad.
  - Computación colaborativa paralela multinodo y descomposición de tareas.

- 🔍 **Consulta Estructurada y Búsqueda Vectorial**
  - Soporta consultas de condiciones complejas, JOINs, cálculos de agregación y TTL a nivel de tabla.
  - Soporta campos vectoriales, índices vectoriales y búsqueda de vecinos más cercanos (ANN).
  - Los datos estructurados y vectoriales pueden usarse colaborativamente dentro del mismo motor.

- 🔑 **Claves Primarias, Indexación y Evolución del Esquema**
  - Algoritmos integrados de incremento secuencial, marca de tiempo, prefijo de fecha y código corto.
  - Soporta índices únicos, índices compuestos, índices vectoriales y restricciones de clave foránea.
  - Identifica inteligentemente los cambios en el esquema y automatiza la migración de datos.

- 🛡️ **Transacciones, Seguridad y Recuperación**
  - Ofrece transacciones ACID, actualizaciones de expresiones atómicas y claves foráneas en cascada.
  - Soporta recuperación ante fallos, persistencia en disco y garantías de consistencia de datos.
  - Soporta cifrado ChaCha20-Poly1305 y AES-256-GCM.

- 🔄 **Multi-espacio y Flujo de Trabajo de Datos**
  - Soporta aislamiento de datos mediante Espacios con uso compartido global configurable.
  - Receptores de consultas en tiempo real, caché inteligente de varios niveles y paginación por cursor.
  - Perfecto para aplicaciones multiusuario, de prioridad local y de colaboración sin conexión.


<a id="installation"></a>
## Instalación

> [!IMPORTANT]
> **¿Actualizando desde v2.x?** Lea la [Guía de Actualización v3.x](../UPGRADE_GUIDE_v3.md) para conocer los pasos críticos de migración y los cambios importantes.

Agregue `tostore` como una dependencia en su `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Use la versión más reciente
```

<a id="quick-start"></a>
## Inicio Rápido

> [!TIP]
> **Admite almacenamiento mixto de datos estructurados y no estructurados**
> ¿Cómo elegir el modo de almacenamiento?
> 1. **Datos centrales del negocio**: se recomienda [Definición de Esquema](#schema-definition). Adecuado para escenarios con consultas complejas, validación de restricciones, relaciones o requisitos altos de seguridad. Al llevar la lógica de integridad al motor, se reducen notablemente los costes de desarrollo y mantenimiento en la capa de aplicación.
> 2. **Datos dinámicos/dispersos**: puede usar directamente [Almacenamiento Clave-Valor (KV)](#quick-start) o definir campos `DataType.json` en tablas. Adecuado para acceso a configuración o gestión de estados dispersos, priorizando rapidez de adopción y máxima flexibilidad.

### Modo de tabla estructurada (Table)
Para realizar operaciones CRUD, es necesario crear previamente el esquema de la tabla (véase [Definición de Esquema](#schema-definition)). Recomendaciones según el escenario:
- **Móvil/Escritorio**: para [escenarios de inicio frecuente](#mobile-integration), se recomienda pasar `schemas` al inicializar la instancia.
- **Servidor/Agente**: para [escenarios de ejecución continua](#server-integration), se recomienda crear dinámicamente mediante `createTables`.

```dart
// 1. Inicializar la base de datos
final db = await ToStore.open();

// 2. Insertar datos
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Consultas encadenadas (vea [Operadores de Consulta](#query-operators); soporta =, !=, >, <, LIKE, IN, etc.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. Actualizar y Eliminar
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Escucha en tiempo real (la UI se actualiza automáticamente cuando los datos cambian)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Usuarios coincidentes actualizados: $users');
});
```

### Almacenamiento Clave-Valor (KV)
Adecuado para escenarios que no requieren tablas estructuradas. Es simple y práctico, cuenta con un almacenamiento KV de alto rendimiento integrado para configuración, estado y otros datos dispersos. Los datos en diferentes Espacios están aislados por defecto, pero pueden configurarse para compartirse globalmente.

```dart
// Inicializar la base de datos
final db = await ToStore.open();

// Establecer pares clave-valor (soporta String, int, bool, double, Map, List, etc.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// Obtener datos
final theme = await db.getValue('theme'); // 'dark'

// Eliminar datos
await db.removeValue('theme');

// Clave-valor global (compartido entre Espacios)
// Los datos KV normales se desactivan al cambiar de espacio. Use isGlobal: true para compartir globalmente.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```


<a id="schema-definition"></a>
## Definición de Esquema
**Definir una vez permite que el motor se encargue de la gobernanza automatizada de extremo a extremo y libera a la aplicación del mantenimiento pesado de validaciones a largo plazo.**

Los siguientes ejemplos de móvil, servidor y agente reutilizan `appSchemas` definido aquí.

### Descripción General de TableSchema

```dart
const userSchema = TableSchema(
  name: 'users', // Nombre de la tabla, requerido
  tableId: 'users', // Identificador único, opcional; para detección 100% precisa de renombrado
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // Nombre del campo PK, por defecto 'id'
    type: PrimaryKeyType.sequential, // Tipo de auto-generación
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, // Valor inicial
      increment: 1, // Tamaño del paso
      useRandomIncrement: false, // Si se usan incrementos aleatorios
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username', // Nombre del campo, requerido
      type: DataType.text, // Tipo de dato, requerido
      nullable: false, // Si se permite null
      minLength: 3, // Longitud mínima
      maxLength: 32, // Longitud máxima
      unique: true, // Restricción de unicidad
      fieldId: 'username', // Identificador único de campo, opcional; para identificar cambios de nombre
      comment: 'Nombre de usuario', // Comentario opcional
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0, // Límite inferior
      maxValue: 150, // Límite superior
      defaultValue: 0, // Valor por defecto estático
      createIndex: true,  // Atajo para crear un índice y mejorar el rendimiento
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // Auto-llenado con hora actual
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at', // Nombre de índice opcional
      fields: ['status', 'created_at'], // Campos de índice compuesto
      unique: false, // Si es un índice único
      type: IndexType.btree, // Tipo de índice: btree/hash/bitmap/vector
    ),
  ],
  foreignKeys: const [], // Restricciones de clave foránea opcionales; vea el ejemplo de "Claves Foráneas"
  isGlobal: false, // Si es una tabla global; accesible en todos los Espacios
  ttlConfig: null, // TTL a nivel de tabla; vea el ejemplo de "TTL a Nivel de Tabla"
);

const appSchemas = [userSchema];
```

`DataType` soporta `integer`, `bigInt`, `double`, `text`, `blob`, `boolean`, `datetime`, `array`, `json`, `vector`. `PrimaryKeyType` soporta `none`, `sequential`, `timestampBased`, `datePrefixed`, `shortCode`.

### Restricciones y Auto-validación

Puede escribir reglas de validación comunes directamente en el esquema usando `FieldSchema`, evitando duplicar lógica en la UI o capas de servicio:

- `nullable: false`: Restricción de no nulo.
- `minLength` / `maxLength`: Restricciones de longitud de texto.
- `minValue` / `maxValue`: Restricciones de rango numérico.
- `defaultValue` / `defaultValueType`: Valores por defecto estáticos y dinámicos.
- `unique`: Restricción de unicidad.
- `createIndex`: Crea un índice para filtrado, ordenado o unión de alta frecuencia.
- `fieldId` / `tableId`: Ayuda a identificar campos o tablas renombrados durante la migración.

Estas restricciones se validan en la ruta de escritura de datos, reduciendo la implementación duplicada. `unique: true` genera automáticamente un índice único. `createIndex: true` y las claves foráneas generan automáticamente índices estándar. Use `indexes` para índices compuestos o vectoriales.


### Elección del Método de Integración

- **Móvil/Escritorio**: Lo mejor es pasar `appSchemas` directamente a `ToStore.open(...)`.
- **Servidor**: Lo mejor es crear esquemas dinámicamente en tiempo de ejecución a través de `createTables(appSchemas)`.


<a id="mobile-integration"></a>
## Integración Móvil/Escritorio

📱 **Ejemplo**: [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Android/iOS: Resuelva primero el directorio de escritura, luego páselo como dbPath
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

// Reutilizar appSchemas definidos anteriormente
final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// Arquitectura multi-espacio - Aislamiento de datos de diferentes usuarios
await db.switchSpace(spaceName: 'user_123');
```

### Mantener Estado de Sesión y Cierre (Espacio Activo)

El multi-espacio es ideal para **aislar datos de usuario**: un espacio por usuario, cambiado al iniciar sesión. Usando **Espacio Activo** y **opciones de Cierre**, puede persistir al usuario actual tras reiniciar la app y permitir cierres de sesión limpios.

- **Persistir Estado de Sesión**: Cuando un usuario cambia a su espacio, márquelo como activo. El próximo inicio entrará directamente en ese espacio mediante la apertura por defecto, evitando la secuencia "abrir por defecto y luego cambiar".
- **Cierre de Sesión**: Cuando un usuario cierra sesión, cierre la base de datos con `keepActiveSpace: false`. El próximo inicio no entrará automáticamente al espacio del usuario anterior.

```dart
// Tras Iniciar Sesión: Cambiar al espacio de usuario y marcar como activo (mantener sesión)
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Opcional: Usar estrictamente el espacio por defecto (ej. solo pantalla de login)
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// Al Cerrar Sesión: Cerrar y limpiar el espacio activo para usar el espacio por defecto en el próximo inicio
await db.close(keepActiveSpace: false);
```


<a id="server-integration"></a>
## Integración en Servidor

🖥️ **Ejemplo**: [server_quickstart.dart](../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Crear o validar la estructura de la tabla al iniciar el servicio
await db.createTables(appSchemas);

// Actualizaciones de Esquema en Línea
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // Renombrar tabla
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // Modificar atributos de campo
  .renameField('old_name', 'new_name')     // Renombrar campo
  .removeField('deprecated_field')         // Eliminar campo
  .addField('created_at', type: DataType.datetime)  // Añadir campo
  .removeIndex(fields: ['age'])            // Eliminar índice
  .setPrimaryKeyConfig(                    // Cambiar tipo de PK; los datos deben estar vacíos
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// Monitorear progreso de migración
final status = await db.queryMigrationTaskStatus(taskId);
print('Progreso de Migración: ${status?.progressPercentage}%');


// Gestión Manual de Caché de Consultas (Servidor)
Consultas de igualdad o IN sobre PKs o campos indexados son extremadamente rápidas; la gestión manual de caché rara vez es necesaria.

// Cachear manualmente el resultado de una consulta por 5 minutos. Sin expiración si no se provee duración.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Invalidar caché específica cuando los datos cambian para asegurar la consistencia.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// Deshabilitar explícitamente la caché para consultas que requieren datos en tiempo real.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```


<a id="advanced-usage"></a>
## Uso Avanzado

ToStore ofrece un conjunto de características avanzadas para requisitos empresariales complejos:


<a id="vector-advanced"></a>
### Vectores y Búsqueda ANN

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
        type: DataType.vector,  // Declarar tipo vectorial
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: 128, // Dimensiones; deben coincidir al escribir y consultar
          precision: VectorPrecision.float32, // Precisión; float32 equilibra precisión y espacio
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'], // Campo a indexar
        type: IndexType.vector,  // Construir índice vectorial
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,  // Algoritmo; NGH integrado
          distanceMetric: VectorDistanceMetric.cosine, // Métrica; ideal para embeddings normalizados
          maxDegree: 32, // Máximo de vecinos; mayor valor aumenta recall pero usa más memoria
          efSearch: 64, // Factor de expansión de búsqueda; mayor valor es más preciso pero lento
          constructionEf: 128, // Calidad del índice; mayor valor es mejor pero lento de construir
        ),
      ),
    ],
  ),
]);

final queryVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.01)); // Dimensiones deben coincidir

// Búsqueda Vectorial
final results = await db.vectorSearch(
  'embeddings', 
  fieldName: 'embedding', 
  queryVector: queryVector, 
  topK: 5, // Devolver los mejores 5
  efSearch: 64, // Sobrescribir factor de expansión por defecto
);

for (final r in results) {
  print('pk=${r.primaryKey}, score=${r.score}, distance=${r.distance}');
}
```

**Descripción de Parámetros**:
- `dimensions`: Debe coincidir con el ancho de los embeddings de entrada.
- `precision`: Opcional `float64`, `float32`, `int8`; mayor precisión aumenta costo de almacenamiento.
- `distanceMetric`: `cosine` para similitud semántica, `l2` para distancia Euclídea, `innerProduct` para producto escalar.
- `maxDegree`: Vecinos máximos en el grafo NGH; valores altos mejoran el recall.
- `efSearch`: Ancho de expansión en búsqueda; valores altos mejoran el recall pero añaden latencia.
- `topK`: Número de resultados.

**Descripción de Resultados**:
- `score`: Puntuación normalizada (0 a 1); mayor valor es más similar.
- `distance`: Mayor distancia significa menor similitud en `l2` y `cosine`.


<a id="ttl-config"></a>
### TTL a Nivel de Tabla (Expiración Automática)

Para datos de series temporales como logs, defina `ttlConfig` en el esquema. Los datos expirados se limpian automáticamente en segundo plano:

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
    ttlMs: 7 * 24 * 60 * 60 * 1000, // Mantener por 7 días
    // sourceField: se usa un índice auto-creado si se omite.
    // Requisitos de campo personalizado:
    // 1) DataType.datetime
    // 2) no nulo (nullable: false)
    // 3) DefaultValueType.currentTimestamp
    // sourceField: 'created_at',
  ),
);
```


### Consultas Anidadas y Filtrado Personalizado
Soporta anidamiento infinito y funciones personalizadas flexibles.

```dart
// Anidamiento: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// Función personalizada
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('recomendado') ?? false);
```

### Almacenamiento Inteligente (Upsert)
Actualiza si la PK o clave única existe, de lo contrario inserta. Sin cláusula `where`; el objetivo de conflicto se determina por los datos.

```dart
// Por clave primaria
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// Por clave única (debe incluir todos los campos de un índice único y requeridos)
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// Batch upsert
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### JOINs y Selección de Campos
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### Streaming y Agregación
```dart
// Contar registros
final count = await db.query('users').count();

// Comprobar existencia de tabla (independiente del espacio)
final usersTableDefined = await db.tableExists('users');

// Comprobar existencia eficiente sin carga
final emailExists = await db.query('users')
    .where('email', '=', 'test@example.com')
    .exists();

// Funciones de agregación
final totalAge = await db.query('users').where('age', '>', 18).sum('age');
final avgAge = await db.query('users').avg('age');
final maxAge = await db.query('users').max('age');
final minAge = await db.query('users').min('age');

// Agrupación y Filtrado
final result = await db.query('orders')
    .select(['status', Agg.sum('amount', alias: 'total')])
    .groupBy(['status'])
    .having(Agg.sum('amount'), '>', 1000)
    .limit(20);

// Consulta Distinct
final uniqueCities = await db.query('users').distinct(['city']);

// Streaming (ideal para datos masivos)
db.streamQuery('users').listen((data) => print(data));
```


<a id="query-pagination"></a>
### Consulta y Paginación Eficiente

> [!TIP]
> **Especifique `limit` explícitamente para mejor rendimiento**: Se recomienda encarecidamente. Si se omite, el motor limita por defecto a 1000 registros. Aunque el motor es rápido, serializar lotes grandes en la app puede añadir latencia innecesaria.

ToStore ofrece paginación de modo dual:

#### 1. Modo Offset (Desplazamiento)
Ideal para conjuntos pequeños (<10k registros) o salto específico de página.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Saltarse los primeros 40
    .limit(20); // Tomar 20
```
> [!TIP]
> El rendimiento cae linealmente al aumentar `offset` porque se deben escanear y descartar registros. Use el **Modo Cursor** para paginación profunda.

#### 2. Modo Cursor
**Recomendado para datos masivos y scroll infinito**. Usa `nextCursor` para retomar desde la posición actual, evitando la carga de grandes offsets.

> [!IMPORTANT]
> Para consultas complejas o en campos no indexados, el motor puede recurrir a escaneo total y devolver un cursor `null` (indicando que no se soporta paginación para esa consulta específica).

```dart
// Página 1
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Obtener siguiente página vía cursor
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Busca directamente la posición
}

// Retroceder eficientemente con prevCursor
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Característica | Modo Offset | Modo Cursor |
| :--- | :--- | :--- |
| **Rendimiento** | Cae al aumentar página | **Siempre Constante (O(1))** |
| **Uso** | Datos pequeños, salto de página | **Datos masivos, scroll infinito** |
| **Consistencia** | Cambios pueden causar saltos | **Evita duplicados/omisiones** |


<a id="foreign-keys"></a>
### Claves Foráneas y Cascada

Imponga integridad referencial y configure actualizaciones o eliminaciones en cascada. Las restricciones se verifican al escribir; las políticas de cascada manejan datos relacionados automáticamente, reduciendo lógica de consistencia manual.

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
          fields: ['user_id'],              // Campo tabla actual
          referencedTable: 'users',         // Tabla referenciada
          referencedFields: ['id'],         // Campo referenciado
          onDelete: ForeignKeyCascadeAction.cascade,  // Borrado en cascada
          onUpdate: ForeignKeyCascadeAction.cascade,  // Actualización en cascada
        ),
    ],
  ),
]);
```


<a id="query-operators"></a>
### Operadores de Consulta

Todas las condiciones `where(campo, operador, valor)` soportan estos operadores (insensible a mayúsculas):

| Operador | Descripción | Ejemplo / Tipo de Valor |
| :--- | :--- | :--- |
| `=` | Igual | `where('status', '=', 'active')` |
| `!=`, `<>` | No igual | `where('role', '!=', 'guest')` |
| `>` | Mayor que | `where('age', '>', 18)` |
| `>=` | Mayor o igual | `where('score', '>=', 60)` |
| `<` | Menor que | `where('price', '<', 100)` |
| `<=` | Menor o igual | `where('quantity', '<=', 10)` |
| `IN` | En lista | `where('id', 'IN', ['a','b','c'])` — valor: `List` |
| `NOT IN` | No en lista | `where('status', 'NOT IN', ['banned'])` — valor: `List` |
| `BETWEEN` | Entre rango (inclusive) | `where('age', 'BETWEEN', [18, 65])` — valor: `[inicio, fin]` |
| `LIKE` | Patrón (`%` cualquiera, `_` uno) | `where('name', 'LIKE', '%John%')` — valor: `String` |
| `NOT LIKE` | No coincide con patrón | `where('email', 'NOT LIKE', '%@test.com')` — valor: `String` |
| `IS` | Es nulo | `where('deleted_at', 'IS', null)` — valor: `null` |
| `IS NOT` | No es nulo | `where('email', 'IS NOT', null)` — valor: `null` |

### Métodos de Consulta Semántica (Recomendado)

Evitan cadenas manuales y ofrecen mejor soporte del IDE:

```dart
// Comparación
db.query('users').whereEqual('username', 'John');
db.query('users').whereNotEqual('role', 'guest');
db.query('users').whereGreaterThan('age', 18);
db.query('users').whereGreaterThanOrEqualTo('score', 60);
db.query('users').whereLessThan('price', 100);
db.query('users').whereLessThanOrEqualTo('quantity', 10);

// Conjuntos y Rangos
db.query('users').whereIn('id', ['id1', 'id2']);
db.query('users').whereNotIn('status', ['banned', 'pending']);
db.query('users').whereBetween('age', 18, 65);

// Verificación de nulos
db.query('users').whereNull('deleted_at');
db.query('users').whereNotNull('email');

// Patrones
db.query('users').whereLike('name', '%John%');
db.query('users').whereNotLike('email', '%@temp.');
db.query('users').whereContains('bio', 'flutter');   // LIKE '%flutter%'
db.query('users').whereNotContains('title', 'draft');

// Equivalente a: .where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```


<a id="distributed-architecture"></a>
## Arquitectura Distribuida

```dart
// Configurar Nodos Distribuidos
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,            // Habilitar modo distribuido
      clusterId: 1,                       // ID del cluster
      centralServerUrl: 'https://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// Inserción por Lotes de Alto Rendimiento
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... inserción masiva eficiente
]);

// Stream de Grandes Conjuntos de Datos
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Procesamiento secuencial para evitar picos de memoria
  print(record);
}
```


<a id="primary-key-examples"></a>
## Claves Primarias

ToStore ofrece varios algoritmos de PK distribuida:

- **Secuencial** (PrimaryKeyType.sequential): 238978991
- **Basado en Marca de Tiempo** (PrimaryKeyType.timestampBased): 1306866018836946
- **Prefijo de Fecha** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **Código Corto** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// Ejemplo de Configuración de PK Secuencial
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // Ocultar volumen de negocio
      ),
    ),
    fields: [/* definiciones de campos */]
  ),
]);
```


<a id="atomic-expressions"></a>
## Expresiones Atómicas

Actualizaciones de campo atómicas y seguras al nivel de base de datos para prevenir conflictos:

```dart
// Incremento Simple: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Cálculo Complejo: total = precio * cantidad + tasa
await db.update('orders', {
  'total': (Expr.field('price') * Expr.field('quantity')) + Expr.field('tax'),
}).where('id', '=', orderId);

// Paréntesis Anidados
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Funciones: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Marca de tiempo
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

**Expresiones Condicionales (ej. para Upserts)**: Use `Expr.isUpdate()` / `Expr.isInsert()` con `Expr.ifElse` o `Expr.when`:

```dart
// Upsert: Incrementa en actualización, establece a 1 en inserción
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    1, // rama de inserción: valor literal, ignorado en evaluación
  ),
});

// Usando Expr.when
await db.upsert('orders', {
  'id': orderId,
  'updatedAt': Expr.when(Expr.isUpdate(), Expr.now(), otherwise: Expr.now()),
});
```


<a id="transactions"></a>
## Transacciones

Aseguran que todas las operaciones tengan éxito o todas se reviertan, manteniendo consistencia absoluta.

**Características**:
- Commit atómico de múltiples pasos.
- Recuperación automática tras un fallo.
- Datos persistidos con seguridad tras el commit.

```dart
// Transacción Básica
final txResult = await db.transaction(() async {
  // Insertar usuario
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // Actualización atómica vía expresión
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // Cualquier error aquí revierte todos los cambios automáticamente.
});

if (txResult.isSuccess) {
  print('Transacción confirmada');
} else {
  print('Transacción revertida: ${txResult.error?.message}');
}

// Rollback automático en excepción
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('Fallo de Negocio'); 
}, rollbackOnError: true);
```


<a id="database-maintenance"></a>
### Administración y Mantenimiento de la Base de Datos

Las siguientes APIs se enfocan en administración, diagnóstico y tareas de mantenimiento:

- **Mantenimiento de tablas**
  `createTable(schema)`: Crea una sola tabla en tiempo de ejecución.
  `getTableSchema(tableName)`: Lee la definición de esquema actualmente activa.
  `getTableInfo(tableName)`: Consulta estadísticas de la tabla, como número de registros, índices, tamaño del archivo, fecha de creación y si es global.
  `clear(tableName)`: Elimina todos los datos manteniendo el esquema, los índices y las restricciones.
  `dropTable(tableName)`: Elimina la tabla completa, incluyendo esquema y datos.
- **Gestión de espacios**
  `currentSpaceName`: Obtiene el nombre del espacio activo actual.
  `listSpaces()`: Lista todos los espacios de la instancia actual.
  `getSpaceInfo(useCache: true)`: Obtiene estadísticas del espacio actual; usa `useCache: false` para forzar datos actualizados.
  `deleteSpace(spaceName)`: Elimina un espacio. No se puede eliminar `default` ni el espacio activo actual.
- **Metadatos de la instancia**
  `config`: Lee el `DataStoreConfig` efectivo.
  `instancePath`: Obtiene el directorio final de almacenamiento de la instancia.
  `getVersion()` / `setVersion(version)`: Lee y escribe tu versión de negocio. Este valor no participa en la lógica interna del motor.
- **Operaciones de mantenimiento**
  `flush(flushStorage: true)`: Fuerza el volcado de escrituras pendientes a disco. Cuando es `true`, también vacía los buffers del almacenamiento subyacente.
  `deleteDatabase()`: Elimina la instancia actual de la base de datos y sus archivos. Es una operación destructiva.
- **Entrada unificada de diagnóstico**
  `db.status.memory()`: Revisa el uso de caché y memoria.
  `db.status.space()`: Revisa el estado general del espacio actual.
  `db.status.table(tableName)`: Revisa el diagnóstico de una tabla concreta.
  `db.status.config()`: Revisa la instantánea de la configuración efectiva.
  `db.status.migration(taskId)`: Revisa el estado de una tarea de migración de esquema.

```dart
print('current space: ${db.currentSpaceName}');
print('instance path: ${db.instancePath}');

final spaces = await db.listSpaces();
final spaceInfo = await db.getSpaceInfo(useCache: false);
final tableInfo = await db.getTableInfo('users');

final userVersion = await db.getVersion();
await db.setVersion(userVersion + 1);
await db.flush();

final memoryInfo = await db.status.memory();
print(spaces);
print(spaceInfo.toJson());
print(tableInfo?.toJson());
print(memoryInfo.toJson());
```

Si solo deseas limpiar los datos pero conservar el esquema y los índices, usa `clear(...)`; usa `dropTable(...)` para eliminar la tabla completa. `deleteSpace(...)`, `dropTable(...)` y `deleteDatabase(...)` son operaciones destructivas y deben usarse con cuidado.


<a id="backup-restore"></a>
### Respaldo y Restauración

Adecuado para importación/exportación local, migración de datos de usuario, rollback y snapshots operativos:

- `backup(compress: true, scope: ...)`: Crea un respaldo y devuelve su ruta. `compress: true` genera un paquete comprimido y `scope` controla el alcance.
- `restore(backupPath, deleteAfterRestore: false, cleanupBeforeRestore: true)`: Restaura desde un respaldo. `cleanupBeforeRestore: true` limpia los datos relacionados antes de restaurar para evitar mezclar información antigua y nueva, y `deleteAfterRestore: true` elimina el archivo tras una restauración exitosa.
- `BackupScope.database`: Respalda toda la instancia, incluyendo todos los espacios, tablas globales y metadatos relacionados.
- `BackupScope.currentSpace`: Respalda solo el espacio actual, excluyendo tablas globales.
- `BackupScope.currentSpaceWithGlobal`: Respalda el espacio actual más las tablas globales. Es útil para exportar/importar datos de un solo usuario.

```dart
final backupPath = await db.backup(
  compress: true,
  scope: BackupScope.currentSpaceWithGlobal,
);

final restored = await db.restore(
  backupPath,
  cleanupBeforeRestore: true,
  deleteAfterRestore: false,
);

print(backupPath);
print(restored);
```

Siempre que sea posible, pausa las escrituras de la aplicación antes de restaurar.


<a id="error-handling"></a>
### Manejo de Errores

Modelo de respuesta unificado:
- `ResultType`: Enum estable para lógica de ramificación.
- `result.code`: Código numérico.
- `result.message`: Descripción legible.
- `successKeys` / `failedKeys`: Listas de PKs para operaciones masivas.

```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (!result.isSuccess) {
  switch (result.type) {
    case ResultType.notFound:
      print('No encontrado: ${result.message}');
      break;
    case ResultType.notNullViolation:
    case ResultType.validationFailed:
      print('Validación fallida: ${result.message}');
      break;
    case ResultType.primaryKeyViolation:
    case ResultType.uniqueViolation:
      print('Conflicto: ${result.message}');
      break;
    case ResultType.foreignKeyViolation:
      print('Falló la restricción de clave foránea: ${result.message}');
      break;
    case ResultType.resourceExhausted:
    case ResultType.timeout:
      print('El sistema está ocupado, inténtalo más tarde: ${result.message}');
      break;
    case ResultType.ioError:
    case ResultType.dbError:
      print('Error de almacenamiento, registra el detalle: ${result.message}');
      break;
    default:
      print('Tipo: ${result.type}, Código: ${result.code}, Mensaje: ${result.message}');
  }
}
```

**Códigos de estado comunes**:
El éxito es `0`; los valores negativos indican errores.
- `ResultType.success` (`0`): La operación se completó correctamente.
- `ResultType.partialSuccess` (`1`): Una operación por lotes se completó parcialmente.
- `ResultType.unknown` (`-1`): Error desconocido.
- `ResultType.uniqueViolation` (`-2`): Conflicto con un índice único.
- `ResultType.primaryKeyViolation` (`-3`): Conflicto de clave primaria.
- `ResultType.foreignKeyViolation` (`-4`): Falló una restricción de clave foránea.
- `ResultType.notNullViolation` (`-5`): Falta un campo obligatorio o `null` no está permitido.
- `ResultType.validationFailed` (`-6`): Falló una validación de longitud, rango, formato o restricción.
- `ResultType.notFound` (`-11`): No se encontró la tabla, el espacio o el recurso solicitado.
- `ResultType.resourceExhausted` (`-15`): Los recursos del sistema son insuficientes; reduce la carga o reintenta.
- `ResultType.ioError` (`-90`): Error de E/S del sistema de archivos o del almacenamiento.
- `ResultType.dbError` (`-91`): Error interno de la base de datos.
- `ResultType.timeout` (`-92`): La operación excedió el tiempo límite.

### Manejo del Resultado de la Transacción

```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
  });
});

if (txResult.isFailed) {
  print('Tipo de error de la transacción: ${txResult.error?.type}');
  print('Mensaje de error de la transacción: ${txResult.error?.message}');
}
```

Tipos de error de transacción:
- `TransactionErrorType.operationError`: Fallo de una operación normal dentro de la transacción, como validación de campos, estado inválido de recursos u otras excepciones de negocio.
- `TransactionErrorType.integrityViolation`: Conflicto de integridad o de restricciones, por ejemplo clave primaria, clave única, clave foránea o no-nulo.
- `TransactionErrorType.timeout`: La transacción excedió el tiempo límite.
- `TransactionErrorType.io`: Error de E/S en el almacenamiento subyacente o en el sistema de archivos.
- `TransactionErrorType.conflict`: La transacción falló debido a un conflicto.
- `TransactionErrorType.userAbort`: Cancelación iniciada por el usuario. El aborto manual lanzando excepciones todavía no está soportado.
- `TransactionErrorType.unknown`: Cualquier otro error inesperado.


<a id="logging-diagnostics"></a>
### Callback de Logs y Diagnóstico de Base de Datos

ToStore puede usar `LogConfig.setConfig(...)` para devolver a la capa de aplicación los logs de inicio, recuperación, migración automática y conflictos de restricciones en tiempo de ejecución.

- `onLogHandler` recibe todos los logs filtrados por el `enableLog` y `logLevel` actuales.
- Llame a `LogConfig.setConfig(...)` antes de la inicialización para que también se capturen los logs de inicialización y migración automática.

```dart
  // Configurar parámetros o callback de logs
  LogConfig.setConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    publicLabel: 'my_app_db',
    onLogHandler: (message, type, label) {
      // En producción, warn/error pueden reportarse al backend o a la plataforma de logs
      if (!debugMode && (type == LogType.warn || type == LogType.error)) {
        developer.log(message, name: label);
      }
    },
  );

  final db = await ToStore.open();
```


### Modo Memoria Pura

Para caché o entornos sin disco, use `ToStore.memory()`. Todo (esquemas, índices, KV) queda estrictamente en RAM.

**Nota**: Los datos se pierden al cerrar o reiniciar la app.

```dart
// Inicializar base de datos en memoria
final db = await ToStore.memory(schemas: []);

// Operaciones casi instantáneas
await db.insert('temp_cache', {'key': 'session_1', 'value': 'admin'});
```


<a id="security-config"></a>
## Seguridad

> [!WARNING]
> **Gestión de Claves**: **`encodingKey`** se puede cambiar (migración automática). **`encryptionKey`** es crítica; cambiarla hace ilegibles los datos antiguos sin migración. Nunca codifique claves sensibles.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Soportados: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // Encoding Key (flexible; auto-migración)
      encodingKey: 'Su-Clave-De-Codificion-De-32-Bytes...', 
      
      // Encryption Key (Crítica; no cambiar sin migración)
      encryptionKey: 'Su-Clave-De-Cifrado-Segura...',
      
      // Vinculación al Dispositivo (Basada en ruta)
      // Vincula claves a la ruta de la DB y características del dispositivo.
      deviceBinding: false, 
    ),
    enableJournal: true, // Write-Ahead Logging (WAL)
    persistRecoveryOnCommit: true, // Forzar flush al commit
  ),
);
```

### Cifrado a Nivel de Campo (ToCrypto)

Si prefiere cifrar solo campos sensibles para mayor rendimiento, use **ToCrypto**: utilidad independiente para codificar/decodificar con salida Base64, ideal para columnas JSON o TEXT.

```dart
const key = 'mi-clave-secreta';
// Codificar: Texto plano -> Base64 cifrado
final cipher = ToCrypto.encode('datos sensibles', key: key);
// Decodificar
final plain = ToCrypto.decode(cipher, key: key);

// Opcional: Vincular contexto con AAD (debe coincidir al decodificar)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secreto', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```


<a id="performance"></a>
## Rendimiento

### Buenas Prácticas
- 📱 **Proyecto Ejemplo**: Vea el directorio `example` para una app Flutter completa.
- 🚀 **Producción**: El rendimiento en modo Release es muy superior al modo Debug.
- ✅ **Estandarizado**: Todas las funciones núcleo están cubiertas por pruebas exhaustivas.

### Benchmarks

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="Demostración de rendimiento de ToStore" width="320" />
</p>

- **Escaparate de rendimiento**: Incluso con más de 100 millones de registros, el inicio, el desplazamiento y la búsqueda se mantienen fluidos en dispositivos móviles estándar. (Ver [Video](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4))

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="Recuperación ante desastres de ToStore" width="320" />
</p>

- **Recuperación ante desastres**: ToStore se auto-recupera rápidamente incluso si se corta la energía o se elimina el proceso durante escrituras de alta frecuencia. (Ver [Video](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4))


Si ToStore le ayuda, ¡por favor denos una ⭐️! Es el mayor apoyo para el código abierto.

---

> **Recomendación**: Considere usar el [ToApp Framework](https://github.com/tocreator/toapp) para desarrollo frontend. Ofrece una solución full-stack que automatiza peticiones, carga, almacenamiento, caché y gestión de estado.


<a id="more-resources"></a>
## Más Recursos

- 📖 **Documentación**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Feedback**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Discusión**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
