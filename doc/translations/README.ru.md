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
- **Начало работы**: [Почему ToStore](#why-tostore) | [Основные характеристики](#key-features) | [Руководство по установке](#installation) | [Режим КВ](#quick-start-kv) | [Режим таблицы](#quick-start-table) | [Режим памяти](#quick-start-memory)
- **Архитектура и модель**: [Определение схемы](#schema-definition) | [Распределенная архитектура](#distributed-architecture) | [Каскадирование внешних ключей](#foreign-keys) | [Мобильный/Настольный компьютер](#mobile-integration) | [Сервер/Агент](#server-integration) | [Алгоритмы первичного ключа](#primary-key-examples)
- **Расширенные запросы**: [Расширенные запросы (ПРИСОЕДИНИТЬСЯ)](#query-advanced) | [Агрегация и статистика](#aggregation-stats) | [Сложная логика (QueryCondition)](#query-condition) | [Реактивный запрос (смотреть)](#reactive-query) | [Запрос потоковой передачи](#streaming-query)
- **Дополнительно и производительность**: [Векторный поиск](#vector-advanced) | [TTL на уровне таблицы](#ttl-config) | [Эффективное разбиение на страницы](#query-pagination) | [Кэш запросов](#query-cache) | [Атомарные выражения](#atomic-expressions) | [Транзакции](#transactions)
- **Операции и безопасность**: [Администрирование](#database-maintenance) | [Конфигурация безопасности](#security-config) | [Обработка ошибок](#error-handling) | [Производительность и диагностика](#performance) | [Дополнительные ресурсы](#more-resources)

## <a id="why-tostore"></a>Почему стоит выбрать ToStore?

ToStore — это современный механизм обработки данных, разработанный для эпохи искусственного интеллекта и сценариев периферийного интеллекта. Он изначально поддерживает распределенные системы, мультимодальное объединение, реляционные структурированные данные, многомерные векторы и хранилище неструктурированных данных. Построенный на архитектуре узла с самомаршрутизацией и механизме, основанном на нейронных сетях, он обеспечивает узлам высокую автономность и эластичную горизонтальную масштабируемость, одновременно логически отделяя производительность от масштаба данных. Он включает в себя транзакции ACID, сложные реляционные запросы (JOIN и каскадные внешние ключи), TTL на уровне таблицы и агрегаты, а также несколько алгоритмов распределенных первичных ключей, атомарные выражения, распознавание изменений схемы, шифрование, многопространственную изоляцию данных, интеллектуальное планирование нагрузки с учетом ресурсов и самовосстановление после сбоев или сбоев.

Поскольку вычисления продолжают смещаться в сторону периферийного интеллекта, агенты, датчики и другие устройства больше не являются просто «дисплеями контента». Это интеллектуальные узлы, отвечающие за местное производство энергии, экологическую осведомленность, принятие решений в режиме реального времени и координацию потоков данных. Традиционные решения для баз данных ограничены своей базовой архитектурой и встроенными расширениями, что делает все более трудным удовлетворение требований к малой задержке и стабильности интеллектуальных приложений периферийного облака при записи с высоким уровнем параллелизма, больших наборах данных, векторном поиске и совместной генерации.

ToStore предоставляет периферийные распределенные возможности, достаточно мощные для больших наборов данных, сложной локальной генерации искусственного интеллекта и крупномасштабного перемещения данных. Глубокое интеллектуальное сотрудничество между периферийными и облачными узлами обеспечивает надежную основу данных для иммерсивной смешанной реальности, мультимодального взаимодействия, семантических векторов, пространственного моделирования и подобных сценариев.

## <a id="key-features"></a>Ключевые особенности

- 🌐 **Единая кроссплатформенная система обработки данных**
  - Единый API для мобильных, настольных, веб- и серверных сред.
  - Поддерживает реляционные структурированные данные, многомерные векторы и хранилище неструктурированных данных.
  - Создает конвейер данных от локального хранилища до совместной работы в периферийном облаке.

- 🧠 **Распределенная архитектура в стиле нейронной сети**
  - Архитектура узлов с самомаршрутизацией, которая отделяет физическую адресацию от масштабирования.
  - Высокоавтономные узлы совместно создают гибкую топологию данных.
  - Поддерживает взаимодействие узлов и эластичное горизонтальное масштабирование.
  - Глубокая взаимосвязь между периферийными интеллектуальными узлами и облаком.

- ⚡ **Параллельное выполнение и планирование ресурсов**
  - Интеллектуальное планирование нагрузки с учетом ресурсов и высокая доступность.
  - Многоузловое параллельное сотрудничество и декомпозиция задач.
  - Функция разделения времени обеспечивает плавность анимации пользовательского интерфейса даже при большой нагрузке.

- 🔍 **Структурированные запросы и векторный поиск**
  - Поддерживает сложные предикаты, JOIN, агрегаты и TTL на уровне таблицы.
  - Поддерживает векторные поля, векторные индексы и поиск ближайших соседей.
  - Структурированные и векторные данные могут работать вместе в одном движке.

- 🔑 **Первичные ключи, индексы и эволюция схемы**
  - Встроенные алгоритмы первичного ключа, включая последовательные стратегии, стратегии с временной меткой, с префиксом даты и короткие коды.
  - Поддерживает уникальные индексы, составные индексы, векторные индексы и ограничения внешнего ключа.
  - Автоматически обнаруживает изменения схемы и завершает работу по миграции.

- 🛡️ **Транзакции, безопасность и восстановление**
  - Обеспечивает транзакции ACID, обновления атомарных выражений и каскадные внешние ключи.
  - Поддерживает восстановление после сбоев, надежные фиксации и гарантии согласованности.
  - Поддерживает шифрование ChaCha20-Poly1305 и AES-256-GCM.

- 🔄 **Рабочие процессы с несколькими пространствами и данными**
  - Поддерживает изолированные пространства с дополнительными глобальными данными.
  - Поддерживает прослушиватели запросов в реальном времени, многоуровневое интеллектуальное кэширование и нумерацию страниц курсора.
  - Подходит для многопользовательских, локальных и автономных приложений для совместной работы.

## <a id="installation"></a>Установка

> [!IMPORTANT]
> **Обновление с версии 2.x?** Прочтите [Руководство по обновлению до версии 3.x](../UPGRADE_GUIDE_v3.md), чтобы узнать о важных этапах миграции и критических изменениях.

Добавьте `tostore` к вашему `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Please use the latest version
```

## <a id="quick-start"></a>Быстрый старт

> [!TIP]
> **Как выбрать режим хранения?**
> 1. [**Режим «ключ-значение» (KV)**](#quick-start-kv): лучше всего подходит для доступа к конфигурации, управления разрозненным состоянием или хранения данных JSON. Это самый быстрый способ начать работу.
> 2. [**Режим структурированной таблицы**](#quick-start-table): лучше всего подходит для основных бизнес-данных, требующих сложных запросов, проверки ограничений или крупномасштабного управления данными. Включив логику целостности в механизм, вы можете значительно сократить затраты на разработку и обслуживание на уровне приложений.
> 3. [**Режим памяти**](#quick-start-memory): лучше всего подходит для временных вычислений, модульных тестов или **сверхбыстрого глобального управления состоянием**. С помощью глобальных запросов и прослушивателей `watch` вы можете изменить взаимодействие приложения, не сохраняя кучу глобальных переменных.

### <a id="quick-start-kv"></a>Хранилище ключей и значений (KV)
Этот режим подходит, когда вам не нужны заранее определенные структурированные таблицы. Это простой, практичный и поддерживаемый высокопроизводительным механизмом хранения данных. **Эффективная архитектура индексирования обеспечивает высокую стабильность производительности запросов и высокую скорость реагирования даже на обычных мобильных устройствах при очень больших объемах данных.** Данные в разных пространствах естественным образом изолированы, но также поддерживается глобальное совместное использование.

```dart
// Initialize the database
final db = await ToStore.open();

// Set key-value pairs (supports String, int, bool, double, Map, List, Json, and more)
await db.setValue('user_profile', {
  'name': 'John',
  'age': 25,
});

// Switch space - isolate data for different users
await db.switchSpace(spaceName: 'user_123');

// Set a globally shared variable (isGlobal: true enables cross-space sharing, such as login state)
await db.setValue('current_user', 'John', isGlobal: true);

// Automatic expiration cleanup (TTL)
// Supports either a relative lifetime (ttl) or an absolute expiration time (expiresAt)
await db.setValue('temp_config', 'value', ttl: Duration(hours: 2));
await db.setValue('session_token', 'abc', expiresAt: DateTime(2026, 2, 31));

// Read data
final profile = await db.getValue('user_profile'); // Map<String, dynamic>

// Listen for real-time value changes (useful for refreshing local UI without extra state frameworks)
db.watchValue('current_user', isGlobal: true).listen((value) {
  print('Logged-in user changed to: $value');
});

// Listen to multiple keys at once
db.watchValues(['current_user', 'login_status']).listen((map) {
  print('Multiple config values were updated: $map');
});

// Remove data
await db.removeValue('current_user');
```

#### Пример автоматического обновления пользовательского интерфейса Flutter
Во Flutter `StreamBuilder` плюс `watchValue` дает вам очень краткий поток реактивного обновления:

```dart
StreamBuilder(
  // When listening to a global variable, remember to set isGlobal: true
  stream: db.watchValue('current_user', isGlobal: true),
  builder: (context, snapshot) {
    // snapshot.data is the latest value of 'current_user' in KV storage
    final user = snapshot.data ?? 'Not logged in';
    return Text('Current user: $user');
  },
)
```

### <a id="quick-start-table"></a>Режим структурированной таблицы
CRUD в структурированных таблицах требует предварительного создания схемы (см. [Определение схемы](#schema-definition)). Рекомендуемые подходы к интеграции для разных сценариев:
- **Мобильный/Настольный компьютер**: для [сценариев частого запуска](#mobile-integration) рекомендуется передавать `schemas` во время инициализации.
- **Сервер/Агент**: Для [длительных сценариев](#server-integration) рекомендуется создавать таблицы динамически через `createTables`.

```dart
// 1. Initialize the database
final db = await ToStore.open();

// 2. Insert data (prepare some base records)
final result = await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// Unified operation result model: DbResult
// It is recommended to always check isSuccess
if (result.isSuccess) {
  print('Insert succeeded, generated primary key ID: ${result.successKeys.first}');
} else {
  print('Insert failed: ${result.message}');
}

// Chained query (see [Query Operators](#query-operators); supports =, !=, >, <, LIKE, IN, and more)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// Update and delete
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// Real-time listening (see [Reactive Query](#reactive-query) for more details)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Users matching the condition have changed: $users');
});

// Pair with Flutter StreamBuilder for automatic local UI refresh
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

### <a id="quick-start-memory"></a>Режим памяти

Для таких сценариев, как кэширование, временные вычисления или рабочие нагрузки, не требующие сохранения на диске, вы можете инициализировать базу данных, находящуюся исключительно в памяти, через `ToStore.memory()`. В этом режиме все данные, включая схемы, индексы и пары «ключ-значение», полностью хранятся в памяти для максимальной производительности чтения/записи.

#### 💡 Также работает как управление глобальным состоянием
Вам не нужна куча глобальных переменных или тяжелая структура управления состоянием. Комбинируя режим памяти с `watchValue` или `watch()`, вы можете добиться полностью автоматического обновления пользовательского интерфейса виджетов и страниц. Он сохраняет мощные возможности поиска данных из базы данных, одновременно предоставляя вам возможности реагирования, выходящие далеко за рамки обычных переменных, что делает его идеальным для состояния входа в систему, оперативной конфигурации или глобальных счетчиков сообщений.

> [!CAUTION]
> **Примечание**. Данные, созданные в режиме чистой памяти, полностью теряются после закрытия или перезапуска приложения. Не используйте его для основных бизнес-данных.

```dart
// Initialize a pure in-memory database
final memDb = await ToStore.memory();

// Set a global state value (for example: unread message count)
await memDb.setValue('unread_count', 5, isGlobal: true);

// Listen from anywhere in the UI without passing parameters around
memDb.watchValue<int>('unread_count', isGlobal: true).listen((count) {
  print('UI automatically sensed the message count change: $count');
});

// All CRUD, KV access, and vector search run at in-memory speed
await memDb.insert('active_users', {'name': 'Marley', 'status': 'online'});
```


## <a id="schema-definition"></a>Определение схемы
**Определите один раз, и пусть механизм осуществляет сквозное автоматизированное управление, чтобы ваше приложение больше не требовало трудоемкого обслуживания проверки.**

В следующих примерах для мобильных устройств, на стороне сервера и агентов повторно используется `appSchemas`, определенный здесь.


### Обзор схемы таблицы

```dart
const userSchema = TableSchema(
  name: 'users', // Table name, required
  tableId: 'users', // Unique identifier of the table, optional
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // Primary key field name, defaults to id
    type: PrimaryKeyType.sequential, // Primary key auto-generation strategy
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, // Initial value for sequential IDs
      increment: 1, // Step size
      useRandomIncrement: false, // Whether to use random step sizes
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username', // Field name, required
      type: DataType.text, // Field data type, required
      nullable: false, // Whether null is allowed
      minLength: 3, // Minimum length
      maxLength: 32, // Maximum length
      unique: true, // Whether it must be unique
      fieldId: 'username', // Stable field identifier, optional, used to detect field renames
      comment: 'Login name', // Optional comment
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0, // Minimum numeric value
      maxValue: 150, // Maximum numeric value
      defaultValue: 0, // Static default value
      createIndex: true, // Shortcut for creating an index
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // Automatically fill with current time
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at', // Optional index name
      fields: ['status', 'created_at'], // Composite index fields
      unique: false, // Whether it is a unique index
      type: IndexType.btree, // Index type: btree/hash/bitmap/vector
    ),
  ],
  foreignKeys: const [], // Optional foreign-key constraints; see "Foreign Keys & Cascading"
  isGlobal: false, // Whether this is a global table; true means it can be shared across spaces
  ttlConfig: null, // Optional table-level TTL; see "Table-level TTL"
);

const appSchemas = [userSchema];
```

- **Общие сопоставления `DataType`**:
  | Тип | Соответствующий тип дротика | Описание |
  | :--- | :--- | :--- |
| `integer` | `int` | Стандартное целое число, подходящее для идентификаторов, счетчиков и подобных данных |
  | `bigInt` | `BigInt` / `String` | Большие целые числа; рекомендуется, когда числа превышают 18 цифр, чтобы избежать потери точности |
  | `double` | `double` | Число с плавающей запятой, подходящее для цен, координат и аналогичных данных |
  | `text` | `String` | Текстовая строка с дополнительными ограничениями длины |
  | `blob` | `Uint8List` | Необработанные двоичные данные |
  | `boolean` | `bool` | Логическое значение |
  | `datetime` | `DateTime` / `String` | Дата/время; хранится внутри как ISO8601 |
  | `array` | `List` | Тип списка или массива |
  | `json` | `Map<String, dynamic>` | JSON-объект, подходящий для динамических структурированных данных |
  | `vector` | `VectorData` / `List<num>` | Многомерные векторные данные для семантического поиска ИИ (встраивания) |

- **`PrimaryKeyType` стратегии автогенерации**:
  | Стратегия | Описание | Характеристики |
  | :--- | :--- | :--- |
| `none` | Нет автоматической генерации | Вы должны вручную указать первичный ключ во время вставки |
  | `sequential` | Последовательное приращение | Хорошо подходит для удобных для пользователя идентификаторов, но менее подходит для распределенной производительности |
  | `timestampBased` | На основе временных меток | Рекомендуется для распределенных сред |
  | `datePrefixed` | С префиксом даты | Полезно, когда читаемость даты важна для бизнеса |
  | `shortCode` | Первичный ключ короткого кода | Компактный и подходит для внешнего дисплея |

> По умолчанию все первичные ключи сохраняются как `text` (`String`).


### Ограничения и автоматическая проверка

Вы можете написать общие правила проверки непосредственно в `FieldSchema`, избегая дублирования логики в коде приложения:

- `nullable: false`: ненулевое ограничение
- `minLength` / `maxLength`: ограничения длины текста.
- `minValue` / `maxValue`: ограничения диапазона целых чисел или чисел с плавающей запятой.
- `defaultValue` / `defaultValueType`: статические значения по умолчанию и динамические значения по умолчанию.
- `unique`: уникальное ограничение
- `createIndex`: создание индексов для высокочастотной фильтрации, сортировки или связей.
- `fieldId` / `tableId`: помогает обнаружить переименование полей и таблиц во время миграции.

Кроме того, `unique: true` автоматически создает уникальный индекс из одного поля. `createIndex: true` и внешние ключи автоматически создают нормальные индексы с одним полем. Используйте `indexes`, когда вам нужны составные индексы, именованные индексы или векторные индексы.


### Выбор метода интеграции

- **Мобильный/Настольный компьютер**: лучше всего передавать `appSchemas` непосредственно в `ToStore.open(...)`.
- **Сервер/Агент**: лучше всего использовать при динамическом создании схем во время выполнения через `createTables(appSchemas)`.


## <a id="mobile-integration"></a>Интеграция для мобильных устройств, настольных компьютеров и других сценариев частого запуска

📱 **Пример**: [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// On Android/iOS, resolve the app's writable directory first, then pass dbPath explicitly
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

// Reuse the appSchemas defined above
final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// Multi-space architecture - isolate data for different users
await db.switchSpace(spaceName: 'user_123');
```

### Эволюция схемы

Во время `ToStore.open()` механизм автоматически обнаруживает структурные изменения в `schemas`, такие как добавление, удаление, переименование или изменение таблиц и полей, а также изменения индексов, а затем выполняет необходимую работу по миграции. Вам не нужно вручную поддерживать номера версий базы данных или писать сценарии миграции.


### Сохранение состояния входа и выхода из системы (активное пространство)

Мультипространство идеально подходит для **изоляции пользовательских данных**: одно пространство на каждого пользователя при включенном входе в систему. С помощью **Активного пространства** и параметров закрытия вы можете сохранить текущего пользователя при перезапуске приложения и обеспечить чистый выход из системы.

- **Сохранять состояние входа**. После переключения пользователя в собственное пространство отметьте это пространство как активное. Следующий запуск может войти в это пространство непосредственно при открытии экземпляра по умолчанию, без шага «сначала по умолчанию, затем переключение».
- **Выход**: когда пользователь выходит из системы, закройте базу данных с помощью `keepActiveSpace: false`. Следующий запуск не приведет автоматически к входу в пространство предыдущего пользователя.

```dart
// After login: switch to the user's space and mark it active
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Optional: strictly stay in default when needed (for example, login screen only)
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// On logout: close and clear the active space so the next launch starts from default
await db.close(keepActiveSpace: false);
```


## <a id="server-integration"></a>Интеграция на стороне сервера/агента (длительные сценарии)

🖥️ **Пример**: [server_quickstart.dart](../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Create table structures while the process is running
await db.createTables(appSchemas);

// Online schema updates
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
  .setPrimaryKeyConfig(                    // Change PK type; existing data must be empty or a warning will be issued
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );

// Monitor migration progress
final status = await db.queryMigrationTaskStatus(taskId);
print('Migration progress: ${status?.progressPercentage}%');


// Optional performance tuning for pure server workloads
// yieldDurationMs controls how often long-running work yields time slices.
// The default is tuned to 8ms to keep frontend UI animations smooth.
// In environments without UI, 50ms is recommended for higher throughput.
final dbServer = await ToStore.open(
  config: DataStoreConfig(yieldDurationMs: 50),
);
```


## <a id="advanced-usage"></a>Расширенное использование

ToStore предоставляет богатый набор расширенных возможностей для сложных бизнес-сценариев:


### <a id="vector-advanced"></a>Векторные поля, векторные индексы и векторный поиск

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
        type: DataType.vector, // Declare a vector field
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: 128, // Written and queried vectors must match this width
          precision: VectorPrecision.float32, // float32 usually balances precision and storage well
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'], // Field to index
        type: IndexType.vector, // Build a vector index
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh, // Built-in vector index type
          distanceMetric: VectorDistanceMetric.cosine, // Good for normalized embeddings
          maxDegree: 32, // More neighbors usually improve recall at higher memory cost
          efSearch: 64, // Higher recall but slower queries
          constructionEf: 128, // Higher-quality index but slower build time
        ),
      ),
    ],
  ),
]);

final queryVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.01)); // Must match dimensions

// Vector search
final results = await db.vectorSearch(
  'embeddings',
  fieldName: 'embedding',
  queryVector: queryVector,
  topK: 5, // Return the top 5 nearest records
  efSearch: 64, // Override the search expansion factor for this request
);

for (final r in results) {
  print('pk=${r.primaryKey}, score=${r.score}, distance=${r.distance}');
}
```

Примечания к параметрам:

- `dimensions`: должно соответствовать фактической ширине встраивания, которую вы пишете.
- `precision`: распространенные варианты включают `float64`, `float32` и `int8`; более высокая точность обычно требует большего объема памяти
- `distanceMetric`: `cosine` обычно используется для семантических вложений, `l2` соответствует евклидову расстоянию, а `innerProduct` подходит для поиска скалярного произведения
- `maxDegree`: верхняя граница числа соседей, сохраняемых для каждого узла в графе NGH; более высокие значения обычно улучшают отзыв за счет увеличения памяти и времени сборки.
- `efSearch`: ширина расширения во время поиска; его увеличение обычно улучшает запоминание, но увеличивает задержку
- `constructionEf`: ширина расширения во время сборки; его увеличение обычно улучшает качество индекса, но увеличивает время построения
- `topK`: количество возвращаемых результатов.

Примечания к результатам:

- `score`: нормализованный показатель сходства, обычно в диапазоне `0 ~ 1`; больше значит больше похоже
- `distance`: значение расстояния; для `l2` и `cosine` меньший размер обычно означает более похожий

### <a id="ttl-config"></a>TTL на уровне таблицы (автоматический срок действия на основе времени)

Для журналов, телеметрии, событий и других данных, срок действия которых истекает со временем, вы можете определить TTL на уровне таблицы через `ttlConfig`. Движок автоматически очистит просроченные записи в фоновом режиме:

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
    ttlMs: 7 * 24 * 60 * 60 * 1000, // Keep for 7 days
    // When sourceField is omitted, the engine creates the needed index automatically.
    // Optional custom sourceField requirements:
    // 1) type must be DataType.datetime
    // 2) nullable must be false
    // 3) defaultValueType must be DefaultValueType.currentTimestamp
    // sourceField: 'created_at',
  ),
);
```


### Интеллектуальное хранилище (Upsert)
ToStore решает, обновлять или вставлять, на основе первичного ключа или уникального ключа, включенного в `data`. `where` здесь не поддерживается; цель конфликта определяется самими данными.

```dart
// By primary key
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// By unique key (the record must contain all fields from a unique index plus required fields)
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// Batch upsert (supports atomic mode or partial-success mode)
// allowPartialErrors: true means some rows may fail while others still succeed
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### <a id="query-advanced"></a>Расширенные запросы

ToStore предоставляет API декларативных цепочек запросов с гибкой обработкой полей и сложными связями между несколькими таблицами.

#### 1. Выбор поля (`select`)
Метод `select` определяет, какие поля возвращаются. Если вы его не вызываете, все поля возвращаются по умолчанию.
- **Псевдонимы**: поддерживает синтаксис `field as alias` (без учета регистра) для переименования ключей в наборе результатов.
- **Поля с указанием таблицы**: при объединении нескольких таблиц `table.field` позволяет избежать конфликтов имен.
- **Смешивание агрегаций**: объекты `Agg` можно размещать непосредственно внутри списка `select`.

```dart
final results = await db.query('orders')
    .select([
      'orders.id',
      'users.name as customer_name',
      'orders.amount',
      Agg.count('id', alias: 'total_items')
    ])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

#### 2. Присоединяется (`join`)
Поддерживает стандарт `join` (внутреннее соединение), `leftJoin` и `rightJoin`.

#### 3. Умные соединения на основе внешнего ключа (рекомендуется)
Если `foreignKeys` правильно определены в `TableSchema`, вам не нужно писать условия соединения вручную. Механизм может разрешать ссылочные отношения и автоматически генерировать оптимальный путь JOIN.

- **`joinReferencedTable(tableName)`**: автоматически присоединяется к родительской таблице, на которую ссылается текущая таблица.
- **`joinReferencingTable(tableName)`**: автоматически объединяет дочерние таблицы, ссылающиеся на текущую таблицу.

```dart
// Assume posts defines a foreign key to users
final posts = await db.query('posts')
    .joinReferencedTable('users') // Automatically resolves to ON posts.user_id = users.id
    .select(['posts.title', 'users.username'])
    .limit(20);
```

---

### <a id="aggregation-stats"></a>Агрегация, группировка и статистика (Agg & GroupBy)

#### 1. Агрегация (`Agg` фабрика)
Агрегатные функции вычисляют статистику по набору данных. С помощью параметра `alias` вы можете настроить имена полей результатов.

| Метод | Цель | Пример |
| :--- | :--- | :--- |
| `Agg.count(field)` | Подсчет ненулевых записей | `Agg.count('id', alias: 'total')` |
| `Agg.sum(field)` | Сумма значений | `Agg.sum('amount', alias: 'total_price')` |
| `Agg.avg(field)` | Среднее значение | `Agg.avg('score', alias: 'average_score')` |
| `Agg.max(field)` | Максимальное значение | `Agg.max('age')` |
| `Agg.min(field)` | Минимальное значение | `Agg.min('price')` |

> [!TIP]
> **Два распространенных стиля агрегирования**
> 1. **Методы быстрого доступа (рекомендуются для отдельных метрик)**: вызов непосредственно в цепочке и немедленное получение обратно вычисленного значения.
> `num? totalAge = await db.query('users').sum('age');`
> 2. **Встроено в `select` (для нескольких метрик или группировки)**: передать объекты `Agg` в список `select`.
> `final stats = await db.query('orders').select(['status', Agg.sum('amount')]).groupBy(['status']);`

#### 2. Группировка и фильтрация (`groupBy` / `having`)
Используйте `groupBy` для категоризации записей, затем `having` для фильтрации агрегированных результатов, аналогично поведению SQL HAVING.

```dart
final stats = await db.query('orders')
    .select([
      'status',
      Agg.sum('amount', alias: 'sum_amount'),
      Agg.count('id', alias: 'order_count')
    ])
    .groupBy(['status'])
    // having accepts a QueryCondition used to filter aggregated results
    .having(QueryCondition().where(Agg.sum('amount'), '>', 5000))
    .limit(10);
```

#### 3. Вспомогательные методы запроса
- **`exists()` (высокая производительность)**: проверяет, совпадает ли какая-либо запись. В отличие от `count() > 0`, он выполняет короткое замыкание, как только будет найдено одно совпадение, что отлично подходит для очень больших наборов данных.
- **`count()`**: эффективно возвращает количество совпадающих записей.
- **`first()`**: удобный метод, эквивалентный `limit(1)` и возвращающий первую строку непосредственно как `Map`.
- **`distinct([fields])`**: дедупликация результатов. Если указаны `fields`, уникальность рассчитывается на основе этих полей.

```dart
// Efficient existence check
if (await db.query('users').whereEqual('email', 'test@test.com').exists()) {
  print('Email is already registered');
}

// Get a deduplicated city list
final cities = await db.query('users').distinct(['city']);
```

#### <a id="query-condition"></a>4. Сложная логика с `QueryCondition`
`QueryCondition` — это основной инструмент ToStore для вложенной логики и построения запросов в скобках. Когда простых связанных вызовов `where` недостаточно для таких выражений, как `(A AND B) OR (C AND D)`, можно использовать этот инструмент.

- **`condition(QueryCondition sub)`**: открывает вложенную группу `AND`.
- **`orCondition(QueryCondition sub)`**: открывает вложенную группу `OR`.
- **`or()`**: меняет следующий соединитель на `OR` (по умолчанию `AND`)

##### Пример 1: смешанные условия ИЛИ
Эквивалентный SQL: `WHERE is_active = true AND (role = 'admin' OR fans >= 1000)`

```dart
final subGroup = QueryCondition()
    .whereEqual('role', 'admin')
    .or()
    .whereGreaterThanOrEqualTo('fans', 1000);

final results = await db.query('users')
    .whereEqual('is_active', true)
    .condition(subGroup);
```

##### Пример 2: повторно используемые фрагменты условий
Вы можете один раз определить повторно используемые фрагменты бизнес-логики и объединить их в разных запросах:

```dart
final hotUser = QueryCondition().whereGreaterThan('fans', 5000);
final recentLogin = QueryCondition().whereGreaterThan('last_login', '2024-01-01');

final targetUsers = await db.query('users')
    .condition(hotUser)
    .condition(recentLogin);
```


#### <a id="streaming-query"></a>5. Потоковый запрос
Подходит для очень больших наборов данных, когда вы не хотите загружать все в память сразу. Результаты можно обрабатывать по мере их считывания.

```dart
db.streamQuery('users').listen((data) {
  print('Processing one record: $data');
});
```

#### <a id="reactive-query"></a>6. Реактивный запрос
Метод `watch()` позволяет отслеживать результаты запроса в режиме реального времени. Он возвращает `Stream` и автоматически повторно запускает запрос при каждом изменении соответствующих данных в целевой таблице.
- **Автоматическое устранение дребезга**: встроенное интеллектуальное устранение дребезжания позволяет избежать избыточных всплесков запросов.
- **Синхронизация пользовательского интерфейса**: естественно работает с Flutter `StreamBuilder` для списков, обновляемых в реальном времени.

```dart
// Simple listener
db.query('users').whereEqual('is_online', true).watch().listen((users) {
  print('Online user count changed: ${users.length}');
});

// Flutter StreamBuilder integration example
// Local UI refreshes automatically when data changes
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

### <a id="query-cache"></a>Кэширование результатов запроса вручную (необязательно)

> [!IMPORTANT]
> **ToStore уже включает в себя эффективный многоуровневый интеллектуальный внутренний кэш LRU.**
> **Рутинное управление кэшем вручную не рекомендуется.** Учитывайте это только в особых случаях:
> 1. Дорогое полное сканирование неиндексированных данных, которые редко меняются.
> 2. Постоянные требования к сверхнизкой задержке даже для негорячих запросов.

- `useQueryCache([Duration? expiry])`: включить кеш и, при необходимости, установить срок действия.
- `noQueryCache()`: явно отключить кеш для этого запроса.
- `clearQueryCache()`: вручную аннулировать кэш для этого шаблона запроса.

```dart
final results = await db.query('heavy_table')
    .where('non_indexed_field', '=', 'value')
    .useQueryCache(const Duration(minutes: 10)); // Manual acceleration for a heavy query only
```


### <a id="query-pagination"></a>Запрос и эффективная нумерация страниц

> [!TIP]
> **Для лучшей производительности всегда указывайте `limit`**: настоятельно рекомендуется явно указывать `limit` в каждом запросе. Если этот параметр опущен, механизм по умолчанию использует 1000 строк. Базовый механизм запросов работает быстро, но сериализация очень больших наборов результатов на уровне приложения все равно может привести к ненужным накладным расходам.

ToStore предоставляет два режима нумерации страниц, поэтому вы можете выбирать в зависимости от масштаба и требований к производительности:

#### 1. Базовая нумерация страниц (режим смещения)
Подходит для относительно небольших наборов данных или случаев, когда вам нужны точные переходы по страницам.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Skip the first 40 rows
    .limit(20); // Take 20 rows
```
> [!TIP]
> Когда `offset` становится очень большим, базе данных приходится сканировать и отбрасывать множество строк, поэтому производительность падает линейно. Для глубокой нумерации страниц выберите **Режим курсора**.

#### 2. Разбивка курсора на страницы (режим курсора)
Идеально подходит для больших наборов данных и бесконечной прокрутки. Используя `nextCursor`, механизм продолжает работу с текущей позиции и позволяет избежать дополнительных затрат на сканирование, связанных с глубокими смещениями.

> [!IMPORTANT]
> Для некоторых сложных запросов или сортировок по неиндексированным полям механизм может вернуться к полному сканированию и вернуть курсор `null`, что означает, что нумерация страниц в настоящее время не поддерживается для этого конкретного запроса.

```dart
// First page
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Use the returned cursor to fetch the next page
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Seek directly to the next position
}

// Likewise, prevCursor enables efficient backward paging
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Особенность | Режим смещения | Режим курсора |
| :--- | :--- | :--- |
| **Производительность запросов** | Деградирует по мере углубления страниц | Стабильно для глубокого подкачки |
| **Лучший вариант** | Меньшие наборы данных, точные переходы на страницы | **Огромные наборы данных, бесконечная прокрутка** |
| **Согласованность изменений** | Изменения данных могут привести к пропуску строк | Избегает дублирования и пропусков, вызванных изменениями данных |


### <a id="foreign-keys"></a>Внешние ключи и каскадирование

Внешние ключи гарантируют ссылочную целостность и позволяют настраивать каскадные обновления и удаления. Отношения проверяются при записи и обновлении. Если включены каскадные политики, связанные данные обновляются автоматически, что снижает согласованность кода приложения.

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
          fields: ['user_id'],              // Field in the current table
          referencedTable: 'users',         // Referenced table
          referencedFields: ['id'],         // Referenced field
          onDelete: ForeignKeyCascadeAction.cascade,  // Delete posts automatically when the user is deleted
          onUpdate: ForeignKeyCascadeAction.cascade,  // Cascade updates
        ),
    ],
  ),
]);
```


### <a id="query-operators"></a>Операторы запроса

Все условия `where(field, operator, value)` поддерживают следующие операторы (без учета регистра):

| Оператор | Описание | Пример / Производительность |
| :--- | :--- | :--- |
| `=` | Равно | `where('status', '=', 'val')` — **[Рекомендуется]** Поиск по индексу (Seek) |
| `!=`, `<>` | Не равно | `where('role', '!=', 'val')` — **[Осторожно]** Полное сканирование таблицы |
| `>` , `>=`, `<`, `<=` | Сравнение | `where('age', '>', 18)` — **[Рекомендуется]** Сканирование по индексу |
| `IN` | В списке | `where('id', 'IN', [...])` — **[Рекомендуется]** Поиск по индексу (Seek) |
| `NOT IN` | Не в списке | `where('status', 'NOT IN', [...])` — **[Осторожно]** Полное сканирование таблицы |
| `BETWEEN` | Диапазон | `where('age', 'BETWEEN', [18, 65])` — **[Рекомендуется]** Сканирование по индексу |
| `LIKE` | Соответствие шаблону (`%` = любые символы, `_` = один символ) | `where('name', 'LIKE', 'John%')` — **[Осторожно]** См. примечание ниже |
| `NOT LIKE` | Несоответствие шаблона | `where('email', 'NOT LIKE', '...')` — **[Осторожно]** Полное сканирование таблицы |
| `IS` | null | `where('deleted_at', 'IS', null)` — **[Рекомендуется]** Поиск по индексу (Seek) |
| `IS NOT` | Не null | `where('email', 'IS NOT', null)` — **[Осторожно]** Полное сканирование таблицы |

### Методы семантических запросов (рекомендуется)

Рекомендуется, чтобы избежать рукописных строк операторов и улучшить поддержку IDE.

#### 1. Сравнение
Используется для прямого числового или строкового сравнения.

```dart
db.query('users').whereEqual('username', 'John');           // Equal
db.query('users').whereNotEqual('role', 'guest');          // Not equal
db.query('users').whereGreaterThan('age', 18);             // Greater than
db.query('users').whereGreaterThanOrEqualTo('score', 60);  // Greater than or equal
db.query('users').whereLessThan('price', 100);             // Less than
db.query('users').whereLessThanOrEqualTo('quantity', 10);  // Less than or equal
db.query('users').whereTrue('is_active');                  // Is true
db.query('users').whereFalse('is_banned');                 // Is false
```

#### 2. Коллекция и ассортимент
Используется для проверки того, попадает ли поле в набор или диапазон.

```dart
db.query('users').whereIn('id', ['id1', 'id2']);                 // In list
db.query('users').whereNotIn('status', ['banned', 'pending']);   // Not in list
db.query('users').whereBetween('age', 18, 65);                   // In range (inclusive)
```

#### 3. Проверка нуля
Используется для проверки того, имеет ли поле значение.

```dart
db.query('users').whereNull('deleted_at');    // Is null
db.query('users').whereNotNull('email');      // Is not null
db.query('users').whereEmpty('nickname');     // Is null or empty string
db.query('users').whereNotEmpty('bio');       // Is not null and not empty
```

#### 4. Сопоставление с образцом
Поддерживает поиск по шаблонам SQL (`%` соответствует любому количеству символов, `_` соответствует одному символу).

```dart
db.query('users').whereLike('name', 'John%');                        // SQL-style pattern match
db.query('users').whereContains('bio', 'flutter');                   // Contains match (LIKE '%value%')
db.query('users').whereStartsWith('name', 'Admin');                  // Prefix match (LIKE 'value%')
db.query('users').whereEndsWith('email', '.com');                    // Suffix match (LIKE '%value')
db.query('users').whereContainsAny('tags', ['dart', 'flutter']);     // Fuzzy match against any item in the list
```

```dart
// Equivalent to: .where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```

> [!CAUTION]
> **Руководство по производительности запросов (Индекс против полного сканирования)**
>
> В сценариях с большими данными (миллионы строк и более) следуйте этим принципам, чтобы избежать задержек в основном потоке и тайм-аутов запросов:
>
> 1. **Оптимизировано для индекса - [Рекомендуется]**:
>    *   **Семантические методы**: `whereEqual`, `whereGreaterThan`, `whereLessThan`, `whereIn`, `whereBetween`, `whereNull`, `whereTrue`, `whereFalse` и **`whereStartsWith`** (соответствие префикса).
>    *   **Операнды**: `=`, `>`, `<`, `>=`, `<=`, `IN`, `BETWEEN`, `IS null`, `LIKE 'prefix%'`.
>    *   *Пояснение: Эти операции обеспечивают сверхбыстрое позиционирование с использованием индексов. Для `whereStartsWith` / `LIKE 'abc%'` индекс все еще может выполнять сканирование диапазона префиксов.*
>
> 2. **Риски полного сканирования - [Осторожно]**:
>    *   **Неточное соответствие**: `whereContains` (`LIKE '%val%'`), `whereEndsWith` (`LIKE '%val'`), `whereContainsAny`.
>    *   **Запросы отрицания**: `whereNotEqual` (`!=`, `<>`), `whereNotIn` (`NOT IN`), `whereNotNull` (`IS NOT null`/`whereNotEmpty`).
>    *   **Несоответствие шаблона**: `NOT LIKE`.
>    *   *Пояснение: Вышеуказанные операции обычно требуют обхода всей области хранения данных, даже если индекс создан. Хотя влияние минимально на мобильных устройствах или небольших наборах данных, в сценариях распределенного анализа или данных сверхбольшого размера их следует использовать с осторожностью, сочетая с другими условиями индекса (например, сужение диапазона по ID или времени) и предложением `limit`.*

## <a id="distributed-architecture"></a>Распределенная архитектура

```dart
// Configure distributed nodes
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,            // Enable distributed mode
      clusterId: 1,                       // Cluster ID
      centralServerUrl: 'https://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// Batch insert
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... efficient one-shot insertion of vector records
]);

// Stream and process large datasets
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Process each result incrementally to avoid loading everything at once
  print(record);
}
```

## <a id="primary-key-examples"></a>Примеры первичных ключей

ToStore предоставляет несколько распределенных алгоритмов первичного ключа для различных бизнес-сценариев:

- **Последовательный первичный ключ** (`PrimaryKeyType.sequential`): `238978991`
- **Первичный ключ на основе временной метки** (`PrimaryKeyType.timestampBased`): `1306866018836946`
- **Первичный ключ с префиксом даты** (`PrimaryKeyType.datePrefixed`): `20250530182215887631`
- **Краткий первичный ключ** (`PrimaryKeyType.shortCode`): `9eXrF0qeXZ`

```dart
// Sequential primary key configuration example
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,      // Starting value
        increment: 50,            // Step size
        useRandomIncrement: true, // Random step size to hide business volume
      ),
    ),
    fields: [/* field definitions */]
  ),
]);
```


## <a id="atomic-expressions"></a>Атомарные выражения

Система выражений обеспечивает типобезопасные обновления атомарных полей. Все вычисления выполняются атомарно на уровне базы данных, избегая одновременных конфликтов:

```dart
// Simple increment: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Complex calculation: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// Multi-layer parentheses: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) *
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Use functions: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Timestamp: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

**Условные выражения (например, различие обновления и вставки в upsert)**: используйте `Expr.isUpdate()` / `Expr.isInsert()` вместе с `Expr.ifElse` или `Expr.when`, чтобы выражение оценивалось только при обновлении или только при вставке.

```dart
// Upsert: increment on update, set to 1 on insert
// The insert branch can use a plain literal; expressions are only evaluated on the update path
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    1,
  ),
});

