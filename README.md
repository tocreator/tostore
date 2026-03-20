<h1 align="center">
  <img src="doc/resource/logo-tostore.svg" width="400" alt="ToStore">
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
  English | 
  <a href="doc/translations/README.zh-CN.md">简体中文</a> | 
  <a href="doc/translations/README.ja.md">日本語</a> | 
  <a href="doc/translations/README.ko.md">한국어</a> | 
  <a href="doc/translations/README.es.md">Español</a> | 
  <a href="doc/translations/README.pt-BR.md">Português (Brasil)</a> | 
  <a href="doc/translations/README.ru.md">Русский</a> | 
  <a href="doc/translations/README.de.md">Deutsch</a> | 
  <a href="doc/translations/README.fr.md">Français</a> | 
  <a href="doc/translations/README.it.md">Italiano</a> | 
  <a href="doc/translations/README.tr.md">Türkçe</a>
</p>




## Why Choose ToStore?

ToStore is the only high-performance storage engine for distributed vector databases in the Dart/Flutter ecosystem. Utilizing a neural-network-like architecture, it features intelligent interconnectivity and collaboration between nodes, supporting infinite horizontal scaling. It builds a flexible data topology network and provides precise schema change identification, encryption protection, and multi-space data isolation. ToStore fully leverages multi-core CPUs for extreme parallel processing and naturally supports cross-platform collaboration from mobile edge devices to the cloud. With various distributed primary key algorithms, it provides a powerful data foundation for scenarios such as immersive AR/VR fusion, multi-modal interaction, spatial computing, generative AI, and semantic vector space modeling.

As generative AI and spatial computing shift the center of gravity toward the edge, terminal devices are evolving from mere content displays into cores for local generation, environmental perception, and real-time decision-making. Traditional single-file embedded databases are limited by their architectural design, often struggling to support the immediate response requirements of intelligent applications when facing high-concurrency writes, massive vector retrieval, and cloud-edge collaborative generation. ToStore is born for edge devices, empowering them with distributed storage capabilities sufficient to support complex local AI generation and large-scale data flow, truly achieving deep collaboration between the cloud and the edge.

**Power failure and crash resistant**: Even in the event of an unexpected power outage or application crash, data can be automatically recovered, achieving true zero loss. When a data operation responds, the data has already been safely saved, eliminating the risk of data loss.

**Breaking performance limits**: Performance tests show that even with 100 million+ records, a typical smartphone can maintain constant retrieval performance regardless of data scale, delivering an experience far exceeding that of traditional databases.




...... From fingertips to cloud applications, ToStore helps you release data computing power and empower the future ......




## Key Features

- 🌐 **Seamless All-Platform Support**
  - Run the same code across all platforms, from mobile apps to cloud servers.
  - Intelligently adapt to different platform storage backends (IndexedDB, File System, etc.).
  - Unified API interface for worry-free cross-platform data synchronization.
  - Seamless data flow from edge devices to cloud servers.
  - Local vector computation on edge devices, reducing network latency and cloud dependency.

- 🧠 **Neural-Network-Like Distributed Architecture**
  - Neural-network-like interconnected node topology for efficient data flow organization.
  - High-performance data partitioning mechanism for true distributed processing.
  - Intelligent dynamic workload balancing to maximize resource utilization.
  - Infinite horizontal scaling of nodes to easily build complex data networks.

- ⚡ **Ultimate Parallel Processing**
  - True parallel read/write using Isolates, running at full speed on multi-core CPUs.
  - Intelligent resource scheduling automatically balances load to maximize multi-core performance.
  - Collaborative multi-node computing network doubles task processing efficiency.
  - Resource-aware scheduling framework automatically optimizes execution plans to avoid resource contention.
  - Streaming query interface handles massive datasets with ease.

- 🔑 **Diverse Distributed Primary Key Algorithms**
  - Sequential Increment Algorithm - Freely adjust random step sizes to hide business scale.
  - Timestamp-Based Algorithm - The best choice for high-concurrency scenarios.
  - Date-Prefix Algorithm - Perfect support for time-range data display.
  - Short Code Algorithm - Generates short, human-readable unique identifiers.

- 🔄 **Intelligent Schema Migration & Data Integrity**
  - Precisely identifies renamed table fields with zero data loss.
  - Millisecond-level automatic detection of schema changes and data migration.
  - Zero-downtime upgrades, seamless to the business.
  - Safe migration strategies for complex structure changes.
  - Automatic foreign key constraint validation with cascading support ensures referential integrity.

