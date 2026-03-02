# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | Español | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)


## ¿Por qué elegir Tostore?

Tostore es el único motor de almacenamiento de alto rendimiento para bases de datos vectoriales distribuidas en el ecosistema Dart/Flutter. Utilizando una arquitectura de tipo red neuronal, presenta una interconectividad e inteligencia de colaboración entre nodos, permitiendo una escalabilidad horizontal infinita. Construye una red de topología de datos flexible y proporciona una identificación precisa de cambios de esquema, protección por cifrado y aislamiento de datos multiespacio. Tostore aprovecha al máximo las CPUs multinúcleo para un procesamiento paralelo extremo y soporta de forma nativa la colaboración multiplataforma desde dispositivos de borde (edge) móviles hasta la nube. Con varios algoritmos de claves primarias distribuidas, proporciona una base de datos potente para escenarios como la realidad virtual inmersiva, la interacción multimodal, la computación espacial, la IA generativa y el modelado de espacios vectoriales semánticos.

A medida que la IA generativa y la computación espacial desplazan el centro de gravedad hacia el borde (edge), los dispositivos terminales están evolucionando de ser meros visualizadores de contenido a núcleos de generación local, percepción ambiental y toma de decisiones en tiempo real. Las bases de datos integradas tradicionales de un solo archivo están limitadas por su diseño arquitectónico, a menudo luchando para soportar los requisitos de respuesta inmediata de las aplicaciones inteligentes ante escrituras de alta concurrencia, recuperación de vectores masivos y generación colaborativa nube-borde. Tostore nace para dispositivos de borde, dotándolos de capacidades de almacenamiento distribuido suficientes para soportar la generación local de IA compleja y el flujo de datos a gran escala, logrando una verdadera colaboración profunda entre la nube y el borde.

**Resistente a fallos de energía y bloqueos**: Incluso en caso de un corte de energía inesperado o un bloqueo de la aplicación, los datos pueden recuperarse automáticamente, logrando una pérdida cero real. Cuando una operación de datos responde, los datos ya se han guardado de forma segura, eliminando el riesgo de pérdida de datos.

**Superando los límites de rendimiento**: Las pruebas muestran que incluso con más de 100 millones de registros, un smartphone típico puede mantener un rendimiento de búsqueda constante independiente del volumen de datos, ofreciendo una experiencia que supera con creces a las bases de datos tradicionales.




...... Desde la punta de los dedos hasta las aplicaciones en la nube, Tostore le ayuda a liberar la potencia de cálculo de datos y a potenciar el futuro ......




## Características de Tostore

- 🌐 **Soporte total multiplataforma sin fisuras**
  - Ejecute el mismo código en todas las plataformas, desde aplicaciones móviles hasta servidores en la nube.
  - Se adapta inteligentemente a diferentes backends de almacenamiento de plataforma (IndexedDB, sistema de archivos, etc.).
  - Interfaz API unificada para una sincronización de datos multiplataforma sin preocupaciones.
  - Flujo de datos fluido desde dispositivos de borde hasta servidores en la nube.
  - Computación vectorial local en dispositivos de borde, reduciendo la latencia de red y la dependencia de la nube.

- 🧠 **Arquitectura distribuida tipo red neuronal**
  - Estructura de topología de nodos interconectados para una organización eficiente del flujo de datos.
  - Mecanismo de particionamiento de datos de alto rendimiento para un verdadero procesamiento distribuido.
  - Equilibrio de carga de trabajo dinámico inteligente para maximizar la utilización de recursos.
  - Escalado horizontal infinito de nodos para construir fácilmente redes de datos complejas.

- ⚡ **Máxima capacidad de procesamiento paralelo**
  - Lectura/escritura paralela real utilizando Isolates, funcionando a máxima velocidad en CPUs multinúcleo.
  - La programación inteligente de recursos equilibra automáticamente la carga para maximizar el rendimiento multinúcleo.
  - La red de computación multinodo colaborativa duplica la eficiencia del procesamiento de tareas.
  - El marco de programación consciente de los recursos optimiza automáticamente los planes de ejecución para evitar la contienda de recursos.
  - La interfaz de consulta por flujo (streaming) maneja conjuntos de datos masivos con facilidad.

