# ToStore

English | [简体中文](doc/translations/README.zh-CN.md) | [日本語](doc/translations/README.ja.md) | [한국어](doc/translations/README.ko.md) | [Español](doc/translations/README.es.md) | [Português (Brasil)](doc/translations/README.pt-BR.md) | [Русский](doc/translations/README.ru.md) | [Deutsch](doc/translations/README.de.md) | [Français](doc/translations/README.fr.md) | [Italiano](doc/translations/README.it.md) | [Türkçe](doc/translations/README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

ToStore is a fast, high-performance relational database and storage engine for Dart/Flutter applications. it provides both SQL and key-value data persistence with smart caching and efficient indexing. The multi-space architecture enables concurrent query capabilities and optimized local storage.



Built with mobile apps in mind, ToStore offers:
- Efficient data persistence through file storage and smart caching
- Flexible query options with SQL, key-value, and schema-based tables
- Advanced indexing system for fast data retrieval
- Transaction support with ACID compliance
- Multi-space architecture for data isolation
- Concurrent access with optimized performance
- Lightweight and easy to integrate
- Automatic schema upgrades without manual version migration

Implemented purely in Dart, ToStore achieves exceptional performance through B+ tree indexing and intelligent caching strategies. Enterprise-grade features like transaction protection, automatic repair, and incremental backup ensure reliable data storage for your applications.

## Why ToStore?

- 🚀 **Ultimate Performance**: 
  - B+ tree indexing with smart query optimization
  - Intelligent caching strategy with millisecond response
  - Non-blocking concurrent read/write with stable performance
- 🔄 **Smart Schema Evolution**: 
  - Automatic table structure upgrades through schemas
  - No more manual version-by-version migrations
  - Chainable schema modification API for complex changes
  - Zero-downtime schema updates
- 🎯 **Easy to Use**: 
  - Fluent chainable API design
  - Support for SQL/Map style queries
  - Smart type inference with complete code hints
  - Zero configuration, ready out of the box
- 🔄 **Innovative Architecture**: 
  - Multi-space data isolation, perfect for multi-user scenarios
  - Global data sharing solves configuration sync challenges
  - Support for nested transactions
  - On-demand space loading minimizes resource usage
  - Automatic storage data operations (upsert)
- 🛡️ **Enterprise-Grade Reliability**: 
  - ACID transaction protection ensures data consistency
  - Incremental backup mechanism with quick recovery
  - Data integrity validation with automatic error repair

## Quick Start

### Basic Setup

```dart
// Initialize database
final db = ToStore(
  version: 2, // every time the version number is increased, the data table structure in schemas will be automatically created or upgraded
  schemas: [
    // Simply define your latest schema, ToStore handles the upgrade automatically
    const TableSchema(
      name: 'users',
      primaryKey: 'id',
      fields: [
        FieldSchema(name: 'id', type: DataType.integer, nullable: false),
        FieldSchema(name: 'username', type: DataType.text, nullable: false),
        FieldSchema(name: 'email', type: DataType.text, nullable: false),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [
        IndexSchema(fields: ['username'], unique: true),
        IndexSchema(fields: ['email'], unique: true),
      ],
    ),
    const TableSchema(
      name: 'settings',
      primaryKey: 'key',
      isGlobal: true,
      fields: [
        FieldSchema(name: 'key', type: DataType.text, nullable: false),
        FieldSchema(name: 'value', type: DataType.text),
        FieldSchema(name: 'updated_at', type: DataType.datetime),
      ],
    ),
  ],
  // complex upgrade and migration can be done using db.updateSchema
  // if the number of data tables is small, it is recommended to directly adjust the data structure in schemas for automatic upgrade
  onUpgrade: (db, oldVersion, newVersion) async {
    if (oldVersion == 1) {
      await db.updateSchema('users') // update users table structure
          .addField("fans", type: DataType.array, comment: "fans") // add fans field
          .addIndex("follow",fields: ["follow", "username"]) // add follow index
          .dropField("last_login") // drop last_login field
          .modifyField('email', unique: true)   // more complex field modification
          .renameField("last_login", "last_login_time"); // rename last_login to last_login_time
    } else if (oldVersion == 2) {
      await db.updateSchema('users').renameTo('users_new'); // rename users table to users_new
    }
  },
);
await db.initialize(); // Optional, ensures database is fully initialized before operations

// Insert data
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// Update data
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Delete data
await db.delete('users').where('id', '!=', 1);

// Chain query with complex conditions
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Count records
final count = await db.query('users').count();

// SQL style query
final users = await db.queryBySql(
  'users',
  where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)',
  limit: 10
);

// Map style query
final users = await db.queryByMap(
  'users',
  where: {
    'age': {'>=': 30},
    'name': {'like': '%John%'},
  },
  orderBy: ['age'],
  limit: 10,
);

// Batch insert
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## Multi-Space Architecture

ToStore's multi-space architecture makes multi-user data management effortless:

```dart
// Switch to user space
await db.switchBaseSpace(spaceName: 'user_123');

// Query user data
final followers = await db.query('followers');

// Set or update key-value data, isGlobal: true means global data
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Get global key-value data
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```



### Upsert Data

```dart
// Automatically store data,Support batch upsert
await db.upsert('users', {'name': 'John'})
  .where('email', '=', 'john@example.com');

// Auto insert or update based on primary key
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});
```



## Performance

In high-concurrency scenarios including batch writes, random read/writes, and conditional queries, ToStore demonstrates exceptional performance, far surpassing other mainstream databases available for Dart/Flutter.

## More Features

- 💫 Elegant chainable API
- 🎯 Smart type inference
- 📝 Complete code hints
- 🔐 Automatic incremental backup
- 🛡️ Data integrity validation
- 🔄 Crash auto-recovery
- 📦 Smart data compression
- 📊 Automatic index optimization
- 💾 Tiered caching strategy

Our goal isn't just to create another database. ToStore is extracted from the Toway framework to provide an alternative solution. If you're developing mobile applications, we recommend using the Toway framework, which offers a complete Flutter development ecosystem. With Toway, you won't need to deal with the underlying database directly - data requests, loading, storage, caching, and display are all handled automatically by the framework.
For more information about the Toway framework, visit the [Toway Repository](https://github.com/tocreator/toway)

## Documentation

Visit our [Wiki](https://github.com/tocreator/tostore) for detailed documentation.

## Support & Feedback

- Submit Issues: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Join Discussions: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Contribute: [Contributing Guide](CONTRIBUTING.md)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<p align="center">If you find ToStore helpful, please give us a ⭐️</p> 