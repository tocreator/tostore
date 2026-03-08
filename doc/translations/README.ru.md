<p align="center">
  <img src="../resource/logo-tostore.svg" width="400" alt="Tostore">
</p>

<p align="center">
  <img src="../resource/divider.svg" width="600">
</p>

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




## Почему выбирают Tostore?

Tostore — это единственный в экосистеме Dart/Flutter высокопроизводительный движок хранения для распределенных векторных баз данных. Используя архитектуру, подобную нейронным сетям, он обеспечивает интеллектуальное взаимодействие и совместную работу между узлами, поддерживая неограниченное горизонтальное масштабирование. Он выстраивает гибкую топологическую сеть данных и предоставляет точную идентификацию изменений схемы, защиту шифрованием и изоляцию данных в нескольких пространствах (Multi-Space). Tostore в полной мере использует многоядерные процессоры для экстремально параллельной обработки и нативно поддерживает кроссплатформенное взаимодействие от мобильных периферийных (Edge) устройств до облака. Благодаря различным алгоритмам распределенных первичных ключей, он предоставляет мощный фундамент данных для таких сценариев, как иммерсивная виртуальная реальность, мультимодальное взаимодействие, пространственные вычисления, генеративный ИИ и семантическое моделирование векторного пространства.

По мере того как генеративный ИИ и пространственные вычисления смещают центр тяжести вычислений к периферии, терминальные устройства превращаются из простых дисплеев контента в ядра локальной генерации, восприятия окружающей среды и принятия решений в реальном времени. Традиционные встроенные базы данных с одним файлом ограничены своей архитектурой и часто с трудом справляются с требованиями интеллектуальных приложений к мгновенному отклику при высокопараллельной записи, массовом поиске векторов и совместной облачно-периферийной генерации. Tostore рожден для периферийных устройств, наделяя их возможностями распределенного хранения, достаточными для поддержки сложных локальных генераций ИИ и крупномасштабного потока данных, реализуя подлинное глубокое взаимодействие между облаком и периферией.

**Устойчивость к сбоям питания и крахам**: Даже в случае неожиданного отключения питания или краха приложения данные могут быть автоматически восстановлены, что означает реальную нулевую потерю. Как только операция с данными подтверждена, данные уже надежно сохранены, что исключает риск их потери.

**Преодоление пределов производительности**: Тесты показывают, что даже при 100+ миллионах записей типичный смартфон сохраняет постоянную скорость поиска независимо от объёма данных, обеспечивая опыт работы, намного превосходящий возможности традиционных баз данных.




...... От кончиков пальцев до облачных приложений, Tostore помогает вам высвободить вычислительную мощность данных и расширить возможности будущего ......




## Особенности Tostore

- 🌐 **Бесшовная поддержка всех платформ**
  - Запуск одного и того же кода на всех платформах: от мобильных приложений до облачных серверов.
  - Интеллектуальная адаптация к различным серверным хранилищам платформ (IndexedDB, файловая система и т. д.).
  - Унифицированный API-интерфейс для беспроблемной кроссплатформенной синхронизации данных.
  - Бесшовный поток данных от периферийных устройств к облачным серверам.
  - Локальные векторные вычисления на периферийных устройствах, снижающие задержки сети и зависимость от облака.

- 🧠 **Распределенная архитектура, подобная нейронной сети**
  - Топология взаимосвязанных узлов для эффективной организации потока данных.
  - Высокопроизводительный механизм секционирования данных для истинно распределенной обработки.
  - Интеллектуальное динамическое распределение рабочей нагрузки для максимального использования ресурсов.
  - Неограниченное горизонтальное масштабирование узлов для легкого построения сложных сетей данных.

- ⚡ **Максимальные возможности параллельной обработки**
  - Истинное параллельное чтение/запись с использованием Isolates на полной скорости на многоядерных процессорах.
  - Интеллектуальное планирование ресурсов автоматически балансирует нагрузку для максимизации производительности многоядерных систем.
  - Совместная работа многоузловой вычислительной сети удваивает эффективность обработки задач.
  - Фреймворк планирования, учитывающий ресурсы, автоматически оптимизирует планы выполнения во избежание конфликтов ресурсов.
  - Интерфейс потоковых запросов легко справляется с огромными наборами данных.

