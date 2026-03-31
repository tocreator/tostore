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
  <a href="README.zh-CN.md">简体中文</a> | 
  <a href="README.ja.md">日本語</a> | 
  <a href="README.ko.md">한국어</a> | 
  <a href="README.es.md">Español</a> | 
  <a href="README.pt-BR.md">Português (Brasil)</a> | 
  Русский | 
  <a href="README.de.md">Deutsch</a> | 
  <a href="README.fr.md">Français</a> | 
  <a href="README.it.md">Italiano</a> | 
  <a href="README.tr.md">Türkçe</a>
</p>


## Быстрая навигация

- [Почему ToStore?](#why-tostore) | [Ключевые особенности](#key-features) | [Установка](#installation) | [Быстрый старт](#quick-start)
- [Определение схемы](#schema-definition) | [Мобильная/Десктопная интеграция](#mobile-integration) | [Серверная интеграция](#server-integration)
- [Векторы и поиск ANN](#vector-advanced) | [TTL на уровне таблицы](#ttl-config) | [Запросы и пагинация](#query-pagination) | [Внешние ключи](#foreign-keys) | [Операторы запросов](#query-operators)
- [Распределенная архитектура](#distributed-architecture) | [Примеры первичных ключей](#primary-key-examples) | [Атомарные операции](#atomic-expressions) | [Транзакции](#transactions) | [Управление и обслуживание базы данных](#database-maintenance) | [Резервное копирование и восстановление](#backup-restore) | [Обработка ошибок](#error-handling) | [Колбэк логов и диагностика базы данных](#logging-diagnostics)
- [Конфигурация безопасности](#security-config) | [Производительность](#performance) | [Ресурсы](#more-resources)


<a id="why-tostore"></a>
## Почему ToStore?

ToStore — это современный движок данных, разработанный для эры AGI и сценариев пограничного интеллекта (edge intelligence). Он нативно поддерживает распределенные системы, мультимодальное слияние, реляционные структурированные данные, многомерные векторы и хранение неструктурированных данных. Основанный на нейросетевой архитектуре, узлы обладают высокой автономностью и эластичной горизонтальной масштабируемостью, создавая гибкую топологическую сеть данных для бесшовного кроссплатформенного взаимодействия между периферией и облаком. Он предлагает транзакции ACID, сложные реляционные запросы (JOIN, каскадные внешние ключи), TTL на уровне таблицы и агрегационные вычисления. Включает несколько алгоритмов распределенных первичных ключей, атомарные выражения, идентификацию изменений схемы, шифрование, изоляцию данных в пространствах, интеллектуальное распределение нагрузки с учетом ресурсов и автоматическое восстановление после сбоев.

По мере того как центр тяжести вычислений смещается к пограничному интеллекту, терминалы (агенты, сенсоры) становятся интеллектуальными узлами, отвечающими за локальную генерацию, восприятие среды и принятие решений. Традиционные БД, ограниченные своей архитектурой и надстройками, с трудом соответствуют требованиям низкой задержки и стабильности при высокой нагрузке, поиске по векторам и совместной генерации.

ToStore предоставляет периферии распределенные возможности для поддержки массивных данных, сложной локальной генерации ИИ и крупномасштабных потоков данных. Глубокое интеллектуальное взаимодействие между узлами периферии и облака обеспечивает надежную основу для AR/VR, мультимодального взаимодействия, семантических векторов и пространственного моделирования.


<a id="key-features"></a>
## Ключевые особенности

- 🌐 **Единый кроссплатформенный движок**
  - Общий API для мобильных устройств, десктопа, веба и серверов.
  - Поддержка реляционных данных, многомерных векторов и неструктурированных данных.
  - Идеально для жизненного цикла данных от локального хранения до взаимодействия периферии и облака.

- 🧠 **Нейросетевая распределенная архитектура**
  - Высокая автономность узлов; гибкая топология данных через взаимосвязанное сотрудничество.
  - Поддержка эластичного горизонтального масштабирования.
  - Глубокая связь между интеллектуальными узлами периферии и облаком.

- ⚡ **Параллельное выполнение и управление ресурсами**
  - Интеллектуальное распределение нагрузки с учетом ресурсов для высокой доступности.
  - Многоузловые параллельные вычисления и декомпозиция задач.

- 🔍 **Структурированные запросы и векторный поиск**
  - Сложные условия, JOIN, агрегация и TTL на уровне таблицы.
  - Векторные поля, индексы и поиск ближайших соседей (ANN).
  - Совместное использование структурированных и векторных данных.

- 🔑 **Первичные ключи, индексация и эволюция схемы**
  - Встроенные алгоритмы: последовательный инкремент, метка времени, префикс даты и короткий код.
  - Уникальные, составные, векторные индексы и ограничения внешних ключей.
  - Автоматическое распознавание изменений схемы и миграция данных.

- 🛡️ **Транзакции, безопасность и восстановление**
  - Транзакции ACID, атомарные обновления выражений и каскадные внешние ключи.
  - Восстановление после сбоев, flush-персистентность и гарантия целостности.
  - Шифрование ChaCha20-Poly1305 и AES-256-GCM.

- 🔄 **Мультипространственность и рабочие процессы**
  - Изоляция данных через Пространства (Spaces) с глобальным доступом.
  - Слушатели запросов в реальном времени, многоуровневое кэширование и пагинация через курсоры.
  - Оптимально для многопользовательских и оффлайн-приложений.


<a id="installation"></a>
## Установка

> [!IMPORTANT]
> **Обновление с v2.x?** Прочтите [Руководство по обновлению v3.x](../UPGRADE_GUIDE_v3.md) для ознакомления с критическими шагами миграции.

Добавьте `tostore` в зависимости вашего `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Используйте последнюю версию
```

<a id="quick-start"></a>
## Быстрый старт

> [!TIP]
> **Поддерживает смешанное хранение структурированных и неструктурированных данных**
> Как выбрать способ хранения?
> 1. **Ключевые бизнес-данные**: рекомендуется [Определение схемы](#schema-definition). Подходит для сложных запросов, проверки ограничений, связей и повышенных требований к безопасности. Перенос логики целостности в движок заметно снижает затраты на разработку и сопровождение приложения.
> 2. **Динамические/разрозненные данные**: можно сразу использовать [хранилище ключ-значение (KV)](#quick-start) или определить в таблице поля `DataType.json`. Подходит для хранения конфигурации или разрозненных состояний, когда важны быстрый старт и максимальная гибкость.

### Структурированный табличный режим (Table)
Для CRUD-операций нужно заранее создать схему таблицы (см. [Определение схемы](#schema-definition)). Рекомендации по интеграции для разных сценариев:
- **Мобильные/Десктоп**: в [сценариях с частым запуском](#mobile-integration) рекомендуется передавать `schemas` при инициализации экземпляра.
- **Сервер/Агент**: в [сценариях непрерывной работы](#server-integration) рекомендуется динамически создавать таблицы через `createTables`.

```dart
// 1. Инициализация БД
final db = await ToStore.open();

// 2. Вставка данных
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Цепочка запросов (поддерживает =, !=, >, <, LIKE, IN и т.д.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. Обновление и удаление
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Прослушивание в реальном времени (UI обновится автоматически)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Обновленные пользователи: $users');
});
```

### Хранилище ключ-значение (KV)
Для сценариев без структурированных таблиц. Высокая производительность для настроек и состояний. Данные в разных Пространствах изолированы по умолчанию, но могут быть глобальными.

```dart
final db = await ToStore.open();

// Установка пары (поддерживает String, int, bool, double, Map, List и т.д.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// Получение данных
final theme = await db.getValue('theme'); // 'dark'

// Удаление
await db.removeValue('theme');

// Глобальные данные (общие между Пространствами)
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```


<a id="schema-definition"></a>
## Определение схемы
**Одно определение позволяет движку взять на себя сквозное автоматизированное управление и надолго снимает с приложения бремя сложной валидации.**

Примеры ниже для мобильных, серверных и агентных сценариев повторно используют `appSchemas`, определённый здесь.

### Обзор TableSchema

```dart
const userSchema = TableSchema(
  name: 'users', // Имя таблицы, обязательно
  tableId: 'users', // Уникальный ID, опционально; для точного распознавания переименования
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // Поле PK, по умолчанию 'id'
    type: PrimaryKeyType.sequential, // Тип автогенерации
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, 
      increment: 1, 
      useRandomIncrement: false, 
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username',
      type: DataType.text,
      nullable: false,
      minLength: 3,
      maxLength: 32,
      unique: true,
      fieldId: 'username', 
      comment: 'Логин', 
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0,
      maxValue: 150,
      defaultValue: 0,
      createIndex: true, // Создать индекс для ускорения
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // Автозаполнение текущим временем
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at',
      fields: ['status', 'created_at'],
      unique: false,
      type: IndexType.btree,
    ),
  ],
  foreignKeys: const [], // Внешние ключи (см. раздел ниже)
  isGlobal: false, // Глобальная таблица (доступна во всех Пространствах)
  ttlConfig: null, // TTL (автоудаление, см. раздел ниже)
);

const appSchemas = [userSchema];
```

`DataType` поддерживает `integer`, `bigInt`, `double`, `text`, `blob`, `boolean`, `datetime`, `array`, `json`, `vector`. 

### Ограничения и автопроверка

`FieldSchema` позволяет описывать правила валидации прямо в схеме:

- `nullable: false`: Запрет null.
- `minLength` / `maxLength`: Длина текста.
- `minValue` / `maxValue`: Диапазон чисел.
- `defaultValue`: Значения по умолчанию.
- `unique`: Уникальность (автосоздание уникального индекса).
- `createIndex`: Индекс для частого фильтра, сортировки или JOIN.

Ограничения проверяются при записи. `createIndex: true` и внешние ключи автоматически создают стандартные индексы.


<a id="mobile-integration"></a>
## Мобильная/Десктопная интеграция

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Android/iOS: разрешите путь для записи
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// Мультипространственность - изоляция данных пользователей
await db.switchSpace(spaceName: 'user_123');
```

### Сохранение логина и выход (Активное пространство)

Позволяет сохранять текущего пользователя после перезапуска.

- **Сохранение сессии**: При переключении пометьте пространство активным (`keepActive: true`).
- **Выход**: Закройте БД с `keepActiveSpace: false`.

```dart
// После логина: сохранить пользователя
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// При выходе: очистить активное пространство
await db.close(keepActiveSpace: false);
```


<a id="server-integration"></a>
## Серверная интеграция

```dart
final db = await ToStore.open();

// Создание или проверка структуры при старте
await db.createTables(appSchemas);

// Онлайн обновление схемы
final taskId = await db.updateSchema('users')
  .renameTable('users_new')
  .modifyField('username', minLength: 5, unique: true)
  .renameField('old', 'new')
  .removeField('deprecated')
  .addField('created_at', type: DataType.datetime)
  .removeIndex(fields: ['age']);
    
// Мониторинг прогресса
final status = await db.queryMigrationTaskStatus(taskId);
print('Прогресс миграции: ${status?.progressPercentage}%');


// Управление кэшем запросов
// Кэширование результата на 5 минут
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Очистка при изменении данных
await db.query('users').where('is_active', '=', true).clearQueryCache();
```


<a id="advanced-usage"></a>
## Продвинутое использование


<a id="vector-advanced"></a>
### Векторы и поиск ANN

```dart
await db.createTables([
  const TableSchema(
    name: 'embeddings',
    fields: [
      FieldSchema(name: 'document_title', type: DataType.text, nullable: false),
      FieldSchema(
        name: 'embedding',
        type: DataType.vector,
        nullable: false,
        vectorConfig: VectorFieldConfig(dimensions: 128, precision: VectorPrecision.float32),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'],
        type: IndexType.vector,
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,
          distanceMetric: VectorDistanceMetric.cosine,
          maxDegree: 32,
          efSearch: 64,
        ),
      ),
    ],
  ),
]);

final queryVector = VectorData.fromList(List.generate(128, (i) => i * 0.01));

// Поиск по векторам
final results = await db.vectorSearch(
  'embeddings', 
  fieldName: 'embedding', 
  queryVector: queryVector, 
  topK: 5,
);
```


<a id="ttl-config"></a>
### Табличный TTL (Автоудаление)

Для логов и событий: данные удаляются по истечении времени.

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
  ttlConfig: TableTtlConfig(ttlMs: 7 * 24 * 60 * 60 * 1000), // 7 дней
);
```


### Интеллектуальное сохранение (Upsert)
Обновление, если ключ существует, иначе вставка.

```dart
await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});
```


### JOIN и агрегация
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .limit(20);

// Агрегация
final count = await db.query('users').count();
final totalAge = await db.query('users').sum('age');
```


<a id="query-pagination"></a>
### Эффективная пагинация

- **Offset**: для небольших данных.
- **Cursor**: для массивных данных и бесконечного скролла (O(1)).

```dart
// Пагинация через курсор
final page1 = await db.query('users').orderByDesc('id').limit(20);

if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor);
}
```


<a id="foreign-keys"></a>
### Внешние ключи и каскад

```dart
foreignKeys: [
    ForeignKeySchema(
      name: 'fk_posts_user',
      fields: ['user_id'],
      referencedTable: 'users',
      referencedFields: ['id'],
      onDelete: ForeignKeyCascadeAction.cascade, // Удаление связанных постов
    ),
],
```


<a id="query-operators"></a>
### Операторы запросов

Поддерживаются: `=`, `!=`, `>`, `>=`, `<`, `<=`, `IN`, `NOT IN`, `BETWEEN`, `LIKE`, `IS NULL`, `IS NOT NULL`.

```dart
db.query('users').whereEqual('name', 'John').whereGreaterThan('age', 18).limit(20);
```


<a id="atomic-expressions"></a>
## Атомарные операции

Вычисления на уровне БД для предотвращения конфликтов параллелизма:

```dart
// balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', id);

// Условные операции (в Upsert)
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(Expr.isUpdate(), Expr.field('count') + 1, 1),
});
```


<a id="transactions"></a>
## Транзакции

Гарантируют атомарность: либо все успешно, либо откат всего.

```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {...});
  await db.update('users', {...});
});
```


<a id="database-maintenance"></a>
### Управление и обслуживание базы данных

Следующие API подходят для администрирования, диагностики и служебного обслуживания:

- **Обслуживание таблиц**
  `createTable(schema)`: Создает одну таблицу во время выполнения.
  `getTableSchema(tableName)`: Читает текущую активную схему таблицы.
  `getTableInfo(tableName)`: Возвращает статистику таблицы, включая число записей, индексов, размер файла, время создания и признак глобальности.
  `clear(tableName)`: Удаляет все данные, сохраняя схему, индексы и ограничения.
  `dropTable(tableName)`: Полностью удаляет таблицу вместе со схемой и данными.
- **Управление пространствами**
  `currentSpaceName`: Возвращает имя текущего активного пространства.
  `listSpaces()`: Перечисляет все пространства текущего экземпляра.
  `getSpaceInfo(useCache: true)`: Возвращает статистику текущего пространства; используйте `useCache: false`, чтобы принудительно получить самые свежие данные.
  `deleteSpace(spaceName)`: Удаляет пространство. Нельзя удалить пространство `default` и текущее активное пространство.
- **Метаданные экземпляра**
  `config`: Читает фактически примененный `DataStoreConfig`.
  `instancePath`: Возвращает итоговый каталог хранения экземпляра.
  `getVersion()` / `setVersion(version)`: Читает и записывает вашу бизнес-версию. Это значение не участвует во внутренней логике движка.
- **Служебные операции**
  `flush(flushStorage: true)`: Принудительно сбрасывает ожидающие записи на диск. При `true` дополнительно сбрасывает буферы нижележащего хранилища.
  `deleteDatabase()`: Удаляет текущий экземпляр базы данных и связанные файлы. Разрушающая операция.
- **Единая точка диагностики**
  `db.status.memory()`: Проверяет использование кэша и памяти.
  `db.status.space()`: Проверяет общее состояние текущего пространства.
  `db.status.table(tableName)`: Проверяет диагностическую информацию по конкретной таблице.
  `db.status.config()`: Проверяет снимок действующей конфигурации.
  `db.status.migration(taskId)`: Проверяет состояние задачи миграции схемы.

```dart
final spaces = await db.listSpaces();
final spaceInfo = await db.getSpaceInfo(useCache: false);
final tableInfo = await db.getTableInfo('users');
await db.flush();

print(spaces);
print(spaceInfo.toJson());
print(tableInfo?.toJson());
```


<a id="backup-restore"></a>
### Резервное копирование и восстановление

Подходит для локального импорта/экспорта, миграции пользовательских данных, отката и операционных снимков:

- `backup(compress: true, scope: ...)`: Создает резервную копию и возвращает путь к файлу. `compress: true` создает сжатый пакет, а `scope` определяет охват резервного копирования.
- `restore(backupPath, deleteAfterRestore: false, cleanupBeforeRestore: true)`: Восстанавливает данные из резервной копии. `cleanupBeforeRestore: true` предварительно очищает связанные данные, а `deleteAfterRestore: true` удаляет файл после успешного восстановления.
- `BackupScope.database`: Резервирует весь экземпляр базы данных, включая все пространства, глобальные таблицы и связанные метаданные.
- `BackupScope.currentSpace`: Резервирует только текущее пространство без глобальных таблиц.
- `BackupScope.currentSpaceWithGlobal`: Резервирует текущее пространство вместе с глобальными таблицами.

```dart
final backupPath = await db.backup(
  compress: true,
  scope: BackupScope.currentSpaceWithGlobal,
);

final restored = await db.restore(backupPath);
print(backupPath);
print(restored);
```


<a id="error-handling"></a>
### Обработка ошибок

ToStore использует единую модель ответа для операций с данными:

- `ResultType`: Стабильное перечисление статусов для ветвления логики.
- `result.code`: Числовой код, соответствующий `ResultType`.
- `result.message`: Понятное описание ошибки.
- `successKeys` / `failedKeys`: Списки первичных ключей для пакетных операций.

```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (!result.isSuccess) {
  switch (result.type) {
    case ResultType.notFound:
      print('Ресурс не найден: ${result.message}');
      break;
    case ResultType.notNullViolation:
    case ResultType.validationFailed:
      print('Ошибка валидации: ${result.message}');
      break;
    case ResultType.primaryKeyViolation:
    case ResultType.uniqueViolation:
      print('Конфликт ограничения: ${result.message}');
      break;
    case ResultType.foreignKeyViolation:
      print('Нарушение внешнего ключа: ${result.message}');
      break;
    case ResultType.resourceExhausted:
    case ResultType.timeout:
      print('Система занята, попробуйте позже: ${result.message}');
      break;
    case ResultType.ioError:
    case ResultType.dbError:
      print('Ошибка хранилища, добавьте запись в лог: ${result.message}');
      break;
    default:
      print('Тип: ${result.type}, Код: ${result.code}, Сообщение: ${result.message}');
  }
}
```

**Часто встречающиеся коды статуса**:
Успех имеет значение `0`; отрицательные значения означают ошибки.
- `ResultType.success` (`0`): Операция успешно выполнена.
- `ResultType.partialSuccess` (`1`): Пакетная операция выполнена частично.
- `ResultType.unknown` (`-1`): Неизвестная ошибка.
- `ResultType.uniqueViolation` (`-2`): Конфликт уникального индекса.
- `ResultType.primaryKeyViolation` (`-3`): Конфликт первичного ключа.
- `ResultType.foreignKeyViolation` (`-4`): Нарушение ограничения внешнего ключа.
- `ResultType.notNullViolation` (`-5`): Отсутствует обязательное поле или `null` недопустим.
- `ResultType.validationFailed` (`-6`): Не пройдена проверка длины, диапазона, формата или ограничения.
- `ResultType.notFound` (`-11`): Не найдена целевая таблица, пространство или ресурс.
- `ResultType.resourceExhausted` (`-15`): Недостаточно системных ресурсов; снизьте нагрузку или повторите позже.
- `ResultType.ioError` (`-90`): Ошибка ввода-вывода файловой системы или хранилища.
- `ResultType.dbError` (`-91`): Внутренняя ошибка базы данных.
- `ResultType.timeout` (`-92`): Превышено время ожидания.

### Обработка результата транзакции

```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
  });
});