- 🛡️ **Enterprise-Grade Security & Durability**
  - Dual Protection Mechanism: Real-time logging of data changes ensures nothing is ever lost.
  - Automatic Crash Recovery: Automatically resumes unfinished operations after power failure or crash.
  - Data Consistency Guarantee: Operations either succeed entirely or roll back completely.
  - Atomic Computational Updates: Expression system supports complex calculations, executed atomically to avoid concurrency conflicts.
  - Instant Safe Flushing: Data is safely saved when the operation succeeds, no waiting required.
  - High-strength ChaCha20Poly1305 encryption protects sensitive data.
  - End-to-end encryption for security throughout storage and transmission.

- 🚀 **Intelligent Caching & Retrieval Performance**
  - Multi-level intelligent caching mechanism for blazing-fast data retrieval.
  - Caching strategies deeply integrated with the storage engine.
  - Adaptive scaling maintains stable performance as data scale grows.
  - Real-time data change notifications with automatic query result updates.

- 🔄 **Intelligent Data Workflow**
  - Multi-space architecture provides data isolation along with global sharing.
  - Intelligent workload distribution across computing nodes.
  - Provides a solid foundation for large-scale data training and analysis.


## Installation

> [!IMPORTANT]
> **Upgrading from v2.x?** Please read the [v3.x Upgrade Guide](doc/UPGRADE_GUIDE_v3.md) for critical migration steps and breaking changes.

Add `tostore` as a dependency in your `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Please use the latest version
```

## Quick Start

> [!IMPORTANT]
> **Defining table schema is the first step**: Before performing CRUD operations, you must define the table schema. The specific definition method depends on your scenario:
> - **Mobile/Desktop**: Recommended [Static Definition](#integration-for-frequent-startup-scenarios).
> - **Server-side**: Recommended [Dynamic Creation](#server-side-integration).

```dart
// 1. Initialize the database
final db = await ToStore.open();

// 2. Insert data
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Chained queries ([query operators](#query-operators) support =, !=, >, <, LIKE, IN, etc.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. Update and Delete
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Real-time Listening (UI updates automatically when data changes)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Matching users updated: $users');
});
```

### Key-Value Storage (KV)
Suitable for scenarios that do not require defining structured tables. It's simple, practical, and includes a built-in high-performance KV store for configuration, status, and other scattered data. Data in different Spaces is naturally isolated but can be set for global sharing.

```dart
// 1. Set key-value pairs (Supports String, int, bool, double, Map, List, etc.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 2. Get data
final theme = await db.getValue('theme'); // 'dark'

// 3. Remove data
await db.removeValue('theme');

// 4. Global key-value (Shared across Spaces)
// Default KV data is space-specific. Use isGlobal: true for global sharing.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



## Integration for Frequent Startup Scenarios

📱 **Example**: [mobile_quickstart.dart](example/lib/mobile_quickstart.dart)

```dart
// Schema definition suitable for frequent startup scenarios like mobile and desktop apps.
// Precisely identifies schema changes and auto-migrates data with zero code maintenance.
final db = await ToStore.open(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // Global table accessible to all spaces
            fields: [],
    ),
    const TableSchema(
      name: 'users', // Table name
      tableId: "users",  // Unique identifier for 100% rename detection
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // Primary key name
      ),
      fields: [        // Field definitions (excluding primary key)
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true, // Automatically creates a unique index
          fieldId: 'username',
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true // Automatically creates a unique index
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime,
          createIndex: true // Automatically creates an index
        ),
      ],
      // Composite index example
      indexes: [
        IndexSchema(fields: ['username', 'last_login']),
      ],
    ),
    // Foreign key constraint example
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
          fields: ['user_id'],              // Current table fields
          referencedTable: 'users',         // Referenced table
          referencedFields: ['id'],         // Referenced fields
          onDelete: ForeignKeyCascadeAction.cascade,  // Cascade delete
          onUpdate: ForeignKeyCascadeAction.cascade,  // Cascade update
        ),
      ],
    ),
  ],
);

// Multi-space architecture - perfect isolation of different users' data
await db.switchSpace(spaceName: 'user_123');
```

### Keeping login state and logout (active space)

Multi-space works well for **per-user data**: use one space per user and switch when the user logs in. To keep the current user across app restarts and to support logout, use **active space** and **close** options.

- **Keeping login state**: When the user switches to their space, save it as the active space so the next launch opens in that space by default (no need to "open default then switch").
- **Logout**: When the user logs out, close the database with `keepActiveSpace: false` so the next launch does not auto-open in the previous user's space.

```dart