- 🔑 **Diversos algoritmos de claves primarias distribuidas**
  - Algoritmo de incremento secuencial - Ajuste libremente de los tamaños de paso aleatorios para ocultar la escala del negocio.
  - Algoritmo basado en marca de tiempo (Timestamp) - La mejor opción para escenarios de alta concurrencia.
  - Algoritmo de prefijo de fecha - Soporte perfecto para la visualización de datos de rango de tiempo.
  - Algoritmo de código corto - Genera identificadores únicos cortos y fáciles de leer.

- 🔄 **Migración de esquema inteligente e integridad de datos**
  - Identifica con precisión los campos de tabla renombrados con cero pérdida de datos.
  - Detección automática de cambios de esquema y migración de datos en milisegundos.
  - Actualizaciones sin tiempo de inactividad, imperceptibles para el negocio.
  - Estrategias de migración seguras para cambios de estructura complejos.
  - Validación automática de restricciones de claves foráneas con soporte de cascada que garantiza la integridad referencial.

- 🛡️ **Seguridad y durabilidad de nivel empresarial**
  - Mecanismo de doble protección: el registro en tiempo real de los cambios de datos garantiza que nunca se pierda nada.
  - Recuperación automática de bloqueos: reanuda automáticamente las operaciones no finalizadas después de un fallo de energía o bloqueo.
  - Garantía de consistencia de datos: las operaciones o bien tienen éxito por completo o se revierten totalmente.
  - Actualizaciones computacionales atómicas: el sistema de expresiones soporta cálculos complejos, ejecutados atómicamente para evitar conflictos de concurrencia.
  - Persistencia segura instantánea: los datos se guardan de forma segura cuando la operación tiene éxito.
  - El algoritmo de cifrado de alta resistencia ChaCha20Poly1305 protege los datos sensibles.
  - Cifrado de extremo a extremo para la seguridad durante todo el almacenamiento y transmisión.

- 🚀 **Caché inteligente y rendimiento de recuperación**
  - Mecanismo de caché inteligente multinivel para una recuperación de datos ultrarrápida.
  - Estrategias de caché profundamente integradas con el motor de almacenamiento.
  - El escalado adaptativo mantiene un rendimiento estable a medida que crece la escala de datos.
  - Notificaciones de cambios de datos en tiempo real con actualizaciones automáticas de los resultados de consulta.

- 🔄 **Flujo de trabajo de datos inteligente**
  - La arquitectura multiespacio proporciona aislamiento de datos junto con el intercambio compartido global.
  - Distribución inteligente de la carga de trabajo entre nodos de computación.
  - Proporciona una base sólida para el entrenamiento y análisis de datos a gran escala.


## Instalación

> [!IMPORTANT]
> **¿Actualizando desde v2.x?** Lea la [Guía de actualización v3.0](../UPGRADE_GUIDE_v3.md) para conocer los pasos críticos de migración y los cambios importantes.

Añada `tostore` como dependencia en su `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Por favor, utilice la versión más reciente
```

## Inicio Rápido