if (txResult.isFailed) {
  print('Тип ошибки транзакции: ${txResult.error?.type}');
  print('Сообщение ошибки транзакции: ${txResult.error?.message}');
}
```

Типы ошибок транзакции:
- `TransactionErrorType.operationError`: Ошибка обычной операции внутри транзакции, например сбой валидации поля, некорректное состояние ресурса или другое бизнес-исключение.
- `TransactionErrorType.integrityViolation`: Конфликт целостности или ограничений, например первичный ключ, уникальный ключ, внешний ключ или not-null.
- `TransactionErrorType.timeout`: Транзакция превысила лимит времени.
- `TransactionErrorType.io`: Ошибка ввода-вывода в нижележащем хранилище или файловой системе.
- `TransactionErrorType.conflict`: Транзакция завершилась неудачно из-за конфликта.
- `TransactionErrorType.userAbort`: Прерывание по инициативе пользователя. Ручной abort через выброс исключения пока не поддерживается.
- `TransactionErrorType.unknown`: Любая другая неожиданная ошибка.


<a id="logging-diagnostics"></a>
### Колбэк логов и диагностика базы данных

ToStore может через `LogConfig.setConfig(...)` единообразно передавать в прикладной слой логи запуска, восстановления, автоматической миграции и конфликтов ограничений во время выполнения.

- `onLogHandler` получает все логи, отфильтрованные текущими `enableLog` и `logLevel`.
- Вызывайте `LogConfig.setConfig(...)` до инициализации, чтобы также получать логи инициализации и автоматической миграции.

```dart
  // Настройка параметров логов или колбэка
  LogConfig.setConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    publicLabel: 'my_app_db',
    onLogHandler: (message, type, label) {
      // В production warn/error можно отправлять на backend или в лог-платформу
      if (!debugMode && (type == LogType.warn || type == LogType.error)) {
        developer.log(message, name: label);
      }
    },
  );

  final db = await ToStore.open();