- 🔑 **Разнообразные алгоритмы распределенных первичных ключей**
  - Алгоритм последовательного увеличения — свободная настройка случайных шагов для скрытия масштабов бизнеса.
  - Алгоритм на основе меток времени (Timestamp) — лучший выбор для сценариев с высокой степенью параллелизма.
  - Алгоритм с префиксом даты — идеальная поддержка отображения данных во временных диапазонах.
  - Алгоритм короткого кода — генерация коротких, легко читаемых уникальных идентификаторов.

- 🔄 **Интеллектуальная миграция схем и целостность данных**
  - Точная идентификация переименованных полей таблиц с нулевой потерей данных.
  - Автоматическое обнаружение изменений схемы и миграция данных за миллисекунды.
  - Обновления без простоев, незаметно для бизнес-процессов.
  - Стратегии безопасной миграции для сложных структурных изменений.
  - Автоматическая проверка ограничений внешнего ключа с поддержкой каскадных операций для обеспечения ссылочной целостности.

- 🛡️ **Безопасность и долговечность корпоративного уровня**
  - Механизм двойной защиты: запись изменений данных в реальном времени гарантирует, что ничего не будет потеряно.
  - Автоматическое восстановление после краха: возобновление незавершенных операций после сбоя питания или краха.
  - Гарантированная согласованность данных: операции либо выполняются полностью успешно, либо полностью откатываются (Rollback).
  - Атомарные вычислительные обновления: система выражений поддерживает сложные вычисления, выполняемые атомарно во избежание конфликтов параллелизма.
  - Мгновенная безопасная фиксация: данные надежно сохраняются сразу после успешного выполнения операции.
  - Высокопрочное шифрование ChaCha20Poly1305 защищает конфиденциальные данные.
  - Сквозное (end-to-end) шифрование для безопасности на протяжении всего пути хранения и передачи.

- 🚀 **Интеллектуальное кэширование и производительность поиска**
  - Многоуровневый механизм интеллектуального кэширования для молниеносного поиска данных.
  - Стратегии кэширования, глубоко интегрированные с движком хранения.
  - Адаптивное масштабирование сохраняет стабильную производительность при росте объемов данных.
  - Уведомления об изменениях данных в реальном времени с автоматическим обновлением результатов запросов.

- 🔄 **Интеллектуальный рабочий процесс данных**
  - Многопространственная архитектура обеспечивает изоляцию данных наряду с глобальным обменом.
  - Интеллектуальное распределение рабочей нагрузки между вычислительными узлами.
  - Обеспечивает надежную основу для крупномасштабного обучения и анализа данных.


## Установка

> [!IMPORTANT]
> **Обновляетесь с v2.x?** Пожалуйста, прочтите [Руководство по обновлению до v3.0](../UPGRADE_GUIDE_v3.md) для ознакомления с критическими шагами миграции и важными изменениями.

Добавьте зависимость `tostore` в ваш `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Используйте последнюю версию
```

## Быстрый старт