// Use Expr.when (single branch, otherwise null)
await db.upsert('orders', {
  'id': orderId,
  'updatedAt': Expr.when(Expr.isUpdate(), Expr.now(), otherwise: Expr.now()),
});
```

## <a id="transactions"></a>Транзакции

Транзакции обеспечивают атомарность нескольких операций: либо все завершается успешно, либо все откатывается, сохраняя согласованность данных.

**Характеристики транзакции**
- несколько операций либо все завершаются успешно, либо все откатываются
- незавершенная работа автоматически восстанавливается после сбоев
- успешные операции безопасно сохраняются

```dart
// Basic transaction - atomically commit multiple operations
final txResult = await db.transaction(() async {
  // Insert a user
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });

  // Atomic update using an expression
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');

  // If any operation fails, all changes are rolled back automatically
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
  throw Exception('Business logic error'); // Trigger rollback
}, rollbackOnError: true);
```


### <a id="database-maintenance"></a>Администрирование и обслуживание

Следующие API охватывают администрирование, диагностику и обслуживание базы данных для разработки плагинов, панелей администратора и сценариев эксплуатации:

- **Управление столом**
  - `createTable(schema)`: создать одну таблицу вручную; полезно для загрузки модулей или создания таблицы времени выполнения по требованию.
  - `getTableSchema(tableName)`: получить информацию об определенной схеме; полезно для автоматической проверки или создания модели пользовательского интерфейса.
  - `getTableInfo(tableName)`: получение статистики таблицы времени выполнения, включая количество записей, количество индексов, размер файла данных, время создания и является ли таблица глобальной.
  - `clear(tableName)`: очистить все данные таблицы, безопасно сохранив схему, индексы и ограничения внутренних/внешних ключей.
  - `dropTable(tableName)`: полностью уничтожить таблицу и ее схему; не обратимый
- **Управление пространством**
  - `currentSpaceName`: узнать текущее активное пространство в реальном времени.
  - `listSpaces()`: вывести список всех выделенных пространств в текущем экземпляре базы данных.
  - `getSpaceInfo(useCache: true)`: аудит текущего пространства; используйте `useCache: false` для обхода кеша и чтения состояния в реальном времени
  - `deleteSpace(spaceName)`: удалить определенное пространство и все его данные, кроме `default` и текущего активного пространства.
- **Обнаружение экземпляров**
  - `config`: проверьте окончательный эффективный снимок `DataStoreConfig` для экземпляра.
  - `instancePath`: точно найдите каталог физического хранилища.
  - `getVersion()` / `setVersion(version)`: бизнес-определенный контроль версий для принятия решений о миграции на уровне приложения (а не версии ядра).
- **Техническое обслуживание**
  - `flush(flushStorage: true)`: принудительно записать ожидающие данные на диск; если `flushStorage: true`, системе также будет предложено очистить буферы памяти нижнего уровня.
  - `deleteDatabase()`: удалить все физические файлы и метаданные для текущего экземпляра; используйте с осторожностью
- **Диагностика**
  - `db.status.memory()`: проверка коэффициентов попадания в кеш, использования индексных страниц и общего распределения кучи.
  - `db.status.space()` / `db.status.table(tableName)`: проверка актуальной статистики и информации о состоянии пространств и таблиц.
  - `db.status.config()`: проверить текущий снимок конфигурации среды выполнения.
  - `db.status.migration(taskId)`: отслеживайте ход асинхронной миграции в режиме реального времени.

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


### <a id="backup-restore"></a>Резервное копирование и восстановление

Особенно полезно для однопользовательского локального импорта/экспорта, большой автономной миграции данных и отката системы после сбоя:

- **Резервное копирование (`backup`)**
  - `compress`: включать ли сжатие; рекомендуется и включено по умолчанию
  - `scope`: управляет диапазоном резервного копирования.
    - `BackupScope.database`: резервное копирование **всего экземпляра базы данных**, включая все пробелы и глобальные таблицы.
    - `BackupScope.currentSpace`: резервное копирование только **текущего активного пространства**, исключая глобальные таблицы.
    - `BackupScope.currentSpaceWithGlobal`: резервное копирование **текущего пространства и связанных с ним глобальных таблиц**, что идеально подходит для однопользовательской или однопользовательской миграции.
- **Восстановить (`restore`)**
  - `backupPath`: физический путь к пакету резервной копии.
  - `cleanupBeforeRestore`: следует ли автоматически стирать связанные текущие данные перед восстановлением; `true` рекомендуется избегать смешанных логических состояний.
  - `deleteAfterRestore`: автоматическое удаление исходного файла резервной копии после успешного восстановления.

```dart
// Example: export the full data package for the current user
final backupPath = await db.backup(
  compress: true,
  scope: BackupScope.currentSpaceWithGlobal,
);

