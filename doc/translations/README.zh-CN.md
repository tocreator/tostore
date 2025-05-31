# Tostore

[English](../../README.md) | 简体中文 | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

Tostore 是一款跨平台采用分布式架构设计的数据存储引擎，嵌入式与项目深度融合，类神经网络数据处理模型实现类脑计算数据管理。其多分区并行机制与多节点互联拓扑结构创建一个智能数据网络，Isolate并行处理机制充分利用多核心能力。多种分布式主键算法与无限节点扩展能力使其可以作为分布式计算、大规模数据训练基础设施的数据层，从边缘设备到云端服务器的跨平台无缝数据流动。精准的表结构变动识别与智能迁移、ChaCha20Poly1305加密保护以及多空间架构等特性完美助力从移动应用到服务器端的各类应用场景。

## 为什么选择 Tostore？

### 1. 分区并行机制 vs 单一文件存储
| Tostore | 传统数据库 |
|:---------|:-----------|
| ✅ 智能分区机制，数据分布在多个适当大小的文件中 | ❌ 单个数据文件存储，随着数据增长性能直线下降 |
| ✅ 只读取相关分区文件，查询性能与数据总量解耦 | ❌ 即使查询单条记录也需加载整个数据文件 |
| ✅ TB级数据量依然保持毫秒级响应时间 | ❌ 数据超过5MB后移动设备上读写延迟显著增加 |
| ✅ Isolate技术实现真正的多核心并行处理 | ❌ 单文件无法并发处理，CPU资源浪费 |

### 2. 嵌入式与项目深度融合 vs 独立数据存储
| Tostore | 传统数据库 |
|:---------|:-----------|
| ✅ 使用Dart语言，与Flutter/Dart项目无缝集成 | ❌ 需要学习SQL或特定查询语言，增加学习成本 |
| ✅ 同一套代码支持前端和后端，无需切换技术栈 | ❌ 前后端通常需要不同的数据库和访问方式 |
| ✅ 链式API与现代编程风格一致，开发体验佳 | ❌ 字符串拼接SQL容易攻击和出错，缺乏类型安全 |
| ✅ 无需配置复杂的ORM映射，直接使用Dart对象 | ❌ 对象关系映射复杂，开发和维护成本高 |

### 3. 精准识别表结构变动 vs 手动迁移管理
| Tostore | 传统数据库 |
|:---------|:-----------|
| ✅ 自动识别表结构变动，无需版本号管理 | ❌ 依赖手动版本号控制和显式迁移代码 |
| ✅ 毫秒级识别表、字段变化并自动迁移数据 | ❌ 需要维护每个版本间的升级迁移逻辑 |
| ✅ 精准识别表、字段重命名，不丢失任何数据 | ❌ 表、字段重命名会导致数据丢失 |
| ✅ 完全自动化的表结构升级，无需人工干预 | ❌ 版本增多后升级逻辑复杂，维护成本高 |

### 4. 多空间架构 vs 单一存储空间
| Tostore | 传统数据库 |
|:---------|:-----------|
| ✅ 多空间架构，完美隔离不同用户数据 | ❌ 单一存储空间，多用户数据混合存储 |
| ✅ 一行代码切换空间，简单高效 | ❌ 需要多个数据库实例或复杂隔离逻辑 |
| ✅ 灵活的空间隔离与全局数据共享机制 | ❌ 用户数据隔离与共享难以平衡 |
| ✅ 简单API即可跨空间复制或迁移数据 | ❌ 租户迁移或数据复制操作复杂 |
| ✅ 查询自动限定在当前空间，无需额外过滤 | ❌ 针对不同用户的查询需要复杂过滤 |




## 核心技术亮点

- 🌐 **全平台无缝支持**：
  - Web、Linux、Windows、Mobile、Mac全平台一致体验
  - 统一API接口，跨平台数据同步无忧
  - 自动适配不同平台存储后端（IndexedDB、文件系统等）
  - 边缘计算到云端的无缝数据流动