> [!IMPORTANT]
> **Определение схемы таблицы — это первый шаг**: Прежде чем выполнять CRUD-операции, необходимо определить схему таблицы. Конкретный метод определения зависит от вашего сценария:
> - **Мобильные/Десктопные приложения**: Рекомендуется [Статическое определение](#интеграция-для-сценариев-с-частым-запуском).
> - **Серверная сторона**: Рекомендуется [Динамическое создание](#серверная-интеграция).

```dart
// 1. Инициализация базы данных
final db = await ToStore.open();

// 2. Вставка данных
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Цепочечные запросы ([операторы запросов](#операторы-запросов), поддержка =, !=, >, <, LIKE, IN и др.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(10);

// 4. Обновление и удаление
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Прослушивание в реальном времени (UI обновляется автоматически)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Соответствующие пользователи обновлены: $users');
});
```

### Хранилище «ключ-значение» (KV)
Подходит для сценариев, не требующих определения структурированных таблиц. Это простое и практичное встроенное высокопроизводительное KV-хранилище для конфигураций, состояний и других разрозненных данных. Данные в разных пространствах (Space) изолированы по умолчанию, но могут быть настроены для глобального доступа.

```dart
// 1. Установка пар «ключ-значение» (Поддержка String, int, bool, double, Map, List и др.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 2. Получение данных
final theme = await db.getValue('theme'); // 'dark'

// 3. Удаление данных
await db.removeValue('theme');

// 4. Глобальные «ключ-значение» (Доступны во всех Space)
// По умолчанию данные KV привязаны к пространству. Используйте isGlobal: true для общего доступа.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



## Интеграция для сценариев с частым запуском

📱 **Пример**: [mobile_quickstart.dart](example/lib/mobile_quickstart.dart)

```dart
// Определение схемы, подходящее для мобильных и десктопных приложений с частыми запусками.
// Точно идентифицирует изменения схемы и автоматически мигрирует данные.
final db = await ToStore.open(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // Глобальная таблица, доступная во всех пространствах
            fields: [],
    ),
    const TableSchema(
      name: 'users', // Имя таблицы
      tableId: "users",  // Уникальный ID для 100% распознавания переименований
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // Имя первичного ключа
      ),
      fields: [        // Определения полей (без первичного ключа)
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true, // Автоматически создает уникальный индекс
          fieldId: 'username',  // Уникальный ID поля
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true // Автоматически создает уникальный индекс
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime,
          createIndex: true // Автоматически создает индекс (idx_last_login)
        ),
      ],
      // Пример составного индекса
      indexes: [
        IndexSchema(fields: ['username', 'last_login']),
      ],
    ),
    // Пример ограничения внешнего ключа
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
          fields: ['user_id'],              // Поля текущей таблицы
          referencedTable: 'users',         // Ссылочная таблица
          referencedFields: ['id'],         // Ссылочные поля
          onDelete: ForeignKeyCascadeAction.cascade,  // Каскадное удаление
          onUpdate: ForeignKeyCascadeAction.cascade,  // Каскадное обновление
        ),
      ],
    ),
  ],
);

// Многопространственная архитектура — идеальная изоляция данных пользователей
await db.switchSpace(spaceName: 'user_123');
```

### Сохранение состояния входа и выход (активное пространство)

Мульти-пространство удобно для **данных по пользователям**: одно пространство на пользователя и переключение при входе. С **активным пространством** и опцией **close** можно сохранять текущего пользователя между перезапусками и поддерживать выход.

- **Сохранение состояния входа**: Когда пользователь переключился в своё пространство, сохраните его как активное, чтобы при следующем открытии с default сразу попасть в это пространство (не нужно «открыть default и потом переключиться»).
- **Выход**: При выходе закройте базу с `keepActiveSpace: false`, чтобы при следующем открытии не попадать автоматически в пространство предыдущего пользователя.

```dart

// После входа: переключиться в пространство этого пользователя и запомнить на следующее открытие (сохранение входа)
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// По желанию: открывать строго в default (например, только экран входа) — не использовать сохранённое активное пространство
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// При выходе: закрыть и сбросить активное пространство, чтобы следующее открытие использовало default
await db.close(keepActiveSpace: false);
```

## Серверная интеграция

🖥️ **Пример**: [server_quickstart.dart](example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Массовое создание схем во время выполнения
await db.createTables([
  // Таблица хранения 3D пространственных векторов признаков
  const TableSchema(
    name: 'spatial_embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,   // PK на основе меток времени для высокой нагрузки
    ),
    fields: [
      FieldSchema(
        name: 'video_name',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'spatial_features',
        type: DataType.vector,                // Тип векторного хранилища
        vectorConfig: VectorFieldConfig(
          dimensions: 1024,                   // Высокоразмерный вектор
          precision: VectorPrecision.float32, 
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['video_name'],
        unique: true,
      ),
      IndexSchema(
        type: IndexType.vector,              // Векторный индекс
        fields: ['spatial_features'],
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,   // Алгоритм NGH для эффективного ANN
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,
            'efConstruction': 200,
          },
        ),
      ),
    ],
  ),
  // Другие таблицы...
]);

// Онлайн-обновление схемы — незаметно для бизнес-процессов
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // Переименовать таблицу
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // Изменить атрибуты поля
  .renameField('old_name', 'new_name')     // Переименовать поле
  .removeField('deprecated_field')         // Удалить поле
  .addField('created_at', type: DataType.datetime)  // Добавить поле
  .removeIndex(fields: ['age'])            // Удалить индекс
  .setPrimaryKeyConfig(                    // Изменить PK конфиг
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// Мониторинг прогресса миграции
final status = await db.queryMigrationTaskStatus(taskId);
print('Прогресс миграции: ${status?.progressPercentage}%');


// Ручное управление кэшем запросов (Сервер)
// На клиентских платформах управляется автоматически.
// Для серверов или данных большого масштаба используйте эти API для точного контроля.

// Вручную закэшировать результат запроса на 5 минут.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Инвалидировать кэш при изменении данных для согласованности.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// Явно отключить кэш для запросов, требующих данных в реальном времени.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```