// Example: restore from a backup package and clean up the source file automatically
final restored = await db.restore(
  backupPath,
  cleanupBeforeRestore: true,
  deleteAfterRestore: true,
);
```

### <a id="error-handling"></a>Коды состояния и обработка ошибок


ToStore использует унифицированную модель ответа для операций с данными:

- `ResultType`: унифицированное перечисление статуса, используемое для логики ветвления.
- `result.code`: стабильный числовой код, соответствующий `ResultType`
- `result.message`: читаемое сообщение с описанием текущей ошибки.
- `successKeys` / `failedKeys`: списки успешных и неудачных первичных ключей в массовых операциях.


```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (!result.isSuccess) {
  switch (result.type) {
    case ResultType.notFound:
      print('Target resource does not exist: ${result.message}');
      break;
    case ResultType.notNullViolation:
    case ResultType.validationFailed:
      print('Data validation failed: ${result.message}');
      break;
    case ResultType.primaryKeyViolation:
    case ResultType.uniqueViolation:
      print('Unique constraint conflict: ${result.message}');
      break;
    case ResultType.foreignKeyViolation:
      print('Foreign key constraint failed: ${result.message}');
      break;
    case ResultType.resourceExhausted:
    case ResultType.timeout:
      print('System is busy. Please retry later: ${result.message}');
      break;
    case ResultType.ioError:
    case ResultType.dbError:
      print('Underlying storage error. Please record the logs: ${result.message}');
      break;
    default:
      print('Error type: ${result.type}, code: ${result.code}, message: ${result.message}');
  }
}
```

Общие примеры кодов состояния:
Успех возвращается `0`; отрицательные числа указывают на ошибки.
- `ResultType.success` (`0`): операция выполнена успешно.
- `ResultType.partialSuccess` (`1`): массовая операция частично успешна
- `ResultType.unknown` (`-1`): неизвестная ошибка
- `ResultType.uniqueViolation` (`-2`): конфликт уникальных индексов.
- `ResultType.primaryKeyViolation` (`-3`): конфликт первичного ключа.
- `ResultType.foreignKeyViolation` (`-4`): ссылка на внешний ключ не удовлетворяет ограничениям.
- `ResultType.notNullViolation` (`-5`): обязательное поле отсутствует или было передано запрещенное поле `null`.
- `ResultType.validationFailed` (`-6`): длина, диапазон, формат или другая проверка не удалась.
- `ResultType.notFound` (`-11`): целевая таблица, пространство или ресурс не существует.
- `ResultType.resourceExhausted` (`-15`): недостаточно системных ресурсов; уменьшите нагрузку или повторите попытку
- `ResultType.dbError` (`-91`): ошибка базы данных.
- `ResultType.ioError` (`-90`): ошибка файловой системы.
- `ResultType.timeout` (`-92`): тайм-аут

### Обработка результатов транзакции
```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
  });
});

