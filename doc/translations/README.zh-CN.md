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
  简体中文 | 
  <a href="README.ja.md">日本語</a> | 
  <a href="README.ko.md">한국어</a> | 
  <a href="README.es.md">Español</a> | 
  <a href="README.pt-BR.md">Português (Brasil)</a> | 
  <a href="README.ru.md">Русский</a> | 
  <a href="README.de.md">Deutsch</a> | 
  <a href="README.fr.md">Français</a> | 
  <a href="README.it.md">Italiano</a> | 
  <a href="README.tr.md">Türkçe</a>
</p>





## 快速导航

- [为什么选择 ToStore？](#why-tostore) | [ToStore特性](#key-features) | [安装](#installation) | [快速开始](#quick-start)
- [表结构定义](#schema-definition) | [移动、桌面等频繁启动场景集成](#mobile-integration) | [服务端集成](#server-integration)
- [向量字段、向量索引与向量检索](#vector-advanced) | [表级 TTL](#ttl-config) | [查询与高效分页](#query-pagination) | [外键与级联约束](#foreign-keys) | [查询操作符](#query-operators)
- [分布式架构](#distributed-architecture) | [主键类型示例](#primary-key-examples) | [表达式原子操作](#atomic-expressions) | [事务操作](#transactions) | [错误码与错误处理](#error-handling) | [日志回调与数据库诊断](#logging-diagnostics) 
- [安全配置](#security-config) | [性能与体验](#performance) | [更多资源](#more-resources)


<a id="why-tostore"></a>
## 为什么选择 ToStore？

ToStore 是面向 AGI 时代与边缘智能场景设计的现代化数据引擎。原生支持分布式体系、多模态融合、关系型结构化数据、高维向量与非结构化数据存储。基于类神经网络式的底层架构，节点拥有较高自治性与弹性水平扩展，构建灵活的数据拓扑网络，实现无缝的边云跨平台协同。具备 ACID 事务、复杂关系查询（JOIN、级联外键）、表级 TTL、聚合计算等基础，内置多种分布式主键算法与原子性表达式，同时提供表结构变动识别、加密保护、多空间数据隔离、资源感知智能负载调度与灾难崩溃自愈恢复等能力。

随着计算重心持续向端侧边缘智能偏移，智能体、传感器等各类终端设备不再只是单纯的“内容展示器”，而是承担局部生成、环境感知、实时决策与数据协同的智能节点。传统数据库方案受限于底层架构及拼接式扩展，在面对高并发写入、海量数据、向量检索以及云边协同生成时，越来越难以支撑边云智能化应用对低延迟与稳定性的要求。

ToStore 赋予边缘端支撑海量数据、复杂 AI 局部生成与大规模数据流转的分布式能力，边云节点深度智能协同，为沉浸式虚实融合、多模态交互、语义向量、空间建模等场景提供可靠的数据基座。




<a id="key-features"></a>
## ToStore特性

- 🌐 **统一的跨平台数据引擎**
  - 移动端、桌面端、Web 与服务端统一 API
  - 支持关系型结构化数据、高维向量以及非结构化数据存储
  - 构建本地存储到边云协同的数据链路

- 🧠 **类神经网络式分布式架构**
  - 节点具备较高自治性，互联协同构建灵活的数据拓扑
  - 支持节点协作与弹性水平扩展
  - 边缘智能节点与云端的深度互联

- ⚡ **并行执行与资源调度**
  - 资源感知智能负载调度，高可用
  - 多节点并行协同计算与任务拆分

- 🔍 **结构化查询与向量检索**
  - 支持复杂条件查询、JOIN、聚合计算与表级 TTL
  - 支持向量字段、向量索引与近邻检索
  - 结构化数据与向量数据可在同一引擎内协同使用

- 🔑 **主键、索引与模式演进**
  - 内置顺序递增、时间戳、日期前缀、短码等主键算法
  - 支持唯一索引、组合索引、向量索引与外键约束
  - 智能识别表结构变动，自动完成数据迁移

- 🛡️ **事务、安全与恢复**
  - 提供 ACID 事务、原子表达式更新与级联外键
  - 支持崩溃恢复、提交落盘与数据一致性保障
  - 支持 ChaCha20-Poly1305 与 AES-256-GCM 加密

- 🔄 **多空间与数据工作流**
  - 支持按空间隔离数据，可配置全局共享数据
  - 支持查询条件实时监听、多层级智能缓存与游标分页
  - 适合多用户、本地优先、离线协同等应用场景


<a id="installation"></a>
## 安装

> [!IMPORTANT]
> **从 v2.x 升级？** 请阅读 [v3.x 升级指南](../UPGRADE_GUIDE_v3.md) 以了解关键的迁移步骤和重大更改。

在 `pubspec.yaml` 中添加 `tostore` 依赖：

```yaml
dependencies:
  tostore: any # 请使用最新版本
```

<a id="quick-start"></a>
## 快速开始

> [!IMPORTANT]
> **定义表结构是首要步骤**：在进行增删改查之前，必须先定义表结构。当然仅使用键值对存储的忽略。具体的定义方式取决于您的场景：
> - 表结构定义与约束说明见 [表结构定义](#schema-definition)。
> - **移动端/桌面端**：[频繁启动场景集成](#mobile-integration) 在初始化实例时传入 `schemas`。
> - **服务端**： [服务端集成](#server-integration) 推荐在运行时通过调用 `createTables`创建。

```dart
// 1. 初始化数据库
final db = await ToStore.open();

// 2. 插入数据
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. 链式查询（详见[查询操作符](#查询操作符)，支持 =, !=, >, <, LIKE, IN 等）
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. 更新与删除
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. 实时监听 (数据变动时 UI 自动刷新)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('符合条件的用户已更新: $users');
});
```

### 键值对存储 (KV)
适用于不需要定义结构化表的场景，简单实用，内置了高性能的键值对存储，可用于存储配置信息、状态等零散数据。不同空间（Space）的数据是天然隔离的，可设置全局共享。

```dart
// 初始化数据库
final db = await ToStore.open();

// 设置键值对 (支持 String, int, bool, double, Map, List 等)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 获取数据
final theme = await db.getValue('theme'); // 'dark'

// 删除数据
await db.removeValue('theme');

// 全局键值对 (跨 Space 共享)
// 在不同空间切换后，默认键值对数据会自动失效。使用 isGlobal: true 可以实现全局共享。
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



<a id="schema-definition"></a>
## 表结构定义
下文移动端与服务端示例都会复用这里的 `appSchemas`。

### TableSchema 结构总览

```dart
const userSchema = TableSchema(
  name: 'users', // 表名，必填
  tableId: 'users', // 表的唯一标识，可选，用于100%识别表重命名，省略也有99.9%精准识别率
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // 主键字段名，默认 id
    type: PrimaryKeyType.sequential, // 主键自动生成类型
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, // 顺序主键起始值
      increment: 1, // 顺序主键步长
      useRandomIncrement: false, // 是否启用随机步长
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username', // 字段名，必填
      type: DataType.text, // 字段数据类型，必填
      nullable: false, // 是否允许为 null
      minLength: 3, // 最小长度
      maxLength: 32, // 最大长度
      unique: true, // 是否唯一
      fieldId: 'username', // 字段唯一标识，可选，用于识别字段重命名
      comment: '登录名', // 字段注释，可选，比如用于备注用途
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0, // 数值下限
      maxValue: 150, // 数值上限
      defaultValue: 0, // 静态默认值
      createIndex: true,  // 快捷创建索引，提升检索性能
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // 自动填充当前时间
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at', // 索引名，可选
      fields: ['status', 'created_at'], // 复合索引字段列表
      unique: false, // 是否唯一索引
      type: IndexType.btree, // 索引类型：btree/hash/bitmap/vector
    ),
  ],
  foreignKeys: const [], // 外键约束列表，可选；完整示例见下文“外键与级联约束”
  isGlobal: false, // 是否为全局表；true 时可跨 Space 全局共享
  ttlConfig: null, // 表级 TTL，可选；完整示例见下文“表级 TTL”
);

const appSchemas = [userSchema];
```

`DataType` 支持 `integer`、`bigInt`、`double`、`text`、`blob`、`boolean`、`datetime`、`array`、`json`、`vector`；`PrimaryKeyType` 支持 `none`、`sequential`、`timestampBased`、`datePrefixed`、`shortCode`。

### 约束与自动校验

通过 `FieldSchema` 可以直接把常见校验规则写入 schema，而不是在 UI、接口或服务层重复维护同一套逻辑：

- `nullable: false`：非空约束
- `minLength` / `maxLength`：文本长度约束
- `minValue` / `maxValue`：整数或浮点数范围约束
- `defaultValue` / `defaultValueType`：静态默认值与动态默认值
- `unique`：唯一约束
- `createIndex`：为高频查询过滤、排序或关联字段创建索引，提升检索性能
- `fieldId` / `tableId`：辅助识别字段或表重命名，便于迁移

这些约束会在数据写入路径中统一校验，减少业务层重复实现非空、长度、范围和默认值逻辑。

其中，`unique: true` 及会自动生成单字段唯一索引，`createIndex: true` 、外键会自动生成单字段普通索引；`indexes` 更适合定义组合索引、命名索引或向量索引。




### 选择接入方式

- **移动端/桌面端**：适合在初始化实例直接把 `appSchemas` 传入 `ToStore.open(...)`
- **服务端**：适合在进程运行时动态创建 schema，调用 `createTables(appSchemas)`


<a id="mobile-integration"></a>
## 移动、桌面等频繁启动场景集成

📱 **示例**：[mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Android / iOS 需要先解析应用可写目录，再显式传入 dbPath
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

// 复用上文定义好的 appSchemas
final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// 多空间架构 - 隔离不同用户数据
await db.switchSpace(spaceName: 'user_123');
```

### 保持登录状态与退出登录（活跃空间）

多空间适合**按用户隔离数据**：每用户一个空间，登录时切换。通过**活跃空间**与**关闭选项**，可保持当前用户到下次启动，并支持退出登录。

- **保持登录状态**：用户切换到自己的空间后，将其记为活跃空间，下次启动时用 default 打开即可直接进入该空间，无需「先开 default 再切换」。
- **退出登录**：用户退出时，使用 `keepActiveSpace: false` 关闭数据库，下次启动不会自动进入上一用户空间。

```dart

// 登录后：切换到该用户空间并记为活跃空间（保持登录状态）
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// 可选：仅需严格使用 default 时（如仅登录页）—— 不使用已保存的活跃空间
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// 退出登录：关闭并清除活跃空间，下次启动使用 default 空间
await db.close(keepActiveSpace: false);
```



<a id="server-integration"></a>
## 服务端集成

🖥️ **示例**：[server_quickstart.dart](../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// 服务启动时创建或校验表结构
await db.createTables(appSchemas);

// 在线表结构更新
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // 修改表名
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // 修改字段属性
  .renameField('old_name', 'new_name')     // 修改字段名
  .removeField('deprecated_field')         // 删除字段
  .addField('created_at', type: DataType.datetime)  // 添加字段
  .removeIndex(fields: ['age'])            // 删除索引
  .setPrimaryKeyConfig(                    // 更改主键类型，注意必须数据为空，不然会警告迁移数据
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// 监控迁移进度
final status = await db.queryMigrationTaskStatus(taskId);
print('迁移进度: ${status?.progressPercentage}%');


// 手动查询缓存管理 (服务端)
// 对于主键或索引的等值查询、IN 查询，这些耗时极低，无须额外手动维护查询缓存。

// 手动缓存一个查询结果5分钟。若不提供时长，则缓存永不过期。
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// 当相关数据发生变更时，使用 clearQueryCache 来精确地让缓存失效，确保数据一致性。
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// 对于需要获取最新实时数据的查询，可以显式禁用缓存。
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
    
```





<a id="advanced-usage"></a>
## 进阶用法

ToStore 提供了丰富的进阶功能，满足各种复杂业务场景需求：


<a id="vector-advanced"></a>
### 向量字段、向量索引与向量检索

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
        type: DataType.vector,  // 声明向量类型
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: 128, // 向量维度；写入和查询时的向量长度都必须一致
          precision: VectorPrecision.float32, // 存储精度；float32 通常兼顾精度与空间占用
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'], // 要建立向量索引的字段
        type: IndexType.vector,  // 构建向量索引
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,  // 向量索引类型；当前内置为 NGH
          distanceMetric: VectorDistanceMetric.cosine, // 距离度量；适合归一化后的 embedding
          maxDegree: 32, // 图中每个节点保留的最大邻居数；越大召回通常越高，但更耗内存
          efSearch: 64, // 查询扩展因子；越大召回通常越高，但查询更慢
          constructionEf: 128, // 建索引扩展因子；越大索引质量通常越高，但构建更慢
        ),
      ),
    ],
  ),
]);

final queryVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.01)); // 长度需与 dimensions 一致

// 向量检索
final results = await db.vectorSearch(
  'embeddings', // 表名
  fieldName: 'embedding', // 向量字段名
  queryVector: queryVector, // 查询向量
  topK: 5, // 返回最相近的前 5 条记录
  efSearch: 64, // 可覆盖索引中的查询扩展因子；越大通常召回越高，但延迟也更高
);

for (final r in results) {
  print('pk=${r.primaryKey}, score=${r.score}, distance=${r.distance}');
}
```

参数说明：

- `dimensions`：向量维度，必须与实际写入的 embedding 长度一致。
- `precision`：向量存储精度，常见可选值有 `float64`、`float32`、`int8`；精度越高，存储开销通常越大。
- `distanceMetric`：相似度度量方式；`cosine` 常用于语义 embedding，`l2` 适合欧氏距离场景，`innerProduct` 适合点积检索。
- `maxDegree`：NGH 图索引中每个节点保留的邻居上限，增大后通常可提升召回率，但会增加内存占用和构建成本。
- `efSearch`：查询阶段扩展宽度，增大后通常可提升召回率，但会增加查询延迟。索引配置里可设置默认值，`vectorSearch(...)` 时也可以按单次查询覆盖。
- `constructionEf`：索引构建阶段扩展宽度，增大后通常可提升索引质量，但会增加建索引耗时。
- `topK`：返回结果数量。

结果说明：

- `score`：归一化后的相似度分数，范围通常在 `0 ~ 1`，值越大表示越相近。
- `distance`：距离值；对 `l2` / `cosine` 场景通常越小表示越相近。

<a id="ttl-config"></a>
### 表级 TTL（按时间自动过期清理）

对于日志、埋点、时序等按时间淘汰的数据，可以在表结构中通过 `ttlConfig` 定义表级 TTL，到期数据将由引擎在后台自动清理，无需业务端手动清理维护：

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
    ttlMs: 7 * 24 * 60 * 60 * 1000, // 保留 7 天
    // sourceField 省略时，默认自动创建索引；
    // 可选：自定义 sourceField 时必须：
    // 1）字段类型为 DataType.datetime
    // 2）字段不可为空（nullable: false）
    // 3）字段 defaultValueType 必须为 DefaultValueType.currentTimestamp
    // sourceField: 'created_at',
  ),
);
```


### 复杂查询嵌套与自定义过滤
支持无限层级的条件嵌套和灵活的自定义函数。

```dart
// 条件嵌套：(type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// 自定义条件函数
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('推荐') ?? false);
```

### 智能存储 (Upsert)
根据 data 中的主键或唯一键判断：存在则更新，不存在则插入。不支持 where，冲突目标由 data 决定。

```dart
// 按主键
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// 按唯一键（记录须包含某一唯一索引的全部字段及必填字段）
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// 批量 upsert
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### 表连接关联查询与字段选择
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### 流式处理与统计
```dart
// 统计记录数
final count = await db.query('users').count();

// 检查当前数据库中是否已经存在名为 'users' 的表结构（与 Space 无关）
// 注意：这不代表该表有数据
final usersTableDefined = await db.tableExists('users');

// 基于条件的高效存在性检查（不读取完整记录）
final emailExists = await db.query('users')
    .where('email', '=', 'test@example.com')
    .exists();

// 聚合函数
final totalAge = await db.query('users').where('age', '>', 18).sum('age');
final avgAge = await db.query('users').avg('age');
final maxAge = await db.query('users').max('age');
final minAge = await db.query('users').min('age');

// 分组统计与过滤
final result = await db.query('orders')
    .select(['status', Agg.sum('amount', alias: 'total')])
    .groupBy(['status'])
    .having(Agg.sum('amount'), '>', 1000)
    .limit(20);

// 去重查询
final uniqueCities = await db.query('users').distinct(['city']);

// 流式查询 (适用于海量数据)
db.streamQuery('users').listen((data) => print(data));
```



<a id="query-pagination"></a>
### 查询与高效分页

> [!TIP]
> **显式指定 `limit` 以获得最佳性能**：强烈建议在查询时始终指定 `limit`。如果省略，引擎默认限制为 1000 条记录。虽然核心查询速度极快，但在应用层序列化大量记录可能会带来不必要的耗时开销。

ToStore 提供双模式分页支持，您可以根据数据规模和性能需求灵活选择：

#### 1. 基础分页 (Offset Mode)
适用于数据量较小（如万级以下）或需要精确跳转页码的场景。

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // 跳过前 40 条
    .limit(20); // 取 20 条
```
> [!TIP]
> 当 `offset` 非常大时，数据库需要扫描并丢弃大量记录，性能会线性下降。建议深度翻页时使用 **Cursor 模式**。

#### 2. 游标分页 (Cursor Mode)
适合海量数据和无限滚动场景。利用 `nextCursor` 从当前位置继续读取，可避免深度翻页时 `offset` 带来的额外扫描。

> [!IMPORTANT]
> 对于部分复杂的查询或针对未索引字段进行排序时，引擎可能会回退到全表扫描并返回 `null` 游标（即暂不支持该特定查询的分页）。

```dart
// 第一页查询
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// 使用返回的游标查询下一页
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // 传入游标，引擎将直接 seek 到对应位置
}

// 同理，使用 prevCursor 可以实现高效回翻
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| 特性 | Offset 模式 | Cursor 模式 |
| :--- | :--- | :--- |
| **查询性能** | 随页数增加而下降 | 深度翻页时始终恒定 |
| **适用范围** | 少量数据、精确跳转 | **海量数据、无限滚动** |
| **数据一致性** | 数据变动后可能导致跳行 | 避免数据变动导致的重复或遗漏 |




<a id="foreign-keys"></a>
### 外键与级联约束

使用外键约束可以保证引用完整性，并配置级联更新、级联删除等行为。外键约束会在写入和更新时校验引用关系；如果启用了级联策略，关联记录变化时会同步处理引用数据，减少业务层手动维护的一致性逻辑。

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
          fields: ['user_id'],              // 当前表的字段
          referencedTable: 'users',         // 引用的表
          referencedFields: ['id'],         // 引用的字段
          onDelete: ForeignKeyCascadeAction.cascade,  // 删除时级联删除，users表的记录删除后会自动删除posts表的数据
          onUpdate: ForeignKeyCascadeAction.cascade,  // 更新时级联更新
        ),
    ],
  ),
]);
```





<a id="query-operators"></a>
### 查询操作符

所有 `where(field, operator, value)` 条件支持以下操作符（大小写不敏感）：

| 操作符 | 说明 | 示例 / 值类型 |
| :--- | :--- | :--- |
| `=` | 等于 | `where('status', '=', 'active')` |
| `!=`, `<>` | 不等于 | `where('role', '!=', 'guest')` |
| `>` | 大于 | `where('age', '>', 18)` |
| `>=` | 大于等于 | `where('score', '>=', 60)` |
| `<` | 小于 | `where('price', '<', 100)` |
| `<=` | 小于等于 | `where('quantity', '<=', 10)` |
| `IN` | 在列表中 | `where('id', 'IN', ['a','b','c'])` — value: `List` |
| `NOT IN` | 不在列表中 | `where('status', 'NOT IN', ['banned'])` — value: `List` |
| `BETWEEN` | 介于（含首尾） | `where('age', 'BETWEEN', [18, 65])` — value: `[start, end]` |
| `LIKE` | 模式匹配（`%` 任意，`_` 单字符） | `where('name', 'LIKE', '%John%')` — value: `String` |
| `NOT LIKE` | 模式不匹配 | `where('email', 'NOT LIKE', '%@test.com')` — value: `String` |
| `IS` | 为 null | `where('deleted_at', 'IS', null)` — value: `null` |
| `IS NOT` | 不为 null | `where('email', 'IS NOT', null)` — value: `null` |

### 语义化查询方法（推荐）

推荐使用语义化方法，避免手写操作符字符串并便于 IDE 提示：

```dart
// 比较
db.query('users').whereEqual('username', 'John');
db.query('users').whereNotEqual('role', 'guest');
db.query('users').whereGreaterThan('age', 18);
db.query('users').whereGreaterThanOrEqualTo('score', 60);
db.query('users').whereLessThan('price', 100);
db.query('users').whereLessThanOrEqualTo('quantity', 10);