> [!IMPORTANT]
> **Definir el esquema de la tabla es el primer paso**: Antes de realizar operaciones CRUD, debe definir el esquema de la tabla. El método de definición específico depende de su escenario:
> - **Móvil/Escritorio**: Recomendado [Definición estática](#integración-para-escenarios-de-inicio-frecuente).
> - **Servidor**: Recomendado [Creación dinámica](#integración-del-lado-del-servidor).

```dart
// 1. Inicializar la base de datos
final db = await ToStore.open();

// 2. Insertar datos
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Consultas encadenadas ([operadores de consulta](#operadores-de-consulta), soporta =, !=, >, <, LIKE, IN, etc.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. Actualizar y Eliminar
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Escucha en tiempo real (La interfaz se actualiza automáticamente)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Usuarios coincidentes actualizados: $users');
});
```

### Almacenamiento Clave-Valor (KV)
Adecuado para escenarios que no requieren definir tablas estructuradas. Es simple, práctico e incluye un almacén KV de alto rendimiento incorporado para configuraciones, estados y otros datos dispersos. Los datos en espacios (Spaces) diferentes están aislados de forma natural, pero pueden configurarse para el intercambio global.

```dart
// 1. Establecer pares clave-valor (Soporta String, int, bool, double, Map, List, etc.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 2. Obtener datos
final theme = await db.getValue('theme'); // 'dark'

// 3. Eliminar datos
await db.removeValue('theme');

// 4. Clave-valor global (Compartido entre Spaces)
// Los datos KV por defecto son específicos del espacio. Use isGlobal: true para compartir.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



## Integración para Escenarios de Inicio Frecuente

📱 **Ejemplo**: [mobile_quickstart.dart](example/lib/mobile_quickstart.dart)

```dart
// Definición de esquema adecuada para aplicaciones móviles y de escritorio.
// Identifica con precisión los cambios de esquema y migra automáticamente los datos.
final db = await ToStore.open(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // Tabla global accesible para todos los espacios
            fields: [],
    ),
    const TableSchema(
      name: 'users', // Nombre de la tabla
      tableId: "users",  // Identificador único para detección de renombrado al 100%
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // Nombre de la clave primaria
      ),
      fields: [        // Definición de campos (excluyendo la clave primaria)
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true, // Crea automáticamente un índice único
          fieldId: 'username',  // Identificador único de campo
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true // Crea automáticamente un índice único
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime,
          createIndex: true // Crea automáticamente un índice
        ),
      ],
      // Ejemplo de índice compuesto
      indexes: [
        IndexSchema(fields: ['username', 'last_login']),
      ],
    ),
    // Ejemplo de restricción de clave foránea
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
          fields: ['user_id'],              // Campos de la tabla actual
          referencedTable: 'users',         // Tabla referenciada
          referencedFields: ['id'],         // Campos referenciados
          onDelete: ForeignKeyCascadeAction.cascade,  // Eliminación en cascada
          onUpdate: ForeignKeyCascadeAction.cascade,  // Actualización en cascada
        ),
      ],
    ),
  ],
);

// Arquitectura multiespacio - aislamiento perfecto de los datos de diferentes usuarios
await db.switchSpace(spaceName: 'user_123');
```

### Mantener estado de sesión y cierre de sesión (espacio activo)

El multi-espacio encaja bien para **datos por usuario**: un espacio por usuario y cambiar al iniciar sesión. Con el **espacio activo** y las opciones de **close** puedes mantener al usuario actual entre reinicios y soportar cierre de sesión.

- **Mantener estado de sesión**: Al cambiar el usuario a su espacio, guárdalo como espacio activo para que la próxima apertura con default entre directamente en ese espacio (no hace falta «abrir default y luego cambiar»).
- **Cierre de sesión**: Al cerrar sesión, cierra la base con `keepActiveSpace: false` para que la próxima apertura no entre automáticamente en el espacio del usuario anterior.

```dart