// After login: switch to this user's space and remember it for next launch (keep login state)
await db.switchSpace(spaceName: 'user_${userId}', keepActive: true);

// Optional: open strictly in default (e.g. login screen only) — do not use stored active space
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// On logout: close and clear active space so next launch uses default space (logout)
await db.close(keepActiveSpace: false);
```


## Server-Side Integration

🖥️ **Example**: [server_quickstart.dart](example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Bulk schema creation at runtime - suitable for continuous running scenarios
await db.createTables([
  // 3D Spatial Feature Vector storage
  const TableSchema(
    name: 'spatial_embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,   // Timestamp PK for high-concurrency writes
    ),
    fields: [
      FieldSchema(
        name: 'video_name',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'spatial_features',
        type: DataType.vector,                // Vector storage type
        vectorConfig: VectorFieldConfig(
          dimensions: 1024,                   // High-dimensional vector
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
        type: IndexType.vector,              // Vector index
        fields: ['spatial_features'],
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,    // NGH algorithm for efficient ANN
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,
            'efConstruction': 200,
          },
        ),
      ),
    ],
  ),
  // Other tables...
]);

// Online Schema Updates - Seamless to the business
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
  .setPrimaryKeyConfig(                    // Change PK config
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// Monitor migration progress
final status = await db.queryMigrationTaskStatus(taskId);
print('Migration Progress: ${status?.progressPercentage}%');


// Manual Query Cache Management (Server-side)
// For queries on primary keys or indexed fields (Equality, IN queries), 
// performance is already extreme and manual cache management is usually unnecessary.

// Manually cache a query result for 5 minutes.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Invalidate specific cache when data changes to ensure consistency.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// Explicitly disable cache for queries requiring real-time data.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```



## Advanced Usage

ToStore provides a rich set of advanced features for complex business requirements:

### Table-level TTL (automatic time-based expiration)

For logs, events, and other time-series style data that should expire automatically, you can define table-level TTL via `ttlConfig`. Expired data is cleaned up in the background in small batches, without requiring manual iteration in your business code:

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
    ttlMs: 7 * 24 * 60 * 60 * 1000, // keep 7 days
    // When sourceField is omitted, the engine uses the write time
    // and manages the required index automatically.
    // Optional: when you provide a custom sourceField, it must:
    // 1) have type DataType.datetime
    // 2) be non-nullable (nullable: false)
    // 3) use DefaultValueType.currentTimestamp as defaultValueType
    // sourceField: 'created_at',
  ),
);
```

### Nested Queries & Custom Filtering
Supports infinite nesting of conditions and flexible custom functions.

```dart
// Condition nesting: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// Custom condition function
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('recommend') ?? false)
    .limit(20);
```

### Intelligent Upsert
Update if a row exists (by primary key or unique key in data), otherwise insert. No where clause; conflict target is derived from data.

```dart
// By primary key
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// By unique key (record must contain all fields of one unique index + required fields)
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


### Joins & Field Selection
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### Streaming & Aggregation
```dart
// Count records
final count = await db.query('users').count();

// Check if a table has been defined in the current database (space-agnostic).
// Note: this does NOT indicate whether the table has data.
final usersTableDefined = await db.tableExists('users');

// Efficient existence check based on conditions (no full record loading).
final emailExists = await db.query('users')
    .where('email', '=', 'test@example.com')
    .exists();

// Aggregate functions
final totalAge = await db.query('users').where('age', '>', 18).sum('age');
final avgAge = await db.query('users').avg('age');
final maxAge = await db.query('users').max('age');
final minAge = await db.query('users').min('age');

// Group and filter
final result = await db.query('orders')
    .select(['status', Agg.sum('amount', alias: 'total')])
    .groupBy(['status'])
    .having(Agg.sum('amount'), '>', 1000)
    .limit(20);

// Distinct query
final uniqueCities = await db.query('users').distinct(['city']);

// Streaming query (suitable for massive data)
db.streamQuery('users').listen((data) => print(data));
```



### Querying & Efficient Pagination

> [!TIP]
> **Use `limit` for better performance**: It is highly recommended to always specify a `limit`. If omitted, the engine defaults to a limit of 1000 records. While the core engine is fast, fetching and serializing 1000 records can cause unnecessary latency in UI-sensitive applications.

ToStore offers dual-mode pagination support to fit different data scales and performance needs:

#### 1. Offset Mode
Suitable for small datasets (e.g., under 10k records) or when specific page jumping is required.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Skip first 40
    .limit(20); // Take 20
```
> [!TIP]
> When `offset` is very large, the database must scan and discard many records, leading to linear performance degradation. Use **Cursor Mode** for deep paging.

#### 2. High-Performance Cursor Mode
**Recommended for massive data and infinite scroll scenarios**. Utilizes `nextCursor` for O(1) performance, ensuring constant query speed regardless of page depth.

> [!IMPORTANT]
> If sorting by an unindexed field or for certain complex queries, the engine may fall back to a full table scan and return a `null` cursor (meaning pagination for that specific query is not yet supported).

```dart
// Page 1
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Fetch next page using the cursor
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Seek directly to the position
}

// Efficiently move backwards with prevCursor
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Feature | Offset Mode | Cursor Mode |
| :--- | :--- | :--- |
| **Query Performance** | Decreases as page increases | **Constant (O(1))** |
| **Complexity** | Small data, page jumping | **Massive data, infinite scroll** |
| **Consistency** | Data changes can cause skips | **Avoids duplicates/omissions from data changes** |



### Query Operators

All `where(field, operator, value)` conditions use the following operators (case-insensitive):

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

### Semantic query methods (recommended)

Prefer semantic methods to avoid typing operator strings and get better IDE support:

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

## Distributed Architecture

```dart
// Configure Distributed Nodes
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

// High-Performance Batch Insertion
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Records inserted efficiently in bulk
]);

// Stream large datasets - Constant memory usage
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Efficiently process even TB-scale data without high memory usage
  print(record);
}
```

## Primary Key Examples

ToStore provides various distributed primary key algorithms for different scenarios:

- **Sequential** (PrimaryKeyType.sequential): 238978991
- **Timestamp-Based** (PrimaryKeyType.timestampBased): 1306866018836946
- **Date-Prefix** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **Short Code** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// Sequential Primary Key configuration example
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // Hide business volume
      ),
    ),
    fields: [/* Field definitions */]
  ),
]);
```


## Expression Atomic Operations

The expression system provides type-safe atomic field updates. All calculations are executed atomically at the database level to avoid concurrency conflicts:

```dart
// Simple Increment: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Complex Calculation: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// Nested Parentheses: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Using Functions: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Timestamp: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

**Conditional expressions (e.g. for upsert)**: Use `Expr.isUpdate()` / `Expr.isInsert()` with `Expr.ifElse` or `Expr.when` so that expressions run only on update or only on insert:

```dart
// Upsert: increment on update, set to 1 on insert (insert branch uses plain value; only update evaluates expression)
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    1,  // insert branch: plain value, not evaluated by insert
  ),
});

// Same with Expr.when (single-branch, otherwise defaults to null)
await db.upsert('orders', {
  'id': orderId,
  'updatedAt': Expr.when(Expr.isUpdate(), Expr.now(), otherwise: Expr.now()),
});
```

## Transactions

Transactions ensure the atomicity of multiple operations—either all succeed or all roll back, guaranteeing data consistency.

**Transaction Features**:
- Atomic execution of multiple operations.
- Automatic recovery of unfinished operations after a crash.
- Data is safely saved upon successful commit.

```dart
// Basic Transaction - Atomic commit of multiple operations
final txResult = await db.transaction(() async {
  // Insert User
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // Atomic update using expressions
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // If any operation fails, all changes roll back automatically.
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
  throw Exception('Business logic error'); // Triggers rollback
}, rollbackOnError: true);
```

### Pure Memory Mode

For scenarios like data caching, temporary computation, or diskless environments without persisting to disk, you can initialize a pure in-memory database using ToStore.memory(). In this mode, all data (including schemas, indexes, and key-value pairs) is kept strictly in memory.

```dart
// Initialize database in pure memory mode
final db = await ToStore.memory(
  schemas: [],
);

// All operations (CRUD and search) are instantly executed in memory
await db.insert('temp_cache', {'key': 'session_1', 'value': {'user': 'admin'}});

// Note: Data created in memory mode is completely lost upon application closure or restart.
```

## Security Configuration

**Data Security Mechanisms**:
- Dual protection mechanisms ensure data is never lost.
- Automatic crash recovery of unfinished operations.
- Instant safe persistence upon operation success.
- High-strength encryption protects sensitive data.