// 集合与范围
db.query('users').whereIn('id', ['id1', 'id2']);
db.query('users').whereNotIn('status', ['banned', 'pending']);
db.query('users').whereBetween('age', 18, 65);

// 空值判断
db.query('users').whereNull('deleted_at');
db.query('users').whereNotNull('email');

// 模式匹配
db.query('users').whereLike('name', '%John%');
db.query('users').whereNotLike('email', '%@temp.');
db.query('users').whereContains('bio', 'flutter');   // LIKE '%flutter%'
db.query('users').whereNotContains('title', 'draft');

// 等价于：.where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```

<a id="distributed-architecture"></a>
## 分布式架构

```dart
// 配置分布式节点
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,            // 启用分布式模式
      clusterId: 1,                       // 集群ID，配置集群归属
      centralServerUrl: 'https://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// 批量插入
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... 向量数据记录一次性高效插入
]);

// 流式处理大数据集
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // 逐条处理结果，避免一次性加载整批数据
  print(record);
}
```

<a id="primary-key-examples"></a>
## 主键类型示例

ToStore提供多种分布式主键算法，支持各种业务场景：

- **有序递增主键** (PrimaryKeyType.sequential)：238978991
- **时间戳主键** (PrimaryKeyType.timestampBased)：1306866018836946
- **日期前缀主键** (PrimaryKeyType.datePrefixed)：20250530182215887631
- **短码主键** (PrimaryKeyType.shortCode)：9eXrF0qeXZ