// Tras el login: cambiar al espacio de este usuario y recordarlo para la próxima apertura (mantener sesión)
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Opcional: abrir solo en default (p. ej. solo pantalla de login) — no usar el espacio activo guardado
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// Al cerrar sesión: cerrar y limpiar espacio activo para que la próxima apertura use el espacio default
await db.close(keepActiveSpace: false);
```

## Integración del Lado del Servidor

🖥️ **Ejemplo**: [server_quickstart.dart](example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Creación masiva de esquemas en tiempo de ejecución
await db.createTables([
  // Tabla de almacenamiento de vectores de características espaciales 3D
  const TableSchema(
    name: 'spatial_embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,   // PK de marca de tiempo para alta concurrencia
    ),
    fields: [
      FieldSchema(
        name: 'video_name',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'spatial_features',
        type: DataType.vector,                // Tipo de almacenamiento de vectores
        vectorConfig: VectorFieldConfig(
          dimensions: 1024,                   // Vector de alta dimensión
          precision: VectorPrecision.float32, 
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['video_name'],
        unique: true,
      ),
      IndexSchema(
        type: IndexType.vector,              // Índice vectorial
        fields: ['spatial_features'],
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,   // Algoritmo NGH para ANN eficiente
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,
            'efConstruction': 200,
          },
        ),
      ),
    ],
  ),
  // Otras tablas...
]);

// Actualizaciones de Esquema en Línea - Sin interrupción para el negocio
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
  .setPrimaryKeyConfig(                    // Cambiar configuración de PK
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// Monitorear el progreso de la migración
final status = await db.queryMigrationTaskStatus(taskId);
print('Progreso de la migración: ${status?.progressPercentage}%');


// Gestión Manual de Caché de Consultas (Servidor)
// Para consultas sobre claves primarias o campos indexados (consultas de igualdad, IN), el rendimiento ya es extremo y la gestión manual del caché suele ser innecesaria.

// Cachear manualmente el resultado de una consulta durante 5 minutos.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Invalidar caché específica cuando los datos cambian.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// Deshabilitar explícitamente el caché para consultas con datos en tiempo real.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```



## Uso Avanzado

Tostore proporciona un conjunto rico de características avanzadas para requisitos complejos:

### Consultas Anidadas y Filtrado Personalizado
Soporta el anidamiento infinito de condiciones y funciones personalizadas flexibles.

```dart
// Anidamiento de condiciones: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// Función de condición personalizada
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('recomendado') ?? false);
```

### Upsert Inteligente
Actualiza si existe, de lo contrario inserta.

```dart
// By primary key or unique key in data (no where)
final result = await db.upsert('users', {'id': 1, 'username': 'john', 'email': 'john@example.com'});
await db.upsert('users', {'username': 'john', 'email': 'john@example.com', 'age': 26});
// Batch upsert
await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### Uniones (Joins) y Selección de Campos
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### Transmisión (Streaming) y Estadísticas
```dart
// Contar registros
final count = await db.query('users').count();

// Verificar si la tabla está definida en el esquema de la base de datos (independiente del Space)
// Nota: esto NO indica si la tabla tiene datos
final usersTableDefined = await db.tableExists('users');

// Comprobación eficiente de existencia basada en condiciones (sin cargar registros completos)
final emailExists = await db.query('users')
    .where('email', '=', 'test@example.com')
    .exists();

// Funciones de agregación
final totalAge = await db.query('users').where('age', '>', 18).sum('age');
final avgAge = await db.query('users').avg('age');
final maxAge = await db.query('users').max('age');
final minAge = await db.query('users').min('age');

// Agrupación y filtrado
final result = await db.query('orders')
    .select(['status', Agg.sum('amount', alias: 'total')])
    .groupBy(['status'])
    .having(Agg.sum('amount'), '>', 1000)
    .limit(20);

// Consulta de valores únicos
final uniqueCities = await db.query('users').distinct(['city']);

// Consulta por flujo (adecuada para datos masivos)
db.streamQuery('users').listen((data) => print(data));
```



### Consultas y Paginación Eficiente

> [!TIP]
> **Especifique `limit` explícitamente para un mejor rendimiento**: Se recomienda encarecidamente especificar siempre un `limit` al realizar consultas. Si se omite, el motor limita por defecto a 1000 registros. Aunque la consulta principal es extremadamente rápida, la serialización de una gran cantidad de registros en aplicaciones sensibles a la interfaz de usuario puede causar una latencia innecesaria.

Tostore ofrece soporte de paginación de modo dual:

#### 1. Modo Offset (Desplazamiento)
Adecuado para conjuntos de datos pequeños o cuando se requiere saltar a una página específica.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Saltar los primeros 40
    .limit(20); // Tomar 20
```
> [!TIP]
> Cuando el `offset` es muy grande, la base de datos debe escanear y descartar muchos registros, lo que degrada el rendimiento. Use el **Modo Cursor** para paginación profunda.