// txResult.isFailed: transaction failed; txResult.isSuccess: transaction succeeded
if (txResult.isFailed) {
  print('Transaction error type: ${txResult.error?.type}');
  print('Transaction error message: ${txResult.error?.message}');
}
```

Типы ошибок транзакции:
- `TransactionErrorType.operationError`: сбой обычной операции внутри транзакции, например сбой проверки поля, неверное состояние ресурса или другая ошибка бизнес-уровня.
- `TransactionErrorType.integrityViolation`: конфликт целостности или ограничений, например, первичный ключ, уникальный ключ, внешний ключ или ненулевой сбой.
- `TransactionErrorType.timeout`: тайм-аут
- `TransactionErrorType.io`: базовая ошибка ввода-вывода хранилища или файловой системы.
- `TransactionErrorType.conflict`: конфликт привел к сбою транзакции.
- `TransactionErrorType.userAbort`: прерывание по инициативе пользователя (ручное прерывание на основе выдачи в настоящее время не поддерживается)
- `TransactionErrorType.unknown`: любая другая ошибка


### <a id="logging-diagnostics"></a>Обратный вызов журнала и диагностика базы данных

ToStore может направлять журналы запуска, восстановления, автоматической миграции и конфликтов ограничений времени выполнения обратно на бизнес-уровень через `LogConfig.setConfig(...)`.

- `onLogHandler` получает все журналы, прошедшие текущие фильтры `enableLog` и `logLevel`.
- Вызовите `LogConfig.setConfig(...)` перед инициализацией, чтобы также были записаны журналы, созданные во время инициализации и автоматической миграции.

```dart
  // Configure log parameters or callback
  LogConfig.setConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    publicLabel: 'my_app_db',
    onLogHandler: (message, type, label) {
      // In production, warn/error can be reported to your backend or logging platform
      if (!debugMode && (type == LogType.warn || type == LogType.error)) {
        developer.log(message, name: label);
      }
    },
  );

  final db = await ToStore.open();