```dart
// 有序递增主键配置示例
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,           // 递增主键类型
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,                     // 起始值
        increment: 50,                           // 步长
        useRandomIncrement: true,                // 随机步长，隐藏业务量
      ),
    ),
    fields: [/* 字段定义 */]
  ),
]);
```


<a id="atomic-expressions"></a>
## 表达式原子操作

表达式系统提供类型安全的原子字段更新，所有计算在数据库层面原子执行，避免并发冲突：

```dart
// 简单增量：balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// 复杂计算：total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// 多层括号：finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// 使用函数：price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// 时间戳：updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

**条件判断（如 upsert 中区分更新/插入）**：使用 `Expr.isUpdate()` / `Expr.isInsert()` 配合 `Expr.ifElse` 或 `Expr.when`，使表达式仅在更新或仅在插入时执行：

```dart
// Upsert：更新时自增，插入时设为 1（插入分支用普通值即可，仅更新路径会求值表达式）
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    1,  // 插入分支：字面量，insert 不会对其做表达式求值
  ),
});

// 使用 Expr.when（单分支，否则为 null）
await db.upsert('orders', {
  'id': orderId,
  'updatedAt': Expr.when(Expr.isUpdate(), Expr.now(), otherwise: Expr.now()),
});
```

<a id="transactions"></a>
## 事务操作

事务确保多个操作的原子性，要么全部成功，要么全部回滚，保证数据一致性：

**事务特性**：
- 多个操作要么全部成功，要么全部回滚，保证数据准确
- 崩溃后自动恢复未完成的操作
- 操作成功时数据已安全保存

```dart
// 基本事务 - 多个操作原子提交
final txResult = await db.transaction(() async {
  // 插入用户
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // 使用表达式原子更新
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // 如果任何操作失败，所有更改都会自动回滚
});