#### 2. Modo Cursor de Alto Rendimiento
**Recomendado para datos masivos y escenarios de scroll infinito**. Utiliza `nextCursor` para un rendimiento O(1), asegurando una velocidad de consulta constante independientemente de la profundidad de la página.

> [!IMPORTANT]
> Si se ordena por un campo no indexado o para ciertas consultas complejas, el motor puede volver al escaneo completo de la tabla y devolver un cursor `null` (lo que significa que la paginación para esa consulta específica aún no es compatible).

```dart
// Página 1
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Obtener la siguiente página usando el cursor
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Buscar directamente la posición
}

// Retroceder eficientemente con prevCursor
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Característica | Modo Offset | Modo Cursor |
| :--- | :--- | :--- |
| **Rendimiento** | Disminuye al aumentar la página | **Constante (O(1))** |
| **Complejidad** | Datos pequeños, saltos de página | **Datos masivos, scroll infinito** |
| **Consistencia** | Los cambios pueden causar saltos | **Perfecta integridad ante cambios** |



### Operadores de consulta

Todos los operadores (insensibles a mayúsculas) para `where(field, operator, value)`:

| Operator | Description | Example / Value type |
| :--- | :--- | :--- |
| `=` | Equal | `where('status', '=', 'active')` |
| `!=`, `<>` | Not equal | `where('role', '!=', 'guest')` |
| `>` | Greater than | `where('age', '>', 18)` |
| `>=` | Greater than or equal | `where('score', '>=', 60)` |
| `<` | Less than | `where('price', '<', 100)` |
| `<=` | Less than or equal | `where('quantity', '<=', 10)` |
| `IN` | Value in list | `where('id', 'IN', ['a','b','c'])` — value: `List` |
| `NOT IN` | Value not in list | `where('status', 'NOT IN', ['banned'])` — value: `List` |
| `BETWEEN` | Between start and end (inclusive) | `where('age', 'BETWEEN', [18, 65])` — value: `[start, end]` |
| `LIKE` | Pattern match (`%` any, `_` single char) | `where('name', 'LIKE', '%John%')` — value: `String` |
| `NOT LIKE` | Pattern not match | `where('email', 'NOT LIKE', '%@test.com')` — value: `String` |
| `IS` | Is null | `where('deleted_at', 'IS', null)` — value: `null` |
| `IS NOT` | Is not null | `where('email', 'IS NOT', null)` — value: `null` |

### Métodos de consulta semánticos (recomendado)

Se recomienda usar métodos semánticos en lugar de escribir operadores a mano.

```dart
// Comparison
db.query('users').whereEqual('username', 'John');
db.query('users').whereNotEqual('role', 'guest');
db.query('users').whereGreaterThan('age', 18);
db.query('users').whereGreaterThanOrEqualTo('score', 60);
db.query('users').whereLessThan('price', 100);
db.query('users').whereLessThanOrEqualTo('quantity', 10);

// Membership & range
db.query('users').whereIn('id', ['id1', 'id2']);
db.query('users').whereNotIn('status', ['banned', 'pending']);
db.query('users').whereBetween('age', 18, 65);

// Null checks
db.query('users').whereNull('deleted_at');
db.query('users').whereNotNull('email');

// Pattern match
db.query('users').whereLike('name', '%John%');
db.query('users').whereNotLike('email', '%@temp.');
db.query('users').whereContains('bio', 'flutter');   // LIKE '%flutter%'
db.query('users').whereNotContains('title', 'draft');

// Equivalent to: .where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```

## Arquitectura Distribuida

```dart
// Configurar Nodos Distribuidos
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,
      clusterId: 1,
      centralServerUrl: 'http://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// Inserción masiva de alto rendimiento (Batch Insert)
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Registros insertados eficientemente en lote
]);

// Procesar grandes conjuntos de datos por flujo - Memoria constante
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Procesa eficientemente incluso datos de escala TB sin alto uso de memoria
  print(record);
}
```

## Ejemplos de Claves Primarias