```


## <a id="security-config"></a>Конфигурация безопасности

> [!WARNING]
> **Управление ключами**: **`encodingKey`** можно свободно менять, и механизм автоматически перенесет данные, поэтому данные можно будет восстановить. **`encryptionKey`** нельзя менять случайно. После изменения старые данные невозможно расшифровать, если вы явно не перенесете их. Никогда не кодируйте чувствительные клавиши жестко; рекомендуется получать их из безопасного сервиса.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Supported encryption algorithms: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305,

      // Encoding key (can be changed; data will be migrated automatically)
      encodingKey: 'Your-32-Byte-Long-Encoding-Key...',

      // Encryption key for critical data (do not change casually unless you are migrating data)
      encryptionKey: 'Your-Secure-Encryption-Key...',

      // Device binding (path-based binding)
      // When enabled, the key is deeply bound to the database path and device characteristics.
      // Data cannot be decrypted when moved to a different physical path.
      // Advantage: better protection if database files are copied directly.
      // Drawback: if the install path or device characteristics change, data may become unrecoverable.
      deviceBinding: false,
    ),
    // Enable crash recovery logging (Write-Ahead Logging), enabled by default
    enableJournal: true,
    // Whether transactions force data to disk on commit; set false to reduce sync overhead
    persistRecoveryOnCommit: true,
  ),
);
```