if (txResult.isSuccess) {
  print('事务提交成功');
} else {
  print('事务回滚: ${txResult.error?.message}');
}

// 错误时自动回滚
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('业务逻辑错误'); // 触发回滚
}, rollbackOnError: true);
```


<a id="error-handling"></a>
### 状态码与错误处理


ToStore 数据操作统一响应模型：

- `ResultType`：统一的状态枚举，可直接用于分支处理
- `result.code`：`ResultType` 对应的稳定数值码
- `result.message`：当前错误的可读说明
- `successKeys` / `failedKeys`：批量操作的成功与失败主键列表


```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (!result.isSuccess) {
  switch (result.type) {
    case ResultType.notFound:
      print('目标资源不存在: ${result.message}');
      break;
    case ResultType.notNullViolation:
    case ResultType.validationFailed:
      print('数据校验失败: ${result.message}');
      break;
    case ResultType.primaryKeyViolation:
    case ResultType.uniqueViolation:
      print('唯一约束冲突: ${result.message}');
      break;
    case ResultType.foreignKeyViolation:
      print('外键约束失败: ${result.message}');
      break;
    case ResultType.resourceExhausted:
    case ResultType.timeout:
      print('系统繁忙，可稍后重试: ${result.message}');
      break;
    case ResultType.ioError:
    case ResultType.dbError:
      print('底层存储异常，请记录日志: ${result.message}');
      break;
    default:
      print('错误类型: ${result.type}, 数值码: ${result.code}, 消息: ${result.message}');
  }
}
```

常见状态码示例：
成功返回0，负数为错误异常
- `ResultType.success`(0)：操作成功
- `ResultType.partialSuccess`(1)：批量操作时部分成功
- `ResultType.unknown`(-1)：未知错误
- `ResultType.uniqueViolation`(-2)：唯一索引冲突
- `ResultType.primaryKeyViolation`(-3)：主键冲突
- `ResultType.foreignKeyViolation`(-4)：外键引用不满足约束
- `ResultType.notNullViolation`(-5)：必填字段缺失或传入了不允许的 `null`
- `ResultType.validationFailed`(-6)：长度、范围、格式、约束等校验未通过
- `ResultType.notFound`(-11)：目标表、空间或目标资源不存在
- `ResultType.resourceExhausted`(-15)：系统资源不足，建议降载或重试
- `ResultType.dbError`（-91）：数据库异常
- `ResultType.ioError`(-90)：文件系统异常
- `ResultType.timeout`(-92)：超时

### 事务响应结果处理
```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
  });
});

