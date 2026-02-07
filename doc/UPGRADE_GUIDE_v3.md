# Upgrade Guide: v2.2.2 → v3.x

[English](#english) | [简体中文](#简体中文)

---

# English

## Why Upgrade to v3.x?

ToStore v3.x is a major release with significant improvements:

| Feature | Description |
|---------|-------------|
| **Foreign Key Support** | Comprehensive relationship management with referential integrity |
| **Atomic Expression Updates** | Efficient batch data modifications without concurrency conflicts |
| **AES Encryption** | Enhanced security for logs, indexes, and table data with device binding |
| **Data Change Listeners** | Automatic UI refresh when data changes |
| **Cursor Pagination** | O(1) performance for large dataset navigation |
| **Enhanced WAL Recovery** | Handles power outages and crashes with zero data loss |
| **Storage Reduction** | Optimized data footprint |
| **Pure Dart Support** | Better server-side compatibility |
| **Massive Data Scale** | Supports TB/PB-level data on edge devices |
| **Constant-Time Index Lookups** | O(1) for primary keys and indexed fields |

> [!IMPORTANT]
> **Backward Compatibility**: v3.x automatically migrates data from v2.x.
> **No Downgrade**: Once upgraded, data cannot be downgraded to v2.x.

---

## Migration Steps

### 1. Add path_provider Dependency

v3.x removed the built-in `path_provider` dependency to support pure Dart environments. You must now provide the database path manually.

```yaml
# pubspec.yaml
dependencies:
  tostore: ^3.x.x
  path_provider: ^2.1.0  # Add this for mobile/desktop
```

### 2. Update Initialization Code

> [!CAUTION]
> **Critical**: You must use the same database path as v2.2.2, otherwise your existing data will not be found!
>
> In v2.2.2, the default path was: `getApplicationDocumentsDirectory()/common`

**Before (v2.2.2):**
```dart
final db = ToStore(dbName: 'my_app');
await db.initialize();
```

**After (v3.x):**
```dart
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// Get the same path as v2.2.2
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');  // Must match v2.2.2 default!

// Use new single-step initialization
final db = await ToStore.open(
  dbPath: dbRoot,
  dbName: 'my_app',
  schemas: [...],
);
```

### 3. Encryption / encoding configuration

v3.x replaces the old encoding flags and keys with a single `EncryptionConfig`. Use it when you need encryption or encoding.

**Before (v2.x):**
```dart
final db = ToStore(
  config: DataStoreConfig(
    enableEncoding: true,
    encodingKey: 'YourEncodingKey',
    encryptionKey: 'YourEncryptionKey',
  ),
);
```

**After (v3.x):**
```dart

final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      encryptionType: EncryptionType.xorObfuscation,  // or aes256Gcm for AES
      encodingKey: 'YourEncodingKey',
      encryptionKey: 'YourEncryptionKey',
      deviceBinding: false,  // set true for path-bound keys
    ),
  ),
);
```

- **encryptionType**: `EncryptionType.none` (no encryption), `xorObfuscation` (lightweight obfuscation), `chacha20Poly1305`, or `aes256Gcm`.
- **encodingKey** / **encryptionKey**: Same role as in v2.x; optional — keys are derived by default when not provided.
- **deviceBinding**: When true, keys are bound to the device path.

### 4. Deprecated APIs

The old two-step initialization is deprecated but still works:

```dart
// Deprecated - will show warning
final db = ToStore(...);
await db.initialize();

// Recommended - use ToStore.open()
final db = await ToStore.open(...);
```

---

## ⚠️ Important Warnings

1. **Database Path Must Match**
   - v2.2.2 default: `getApplicationDocumentsDirectory()/common/{dbName}`
   - If you don't specify the same path, v3.x will create a new empty database

2. **No Downgrade Support**
   - v3.x data format is not backward compatible
   - Once upgraded, you cannot roll back to v2.x without data loss


---

# 简体中文

## 为什么升级到 v3.x？

ToStore v3.x 是一个重大版本更新，包含以下重要改进：

| 特性 | 说明 |
|------|------|
| **外键支持** | 完整的关系管理和引用完整性约束 |
| **原子表达式更新** | 高效批量数据修改，避免并发冲突 |
| **AES 加密** | 增强安全性，支持设备指纹绑定 |
| **数据变更监听** | 数据变化时自动刷新 UI |
| **游标分页** | 大数据集 O(1) 分页性能 |
| **增强恢复** | 断电和崩溃后零数据丢失 |
| **存储空间减少** | 优化数据占用 |
| **纯 Dart 支持** | 更好的服务端兼容性 |
| **超大规模数据** | 边缘设备支持 TB/PB 级数据 |
| **索引查询性能恒定** | 主键和索引字段保持 O(1) 性能 |


> [!IMPORTANT]
> **向下兼容**：v3.x 会自动迁移 v2.x 的数据。
> **不可降级**：升级后数据无法降级回 v2.x。

---

## 迁移步骤

### 1. 添加 path_provider 依赖

v3.x 移除了内置的 `path_provider` 依赖以支持纯 Dart 环境。现在手机端需要手动提供数据库路径。

```yaml
# pubspec.yaml
dependencies:
  tostore: ^3.x.x
  path_provider: ^2.1.0  # 移动端/桌面端需要自行获取数据库存储路径
```

### 2. 更新初始化代码

> [!CAUTION]
> **关键提示**：必须使用与 v2.2.2 相同的数据库路径，否则将找不到原有数据！
>
> v2.2.2 的默认路径是：`getApplicationDocumentsDirectory()/common`

**之前 (v2.2.2)：**
```dart
final db = ToStore(dbName: 'my_app');
await db.initialize();
```

**之后 (v3.x)：**
```dart
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

// 获取与 v2.2.2 相同的路径
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');  // 必须与 v2.2.2 默认值一致！

// 使用新的一步初始化
final db = await ToStore.open(
  dbPath: dbRoot,
  dbName: 'my_app',
  schemas: [...],
);
```

### 3. 加密 / 编码配置

v3.x 用统一的 `EncryptionConfig` 替代了原来的编码开关和密钥配置。需要加密或编码时请使用该配置。

**之前 (v2.x)：**
```dart
final db = ToStore(
  config: DataStoreConfig(
    enableEncoding: true,
    encodingKey: 'YourEncodingKey',
    encryptionKey: 'YourEncryptionKey',
  ),
);
```

**之后 (v3.x)：**
```dart

final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      encryptionType: EncryptionType.xorObfuscation,  // 或 aes256Gcm 使用 AES
      encodingKey: 'YourEncodingKey',
      encryptionKey: 'YourEncryptionKey',
      deviceBinding: false,  // 设为 true 可启用路径绑定密钥
    ),
  ),
);
```

- **encryptionType**：`EncryptionType.none`（不加密）、`xorObfuscation`（轻量混淆）、`chacha20Poly1305` 或 `aes256Gcm`。
- **encodingKey** / **encryptionKey**：与 v2.x 作用相同；可选，不传时默认派生。
- **deviceBinding**：为 true 时密钥与该设备路径特征绑定。


### 4. 已弃用的 API

旧的两步初始化方式已弃用，但仍可使用：

```dart
// 已弃用
final db = ToStore(...);
await db.initialize();

// 推荐
final db = await ToStore.open(...);
```

---

## ⚠️ 重要警告

1. **数据库路径必须一致**
   - v2.2.2 默认路径：`getApplicationDocumentsDirectory()/common/{dbName}`
   - 如果不指定相同路径，v3.x 会创建新的空数据库

2. **不支持版本降级**
   - v3.x 数据格式不向后兼容
   - 升级后无法回退到 v2.x，否则数据会丢失