### Шифрование уровня значений (ToCrypto)

Полное шифрование базы данных защищает все данные таблиц и индексов, но может повлиять на общую производительность. Если вам нужно защитить только несколько конфиденциальных значений, используйте вместо этого **ToCrypto**. Он отделен от базы данных, не требует экземпляра `db` и позволяет вашему приложению кодировать/декодировать значения перед записью или после чтения. Выходные данные — это Base64, который естественным образом помещается в столбцы JSON или TEXT.

- **`key`** (обязательно): `String` или `Uint8List`. Если он не 32-байтовый, для получения 32-байтового ключа используется SHA-256.
- **`type`** (необязательно): тип шифрования `ToCryptoType`, например `ToCryptoType.chacha20Poly1305` или `ToCryptoType.aes256Gcm`. По умолчанию `ToCryptoType.chacha20Poly1305`.
- **`aad`** (необязательно): дополнительные аутентифицированные данные типа `Uint8List`. Если они предоставлены во время кодирования, те же самые байты должны быть предоставлены и во время декодирования.

```dart
const key = 'my-secret-key';
// Encode: plaintext -> Base64 ciphertext (can be stored in DB or JSON)
final cipher = ToCrypto.encode('sensitive data', key: key);
// Decode when reading
final plain = ToCrypto.decode(cipher, key: key);

// Optional: bind contextual data with aad (must match during decode)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```