// txResult.isFailed:事务失败；txResult.isSuccess:事务成功
if (txResult.isFailed) {
  print('事务错误类型: ${txResult.error?.type}');
  print('事务错误消息: ${txResult.error?.message}');
}
```
事务错误类型：
- `TransactionErrorType.operationError`：事务中的普通操作失败，例如字段校验失败、资源状态不满足要求或其他业务级异常
- `TransactionErrorType.integrityViolation`：完整性或约束冲突，例如主键、唯一键、外键、非空等约束失败
- `TransactionErrorType.timeout`：超时
- `TransactionErrorType.io`：底层存储或文件系统 I/O 异常
- `TransactionErrorType.conflict`：冲突导致事务失败
- `TransactionErrorType.userAbort`：用户主动中止事务（抛异常暂不支持此类）；
- `TransactionErrorType.unknown`：其他异常


<a id="logging-diagnostics"></a>
### 日志回调与数据库诊断

ToStore 可以通过 `LogConfig.setConfig(...)` 把启动、恢复、自动迁移、运行时约束冲突等日志统一回调给业务层。

- `onLogHandler` 会收到所有通过当前 `enableLog` 与 `logLevel` 过滤后的日志。
- 请在初始化之前调用 `LogConfig.setConfig(...)`，这样初始化和自动迁移阶段的日志也能被捕获。

```dart
  // 配置日志参数或回调
  LogConfig.setConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    publicLabel: 'my_app_db',
    onLogHandler: (message, type, label) {
      // 生产环境可以将 warn/error上报后端或日志平台
      if (!debugMode && (type == LogType.warn || type == LogType.error)) {
        developer.log(message, name: label);
      }
    },
  );

  final db = await ToStore.open();