## Продвинутое использование

Tostore предоставляет богатый набор продвинутых функций для сложных бизнес-требований:

### TTL на уровне таблицы (автоматическое истечение по времени)

Для логов, событий и других данных, которые должны автоматически удаляться по времени, можно задать TTL на уровне таблицы с помощью `ttlConfig`. Истёкшие данные очищаются в фоновом режиме небольшими пакетами, без необходимости вручную обходить записи в бизнес-коде:

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
    ttlMs: 7 * 24 * 60 * 60 * 1000, // хранить 7 дней
    // Если sourceField опущен, движок использует время записи
    // и автоматически управляет необходимым индексом.
    // Дополнительно: если задаёте собственное sourceField, поле должно:
    // 1) иметь тип DataType.datetime
    // 2) быть NOT NULL (nullable: false)
    // 3) использовать DefaultValueType.currentTimestamp как defaultValueType
    // sourceField: 'created_at',
  ),
);
```

### Вложенные запросы и настраиваемая фильтрация
Поддержка неограниченной вложенности условий и гибких пользовательских функций.

```dart
// Вложение условий: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// Пользовательская функция условия
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('рекомендовано') ?? false);
```

### Интеллектуальный Upsert
Обновить, если существует, иначе вставить.

```dart
// By primary key or unique key in data (no where)
final result = await db.upsert('users', {'id': 1, 'username': 'john', 'email': 'john@example.com'});
await db.upsert('users', {'username': 'john', 'email': 'john@example.com', 'age': 26});
// Batch upsert
await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### Объединения (Joins) и выбор полей
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000);
```

### Стриминг и статистика
```dart
// Подсчет записей
final count = await db.query('users').count();

// Проверить, определена ли таблица в schema базы данных (не зависит от Space)
// Примечание: это НЕ означает, что в таблице есть данные
final usersTableDefined = await db.tableExists('users');

// Эффективная проверка существования по условиям (без загрузки всех записей)
final emailExists = await db.query('users')
    .where('email', '=', 'test@example.com')
    .exists();

// Агрегатные функции
final totalAge = await db.query('users').where('age', '>', 18).sum('age');
final avgAge = await db.query('users').avg('age');
final maxAge = await db.query('users').max('age');
final minAge = await db.query('users').min('age');

// Группировка и фильтрация
final result = await db.query('orders')
    .select(['status', Agg.sum('amount', alias: 'total')])
    .groupBy(['status'])
    .having(Agg.sum('amount'), '>', 1000)
    .limit(20);

// Запрос уникальных значений
final uniqueCities = await db.query('users').distinct(['city']);

// Потоковый запрос (подходит для массивов данных)
db.streamQuery('users').listen((data) => print(data));
```



### Запросы и эффективная пагинация

Tostore предлагает двухрежимную поддержку пагинации для разных масштабов данных:

#### 1. Режим Offset
Подходит для небольших наборов данных (например, до 10 тыс. записей) или при необходимости перехода на конкретную страницу.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Пропустить первые 40
    .limit(20); // Взять 20
```
> [!TIP]
> При очень большом `offset` базе данных приходится сканировать и отбрасывать много записей, что снижает производительность. Используйте **режим Cursor** для глубокой пагинации.