Tostore proporciona varios algoritmos de claves primarias distribuidas:

- **Secuencial** (PrimaryKeyType.sequential): 238978991
- **Basada en marca de tiempo** (PrimaryKeyType.timestampBased): 1306866018836946
- **Prefijo de fecha** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **Código corto** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// Ejemplo de configuración de clave primaria secuencial
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
    fields: [/* Definición de campos */]
  ),
]);
```


## Operaciones Atómicas con Expresiones

El sistema de expresiones proporciona actualizaciones de campos atómicas y seguras. Todos los cálculos se ejecutan atómicamente a nivel de base de datos para evitar conflictos de concurrencia:

```dart
// Incremento simple: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Cálculo complejo: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// Paréntesis anidados: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Uso de funciones: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Sello de tiempo: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

## Transacciones

Las transacciones aseguran la atomicidad de múltiples operaciones: o bien todas tienen éxito o todas se revierten, garantizando la consistencia de los datos.

**Características de las Transacciones**:
- Ejecución atómica de múltiples operaciones.
- Recuperación automática de operaciones inacabadas después de un fallo.
- Los datos se guardan de forma segura al confirmar (commit) con éxito.

```dart
// Transacción básica
final txResult = await db.transaction(() async {
  // Insertar usuario
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // Actualización atómica usando expresiones
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // Si cualquier operación falla, todos los cambios se revierten automáticamente.
});

if (txResult.isSuccess) {
  print('Transacción confirmada con éxito');
} else {
  print('Transacción revertida: ${txResult.error?.message}');
}

// Reversión automática en caso de error
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('Error de lógica de negocio'); // Activa la reversión
}, rollbackOnError: true);
```

## Configuración de Seguridad

**Mecanismos de Seguridad de Datos**:
- Mecanismos de doble protección garantizan que los datos nunca se pierdan.
- Recuperación automática de bloqueos para operaciones incompletas.
- Persistencia segura instantánea al éxito de la operación.
- El cifrado de alta resistencia protege los datos sensibles.

> [!WARNING]
> **Gestión de Claves**: **`encodingKey`** puede cambiarse libremente; el motor migrará los datos automáticamente al cambiarla, por lo que no hay que preocuparse por la pérdida de datos. **`encryptionKey`** no debe cambiarse arbitrariamente: cambiarla hará que los datos antiguos sean ilegibles salvo que se realice una migración. No codifique claves sensibles; obténgalas de un servidor seguro.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Algoritmos soportados: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // Clave de codificación (puede cambiarse libremente; los datos se migran automáticamente)
      encodingKey: 'Su-Clave-De-Codificacion-De-32-Bytes...', 
      
      // Clave de cifrado para datos críticos (no cambiar arbitrariamente; datos antiguos ilegibles salvo migración)
      encryptionKey: 'Su-Clave-De-Cifrado-Segura...',
      
      // Vinculación al dispositivo (Basada en ruta)
      // Cuando se habilita, las claves se vinculan a la ruta y a las características del dispositivo.
      // Mejora la seguridad contra la copia de archivos de base de datos.
      deviceBinding: false, 
    ),
    // Registro previo a la escritura (WAL) habilitado por defecto
    enableJournal: true, 
    // Forzar el volcado a disco en el commit (desactivar para mayor rendimiento)
    persistRecoveryOnCommit: true,
  ),
);
```

### Cifrado a nivel de valor (ToCrypto)

El cifrado de toda la base de datos anterior cifra todas las tablas e índices y puede afectar al rendimiento global. Para cifrar solo campos sensibles, use **ToCrypto**: es independiente de la base de datos (no requiere instancia db). Usted codifica o decodifica los valores antes de escribir o después de leer; la clave la gestiona por completo su aplicación. La salida es Base64, adecuada para columnas JSON o TEXT.

- **key** (obligatorio): `String` o `Uint8List`. Si no son 32 bytes, se deriva una clave de 32 bytes mediante SHA-256.
- **type** (opcional): Tipo de cifrado [ToCryptoType]: [ToCryptoType.chacha20Poly1305] o [ToCryptoType.aes256Gcm]. Por defecto [ToCryptoType.chacha20Poly1305]. Omitir para usar el predeterminado.
- **aad** (opcional): Datos de autenticación adicionales — `Uint8List`. Si se pasa al codificar, debe pasar los mismos bytes al decodificar (p. ej. nombre de tabla + campo para vincular contexto). Omitir en uso simple.

```dart
const key = 'my-secret-key';
// Codificar: texto plano → Base64 cifrado (guardar en DB o JSON)
final cipher = ToCrypto.encode('sensitive data', key: key);
// Decodificar al leer
final plain = ToCrypto.decode(cipher, key: key);