```



### 纯内存模式 (Memory Mode)

对于数据缓存、临时计算或不需要持久化到磁盘等场景，可以使用 ToStore.memory() 初始化一个纯内存数据库。在该模式下，所有数据（包括表结构、索引和键值对）均仅保存在内存中。

**注意**：纯内存模式下产生的数据在应用关闭或重启后将完全丢失。

```dart
// 使用纯内存模式初始化数据库
final db = await ToStore.memory(
  schemas: [],
);

// 所有的增删改查及搜索都将在内存中以极速完成
await db.insert('temp_cache', {'key': 'session_1', 'value': {'user': 'admin'}});

```



<a id="security-config"></a>
## 安全配置


> [!WARNING]
> **密钥管理**：**`encodingKey`** 可随意修改，修改后引擎会自动迁移数据，无需担心数据不可恢复。**`encryptionKey`** 不可随意变更，变更后旧数据将无法解密（除非执行数据迁移）。请勿硬编码敏感密钥，建议从安全服务端获取。

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // 加密算法支持：none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // 编码密钥（可随意修改，修改后数据会自动迁移）
      encodingKey: 'Your-32-Byte-Long-Encoding-Key...', 
      
      // 关键数据加密密钥（不可随意变更，否则旧数据无法解密，除非执行迁移）
      encryptionKey: 'Your-Secure-Encryption-Key...',
      
      // 设备绑定 (Path-based binding)
      // 开启后密钥将与数据库文件路径、设备特征深度绑定。数据在不同物理路径下无法解密。
      // 优点：可提升数据库文件被直接拷贝时的保护效果。
      // 缺点：如果应用安装路径发生变化及设备特征发生变化，数据将无法还原。
      deviceBinding: false, 
    ),
    // 启用崩溃恢复日志 (Write-Ahead Logging)，默认开启
    enableJournal: true, 
    // 事务提交时是否强制刷新数据到磁盘，如需降低同步刷新开销可设为 false（交由后台自动刷新）
    persistRecoveryOnCommit: true,
  ),
);
```

