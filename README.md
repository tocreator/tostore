<!--
This README describes the package. If you publish this package to pub.dev,
this README's contents appear on the landing page for your package.

For information about how to write a good package README, see the guide for
[writing package pages](https://dart.dev/tools/pub/writing-package-pages).

For general information about developing packages, see the Dart guide for
[creating packages](https://dart.dev/guides/libraries/create-packages)
and the Flutter guide for
[developing packages and plugins](https://flutter.dev/to/develop-packages).
-->

# ToStore

[English](README_EN.md) | 简体中文

ToStore 是一款重新定义 Dart/Flutter 数据存储的高性能引擎。它完全采用纯 Dart 实现，通过现代化的API设计和创新，表现出超越当前 Flutter 平台上主流数据库数倍的性能。其多空间架构让切换用户数据管理变得前所未有的简单，是目前 Dart 平台上首选的数据存储方案。

## 为什么选择 ToStore?

- 🚀 **极致性能**: 
  - 纯 Dart 实现，无平台限制
  - 智能缓存策略，性能持续优化
  - 高并发读写性能远超主流方案
- 🎯 **简单易用**: 
  - 流畅的链式 API 设计
  - 支持 SQL/Map 双风格查询
  - 5 分钟即可完成迁移
- 🔄 **创新架构**: 
  - 突破性的多空间设计
  - 用户数据完全隔离
  - 全局表轻松共享
- 🛡️ **企业级可靠**: 
  - 自动备份与恢复
  - 数据完整性校验
  - ACID 事务支持

## 快速开始

1. 添加依赖:

```yaml
dependencies:
  tostore: ^1.8.1
```

2. 基础使用:

```dart
// 初始化数据库
final db = ToStore(
  version: 1,
  onCreate: (db) async {
    // 创建表
    await db.createTable(
      'users',
      TableSchema(
        primaryKey: 'id',
        fields: [
          FieldSchema(name: 'id', type: DataType.integer, nullable: false),
          FieldSchema(name: 'name', type: DataType.text, nullable: false),
          FieldSchema(name: 'age', type: DataType.integer),
        ],
        indexes: [
          IndexSchema(fields: ['name'], unique: true),
        ],
      ),
    );
  },
);

// 插入数据
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// 更新数据
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// 删除数据
await db.delete('users').where('id', '!=', 1);

// 链式查询，支持复杂条件
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// 查询记录数
final count = await db.query('users').count();

// Sql风格查询
final users = await db.queryBySql('users',where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)', limit: 10);

// Map风格查询
final users = await db.queryByMap(
    'users',
    where: {
      'age': {'>=': 30},
      'name': {'like': '%John%'},
    },
    orderBy: ['age'],
    limit: 10,
);

// 批量插入
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## 多空间架构

ToStore 的多空间架构设计让多用户数据管理变得轻而易举：

```dart
// 切换到用户
await db.switchBaseSpace(spaceName: 'user_123');

// 查询用户数据
final followers = await db.query('followers');

// 设置键值对数据或更新，isGlobal: true 表示全局数据
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// 获取全局键值对数据
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## 性能测试

在高并发场景下的批量写入、随机读写、条件查询等性能测试，ToStore 均表现出色，远超其它支持dart、flutter的主流数据库。

## 更多特性

- 💫 优雅的链式 API
- 🎯 智能的类型推导
- 📝 完善的代码提示
- 🔐 自动增量备份
- 🛡️ 数据完整性校验
- 🔄 崩溃自动恢复
- 📦 智能数据压缩
- 📊 自动索引优化
- 💾 分级缓存策略

## 文档

访问我们的 [Wiki](https://github.com/tocreator/tostore) 获取详细文档。

## 支持与反馈

- 提交 Issue: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 加入讨论: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- 贡献代码: [Contributing Guide](CONTRIBUTING.md)

## 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件。

---

<p align="center">如果觉得 ToStore 对你有帮助，欢迎给我们一个 ⭐️</p>