> [!WARNING]
> **Key Management**: **`encodingKey`** can be changed freely; the engine will automatically migrate data when it changes, so you need not worry about data loss. **`encryptionKey`** must not be changed arbitrarily—changing it will make old data unreadable unless a migration is performed. Do not hardcode sensitive keys; fetch them from a secure server.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Algorithms supported: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // Encoding Key (can be changed freely; data will be auto-migrated)
      encodingKey: 'Your-32-Byte-Long-Encoding-Key...', 
      
      // Encryption Key for critical data (do not change arbitrarily; old data becomes unreadable unless migrated)
      encryptionKey: 'Your-Secure-Encryption-Key...',
      
      // Device Binding (Path-based)
      // When enabled, keys are bound to path and device characteristics.
      // Boosts security against database file copying but data retrieval 
      // depends on app installation path and device persistence.
      deviceBinding: false, 
    ),
    // Write-Ahead Logging (WAL) enabled by default
    enableJournal: true, 
    // Force disk flush on commit for maximum durability (set to false for performance)
    persistRecoveryOnCommit: true,
  ),
);
```

### Value-level encryption (ToCrypto)

Full-database encryption above encrypts all table and index data and can affect overall performance. To encrypt only sensitive fields, use **ToCrypto**: it is independent of the database (no db instance required). You encode or decode values yourself before writing or after reading; the key is managed entirely by your app. Output is Base64, suitable for JSON or TEXT columns.

- **key** (required): `String` or `Uint8List`. If not 32 bytes, a 32-byte key is derived via SHA-256.
- **type** (optional): Encryption type, [ToCryptoType]: [ToCryptoType.chacha20Poly1305] or [ToCryptoType.aes256Gcm]. Default [ToCryptoType.chacha20Poly1305]. Omit for default.
- **aad** (optional): Additional Authenticated Data — `Uint8List`. If you pass it at encode, you must pass the same bytes at decode (e.g. table name + field name for context binding). Omit for simple use.

```dart

const key = 'my-secret-key';
// Encode: plain → Base64 cipher (store in DB or JSON)
final cipher = ToCrypto.encode('sensitive data', key: key);
// Decode when reading
final plain = ToCrypto.decode(cipher, key: key);

// Optional: bind cipher to context with aad (same aad at encode and decode)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```

## Performance & Experience

### Performance Specs

- **Startup Speed**: Instant startup and data display even with 100M+ records on average smartphones.
- **Query Performance**: Scale-independent, consistently blazing-fast retrieval at any data volume.
- **Data Safety**: ACID transaction guarantees + crash recovery for zero data loss.

### Recommendations

- 📱 **Example Project**: A complete Flutter app example is provided in the `example` directory.
- 🚀 **Production**: Use Release mode for performance far exceeding Debug mode.
- ✅ **Standard Tests**: All core functionalities have passed standard integration tests.

### Demo Videos

<p align="center">
  <img src="doc/media/basic-demo.gif" alt="ToStore basic performance demo" width="320" />
  </p>

- **Basic performance demo** (<a href="doc/media/basic-demo.mp4?raw=1" target="_blank" rel="noopener">basic-demo.mp4</a>): GIF preview may be cropped; click the video to view the full demo. Shows that even on an ordinary mobile device with 100M+ records, startup, paging, and search performance remain stable and smooth. As long as storage is sufficient, edge devices can sustain TB/PB-scale datasets while keeping interactive latency consistently low.

<p align="center">
  <img src="doc/media/disaster-recovery.gif" alt="ToStore disaster recovery stress test" width="320" />
  </p>

- **Disaster recovery stress test** (<a href="doc/media/disaster-recovery.mp4?raw=1" target="_blank" rel="noopener">disaster-recovery.mp4</a>): Intentionally kills the process during intensive write workloads to simulate crashes and power failures. Even when tens of thousands of operations are interrupted, ToStore recovers extremely fast on a typical phone and does not impact startup or data availability.




If ToStore helps you, please give us a ⭐️




## Roadmap

ToStore is actively developing features to further enhance AI-era data infrastructure:

- **High-Dimensional Vectors**: Adding vector retrieval and semantic search algorithms.
- **Multi-modal Data**: Providing end-to-end processing from raw data to feature vectors.
- **Graph Data Structures**: Supporting efficient storage and querying of knowledge graphs and complex relational networks.





> **Recommendation**: Mobile developers might also consider the [Toway Framework](https://github.com/tocreator/toway), a full-stack solution that automates data requests, loading, storage, caching, and display.




## More Resources

- 📖 **Documentation**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Feedback**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Discussion**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