### 价值级加密（ToCrypto）

上文的全库加密会加密所有表与索引数据，可能影响整体性能。若只需加密部分敏感字段，可使用 **ToCrypto**：与数据库解耦（无需 db 实例），在写入前或读取后自行对值进行编码/解码，密钥由应用完全管理。输出为 Base64，适合存入 JSON 或 TEXT 列。

- **key**（必填）：`String` 或 `Uint8List`。若非 32 字节，将用 SHA-256 派生为 32 字节。
- **type**（可选）：加密类型 [ToCryptoType]： [ToCryptoType.chacha20Poly1305] 或 [ToCryptoType.aes256Gcm]。默认 [ToCryptoType.chacha20Poly1305]。不传则使用默认。
- **aad**（可选）：附加认证数据，类型为 `Uint8List`。若在编码时传入，解码时必须传入相同字节（例如表名+字段名做上下文绑定）；简单用法可不传。

```dart
const key = 'my-secret-key';
// 编码：明文 → Base64 密文（可存入 DB 或 JSON）
final cipher = ToCrypto.encode('sensitive data', key: key);
// 读取时解码
final plain = ToCrypto.decode(cipher, key: key);

// 可选：用 aad 绑定上下文（编码与解码须使用相同 aad）
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```



<a id="performance"></a>
## 性能与体验