// Opcional: vincular contexto con aad (mismo aad al codificar y decodificar)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```

## Rendimiento y Experiencia

### Especificaciones de Rendimiento

- **Velocidad de Inicio**: Inicio instantáneo y visualización de datos incluso con más de 100M de registros en smartphones típicos.
- **Rendimiento de Consulta**: Independiente de la escala, rendimiento de búsqueda ultrarrápido constante.
- **Seguridad de Datos**: Garantías de transacción ACID + recuperación ante fallos para cero pérdida de datos.

### Recomendaciones

- 📱 **Proyecto de Ejemplo**: Se proporciona un ejemplo completo de aplicación Flutter en el directorio `example`.
- 🚀 **Producción**: Utilice el modo Release para un rendimiento muy superior al modo Debug.
- ✅ **Pruebas Estándar**: Todas las funcionalidades principales han superado las pruebas de integración.

### Vídeos de demostración

<p align="center">
  <img src="../media/basic-demo.gif" alt="Demo básica de rendimiento de Tostore" width="320" />
  </p>


- **Demo básica de rendimiento** (<a href="../media/basic-demo.mp4?raw=1" target="_blank" rel="noopener">basic-demo.mp4</a>): La vista previa en GIF puede estar recortada; haz clic en el video para ver la demo completa. Muestra que, incluso en un smartphone normal con más de 100 M de registros, el arranque de la app, el paginado y las búsquedas se mantienen siempre estables y fluidas. Mientras haya almacenamiento suficiente, los dispositivos de borde pueden manejar volúmenes de datos de escala TB/PB sin degradar perceptiblemente la latencia de interacción.

<p align="center">
  <img src="../media/disaster-recovery.gif" alt="Prueba de recuperación ante desastres de Tostore" width="320" />
  </p>

- **Prueba de recuperación ante desastres** (<a href="../media/disaster-recovery.mp4?raw=1" target="_blank" rel="noopener">disaster-recovery.mp4</a>): Interrumpe deliberadamente el proceso durante cargas de escritura intensivas para simular fallos y cortes de energía. Incluso quando decenas de miles de operaciones de escritura se detienen de forma abrupta, Tostore se recupera muy rápido en un teléfono típico y no afecta al siguiente arranque ni a la disponibilidad de los datos.




Si Tostore le ayuda, por favor danos una ⭐️




## Hoja de Ruta (Roadmap)

Tostore está desarrollando activamente características para mejorar la infraestructura de datos en la era de la IA:

- **Vectores de Alta Dimensión**: Añadiendo recuperación de vectores y algoritmos de búsqueda semántica.
- **Datos Multimodales**: Proporcionando procesamiento de extremo a extremo desde datos brutos hasta vectores de características.
- **Estructuras de Datos de Grafos**: Soporte para el almacenamiento y consulta eficiente de grafos de conocimiento y redes relacionales complejas.





> **Recomendación**: Los desarrolladores móviles también pueden considerar el [Framework Toway](https://github.com/tocreator/toway), una solución full-stack que automatiza las solicitudes de datos, carga, almacenamiento, caché y visualización.




## Recursos Adicionales

- 📖 **Documentación**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Feedback**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Discusión**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


## Licencia

Este proyecto está bajo la Licencia Apache 2.0 - vea el archivo [LICENSE](LICENSE) para más detalles.

---