```


<a id="security-config"></a>
## Безопасность

> [!WARNING]
> **Ключи**: `encodingKey` можно менять (автомиграция). `encryptionKey` критичен (смена без миграции ведет к потере доступа к старым данным).

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      encryptionType: EncryptionType.chacha20Poly1305, 
      encodingKey: '...', 
      encryptionKey: '...',
      deviceBinding: false, 
    ),
  ),
);
```

### Шифрование полей (ToCrypto)
Для выборочного шифрования чувствительных данных без влияния на общую скорость БД.


<a id="performance"></a>
## Производительность

- 📱 **Пример**: Полный Flutter-проект в директории `example`.
- 🚀 **Release Mode**: В разы быстрее режима отладки.
- ✅ **Надежность**: Все функции покрыты тестами.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="Демо производительности ToStore" width="320" />
</p>

- **Демо производительности**: Плавная работа даже со 100М+ записей. ([Видео](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4))

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="Восстановление ToStore" width="320" />
</p>

- **Восстановление**: Авторемонт данных при внезапном отключении питания. ([Видео](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4))


Если ToStore помог вам, поставьте нам ⭐️! Это лучшая награда.

---

> **Рекомендация**: Используйте [ToApp Framework](https://github.com/tocreator/toapp) для фронтенда — полное решение для управления данными и состоянием.