### 体验建议

- 📱 **示例项目**：`example` 目录下提供了完整的Flutter应用示例
- 🚀 **生产环境**：建议打包release版本，release模式下性能远超调试模式
- ✅ **标准测试**：所有基础、核心功能都通过了标准测试

### 基准测试

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore 基础性能演示" width="320" />
</p>

- **基础性能演示**（<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4" target="_blank" rel="noopener">basic-demo.mp4</a>）：GIF 预览可能显示不全，请点击视频查看完整演示。在普通手机上，即便数据量超过亿级，应用的启动、翻页与检索性能依旧保持稳定顺滑。

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore 灾难恢复压力测试" width="320" />
</p>

- **灾难恢复压力测试**（<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4" target="_blank" rel="noopener">disaster-recovery.mp4</a>）：在高频写入过程中，故意反复中断进程，模拟崩溃与断电，ToStore 能够快速完成自恢复。




如果 ToStore 对您有所帮助，请给我们一个 ⭐️
这是对开源的最大支持，非常感谢





> **推荐**：前端应用开发可考虑使用 [ToApp 开发框架](https://github.com/tocreator/toapp)，提供全栈开发解决方案，自动化、一体化处理数据请求、加载、存储、缓存和展示。




<a id="more-resources"></a>
## 更多资源

- 📖 **文档**：[Wiki](https://github.com/tocreator/tostore)
- 📢 **问题反馈**：[GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **技术讨论**：[GitHub Discussions](https://github.com/tocreator/tostore/discussions)



