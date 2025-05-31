# Tostore

English | [简体中文](doc/translations/README.zh-CN.md) | [日本語](doc/translations/README.ja.md) | [한국어](doc/translations/README.ko.md) | [Español](doc/translations/README.es.md) | [Português (Brasil)](doc/translations/README.pt-BR.md) | [Русский](doc/translations/README.ru.md) | [Deutsch](doc/translations/README.de.md) | [Français](doc/translations/README.fr.md) | [Italiano](doc/translations/README.it.md) | [Türkçe](doc/translations/README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

Tostore is a cross-platform distributed architecture database engine deeply integrated into your project. Its neural network-inspired data processing model implements brain-like data management. Multi-partition parallelism mechanisms and node interconnection topology create an intelligent data network, while parallel processing with Isolate fully utilizes multi-core capabilities. With various distributed primary key algorithms and unlimited node extension, it can serve as a data layer for distributed computing and large-scale data training infrastructures, enabling seamless data flow from edge devices to cloud servers. Features like precise schema change detection, intelligent migration, ChaCha20Poly1305 encryption, and multi-space architecture perfectly support various application scenarios, from mobile apps to server-side systems.

## Why Choose Tostore?

### 1. Partition Parallel Processing vs. Single File Storage
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Intelligent partitioning mechanism, data distributed across multiple files of appropriate size | ❌ Storage in a single data file, linear performance degradation with growing data |
| ✅ Reads only relevant partition files, query performance decoupled from total data volume | ❌ Need to load the entire data file, even for querying a single record |
| ✅ Maintains millisecond response times even with TB-level data volumes | ❌ Significant increase in read/write latency on mobile devices when data exceeds 5MB |
| ✅ Resource consumption proportional to the amount of data queried, not total data volume | ❌ Resource-limited devices subject to memory pressure and OOM errors |
| ✅ Isolate technology enables true multi-core parallel processing | ❌ A single file cannot be processed in parallel, waste of CPU resources |

### 2. Dart Parallelism vs. Traditional Script Languages
| Tostore | Traditional Script-Based Databases |
|:---------|:-----------|
| ✅ Isolates run in true parallel without global lock constraints | ❌ Languages like Python are limited by GIL, inefficient for CPU-intensive tasks |
| ✅ AOT compilation generates efficient machine code, near-native performance | ❌ Performance loss in data processing due to interpreted execution |
| ✅ Independent memory heap model, avoids lock and memory contentions | ❌ Shared memory model requires complex locking mechanisms in high concurrency |
| ✅ Type safety provides performance optimizations and compile-time error checking | ❌ Dynamic typing discovers errors at runtime with fewer optimization opportunities |
| ✅ Deep integration with the Flutter ecosystem | ❌ Requires additional ORM layers and UI adapters, increasing complexity |

### 3. Embedded Integration vs. Independent Data Stores
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Uses Dart language, seamlessly integrates with Flutter/Dart projects | ❌ Requires learning SQL or specific query languages, increasing learning curve |
| ✅ Same code supports frontend and backend, no need to change technology stack | ❌ Frontend and backend typically require different databases and access methods |
| ✅ Chained API style matching modern programming styles, excellent developer experience | ❌ SQL string concatenation vulnerable to attacks and errors, lack of type safety |
| ✅ Support for reactive programming, naturally mates with UI frameworks | ❌ Requires additional adaptation layers to connect UI and data layer |
| ✅ No need for complex ORM mapping configuration, direct use of Dart objects | ❌ Complexity of object-relational mapping, high development and maintenance costs |

### 4. Precise Schema Change Detection vs. Manual Migration Management
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Automatically detects schema changes, no version number management needed | ❌ Dependency on manual version control and explicit migration code |
| ✅ Millisecond-level detection of table/field changes and automatic data migration | ❌ Need to maintain migration logic for upgrades between versions |
| ✅ Precisely identifies table/field renames, preserves all historical data | ❌ Table/field renames can lead to data loss |
| ✅ Atomic migration operations ensuring data consistency | ❌ Migration interruptions can cause data inconsistencies |
| ✅ Fully automated schema updates without manual intervention | ❌ Complex upgrade logic and high maintenance costs with increasing versions |

### 5. Multi-Space Architecture vs. Single Storage Space
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Multi-space architecture, perfectly isolating data of different users | ❌ Single storage space, mixed storage of multiple users' data |
| ✅ Space switching with one line of code, simple and effective | ❌ Requires multiple database instances or complex isolation logic |
| ✅ Flexible space isolation and global data sharing mechanism | ❌ Difficult to balance isolation and sharing of user data |
| ✅ Simple API for copying or migrating data between spaces | ❌ Complex operations for tenant migration or data copying |
| ✅ Queries automatically limited to current space, no additional filtering needed | ❌ Queries for different users require complex filtering |

### 6. Cross-Platform Support vs. Platform Limitations
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Unified API across Linux, Web, Mobile, Desktop platforms | ❌ Different platforms require different storage engines and APIs |
| ✅ Automatic adaptation to various cross-platform storage backends, consistent development experience | ❌ Cross-platform development must handle platform differences |
| ✅ Define once, use data models across all platforms | ❌ Requires redesigning data models for different platforms |
| ✅ Optimized cross-platform performance, maintains consistent user experience | ❌ Inconsistent performance characteristics across platforms |
| ✅ Unified security standards implemented across all platforms | ❌ Platform-specific security mechanisms and configurations |

### 7. Distributed Primary Key Algorithms vs. Traditional Auto-Increment IDs
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Four distributed primary key algorithms suited to various scenario requirements | ❌ Simple auto-increment IDs, subject to conflicts in cluster environments |
| ✅ Distributed ID generation, supports extremely high parallel operations | ❌ Serial ID generation becomes bottleneck in high parallelism |
| ✅ Random step length and distributed algorithms avoiding exposure of business scale | ❌ IDs leak business volume information, creating security risks |
| ✅ From short codes to timestamps, satisfies various readability and performance requirements | ❌ Limited ID types and customization options |

### 8. Streaming Data Processing vs. Batch Loading
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Streaming query interface, on-demand data processing, low memory usage | ❌ Loads all results at once, susceptible to OOM with large datasets |
| ✅ Support for asynchronous iteration and reactive programming patterns | ❌ Synchronous processing model blocks UI thread, affecting user experience |
| ✅ Parallel processing of streaming data, maximizes multi-core performance | ❌ Sequential processing of massive data, low CPU utilization |
| ✅ Support for data pipelines and transformation operations | ❌ Requires custom implementation of data processing logic |
| ✅ Built-in throttling and backpressure handling mechanisms | ❌ Lack of flow control, easy resource exhaustion |

### 9. Intelligent Caching Strategies vs. Traditional Caching
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Multi-level intelligent caching strategies, adaptive to access patterns | ❌ Simple LRU caching, lack of flexibility |
| ✅ Automatic caching strategy adjustment based on usage patterns | ❌ Fixed cache configuration, difficult to adjust dynamically |
| ✅ Startup caching mechanism dramatically reducing cold start times | ❌ No startup cache, slow cold starts, need to rebuild cache |
| ✅ Storage engine deeply integrated with cache for optimal performance | ❌ Separate caching and storage logic, requiring additional synchronization mechanisms |
| ✅ Automatic cache synchronization and invalidation management, no additional code needed | ❌ Cache consistency requires manual maintenance, prone to errors |

### 10. Serverless Architecture vs. Traditional Server Dependency
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Embedded design, no need for additional servers or configurations | ❌ Requires separate database server or cloud service |
| ✅ Zero maintenance cost, application-embedded data layer | ❌ Requires dedicated DBAs and operations teams |
| ✅ Capable of offline operation, no dependency on network connectivity | ❌ Depends on network reliability, unusable in offline scenarios |
| ✅ Simple deployment, application includes full data functionality | ❌ Complex server configuration and connection management |
| ✅ Combines independence with distributed scaling capabilities | ❌ Either simple without scalability, or complex and difficult to maintain |

### 11. Intelligent Resource Optimization vs. Fixed Resource Allocation
| Tostore | Traditional Databases |
|:---------|:-----------|
| ✅ Dynamic adjustment of resource consumption based on actual demands | ❌ Fixed resource allocation regardless of workload |
| ✅ Automatic parallelism adjustment based on device capabilities | ❌ Doesn't account for device capabilities, complex and difficult to optimize |
| ✅ Intelligent batch processing strategies, automatically optimizes batch operations | ❌ Requires manual implementation of batch processing logic, laborious and error-prone |
| ✅ Memory usage corresponding to active data volume, independent of total data volume | ❌ Memory usage highly correlated with total database size |
| ✅ Automatically balances power consumption and performance, mobile-friendly | ❌ Not optimized for battery-powered devices, high energy consumption and heat generation |

## Technical Highlights

- 🌐 **Transparent Cross-Platform Support**:
  - Consistent experience across Web, Linux, Windows, Mobile, Mac platforms
  - Unified API interface, hassle-free cross-platform data synchronization
  - Automatic adaptation to various cross-platform storage backends (IndexedDB, file systems, etc.)
  - Seamless data flow from edge computing to cloud

- 🧠 **Neural Network-Inspired Distributed Architecture**:
  - Neural network-like topology of interconnected nodes
  - Efficient data partitioning mechanism for distributed processing
  - Intelligent dynamic workload balancing
  - Support for unlimited node extension, easy construction of complex data networks

- ⚡ **Ultimate Parallel Processing Capabilities**:
  - Truly parallel read/write with Isolates, full multi-core CPU utilization
  - Multi-node compute network cooperating for multiplied efficiency of multiple tasks
  - Resource-aware distributed processing framework, automatic performance optimization
  - Streaming query interface optimized for processing massive datasets

- 🔑 **Various Distributed Primary Key Algorithms**:
  - Sequential increment algorithm - freely adjustable random step length
  - Timestamp-based algorithm - ideal for high-performance parallel execution scenarios
  - Date-prefixed algorithm - suitable for data with time range indication
  - Short code algorithm - concise unique identifiers

- 🔄 **Intelligent Schema Migration**:
  - Precise identification of table/field renaming behaviors
  - Automatic data updating and migration during schema changes
  - Zero-downtime upgrades, no impact on business operations
  - Safe migration strategies preventing data loss

- 🛡️ **Enterprise-Level Security**:
  - ChaCha20Poly1305 encryption algorithm to protect sensitive data
  - End-to-end encryption, ensuring security of stored and transmitted data
  - Fine-grained data access control

- 🚀 **Intelligent Caching and Search Performance**:
  - Multi-level intelligent caching mechanism for efficient data retrieval
  - Startup caching dramatically improving app launch speed
  - Storage engine deeply integrated with cache, no additional synchronization code needed
  - Adaptive scaling, maintaining stable performance even with growing data

- 🔄 **Innovative Workflows**:
  - Multi-space data isolation, perfect support for multi-tenant, multi-user scenarios
  - Intelligent workload assignment between compute nodes
  - Provides robust database for large-scale data training and analysis
  - Automatic data storage, intelligent updates and insertions

- 💼 **Developer Experience is Priority**:
  - Detailed bilingual documentation and code comments (Chinese and English)
  - Rich debugging information and performance metrics
  - Built-in data validation and corruption recovery capabilities
  - Zero-configuration out-of-the-box, quick start

## Quick Start

Basic usage:

```dart
// Database initialization
final db = ToStore();
await db.initialize(); // Optional, ensures database initialization is completed before operations

// Data insertion
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// Data updating
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Data deletion
await db.delete('users').where('id', '!=', 1);

// Support for complex chained queries
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Automatic data storage, update if exists, insert if not
await db.upsert('users', {'name': 'John','email': 'john@example.com'})
  .where('email', '=', 'john@example.com');
// Or
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});

// Efficient record counting
final count = await db.query('users').count();

// Processing massive data using streaming queries
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // Process each record as needed, avoiding memory pressure
    print('Processing user: ${userData['username']}');
  });

// Set global key-value pairs
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Get data from global key-value pairs
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## Mobile App Example

```dart
// Table structure definition suitable for frequent startup scenarios like mobile apps, precise detection of table structure changes, automatic data upgrade and migration
final db = ToStore(
  schemas: [
    const TableSchema(
      name: 'users', // Table name
      tableId: "users",  // Unique table identifier, optional, used for 100% identification of renaming requirements, even without can achieve >98% accuracy rate
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id', // Primary key
      ),
      fields: [ // Field definition, does not include primary key
        FieldSchema(name: 'username', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'email', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [ // Index definition
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// Switch to user space - data isolation
await db.switchSpace(spaceName: 'user_123');
```

## Backend Server Example

```dart
await db.createTables([
      const TableSchema(
        name: 'users', // Table name
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id', // Primary key
          type: PrimaryKeyType.timestampBased,  // Primary key type
        ),
        fields: [
          // Field definition, does not include primary key
          FieldSchema(
              name: 'username',
              type: DataType.text,
              nullable: false,
              unique: true),
          FieldSchema(name: 'vector_data', type: DataType.blob),  // Vector data storage
          // Other fields...
        ],
        indexes: [
          // Index definition
          IndexSchema(fields: ['username']),
          IndexSchema(fields: ['email']),
        ],
      ),
      // Other tables...
]);


// Table structure update
final taskId = await db.updateSchema('users')
    .renameTable('newTableName')  // Rename table
    .modifyField('username',minLength: 5,maxLength: 20,unique: true)  // Modify field properties
    .renameField('oldName', 'newName')  // Rename field
    .removeField('fieldName')  // Remove field
    .addField('name', type: DataType.text)  // Add field
    .removeIndex(fields: ['age'])  // Remove index
    .setPrimaryKeyConfig(  // Set primary key configuration
      const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
    );
    
// Query migration task status
final status = await db.queryMigrationTaskStatus(taskId);  
print('Migration progress: ${status?.progressPercentage}%');
```


## Distributed Architecture

```dart
// Distributed node configuration
final db = ToStore(
    config: DataStoreConfig(
        distributedNodeConfig: const DistributedNodeConfig(
            enableDistributed: true,  // Enable distributed mode
            clusterId: 1,  // Cluster membership configuration
            centralServerUrl: 'http://127.0.0.1:8080',
            accessToken: 'b7628a4f9b4d269b98649129'))
);

// Batch insertion of vector data
await db.batchInsert('vector', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Thousands of records
]);

// Streaming processing of large datasets for analysis
await for (final record in db.streamQuery('vector')
    .where('vector_name', '=', 'face_2366')
    .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
    .stream) {
  // Streaming interface supports large-scale feature extraction and transformation
  print(record);
}
```

## Primary Key Examples
Various primary key algorithms, all supporting distributed generation, not recommended to generate primary keys yourself to avoid the impact of unordered primary keys on search capabilities.
Sequential primary key PrimaryKeyType.sequential: 238978991
Timestamp-based primary key PrimaryKeyType.timestampBased: 1306866018836946
Date-prefixed primary key PrimaryKeyType.datePrefixed: 20250530182215887631
Short code primary key PrimaryKeyType.shortCode: 9eXrF0qeXZ

```dart
// Sequential primary key PrimaryKeyType.sequential
// When distributed system is enabled, central server allocates ranges that nodes generate themselves, compact and easy to remember, suitable for user IDs and attractive numbers
await db.createTables([
      const TableSchema(
        name: 'users',
        primaryKeyConfig: PrimaryKeyConfig(
          type: PrimaryKeyType.sequential,  // Sequential primary key type
          sequentialConfig:  SequentialIdConfig(
              initialValue: 10000, // Auto-increment starting value
              increment: 50,  // Increment step
              useRandomIncrement: true,  // Use random step to avoid revealing business volume
            ),
        ),
        // Field and index definition...
        fields: []
      ),
      // Other tables...
 ]);
```


## Security Configuration

```dart
// Table and field renaming - automatic recognition and data preservation
final db = ToStore(
      config: DataStoreConfig(
        enableEncoding: true, // Enable secure encoding for table data
        encodingKey: 'YouEncodingKey', // Encoding key, can be adjusted arbitrarily
        encryptionKey: 'YouEncryptionKey', // Encryption key, note: changing this will prevent decoding of old data
      ),
    );
```

## Performance Tests

Tostore 2.0 implements linear performance scalability, fundamental changes in parallel processing, partitioning mechanisms, and distributed architecture have significantly improved data search capabilities, providing millisecond response times even with massive data growth. For processing large datasets, the streaming query interface can process massive data volumes without exhausting memory resources.



## Future Plans
Tostore is developing support for high-dimensional vectors to adapt to multimodal data processing and semantic search.


Our goal is not to create a database; Tostore is simply a component extracted from the Toway framework for your consideration. If you are developing mobile applications, we recommend using the Toway framework with its integrated ecosystem, which covers the full-stack solution for Flutter application development. With Toway, you won't need to touch the underlying database, all query, loading, storage, caching, and data display operations will be automatically performed by the framework.
For more information about the Toway framework, please visit the [Toway repository](https://github.com/tocreator/toway).

## Documentation

Visit our [Wiki](https://github.com/tocreator/tostore) for detailed documentation.

## Support and Feedback

- Submit issues: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Join the discussion: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Contribute code: [Contributing Guide](CONTRIBUTING.md)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<p align="center">If you find Tostore useful, please give us a ⭐️</p>