#### 2. Высокопроизводительный режим Cursor
**Рекомендуется для огромных объемов данных и сценариев бесконечной прокрутки**. Использует `nextCursor` для производительности O(1), обеспечивая постоянную скорость запроса.

> [!IMPORTANT]
> При сортировке по неиндексированному полю или для некоторых сложных запросов движок может переключиться на полное сканирование таблицы и вернуть `null` курсор (что означает, что пагинация для данного конкретного запроса пока не поддерживается).

```dart
// Страница 1
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Получить следующую страницу через курсор
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Прямой переход к позиции
}

// Эффективный возврат назад через prevCursor
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Особенность | Режим Offset | Режим Cursor |
| :--- | :--- | :--- |
| **Производительность** | Снижается с ростом страниц | **Постоянна (O(1))** |
| **Сложность** | Мало данных, перескоки | **Много данных, бесконечный скролл** |
| **Согласованность** | Изменения могут вызвать скачки | **Идеальна при изменениях данных** |



### Операторы запросов

Операторы (без учета регистра) для `where(field, operator, value)`:

| Operator | Description | Example / Value type |
| :--- | :--- | :--- |
| `=` | Equal | `where('status', '=', 'active')` |
| `!=`, `<>` | Not equal | `where('role', '!=', 'guest')` |
| `>` | Greater than | `where('age', '>', 18)` |
| `>=` | Greater than or equal | `where('score', '>=', 60)` |
| `<` | Less than | `where('price', '<', 100)` |
| `<=` | Less than or equal | `where('quantity', '<=', 10)` |
| `IN` | Value in list | `where('id', 'IN', ['a','b','c'])` — value: `List` |
| `NOT IN` | Value not in list | `where('status', 'NOT IN', ['banned'])` — value: `List` |
| `BETWEEN` | Between start and end (inclusive) | `where('age', 'BETWEEN', [18, 65])` — value: `[start, end]` |
| `LIKE` | Pattern match (`%` any, `_` single char) | `where('name', 'LIKE', '%John%')` — value: `String` |
| `NOT LIKE` | Pattern not match | `where('email', 'NOT LIKE', '%@test.com')` — value: `String` |
| `IS` | Is null | `where('deleted_at', 'IS', null)` — value: `null` |
| `IS NOT` | Is not null | `where('email', 'IS NOT', null)` — value: `null` |

### Семантические методы запросов (рекомендуется)

Рекомендуется использовать семантические методы вместо ручного ввода операторов.

```dart
// Comparison
db.query('users').whereEqual('username', 'John');
db.query('users').whereNotEqual('role', 'guest');
db.query('users').whereGreaterThan('age', 18);
db.query('users').whereGreaterThanOrEqualTo('score', 60);
db.query('users').whereLessThan('price', 100);
db.query('users').whereLessThanOrEqualTo('quantity', 10);

// Membership & range
db.query('users').whereIn('id', ['id1', 'id2']);
db.query('users').whereNotIn('status', ['banned', 'pending']);
db.query('users').whereBetween('age', 18, 65);

// Null checks
db.query('users').whereNull('deleted_at');
db.query('users').whereNotNull('email');

// Pattern match
db.query('users').whereLike('name', '%John%');
db.query('users').whereNotLike('email', '%@temp.');
db.query('users').whereContains('bio', 'flutter');   // LIKE '%flutter%'
db.query('users').whereNotContains('title', 'draft');

// Equivalent to: .where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```

## Распределенная архитектура

```dart
// Настройка распределенных узлов
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,
      clusterId: 1,
      centralServerUrl: 'http://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// Высокопроизводительная пакетная вставка (Batch Insert)
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Записи эффективно вставляются пакетами
]);

// Потоковая обработка больших наборов данных — константная память
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Эффективно обрабатывает даже терабайты данных без высокого расхода памяти
  print(record);
}
```

## Примеры первичных ключей

Tostore предоставляет различные алгоритмы распределенных первичных ключей:

- **Последовательный** (PrimaryKeyType.sequential): 238978991
- **На основе меток времени** (PrimaryKeyType.timestampBased): 1306866018836946
- **С префиксом даты** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **Короткий код** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// Пример настройки последовательного первичного ключа
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // Скрыть объемы бизнеса
      ),
    ),
    fields: [/* Определения полей */]
  ),
]);
```


## Атомарные операции выражений

Система выражений обеспечивает типобезопасные атомарные обновления полей. Все вычисления выполняются атомарно на уровне базы данных во избежание конфликтов параллелизма:

```dart
// Простое увеличение: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Сложное вычисление: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// Вложенные скобки: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Использование функций: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Метка времени: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

## Транзакции

Транзакции обеспечивают атомарность нескольких операций: либо все проходят успешно, либо все откатываются, гарантируя согласованность данных.

**Особенности транзакций**:
- Атомарное выполнение нескольких операций.
- Автоматическое восстановление незавершенных операций после краха.
- Данные надежно сохраняются при успешном коммите.

```dart
// Базовая транзакция — атомарный коммит нескольких операций
final txResult = await db.transaction(() async {
  // Вставка пользователя
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // Атомарное обновление через выражения
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // Если любая операция не удалась, все изменения откатываются автоматически.
});

if (txResult.isSuccess) {
  print('Транзакция успешно завершена');
} else {
  print('Откат транзакции: ${txResult.error?.message}');
}

// Автоматический откат при ошибке
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('Ошибка бизнес-логики'); // Вызывает откат
}, rollbackOnError: true);
```

### Чистый режим в памяти (Memory Mode)

Для таких сценариев, как кэширование данных, временные вычисления или среды без дисков, где не требуется сохранение на диск, вы можете инициализировать базу данных полностью в памяти с помощью `ToStore.memory()`. В этом режиме все данные (включая схемы, индексы и пары ключ-значение) хранятся исключительно в памяти.

**Внимание**: Данные, созданные в режиме памяти, полностью теряются при закрытии или перезапуске приложения.

```dart
// Инициализация базы данных в чистом режиме памяти
final db = await ToStore.memory(
  schemas: [],
);

// Все операции (CRUD и поиск) мгновенно выполняются в памяти
await db.insert('temp_cache', {'key': 'session_1', 'value': {'user': 'admin'}});

```


## Конфигурация безопасности

**Механизмы безопасности данных**:
- Двойные механизмы защиты гарантируют, что данные никогда не будут потеряны.
- Автоматическое восстановление незавершенных операций после сбоя.
- Мгновенная надежная фиксация при успехе операции.
- Высокопрочное шифрование защищает конфиденциальные данные.

> [!WARNING]
> **Управление ключами**: **`encodingKey`** можно менять свободно; при изменении движок автоматически мигрирует данные, беспокоиться о потере данных не нужно. **`encryptionKey`** не меняйте произвольно — после изменения старые данные станут нечитаемыми, если не проведена миграция. Не зашивайте конфиденциальные ключи в код; получайте их с защищенного сервера.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Поддерживаемые алгоритмы: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // Ключ кодирования (можно менять свободно; данные мигрируют автоматически)
      encodingKey: 'Ваш-32-байтный-ключ-кодирования...', 
      
      // Ключ шифрования для критически важных данных (не менять произвольно; старые данные нечитаемы без миграции)
      encryptionKey: 'Ваш-надежный-ключ-шифрования...',
      
      // Привязка к устройству (на основе пути)
      // Ключи привязываются к пути и характеристикам устройства.
      // Повышает безопасность против копирования файлов базы данных.
      deviceBinding: false, 
    ),
    // WAL (Write-Ahead Logging) включен по умолчанию
    enableJournal: true, 
    // Принудительный сброс на диск при коммите (false для макс. производительности)
    persistRecoveryOnCommit: true,
  ),
);
```

### Шифрование на уровне значения (ToCrypto)

Полное шифрование базы данных выше шифрует все таблицы и индексы и может влиять на общую производительность. Чтобы шифровать только чувствительные поля, используйте **ToCrypto**: он не зависит от базы данных (экземпляр db не требуется). Вы кодируете или декодируете значения сами перед записью или после чтения; ключ полностью управляется вашим приложением. Вывод в Base64, подходит для колонок JSON или TEXT.

- **key** (обязательно): `String` или `Uint8List`. Если не 32 байта, ключ 32 байта выводится через SHA-256.
- **type** (опционально): Тип шифрования [ToCryptoType]: [ToCryptoType.chacha20Poly1305] или [ToCryptoType.aes256Gcm]. По умолчанию [ToCryptoType.chacha20Poly1305]. Не указывать для значения по умолчанию.
- **aad** (опционально): Дополнительные аутентифицированные данные — `Uint8List`. Если передаётся при кодировании, при декодировании нужно передать те же байты (напр. имя таблицы + поле для привязки контекста). Для простого использования можно опустить.

```dart
const key = 'my-secret-key';
// Кодирование: открытый текст → Base64 шифр (сохранить в DB или JSON)
final cipher = ToCrypto.encode('sensitive data', key: key);
// Декодировать при чтении
final plain = ToCrypto.decode(cipher, key: key);

