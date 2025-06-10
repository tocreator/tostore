# Tostore

English | [简体中文](doc/translations/README.zh-CN.md) | [日本語](doc/translations/README.ja.md) | [한국어](doc/translations/README.ko.md) | [Español](doc/translations/README.es.md) | [Português (Brasil)](doc/translations/README.pt-BR.md) | [Русский](doc/translations/README.ru.md) | [Deutsch](doc/translations/README.de.md) | [Français](doc/translations/README.fr.md) | [Italiano](doc/translations/README.it.md) | [Türkçe](doc/translations/README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

Tostore is a high-performance distributed data storage engine that builds intelligent data networks using multi-partition parallel mechanisms and interconnected topology. It provides precise table structure change detection, encryption protection, and multi-space architecture. The Isolate parallel processing mechanism fully unleashes multi-core performance, while Dart's cross-platform nature naturally supports collaboration from mobile edge devices to the cloud. With various distributed primary key algorithms and node horizontal scaling capabilities, Tostore provides a distributed data foundation for immersive virtual-real integration, multimodal interaction, three-dimensional spatial features, generative AI, and semantic vector space modeling.

## Why Choose Tostore?

### 1. Partition Parallel Mechanism vs Single File Storage
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Intelligent partitioning mechanism, data distributed across multiple appropriately sized files | ❌ Single data file becomes bloated as data grows, performance drops dramatically |
| ✅ Only reads relevant partition data, query performance decoupled from total data volume | ❌ Even querying a single record requires loading the entire data file |
| ✅ Maintains millisecond-level response with TB-scale data | ❌ Performance noticeably decreases on mobile devices after data exceeds 5MB |
| ✅ True multi-core parallel processing via Isolates, multiplying performance | ❌ Single file cannot be processed concurrently, wasting CPU resources |

### 2. Embedded Deep Integration vs Independent Data Storage
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Pure Dart language, seamless integration with Flutter/Dart projects | ❌ Requires learning SQL or specific query languages, increasing learning costs |
| ✅ Unified technology stack for front and back end, same code throughout the stack | ❌ Multiple programming languages and tech stacks for front and back end, high switching costs |
| ✅ Chain API consistent with modern programming styles, superior development experience | ❌ String concatenation for SQL prone to attacks and errors, lacks type safety |
| ✅ Direct use of Dart objects, no need for complex ORM mapping | ❌ Complex object-relational mapping, high development and maintenance costs |

### 3. Precise Table Structure Change Detection vs Manual Migration Management
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Automatically detects table structure changes, no manual version management needed | ❌ Relies on manual version control and explicit migration code |
| ✅ Millisecond-level detection and automatic data migration | ❌ Requires writing upgrade migration logic for each version |
| ✅ Precisely identifies table field renaming with zero data loss | ❌ Renaming table fields is complex and prone to data loss |
| ✅ Fully automated structure upgrades, imperceptible during business operations | ❌ Complex upgrade logic as versions increase, difficult maintenance |

### 4. Multi-space Architecture vs Single Storage Space
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Multi-space architecture, perfect isolation of different user data | ❌ Single storage space, mixed storage of multi-user data |
| ✅ One line of code to switch spaces, simple and efficient | ❌ Requires creating multiple database instances or complex isolation logic |
| ✅ Flexible space isolation and global data sharing mechanism | ❌ Difficult to balance user data isolation and sharing |
| ✅ Simple API for cross-space data copying and migration | ❌ Tenant migration or data copying operations are cumbersome and complex |
| ✅ Queries automatically limited to current space, no additional filtering needed | ❌ Queries for different users require complex filtering conditions |




## Tostore Features

- 🌐 **Seamless Cross-platform Support**
  - One set of code runs across all platforms from mobile apps to cloud servers
  - Intelligently adapts to different platform storage backends (IndexedDB, file system, etc.)
  - Unified API interface, worry-free cross-platform data synchronization
  - Seamless data flow from edge devices to cloud servers
  - Local vector computation on edge devices, reducing network latency and cloud dependency

- 🧠 **Neural Network-like Distributed Architecture**
  - Neural network-like interconnected node topology efficiently organizes data flow
  - High-performance data partitioning mechanism enables true distributed processing
  - Intelligent dynamic workload balancing maximizes resource utilization
  - Unlimited horizontal node scaling, easily building complex data networks

- ⚡ **Ultimate Parallel Processing Capability**
  - True parallel read/write via Isolates, full-speed operation on multi-core CPUs
  - Multi-node computational network working collaboratively, multiplying task processing efficiency
  - Resource-aware scheduling framework automatically optimizes execution plans
  - Streaming query interface easily handles massive datasets

- 🔑 **Diverse Distributed Primary Key Algorithms**
  - Sequential increment algorithm - freely adjustable random step length, hiding business scale
  - Timestamp-based algorithm - best choice for high-concurrency scenarios
  - Date prefix algorithm - perfect support for time-range data display
  - Short code algorithm - generates short, readable unique identifiers

- 🔄 **Intelligent Schema Migration**
  - Precise identification of table field renaming with zero data loss
  - Millisecond-level automatic detection of table structure changes and data migration
  - Zero-downtime upgrades, imperceptible to business operations
  - Safe migration strategies for complex structure changes

- 🛡️ **Security Guarantees**
  - ChaCha20Poly1305 high-strength encryption algorithm protects sensitive data
  - End-to-end encryption, security throughout storage and transmission
  - Fine-grained data access control

- 🚀 **Intelligent Cache and Retrieval Performance**
  - Multi-level intelligent caching mechanism for ultra-fast data retrieval
  - Startup preheating cache significantly improves application startup speed
  - Cache strategies deeply integrated with the storage engine
  - Adaptive expansion, maintaining stable performance as data scale grows

- 🔄 **Intelligent Data Workflow**
  - Multi-space architecture, data isolation with global sharing capabilities
  - Intelligent workload allocation across compute nodes
  - Provides solid foundation for large-scale data training and analysis



## Quick Start

```dart
// Initialize the database
final db = ToStore();
await db.initialize(); // Initialize, ensure database is ready

// Insert data
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// Update data
await db.update('users', {'age': 31}).where('id', '=', 1);

// Delete data
await db.delete('users').where('id', '!=', 1);

// Chain queries - concise and powerful
// Supported operators: =, !=, <>, >, <, >=, <=, LIKE, NOT LIKE, IN, NOT IN, BETWEEN, IS, IS NOT
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Complex query condition nesting - Modular predefined query conditions
final recentLoginCondition = QueryCondition()
    .where('fans', '>=', 200);

final idCondition = QueryCondition()
    .where('id', '>=', 123)
    .orCondition(  // orCondition is equivalent to OR condition combination
        recentLoginCondition
    );

// Custom condition function - Flexible handling of any complex logic
final customCondition = QueryCondition()
    .whereCustom((record) {
      // For example: check if tags contain 'recommended'
      return record['tags'] != null && record['tags'].contains('recommended');
    });

// Query condition nesting example - Demonstrates unlimited nesting capability
final result = await db.query('users')
    .condition(      
        QueryCondition()    // Query condition construction
            .whereEqual('type', 'app')
            .or()
            .condition(idCondition)  // Nest previously defined conditions
    )
    .orCondition(customCondition)    // Or satisfy custom complex condition
    .limit(20);
// SQL equivalent: 
// SELECT * FROM users 
// WHERE (status = 'active' AND is_vip >= 1)
//   AND (type = 'app' OR id >= 123 OR fans >= 200)
//   OR ([custom condition: tags contain 'recommended'])
// LIMIT 20

// Smart storage - update if exists, insert if not
await db.upsert('users', {
  'name': 'John',
  'email': 'john@example.com'
}).where('email', '=', 'john@example.com');
// Or update/insert directly using primary key ID
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});

// Efficient statistics
final count = await db.query('users').count();

// Stream queries - process large datasets without consuming lots of memory
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // Process data item by item, avoiding memory pressure
    print('Processing user: ${userData['username']}');
  });

// Global configuration storage
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Get global key-value data
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);

// Select specific fields query - Improve performance
final userProfiles = await db.query('users')
    .select(['id', 'username', 'email']) // Only return specified fields
    .where('is_active', '=', true)
    .limit(100);

// Table join query - Multi-table data association
final ordersWithUsers = await db.query('orders')
    .select([
      'orders.id', 
      'orders.amount', 
      'users.username as customer_name', // Using alias
    ])
    .join('users', 'orders.user_id', '=', 'users.id') // Inner join
    .where('orders.amount', '>', 1000)
    .limit(50);
```

## Integration for Frequent Startup Scenarios

```dart
// Table structure definition approach for mobile apps, desktop clients, and other frequently starting scenarios
// Precisely identifies table structure changes, automatically upgrades and migrates data, zero code maintenance
final db = ToStore(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // Set as global table, accessible to all spaces
            fields: []
    ),
    const TableSchema(
      name: 'users', // Table name
      tableId: "users",  // Unique table identifier, optional, used for 100% identification of renaming needs, 
                         // even without it, precision rate is still above 99.99%
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // Primary key name
      ),
      fields: [        // Field definitions (excluding primary key)
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true,
          fieldId: 'username',  // Unique field identifier, optional
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime
        ),
      ],
      indexes: [ // Index definitions
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// Multi-space architecture - Perfect isolation of different user data
await db.switchSpace(spaceName: 'user_123');


// Get global table data - Because the table name is globally unique, table operations do not require the isGlobal parameter to distinguish
final globalSettings = await db.query('global_settings');
// Only when storing key value pairs, it is necessary to indicate whether isGlobal is global, and the query should be consistent with the settings
await db.setValue('global_config', true, isGlobal: true);
final isAgreementPrivacy = await db.getValue('global_config', isGlobal: true);

```

## Server-side Integration

```dart
// Dynamic table structure creation for server-side - Suitable for continuous operation scenarios
await db.createTables([
  // Three-dimensional spatial feature vector storage table structure
  const TableSchema(
    name: 'spatial_embeddings',                // Table name
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',                            // Primary key name
      type: PrimaryKeyType.timestampBased,   // Timestamp-based primary key type, ideal for high-concurrency writes
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
          dimensions: 1024,                   // High-dimensional vector suitable for spatial features
          precision: VectorPrecision.float32, // Balance between precision and storage space
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
          indexType: VectorIndexType.hnsw,   // HNSW algorithm, efficient nearest neighbor search algorithm
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,                         // Maximum connections per layer
            'efConstruction': 200,           // Build quality parameter
          },
        ),
      ),
    ],
  ),
  // Other tables...
]);

// Online table structure updates - Business-imperceptible
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // Modify table name
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // Modify field properties
  .renameField('old_name', 'new_name')     // Modify field name
  .removeField('deprecated_field')         // Remove field
  .addField('created_at', type: DataType.datetime)  // Add field
  .removeIndex(fields: ['age'])            // Remove index
  .setPrimaryKeyConfig(                    // Change primary key configuration
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// Monitor migration progress
final status = await db.queryMigrationTaskStatus(taskId);
print('Migration progress: ${status?.progressPercentage}%');
```

## Distributed Architecture

```dart
// Configure distributed nodes
final db = ToStore(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,            // Enable distributed mode
      clusterId: 1,                       // Cluster ID, configures cluster affiliation
      centralServerUrl: 'http://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// High-performance batch insertion
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Vector data records inserted efficiently at once
]);

// Stream processing of large datasets - Constant memory usage
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Process efficiently even with TB-level data without consuming large amounts of memory
  print(record);
}
```

## Primary Key Type Examples

Tostore provides multiple distributed primary key algorithms to support various business scenarios:

- **Sequential Increment Key** (PrimaryKeyType.sequential): 238978991
- **Timestamp Key** (PrimaryKeyType.timestampBased): 1306866018836946
- **Date Prefix Key** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **Short Code Key** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// Sequential increment primary key configuration example
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,           // Sequential key type
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,                     // Starting value
        increment: 50,                           // Step size
        useRandomIncrement: true,                // Random step size, hides business volume
      ),
    ),
    fields: [/* Field definitions */]
  ),
]);
```


## Security Configuration

```dart
// Data security protection configuration
final db = ToStore(
  config: DataStoreConfig(
    enableEncoding: true,          // Enable data security encoding
    encodingKey: 'YourEncodingKey', // Custom encoding key, data automatically migrates after adjustment
    encryptionKey: 'YourEncryptionKey', // Encryption key (Warning: old data cannot be accessed after modification, 
                                        // do not hard-code into applications)
  ),
);
```





If Tostore has been helpful to you, please give us a ⭐️





## Future Plans

Tostore is actively developing the following features to further enhance data infrastructure capabilities in the AI era:

- **High-dimensional Vectors**: Adding vector retrieval and semantic search algorithms
- **Multimodal Data**: Providing end-to-end processing from raw data to feature vectors
- **Graph Data Structures**: Supporting efficient storage and querying of knowledge graphs and complex relationship networks





> **Recommendation**: Mobile app developers may consider using the [Toway Framework](https://github.com/tocreator/toway), which provides a full-stack solution that automatically handles data requests, loading, storage, caching, and display.




## More Resources

- 📖 **Documentation**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Issue Feedback**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Technical Discussions**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details

---