## <a id="advanced-config"></a>Объяснение расширенной конфигурации (DataStoreConfig)

> [!TIP]
> **Нулевая конфигурация**
> ToStore автоматически определяет платформу, характеристики производительности, доступную память и поведение ввода-вывода для оптимизации таких параметров, как параллелизм, размер сегмента и бюджет кэша. **В 99% распространенных бизнес-сценариев вам не нужно настраивать `DataStoreConfig` вручную.** Значения по умолчанию уже обеспечивают отличную производительность для текущей платформы.


| Параметр | По умолчанию | Цель и рекомендации |
| :--- | :--- | :--- |
| **`yieldDurationMs`** | **8 мс** | **Основная рекомендация.** Временной интервал, используемый при выполнении длительных задач. `8ms` хорошо сочетается с рендерингом со скоростью 120/60 кадров в секунду и помогает обеспечить плавность пользовательского интерфейса во время больших запросов или миграций. |
| **`maxQueryOffset`** | **10000** | **Защита запросов.** Когда `offset` превышает этот порог, возникает ошибка. Это предотвращает патологический ввод-вывод из-за глубокого смещения пагинации. |
| **`defaultQueryLimit`** | **1000** | **Защита ресурсов.** Применяется, когда в запросе не указан `limit`, что предотвращает случайную загрузку огромных наборов результатов и потенциальные проблемы OOM. |
| **`cacheMemoryBudgetMB`** | (авто) | **Детальное управление памятью.** Общий бюджет кэш-памяти. Движок использует его для автоматического восстановления LRU. |
| **`enableJournal`** | **правда** | **Самовосстановление после сбоев.** Если этот параметр включен, двигатель может автоматически восстанавливаться после сбоев или сбоев питания. |
| **`persistRecoveryOnCommit`** | **правда** | **Надежная гарантия долговечности.** Если этот параметр равен true, зафиксированные транзакции синхронизируются с физическим хранилищем. Если установлено значение false, очистка выполняется асинхронно в фоновом режиме для повышения скорости с небольшим риском потери небольшого количества данных в случае экстремальных сбоев. |
| **`ttlCleanupIntervalMs`** | **300000** | **Глобальный опрос TTL.** Фоновый интервал сканирования просроченных данных, когда механизм не простаивает. Более низкие значения удаляют устаревшие данные быстрее, но требуют больше накладных расходов. |
| **`maxConcurrency`** | (авто) | **Управление параллелизмом вычислений.** Устанавливает максимальное количество параллельных рабочих процессов для интенсивных задач, таких как векторные вычисления и шифрование/дешифрование. Обычно лучше всего делать это автоматически. |

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    yieldDurationMs: 8, // Excellent for frontend UI smoothness; for servers, 50ms is often better
    defaultQueryLimit: 50, // Force a maximum result-set size
    enableJournal: true, // Ensure crash self-healing
  ),
);
```

---

## <a id="performance"></a>Производительность и опыт

### Тесты

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore Basic Performance Demo" width="320" />
</p>

- **Базовая демонстрация производительности** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4" target="_blank" rel="noopener">basic-demo.mp4</a>): предварительный просмотр GIF может отображать не все. Пожалуйста, откройте видео для полной демонстрации. Даже на обычных мобильных устройствах запуск, подкачка и извлечение данных остаются стабильными и плавными, даже если набор данных превышает 100 миллионов записей.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore Disaster Recovery Stress Test" width="320" />
</p>

- **Стресс-тест аварийного восстановления** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4" target="_blank" rel="noopener">disaster-recovery.mp4</a>): во время высокочастотной записи процесс намеренно прерывается снова и снова для имитации сбоев и сбоев питания. ToStore способен быстро восстановиться.


### Советы по опыту

- 📱 **Пример проекта**: каталог `example` содержит полное приложение Flutter.
- 🚀 **Производственные сборки**: упакуйте и протестируйте в режиме выпуска; производительность релиза выходит далеко за рамки режима отладки
- ✅ **Стандартные тесты**: основные возможности проверяются стандартизированными тестами.


Если ToStore вам поможет, пожалуйста, поставьте нам ⭐️
Это один из лучших способов поддержать проект. Большое спасибо.


> **Рекомендация**. Для разработки внешнего приложения рассмотрите [ToApp framework](https://github.com/tocreator/toapp), который предоставляет комплексное решение, которое автоматизирует и унифицирует запросы данных, загрузку, хранение, кэширование и представление.


## <a id="more-resources"></a>Дополнительные ресурсы

- 📖 **Документация**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Отчеты о проблемах**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Техническое обсуждение**: [Обсуждения GitHub](https://github.com/tocreator/tostore/discussions)