// Опционально: привязать контекст через aad (тот же aad при кодировании и декодировании)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```

## Производительность и опыт

### Спецификации производительности

- **Скорость запуска**: Мгновенный запуск и отображение данных даже при 100M+ записей на обычных смартфонах.
- **Поиск**: Не зависит от масштаба, стабильно молниеносное получение данных.
- **Безопасность данных**: Гарантии ACID-транзакций + восстановление после сбоев для нулевой потери данных.

### Рекомендации

- 📱 **Пример проекта**: Полный пример приложения на Flutter находится в директории `example`.
- 🚀 **Production**: Используйте режим Release для производительности, намного превышающей Debug.
- ✅ **Стандартные тесты**: Все основные функции прошли стандартные интеграционные тесты.

### Демонстрационные видео

<p align="center">
  <img src="../media/basic-demo.gif" alt="Базовая демонстрация производительности Tostore" width="320" />
  </p>

- **Базовая демонстрация производительности** (<a href="../media/basic-demo.mp4?raw=1" target="_blank" rel="noopener">basic-demo.mp4</a>): GIF‑превью может быть обрезано; нажмите на видео, чтобы посмотреть полную демонстрацию. Показывает, что даже на обычном смартфоне с более чем 100 M записей запуск приложения, постраничная навигация и поиск остаются стабильными и плавными. При достаточном объёме хранилища периферийные устройства могут обрабатывать объёмы данных вплоть до TB/PB, сохраняя при этом низкую задержку взаимодействия.

<p align="center">
  <img src="../media/disaster-recovery.gif" alt="Стресс‑тест восстановления после сбоев Tostore" width="320" />
  </p>
  
- **Стресс‑тест восстановления после сбоев** (<a href="../media/disaster-recovery.mp4?raw=1" target="_blank" rel="noopener">disaster-recovery.mp4</a>): Намеренно многократно прерывает процесс во время интенсивной нагрузки на запись, имитируя краши и отключения питания. Даже если десятки тысяч операций записи обрываются внезапно, Tostore очень быстро восстанавливается на типичном смартфоне и не влияет auf последующий запуск приложения или доступность данных.




Если Tostore помогает вам, пожалуйста, поставьте нам ⭐️




## План развития (Roadmap)

Tostore активно развивает функции для укрепления инфраструктуры данных в эпоху ИИ:

- **Высокоразмерные векторы**: добавление алгоритмов поиска векторов и семантического поиска.
- **Мультимодальные данные**: обеспечение сквозной обработки от сырых данных до векторов признаков.
- **Графовые структуры данных**: поддержка эффективного хранения и запросов к графам знаний.





> **Рекомендация**: Мобильным разработчикам также стоит рассмотреть [Toway Framework](https://github.com/tocreator/toway) — full-stack решение, автоматизирующее запросы, загрузку, хранение, кэширование и отображение данных.




## Дополнительные ресурсы

- 📖 **Документация**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Обратная связь**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Обсуждение**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