- 🧠 **神经网络式分布式架构**：
  - 类神经网络的互联节点拓扑结构
  - 高效数据分区机制助力分布式处理
  - 智能工作负载动态平衡
  - 支持无限节点扩展，轻松构建复杂数据网络

- ⚡ **极致并行处理能力**：
  - Isolate真正并行读写，CPU多核心充分利用
  - 多节点计算网络协同工作，多任务同时执行效率倍增
  - 资源感知的分布式处理框架，自动优化性能
  - 流式查询接口优化大数据集处理

- 🔑 **多样化分布式主键算法**：
  - 顺序递增算法 - 自由调整随机步长
  - 时间戳基础算法 - 高性能并发场景首选
  - 日期前缀算法 - 适合时间范围展示数据
  - 短码算法 - 简短的唯一标识符

- 🔄 **智能模式迁移**：
  - 精准识别表、字段重命名行为
  - 表结构变动时自动升级和迁移数据
  - 零停机时间升级，业务无感知
  - 避免数据丢失的安全迁移策略

- 🛡️ **企业级安全保障**：
  - ChaCha20Poly1305加密算法保护敏感数据
  - 端到端加密，数据存储与传输安全有保障
  - 细粒度的数据访问控制

- 🚀 **智能缓存与检索性能**：
  - 多层级智能缓存机制，高效数据检索
  - 启动缓存大幅提升应用启动速度
  - 存储引擎与缓存深度集成，无需额外同步代码
  - 自适应扩展，随数据增长保持稳定性能

- 🔄 **创新的工作流**：
  - 多空间数据隔离，完美支持多租户、多用户场景
  - 跨计算节点的智能工作负载分配
  - 为大规模数据训练和分析提供稳固数据底座
  - 自动存储数据，智能更新插入

- 💼 **开发者体验优先**：
  - 详尽的双语文档和代码注释（中英文）
  - 丰富的调试信息和性能指标
  - 内置数据校验和损坏修复能力
  - 零配置开箱即用，快速上手

## 快速开始

基础使用:

```dart
// 初始化数据库
final db = ToStore();
await db.initialize(); // 可省略，能确保初始化数据库完成就绪，再执行数据库操作

// 插入数据
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// 更新数据
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// 删除数据
await db.delete('users').where('id', '!=', 1);

// 支持复杂的链式查询
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// 自动存储数据，数据存在则更新，不存在则插入数据
await db.upsert('users', {'name': 'John','email': 'john@example.com'})
  .where('email', '=', 'john@example.com');
// 或
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});


// 高效记录统计
final count = await db.query('users').count();

// 使用流式查询处理大规模数据
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // 按需处理每条数据，避免内存压力
    print('处理用户: ${userData['username']}');
  });


// 设置全局键值对
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// 获取全局键值对数据
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## 移动应用示例

```dart
// 适用移动应用等频繁启动场景的表结构定义方式，精准识别表结构变动，自动升级、迁移数据
final db = ToStore(
  schemas: [
    const TableSchema(
      name: 'users', // 表名
      tableId: "users",  // 表名唯一标识，可选，用于100%识别重命名需求，省略也可达到98%以上的精准识别率
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id', // 主键
      ),
      fields: [ // 字段定义，注意不包含主键
        FieldSchema(name: 'username', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'email', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [ // 索引定义
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// 切换到用户空间 - 数据隔离
await db.switchSpace(spaceName: 'user_123');

```

## 后端服务器示例

```dart
await db.createTables([
      const TableSchema(
        name: 'users', // 表名
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id', // 主键
          type: PrimaryKeyType.timestampBased,  // 主键类型
        ),
        fields: [
          // 字段定义，注意不包含主键
          FieldSchema(
              name: 'username',
              type: DataType.text,
              nullable: false,
              unique: true),
          FieldSchema(name: 'vector_data', type: DataType.blob),  // 存储向量数据
          // 其它字段 ...
        ],
        indexes: [
          // 索引定义
          IndexSchema(fields: ['username']),
          IndexSchema(fields: ['email']),
        ],
      ),
      // 其它表 ...
]);


// 更新表结构
final taskId = await db.updateSchema('users')
    .renameTable('newTableName')  //  修改表名
    .modifyField('username',minLength: 5,maxLength: 20,unique: true)  //  修改字段属性
    .renameField('oldName', 'newName')  //  修改字段名
    .removeField('fieldName')  //  删除字段
    .addField('name', type: DataType.text)  //  添加字段
    .removeIndex(fields: ['age'])  //  删除索引
    .setPrimaryKeyConfig(  // 设置主键配置
      const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
    );
    
// 查询迁移任务状态
final status = await db.queryMigrationTaskStatus(taskId);  
print('迁移进度: ${status?.progressPercentage}%');
```


## 分布式架构

```dart
// 配置分布式节点
final db = ToStore(
    config: DataStoreConfig(
        distributedNodeConfig: const DistributedNodeConfig(
            enableDistributed:  true,  // 启用分布式模式
            clusterId: 1,  // 配置集群归属
            centralServerUrl: 'http://127.0.0.1:8080',
            accessToken: 'b7628a4f9b4d269b98649129'))
);

// 批量插入向量数据
await db.batchInsert('vector', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... 数千条记录
]);

// 流式处理大数据集分析
await for (final record in db.streamQuery('vector')
    .where('vector_name', '=', 'face_2366')
    .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
    .stream) {
  // 流式处理接口支持大规模特征提取和转换
  print(record);
}
```

## 主键示例
多种主键算法，都支持分布式生成，不建议自定义生成主键，避免无序主键影响检索能力
有序递增主键 PrimaryKeyType.sequential ： 238978991
时间戳主键 PrimaryKeyType.timestampBased ： 1306866018836946
日期前缀主键 PrimaryKeyType.datePrefixed ：20250530182215887631
短码主键 PrimaryKeyType.shortCode ：9eXrF0qeXZ

```dart
// 有序递增主键 PrimaryKeyType.sequential
// 当分布式启用后，中央服务器分配号段由节点自行生成，短小好记，适用于用户id、靓号
await db.createTables([
      const TableSchema(
        name: 'users',
        primaryKeyConfig: PrimaryKeyConfig(
          type: PrimaryKeyType.sequential,  // 递增主键类型
          sequentialConfig:  SequentialIdConfig(
              initialValue: 10000, // 自增起始值
              increment: 50,  // 自增步长
              useRandomIncrement: true,  // 使用随机步长，避免暴露业务量
            ),
        ),
        // 字段及索引定义 ...
        fields: []
      ),
      // 其它表 ...
 ]);
```


## 安全配置

```dart
// 重命名表和字段 - 自动识别并保留数据
final db = ToStore(
      config: DataStoreConfig(
        enableEncoding: true, // 对表数据启用安全编码
        encodingKey: 'YouEncodingKey', // 编码密钥，可随意调整
        encryptionKey: 'YouEncryptionKey', // 加密密钥，注意：调整该密钥后无法对旧数据解码
      ),
    );
```

## 性能测试

Tostore 2.0实现了线性扩展性能，并行处理、分区机制、分布式架构的底层变革切实的提升了数据检索能力，随着数据的大规模增长，也能实现毫秒级响应。在大数据集处理方面，流式查询接口可以处理大规模数据而不会耗尽内存资源。



## 未来计划
Tostore正在进行高维向量的开发支持，以适应多模态数据的处理，语义检索


我们的目的不是为了打造一个数据库，Tostore只是从Toway框架中抽离出来供大家候选，如果您正在开发移动应用，推荐使用Toway框架，一体化生态，涉及了Flutter应用开发的全栈解决方案，使用Toway后，您将无须触及底层数据库，数据请求、加载、存储、缓存、展示等，均由Toway框架自动完成。
关于Toway框架更多信息，请访问[Toway仓库](https://github.com/tocreator/toway)

## 文档

访问我们的 [Wiki](https://github.com/tocreator/tostore) 获取详细文档。

## 支持与反馈

- 提交 Issue: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 加入讨论: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- 贡献代码: [Contributing Guide](CONTRIBUTING.md)

## 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件。

---

<p align="center">如果觉得 Tostore 对你有帮助，欢迎给我们一个 ⭐️</p>
