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
- [为什么选择ToStore](#why-tostore) | [核心特性](#key-features) | [安装指南](#installation) | [KV模式](#quick-start-kv) | [表模式](#quick-start-table) | [内存模式](#quick-start-memory)
- [表结构定义](#schema-definition) | [分布式架构](#distributed-architecture) | [级联外键](#foreign-keys) | [移动/桌面端](#mobile-integration) | [服务端/智能体](#server-integration) | [主键算法](#primary-key-examples)
- [高级查询 (JOIN)](#query-advanced) | [聚合与统计](#aggregation-stats) | [复杂逻辑 (Condition)](#query-condition) | [响应式监听 (watch)](#reactive-query) | [流式查询](#streaming-query)
- [KV进阶](#kv-advanced) | [批量操作](#bulk-operations) | [向量检索](#vector-advanced) | [表级 TTL](#ttl-config) | [高效分页](#query-pagination) | [查询缓存](#query-cache) | [原子操作](#atomic-expressions) | [事务](#transactions)
- [管理维护](#database-maintenance) | [安全配置](#security-config) | [错误处理](#error-handling) | [性能与诊断](#performance) | [更多资源](#more-resources)


## <a id="why-tostore"></a>为什么选择 ToStore？

ToStore 是面向 AGI 时代与边缘智能场景设计的现代化数据引擎。原生支持分布式体系、多模态融合、关系型结构化数据、高维向量与非结构化数据存储。基于自寻径节点架构 (Self-Routing)与类神经网络引擎，节点拥有较高自治性与弹性水平扩展，实现了性能表现与数据规模的逻辑解耦。具备 ACID 事务、复杂关系查询（JOIN、级联外键）、表级 TTL、聚合计算等基础，内置多种分布式主键算法与原子性表达式，同时提供表结构变动识别、加密保护、多空间数据隔离、资源感知智能负载调度与灾难崩溃自愈恢复等能力。

随着计算重心持续向端侧边缘智能偏移，智能体、传感器等各类终端设备不再只是单纯的“内容展示器”，而是承担局部生成、环境感知、实时决策与数据协同的智能节点。传统数据库方案受限于底层架构及拼接式扩展，在面对高并发写入、海量数据、向量检索以及云边协同生成时，越来越难以支撑边云智能化应用对低延迟与稳定性的要求。

ToStore 赋予边缘端支撑海量数据、复杂 AI 局部生成与大规模数据流转的分布式能力，边云节点深度智能协同，为沉浸式虚实融合、多模态交互、语义向量、空间建模等场景提供可靠的数据基座。




## <a id="key-features"></a>ToStore特性

- 🌐 **统一的跨平台数据引擎**
  - 移动端、桌面端、Web 与服务端统一 API
  - 支持关系型结构化数据、高维向量以及非结构化数据存储
  - 构建本地存储到边云协同的数据链路

- 🧠 **类神经网络式分布式架构**
  - 自寻径节点架构，物理寻址与规模解耦
  - 节点具备较高自治性，互联协同构建灵活的数据拓扑
  - 支持节点协作与弹性水平扩展
  - 边缘智能节点与云端的深度互联

- ⚡ **并行执行与资源调度**
  - 资源感知智能负载调度，高可用
  - 多节点并行协同计算与任务拆分
  - 时间切片机制，保障高负载下 UI 动画流畅

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


## <a id="installation"></a>安装

> [!IMPORTANT]
> **从 v2.x 升级？** 请阅读 [v3.x 升级指南](../UPGRADE_GUIDE_v3.md) 以了解关键的迁移步骤和重大更改。

在 `pubspec.yaml` 中添加 `tostore` 依赖：

```yaml
dependencies:
  tostore: any # 请使用最新版本
```

## <a id="quick-start"></a>快速开始

> [!TIP]
> **如何选择存储方式？**
> 1. [**键值对模式 (KV)**](#quick-start-kv)：适用于配置存取、零散状态管理或 JSON 数据存储，主打快速上手。
> 2. [**结构化表 (Table)**](#quick-start-table)：适用于核心业务，需复杂查询、约束校验或海量数据治理。通过将完整性逻辑下沉到引擎，可显著降低应用层开发与维护成本。
> 3. [**内存模式 (Memory)**](#quick-start-memory)：适用于临时计算、单元测试或 **作为极速全局状态管理使用** —— 无需定义繁琐变量，通过全局查询与 watch 监听即可重塑应用交互。




### <a id="quick-start-kv"></a>键值对存储 (KV)
适用于不需要定义结构化表的场景，简单实用，内置了高性能存储引擎。**高效索引架构，确保在普通手机等边缘设备上，面对亿级数据规模，查询性能依然能维持极高的稳定性与极致的响应速度。** 不同空间 (Space) 的数据天然隔离，同时也支持全局共享。

```dart
// 初始化数据库
final db = await ToStore.open();

// 设置键值对 (支持 String, int, bool, double, Map, List, Json 等)
await db.setValue('user_profile', {
  'name': 'John',
  'age': 25,
});

// 切换空间 - 隔离不同用户数据
await db.switchSpace(spaceName: 'user_123');

// 设置全局共享变量 (isGlobal: true 用于跨 Space 共享，如登录状态)
await db.setValue('current_user', 'John', isGlobal: true);

// 过期自动清理 (TTL)
// 支持设置生存时间 (ttl) 或 明确的过期时刻 (expiresAt)
await db.setValue('temp_config', 'value', ttl: Duration(hours: 2));
await db.setValue('session_token', 'abc', expiresAt: DateTime(2026, 2, 31));

// 获取数据
final profile = await db.getValue('user_profile'); // Map<String, dynamic>

// 数据变动实时监听 (用于刷新局部 UI，避免额外维护状态管理框架)
db.watchValue('current_user', isGlobal: true).listen((value) {
  print('登录用户已变更为: $value');
});

// 批量监听多个键
db.watchValues(['current_user', 'login_status']).listen((map) {
  print('多项配置已更新: $map');
});

// 删除数据
await db.removeValue('current_user');
```

> [!TIP]
> **需要更多键值对功能？**
> 诸如强类型读取（`getInt`、`getBool`）、原子自增、前缀检索、键空间探索等进阶操作，请参阅 [**键值对进阶操作 (db.kv)**](#kv-advanced)。

#### Flutter UI 自动监听刷新示例
在 Flutter 中，利用 `StreamBuilder` 配合 `watchValue` 可以实现极其简洁的响应式刷新：

```dart
StreamBuilder(
  // 监听全局变量时，务必指定 isGlobal: true
  stream: db.watchValue('current_user', isGlobal: true),
  builder: (context, snapshot) {
    // snapshot.data 即为 KV 中 'current_user' 的最新值
    final user = snapshot.data ?? '未登录'; 
    return Text('当前登录用户: $user');
  },
)
```

### <a id="quick-start-table"></a>结构化表方式 (Table)
需预先创建表结构（详见 [表结构定义](#schema-definition)）方可进行增删改查。针对不同场景的接入建议：
- **移动端/桌面端**：[针对频繁启动场景](#mobile-integration)，推荐在初始化实例时传入 `schemas`。
- **服务端/智能体**：[针对持续运行场景](#server-integration)，推荐通过调用 `createTables` 动态创建。


```dart
// 1. 初始化数据库
final db = await ToStore.open();

// 2. 插入数据 (准备基础数据)
final result = await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 统一操作模型 DbResult，推荐始终检查 isSuccess
if (result.isSuccess) {
  print('数据插入成功，生成的主键ID为: ${result.successKeys.first}');
} else {
  print('插入失败: ${result.message}');
}

// 链式查询（详见[查询操作符](#查询操作符)，支持 =, !=, >, <, LIKE, IN 等）
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 更新与删除
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 实时监听 (更多详尽用法详见 [响应式查询](#reactive-query))
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('符合条件的用户已更新: $users');
});

// 配合 Flutter StreamBuilder 实现局部 UI 自动刷新
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


### <a id="quick-start-memory"></a>内存模式 (Memory Mode)

对于数据缓存、临时计算或不需要持久化到磁盘等场景，可以使用 `ToStore.memory()` 初始化一个纯内存数据库。在该模式下，所有数据（包括表结构、索引和键值对）均仅保存在内存中，读写性能达到极致。

#### 💡 也可以作为全局状态管理
无需定义繁杂的全局变量或引入笨重的状态管理框架。通过内存模式配合 `watchValue` 或 `watch()` 监听，您可以实现跨组件、跨页面的全自动 UI 刷新。它既保留了数据库的强大检索能力，又获得了超越普通变量的响应式体验，非常适合管理登录状态、实时配置或全局消息计数。

> [!CAUTION]
> **注意**：纯内存模式下产生的数据在应用关闭或重启后将完全丢失，请勿用于存储核心业务数据。

```dart
// 使用纯内存模式初始化数据库
final memDb = await ToStore.memory();

// 设置一个全局状态（如：当前未读消息数）
await memDb.setValue('unread_count', 5,isGlobal: true);

// 在 UI 任何地方直接监听，无需传参
memDb.watchValue<int>('unread_count',isGlobal: true).listen((count) {
  print('UI 自动感知消息变动: $count');
});

// 所有的增删改查、KV 存取及向量搜索都将在内存中以极速完成
await memDb.insert('active_users', {'name': 'Marley', 'status': 'online'});
```



## <a id="schema-definition"></a>表结构定义
**一次定义，换来引擎全链路自动化治理，长久免除应用维护繁重校验。**

下文移动端、服务端与智能体示例都会复用这里的 `appSchemas`。


### TableSchema 结构总览

```dart
const userSchema = TableSchema(
  name: 'users', // 表名，必填
  tableId: 'users', // 表的唯一标识，可选
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
      type: IndexType.btree, // 索引类型：btree/vector
    ),
  ],
  foreignKeys: const [], // 外键约束列表，可选；完整示例见下文“外键与级联约束”
  isGlobal: false, // 是否为全局表；true 时可跨 Space 全局共享
  ttlConfig: null, // 表级 TTL，可选；完整示例见下文“表级 TTL”
);

const appSchemas = [userSchema];
```

- **`DataType` 常用数据类型对照表**：
  | 类型 | 对应 Dart 类型 | 说明 |
  | :--- | :--- | :--- |
  | `integer` | `int` | 标准整数，适合 ID、计数等 |
  | `bigInt` | `BigInt` / `String` | 大整数，超过 18 位数字建议使用，防止精度丢失 |
  | `double` | `double` | 浮点数，适合价格、坐标等 |
  | `text` | `String` | 文本字符串，支持长度约束 |
  | `blob` | `Uint8List` | 二进制原始数据 |
  | `boolean` | `bool` | 布尔值 |
  | `datetime` | `DateTime` / `String` | 日期时间，底层以 ISO8601 存储 |
  | `array` | `List` | 列表/数组类型 |
  | `json` | `Map<String, dynamic>` | JSON 对象，适合存储动态结构化数据 |
  | `vector` | `VectorData` / `List<num>` | 高维向量数据，用于 AI 语义检索 (Embedding) |

- **`PrimaryKeyType` 主键自动生成策略**：
  | 策略 | 说明 | 特点 |
  | :--- | :--- | :--- |
  | `none` | 不自动生成 | 需在插入时手动指定主键 |
  | `sequential` | 顺序递增 | 适合靓号，但分布式下性能较差 |
  | `timestampBased` | 基于时间戳 | 分布式推荐 |
  | `datePrefixed` | 日期前缀 | 业务需要日期可读性 |
  | `shortCode` | 短码主键 | 简短适合对外展示 |

  > 所有主键默认以 `text`（String）类型存储。

  

### 约束与自动校验

通过 `FieldSchema` 将常见的校验规则直接下沉到引擎层，避免在应用层重复实现逻辑：

- `nullable: false`：非空约束
- `minLength` / `maxLength`：文本长度约束
- `minValue` / `maxValue`：整数或浮点数范围约束
- `defaultValue` / `defaultValueType`：静态默认值与动态默认值
- `unique`：唯一约束
- `createIndex`：为高频查询过滤、排序或关联字段创建索引，提升检索性能
- `fieldId` / `tableId`：辅助识别字段或表重命名，便于迁移


其中，`unique: true` 及会自动生成单字段唯一索引，`createIndex: true` 、外键会自动生成单字段普通索引；`indexes` 更适合定义组合索引、命名索引或向量索引。




### 选择接入方式

- **移动端/桌面端**：适合在初始化实例直接把 `appSchemas` 传入 `ToStore.open(...)`
- **服务端/智能体**：适合在进程运行时动态创建 schema，调用 `createTables(appSchemas)`


## <a id="mobile-integration"></a>移动、桌面等频繁启动场景集成

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

### 表结构自动演进 (Schema Evolution)

在 `ToStore.open()` 阶段，引擎会自动识别 `schemas` 的结构变动（如表/字段的增删、重命名及属性调整、索引的增删改等）并完成数据迁移，无需开发者手动维护数据库版本或编写迁移脚本。


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



## <a id="server-integration"></a>服务端/智能体（持续运行场景集成）

🖥️ **示例**：[server_quickstart.dart](../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// 进程运行时创建表结构
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

    
// 纯服务端性能调优 (可选)
// yieldDurationMs 用于控制持续处理任务的时间片释放。
// 为了保障前端 UI 动画流畅，在非linux平台，默认适配为 8ms。
// 在不需要 UI 的场景，推荐手动调整为 50ms 以换取更高吞吐。
final dbServer = await ToStore.open(
  config: DataStoreConfig(yieldDurationMs: 50),
);
```





## <a id="advanced-usage"></a>进阶用法

ToStore 提供了丰富的进阶功能，满足各种复杂业务场景需求：


### <a id="kv-advanced"></a>键值对进阶操作 (db.kv)

对于更复杂的 Key-Value 场景，建议使用 `db.kv` 命名空间。它提供了完整的 API 集，支持空间隔离、全局共享及多种数据类型。

- **基础存取 (Basic Access)**
  ```dart
  // 设置值 (支持 String, int, bool, double, Map, List 等)
  await db.kv.set('key', 'value', ttl: Duration(hours: 1));
  
  // 获取原始动态类型
  dynamic val = await db.kv.get('key');

  // 删除单个键
  await db.kv.remove('key');
  ```

- **强类型获取 (Type-Safe Getters)**
  无需手动转换类型，直接获取目标格式数据：
  ```dart
  String? name = await db.kv.getString('user_name');
  int? age = await db.kv.getInt('user_age');
  bool? isVip = await db.kv.getBool('is_vip');
  Map<String, dynamic>? profile = await db.kv.getMap('profile');
  List<String>? tags = await db.kv.getList<String>('tags');
  ```

- **批量操作 (Bulk Operations)**
  在单个操作中高效地处理多个键值对：
  ```dart
  // 批量设置
  await db.kv.setMany({
    'theme': 'dark',
    'language': 'zh_CN',
  });

  // 批量删除
  await db.kv.removeKeys(['temp_1', 'temp_2']);
  ```

- **原子计数器 (Atomic Increment)**
  在高并发场景下安全地递增或递减数值：
  ```dart
  // 自增 1 (默认值)
  await db.kv.setIncrement('view_count');
  // 自减 5 (传入负数实现递减)
  await db.kv.setIncrement('stock_count', amount: -5);
  ```

- **键空间管理与探索 (Discovery & Management)**
  ```dart
  // 获取所有前缀以 'setting_' 开头的键名
  final keys = await db.kv.getKeys(prefix: 'setting_');

  // 统计当前空间内的键值对总数
  final count = await db.kv.count();

  // 检查某个键是否存在且未过期
  final exists = await db.kv.exists('config_cache');

  // 清空当前空间的所有 KV 数据
  await db.kv.clear();
  ```

- **生命周期管理 (TTL)**
  获取或动态更新现有键的过期时间：
  ```dart
  // 获取剩余过期时长
  Duration? ttl = await db.kv.getTtl('token');

  // 为现有键更新过期时间（7天后过期）
  await db.kv.setTtl('token', Duration(days: 7));
  ```

- **响应式监听 (Reactive Watch)**
  ```dart
  // 监听单个键
  db.kv.watch<int>('unread_count').listen((count) => print(count));

  // 监听多个键的变化快照
  db.kv.watchValues(['theme', 'font_size']).listen((map) => print(map));
  ```

- **全局共享参数 (isGlobal)**
  以上所有方法均支持可选参数 `isGlobal`：`true` 表示在全局空间操作（跨 Space 共享），`false`（默认）表示在当前隔离空间操作。


### <a id="bulk-operations"></a>批量操作 (Bulk Operations)

ToStore 针对大规模数据吞吐提供了专门的批量处理接口。这些接口内置了并行任务分发与时间切片调度机制，在执行高吞吐写入时能有效降低对 UI 主线程的影响。

| 接口 | 核心用途 | 数据要求 | 特点 |
| :--- | :--- | :--- | :--- |
| `batchInsert` | 批量插入新记录 | 必须包含所有非空字段 | 纯插入，效率最高 |
| `batchUpsert` | 批量同步（插入或更新） | **必须包含所有非空字段** | 全量同步，基于主键或唯一字段自动判断 |
| `batchUpdate` | 批量局部更新 | **主键或唯一字段** + 待更新字段 | 增量更新，专门用于修改已有记录 |

- **批量插入 (batchInsert)**
  ```dart
  await db.batchInsert('users', [
    {'username': 'user1', 'email': '1@ex.com'},
    {'username': 'user2', 'email': '2@ex.com'},
  ]);
  ```

- **智能批量同步 (batchUpsert)**
  基于主键或唯一字段自动识别“插入”或“更新”。常用于数据全量同步场景。
  > [!IMPORTANT]
  > **数据要求**：由于可能触发插入操作，`batchUpsert` 要求每条记录必须包含所有非空（nullable: false）字段。

- **高效批量更新 (batchUpdate)**
  专门用于更新已有记录。每条记录需包含主键或唯一字段作为标识，以及需要修改的字段。
  > [!TIP]
  > **局部更新**：`batchUpdate` 仅更新提供的字段，不需要包含所有非空字段，适合增量修改场景。
  ```dart
  await db.batchUpdate('users', [
    {'username': 'john', 'age': 27}, // 通过唯一字段 username 定位并更新 age
    {'id': '1002', 'status': 'active'}, // 也支持直接指定主键
  ]);
  ```

> [!TIP]
> 可以设置 `allowPartialErrors: true` 来确保个别数据错误不会拒绝本次批量操作。


### <a id="vector-advanced"></a>向量字段、向量索引与向量检索

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

### <a id="ttl-config"></a>表级 TTL（按时间自动过期清理）

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


### 智能存储 (Upsert)
根据 data 中的主键或唯一字段判断：存在则更新，不存在则插入。不支持 where，冲突目标由 data 决定。

```dart
// 按主键
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// 按唯一键（记录须包含参与唯一约束的所有字段及必填字段）
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// 批量 upsert (支持原子性或部分成功模式)
// allowPartialErrors: true 表示允许部分失败（如某条记录因唯一性约束冲突，其他记录仍会正常处理）
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### <a id="query-advanced"></a>高级查询

ToStore 提供声明式的链式查询 API，支持灵活的字段处理与复杂的多表关联。

#### 1. 字段选择 (`select`)
`select` 方法用于指定返回的字段列表。若不调用，默认返回全表字段。
- **字段别名 (Alias)**：支持 `field as alias` 语法（不区分大小写），重命名结果集中的 Key。
- **表名限定**：在多表关联时，使用 `table.field` 格式可以明确指定字段归属，避免命名冲突。
- **聚合混用**：可以在列表中直接传入 `Agg` 聚合对象。

```dart
final results = await db.query('orders')
    .select([
      'orders.id',                       // 指定表名的字段
      'users.name as customer_name',     // 字段别名：结果集中 Key 将变为 customer_name
      'orders.amount',
      Agg.count('id', alias: 'total_items') // 可以在 select 中混入聚合统计
    ])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

#### 2. 表连接 (`join`)
支持标准的 `join` (Inner Join)、`leftJoin` 和 `rightJoin`。

#### 3. 基于外键的智能关联 (推荐)
如果您在 `TableSchema` 中正确定义了 `foreignKeys`，则无需手动编写连接条件。引擎会自动解析引用关系并生成最优的 JOIN 路径。

- **`joinReferencedTable(tableName)`**：自动连接“当前表引用”的父表。
- **`joinReferencingTable(tableName)`**：自动连接“引用当前表”的子表。

```dart
// 假设 posts 表定义了指向 users 的外键
final posts = await db.query('posts')
    .joinReferencedTable('users') // 自动识别为 ON posts.user_id = users.id
    .select(['posts.title', 'users.username'])
    .limit(20);
```

---

### <a id="aggregation-stats"></a>数据聚合、分组与统计 (Agg & GroupBy)

#### 1. 聚合计算 (`Agg` 工厂类)
聚合函数用于对数据集执行统计计算。配合 `alias` 参数，您可以自定义结果集中的字段名。

| 方法 | 功能 | 示例 |
| :--- | :--- | :--- |
| `Agg.count(field)` | 统计非空记录数 | `Agg.count('id', alias: 'total')` |
| `Agg.sum(field)` | 求和 | `Agg.sum('amount', alias: 'total_price')` |
| `Agg.avg(field)` | 平均值 | `Agg.avg('score', alias: 'average_score')` |
| `Agg.max(field)` | 最大值 | `Agg.max('age')` |
| `Agg.min(field)` | 最小值 | `Agg.min('price')` |

> [!TIP]
> **聚合统计的两种用法**：
> 1.  **快捷统计方法 (推荐用于单一统计)**：直接在链式查询上调用，同步返回计算值。
>     `num? totalAge = await db.query('users').sum('age');`
> 2.  **`select` 嵌入模式 (用于多项统计或与分组配合)**：在 `select` 列表中传入 `Agg` 对象。
>     `final stats = await db.query('orders').select(['status', Agg.sum('amount')]).groupBy(['status']);`

#### 2. 分组统计与过滤 (`groupBy` / `having`)
使用 `groupBy` 对数据进行分类，结合 `having` 对聚合后的结果进行二次过滤（类似于 SQL 的 HAVING 触发场景）。

```dart
final stats = await db.query('orders')
    .select([
      'status', 
      Agg.sum('amount', alias: 'sum_amount'), 
      Agg.count('id', alias: 'order_count')
    ])
    .groupBy(['status'])
    // having 接受一个 QueryCondition，用于过滤聚合结果
    .having(QueryCondition().where(Agg.sum('amount'), '>', 5000))
    .limit(10);
```

#### 3. 辅助查询方法
- **`exists()` (高性能)**：检查是否存在符合条件的记录。相比 `count() > 0`，它在底层采用“短路”机制，只要发现一条匹配即立即返回，对于海量数据校验性能极佳。
- **`count()`**：高效返回符合条件的记录总数。
- **`first()`**：便捷方法，相当于 `limit(1)` 并直接返回第一条数据的 Map。
- **`distinct([fields])`**：去重查询。若提供 `fields`，则根据指定字段的唯一性进行去重。

```dart
// 高效存在性检查
if (await db.query('users').whereEqual('email', 'test@test.com').exists()) {
  print('邮箱已注册');
}

// 获取去重后的城市列表
final cities = await db.query('users').distinct(['city']);
```

#### <a id="query-condition"></a>4. 复杂逻辑构造：QueryCondition
`QueryCondition` 是 ToStore 处理复杂“括号层级”查询（Nested Logic）的核心工具。当简单的 `where` 链接无法满足多层嵌套 `(A AND B) OR (C AND D)` 逻辑时，需要用到它。

- **`condition(QueryCondition sub)`**：开启一个 AND 括号层级。
- **`orCondition(QueryCondition sub)`**：开启一个 OR 括号层级。
- **`or()`**：改变下一个条件的连接方式为 OR（默认为 AND）。

##### 示例 1：混合 OR 条件
实现 SQL: `WHERE is_active = true AND (role = 'admin' OR fans >= 1000)`

```dart
final subGroup = QueryCondition()
    .whereEqual('role', 'admin')
    .or()
    .whereGreaterThanOrEqualTo('fans', 1000);

final results = await db.query('users')
    .whereEqual('is_active', true)
    .condition(subGroup); // 以 AND 方式嵌入括号
```

##### 示例 2：条件复用
您可以预先定义一些通用的业务逻辑片段，在不同查询中动态组合：

```dart
final hotUser = QueryCondition().whereGreaterThan('fans', 5000);
final recentLogin = QueryCondition().whereGreaterThan('last_login', '2024-01-01');

// 在任意查询中自由拼装
final targetUsers = await db.query('users')
    .condition(hotUser)
    .condition(recentLogin);
```


#### <a id="streaming-query"></a>5. 流式查询 (Streaming)
适用于海量数据且不需要一次性加载到内存的场景，支持边查询边处理。

```dart
db.streamQuery('users').listen((data) {
  print('处理单条记录: $data');
});
```

#### <a id="reactive-query"></a>6. 响应式查询 (Reactive Query)
`watch()` 方法允许您对查询结果进行实时监控。返回一个 `Stream`，每当被查询的表数据发生符合条件的变更时，它会自动重新查询并推送最新结果。
- **自动去抖 (Debounce)**：内置智能防抖，避免极短时间内触发多次无效查询。
- **UI 同步**：配合 Flutter 的 `StreamBuilder` 轻松实现即时刷新的列表。

```dart
// 简单监听
db.query('users').whereEqual('is_online', true).watch().listen((users) {
  print('当前在线人数变动: ${users.length}');
});

// Flutter StreamBuilder 接入示例
// 数据变动时，会自动刷新局部UI
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

### <a id="query-cache"></a>手动查询结果缓存 (可选)

> [!IMPORTANT]
> **ToStore 内部已具备高效的 LRU 多层级智能缓存**。
> **不推荐常规使用**。需要自行手动维护缓存，仅建议在以下特殊场景下开启：
> 1. 无索引的耗时大扫描，且数据不常变动。
> 2. 对非热点查询有持续极端响应要求（如要求冷门数据也要保持 1ms 访问）。

- `useQueryCache([Duration? expiry])`：开启缓存，可选设置过期时间。
- `noQueryCache()`：显式禁用缓存（覆盖全局设置）。
- `clearQueryCache()`：手动使该查询条件的缓存失效。

```dart
final results = await db.query('heavy_table')
    .where('non_indexed_field', '=', 'value')
    .useQueryCache(const Duration(minutes: 10)); // 仅针对重型查询手动提速
```



### <a id="query-pagination"></a>查询与高效分页

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




### <a id="foreign-keys"></a>外键与级联约束

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





### <a id="query-operators"></a>查询操作符

所有 `where(field, operator, value)` 条件支持以下操作符（大小写不敏感）：

| 操作符 | 说明 | 示例 / 性能 |
| :--- | :--- | :--- |
| `=` | 等于 | `where('status', '=', 'val')` — **[推荐]** 索引 Seek |
| `!=`, `<>` | 不等于 | `where('role', '!=', 'val')` — **[注意]** 全表扫描 |
| `>` , `>=`, `<`, `<=` | 范围比较 | `where('age', '>', 18)` — **[推荐]** 索引 Scan |
| `IN` | 包含 | `where('id', 'IN', [...])` — **[推荐]** 索引 Seek |
| `NOT IN` | 不包含 | `where('status', 'NOT IN', [...])` — **[注意]** 全表扫描 |
| `BETWEEN` | 范围 | `where('age', 'BETWEEN', [18, 65])` — **[推荐]** 索引 Scan |
| `LIKE` | 模式匹配 (`%` 匹配任意字符，`_` 匹配单字符) | `where('name', 'LIKE', 'John%')` — **[注意]** 见下文说明 |
| `NOT LIKE` | 模式不匹配 | `where('email', 'NOT LIKE', '...')` — **[注意]** 全表扫描 |
| `IS` | 为 null | `where('deleted_at', 'IS', null)` — **[推荐]** 索引 Seek |
| `IS NOT` | 不为 null | `where('email', 'IS NOT', null)` — **[注意]** 全表扫描 |

### 语义化查询方法（推荐）

推荐使用语义化方法，避免手写操作符字符串并便于 IDE 提示：

#### 1. 比较 (Comparison)
用于数值或字符串的直接比较关系。
```dart
db.query('users').whereEqual('username', 'John');           // 等于
db.query('users').whereNotEqual('role', 'guest');          // 不等于
db.query('users').whereGreaterThan('age', 18);             // 大于
db.query('users').whereGreaterThanOrEqualTo('score', 60);  // 大于等于
db.query('users').whereLessThan('price', 100);             // 小于
db.query('users').whereLessThanOrEqualTo('quantity', 10);  // 小于等于
db.query('users').whereTrue('is_active');                  // 为真 (true)
db.query('users').whereFalse('is_banned');                 // 为假 (false)
```

#### 2. 集合与范围 (Collection & Range)
用于判断字段值是否落入指定的容器或区间。
```dart
db.query('users').whereIn('id', ['id1', 'id2']);           // 在列表中
db.query('users').whereNotIn('status', ['banned', 'pending']); // 不在列表中
db.query('users').whereBetween('age', 18, 65);             // 在范围内 (含边界)
```

#### 3. 空值判断 (Null Check)
用于筛选字段是否存在值。
```dart
db.query('users').whereNull('deleted_at');               // 为空 (IS NULL)
db.query('users').whereNotNull('email');                 // 不为空 (IS NOT NULL)
db.query('users').whereEmpty('nickname');                // 为空或空字符串
db.query('users').whereNotEmpty('bio');                  // 不为空且不为双空
```

#### 4. 模式匹配 (Pattern Matching)
支持 SQL 风格的通配符搜索（`%` 匹配任意字符，`_` 匹配单个字符）。
```dart
db.query('users').whereLike('name', 'John%');             // SQL 风格匹配
db.query('users').whereContains('bio', 'flutter');   // 包含匹配 (LIKE '%value%')
db.query('users').whereStartsWith('name', 'Admin');  // 前缀匹配 (LIKE 'value%')
db.query('users').whereEndsWith('email', '.com');    // 后缀匹配 (LIKE '%value')
db.query('users').whereContainsAny('tags', ['dart', 'flutter']); // 模糊匹配列表中任意项
```
```dart
// 等价于：.where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```


> [!CAUTION]
> **查询性能指南 (Index vs Full-Scan)**
>
> 在超大规模数据集（数百万级以上）场景下，为避免主线程卡顿和单次查询超时，请遵循以下原则：
>
> 1. **索引友好 (Index Optimized - [推荐])**：
>    *   **语义化方法**：`whereEqual`、`whereGreaterThan`、`whereLessThan`、`whereIn`、`whereBetween`、`whereNull`、`whereTrue`、`whereFalse`、以及 **`whereStartsWith`** (前缀匹配)。
>    *   **操作符**：`=`, `>`, `<`, `>=`, `<=`, `IN`, `BETWEEN`, `IS null`, `LIKE 'prefix%'`。
>    *   *说明：这些操作通过索引能够实现极速定位。对于 `whereStartsWith` / `LIKE 'abc%'`，索引依然可以进行前缀范围扫描。*
>
> 2. **触发全表扫描 (Full-Scan Risks - [慎重])**：
>    *   **模糊语义**：`whereContains` (`LIKE '%val%'`)、`whereEndsWith` (`LIKE '%val'`)、`whereContainsAny`。
>    *   **否定查询**：`whereNotEqual` (`!=`, `<>`)、`whereNotIn` (`NOT IN`)、`whereNotNull` (`IS NOT null`/`whereNotEmpty`)。
>    *   **模式不匹配**：`NOT LIKE`。
>    *   *说明：上述操作即使建立了索引，在大部分物理引擎下也需遍历整个数据存储区。在移动端及小规模数据场景影响不大，但在分布式/超大数据分析场景应尽量结合其它索引条件（如先通过 ID 或时间范围缩小数据量）以及limit使用。*




## <a id="distributed-architecture"></a>分布式架构

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

## <a id="primary-key-examples"></a>主键类型示例

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


## <a id="atomic-expressions"></a>表达式原子操作

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

## <a id="transactions"></a>事务操作

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


### <a id="database-maintenance"></a>管理与维护

接下来介绍数据库管理、诊断与维护相关的 API，方便在插件化开发、后台管理或运维场景下使用：

- **表维护 (Table Management)**
  - `createTable(schema)`：手动创建单张表。适合运行时按需建表或模块化加载场景。
  - `getTableSchema(tableName)`：获取已定义的表结构信息。常用于自动化校验或 UI 模型生成。
  - `getTableInfo(tableName)`：获取表运行时的统计信息。包含记录总数、索引数量、数据文件大小、创建时间、是否为全局表等核心指标。
  - `clear(tableName)`：清空全表数据。此操作会重置数据，但会安全保留表结构、索引定义和内外键约束。
  - `dropTable(tableName)`：彻底销毁表。删除所有数据及对应的模式定义，不可撤销。
- **空间管理 (Space Management)**
  - `currentSpaceName`：实时获取当前实例所处的活跃空间。
  - `listSpaces()`：获取当前数据库实例下所有已分配的空间列表。
  - `getSpaceInfo(useCache: true)`：空间审计。查看当前空间下的表总量、数据总体量等；`useCache: false` 可穿透缓存读取实时状态。
  - `deleteSpace(spaceName)`：销毁指定空间及其完整数据（`default` 及当前活跃空间除外）。
- **实例元信息 (Instance Discovery)**
  - `config`：查看当前实例最终生效的 `DataStoreConfig` 配置快照。
  - `instancePath`：准确定位数据存储目录。
  - `getVersion()` / `setVersion(version)`：业务自定义版本控制。用于记录应用自身的数据库版本号（非引擎版本），方便业务进行手动逻辑迁移判定。
- **底线性维护 (Maintenance)**
  - `flush(flushStorage: true)`：强制数据落盘。调用此方法可立即将内存暂存的变动持久化。若 `flushStorage: true`，还会请求系统同步文件底层缓冲区。
  - `deleteDatabase()`：全量清除。抹除当前实例的所有物理文件及其元数据，慎用。
- **一站式诊断 (Diagnostics)**
  - `db.status.memory()`：内存快照诊断。查看读写缓存命中率、索引页占用及整体堆内存分配。
  - `db.status.space()` / `db.status.table(tableName)`：空间与表的实时统计及健康状态。
  - `db.status.config()`：运行参数快照。
  - `db.status.migration(taskId)`：异步迁移进度实时跟踪。

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



### <a id="backup-restore"></a>备份与恢复

非常适用于单用户的本地导入导出、大规模数据离线迁移、系统故障回滚：

- **数据备份 (`backup`)**
  - `compress`: 是否启用压缩。建议开启（默认 true），可显著减少文件体积。
  - `scope`: 备份作用域控制：
    - `BackupScope.database`: 备份**整个数据库实例**（含所有 Space 及全局表）。
    - `BackupScope.currentSpace`: 仅备份**当前活跃空间**（不含全局表），适合单一数据。
    - `BackupScope.currentSpaceWithGlobal`: 备份**当前空间及其配套的全局表**，适合单租户/单用户迁移。
- **数据恢复 (`restore`)**
  - `backupPath`: 备份包物理路径。
  - `cleanupBeforeRestore`: 恢复前是否先静默抹除当前相关数据，避免还原后出现逻辑混合错误（建议 true）。
  - `deleteAfterRestore`: 恢复成功后自动删除备份源文件。

```dart
// 示例：导出当前用户完整数据包
final backupPath = await db.backup(
  compress: true,
  scope: BackupScope.currentSpaceWithGlobal,
);

// 示例：从数据包还原（并自动清理源文件）
final restored = await db.restore(
  backupPath,
  cleanupBeforeRestore: true,
  deleteAfterRestore: true, 
);
```

### <a id="status-error-codes"></a>状态码与错误处理


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


### <a id="logging-diagnostics"></a>日志回调与数据库诊断

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




## <a id="security-config"></a>安全配置


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



## <a id="advanced-config"></a>高级配置详解 (DataStoreConfig)

> [!TIP]
> **智能自适应 (Zero Config)**
> ToStore 会自动感知运行平台、性能、内存总量及 I/O 特性自动优化各项参数（如并发度、分片大小、缓存预算等）。**在 99% 的常见业务场景下，不需要手动微调 `DataStoreConfig`**，直接默认开启即可获得当前平台的极佳性能。


| 参数 | 默认值 | 用途与建议 |
| :--- | :--- | :--- |
| **`yieldDurationMs`** | **8ms** | **【核心建议】** 任务执行让步时长。8ms 契合 120fps/60fps 刷新率。它能确保在执行海量数据查询或迁移时，UI 线程依然能顺滑渲染，不掉帧。 |
| **`maxQueryOffset`** | **10000** | **查询保护**。当 `offset` 超过此阈值时将报错。这是为了防止由于深度分页导致的 pathological IO（深分页性能急剧退化）。 |
| **`defaultQueryLimit`** | **1000** | **资源预检**。当查询未指定 `limit` 时套用此默认值，防止开发者失误导致的一次性加载海量结果导致 OOM。 |
| **`cacheMemoryBudgetMB`** | (自动) | **内存精细化管理**。各缓存总内存预算。引擎会根据此预算自动启用 LRU 回收。 |
| **`enableJournal`**| **true** | **崩溃自愈**。开启后，遇到异常崩溃或断电，数据会在下次启动时自愈恢复。 |
| **`persistRecoveryOnCommit`**| **true** | **强持久化保证**。为 true 时，事务提交后会强制 Sync 到物理磁盘；为 false 则后台异步 Flush（极大提速，但极端崩溃下可能丢失极少量数据）。 |
| **`ttlCleanupIntervalMs`**| **300000** | **全局 TTL 轮询**。引擎后台会在非闲置时扫描过期数据的时间间隔（默认 5 分钟），调小后删除更及时，但开销稍大。 |
| **`maxConcurrency`**| (自动) | **并发算力控制**。设置密集型任务（如向量计算、加解密）的最大并行线程数。通常推荐保持自动（基于核心数）。 |

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    yieldDurationMs: 8, // 对前端 UI 极其友好，后端建议调整50ms
    defaultQueryLimit: 50, // 强制限制查询最大结果集
    enableJournal: true, // 确保崩溃自愈
  ),
);
```

---

## <a id="performance"></a>性能与体验

### 基准测试

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore 基础性能演示" width="320" />
</p>

- **基础性能演示**（<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4" target="_blank" rel="noopener">basic-demo.mp4</a>）：GIF 预览可能显示不全，请点击视频查看完整演示。在普通手机上，即便数据量超过亿级，应用的启动、翻页与检索性能依旧保持稳定顺滑。

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore 灾难恢复压力测试" width="320" />
</p>

- **灾难恢复压力测试**（<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4" target="_blank" rel="noopener">disaster-recovery.mp4</a>）：在高频写入过程中，故意反复中断进程，模拟崩溃与断电，ToStore 能够快速完成自恢复。




### 体验建议

- 📱 **示例项目**：`example` 目录下提供了完整的Flutter应用示例
- 🚀 **生产环境**：建议打包release版本，release模式下性能远超调试模式
- ✅ **标准测试**：核心功能已覆盖标准化测试




如果 ToStore 对您有所帮助，请给我们一个 ⭐️
这是对开源的最大支持，非常感谢





> **推荐**：前端应用开发可考虑使用 [ToApp 开发框架](https://github.com/tocreator/toapp)，提供全栈开发解决方案，自动化、一体化处理数据请求、加载、存储、缓存和展示。




## <a id="more-resources"></a>更多资源

- 📖 **文档**：[Wiki](https://github.com/tocreator/tostore)
- 📢 **问题反馈**：[GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **技术讨论**：[GitHub Discussions](https://github.com/tocreator/tostore/discussions)



