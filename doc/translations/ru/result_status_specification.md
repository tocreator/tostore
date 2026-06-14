# Спецификация автоматической диагностики и разрешения состояний ToStore ResultStatus

Чтобы автоматизированные операции (Ops), агенты ИИ, автоматические тестовые скрипты и клиентские приложения могли точно идентифицировать различные результаты выполнения базы данных и состояния исключений, в последней версии ToStore представлена структурированная система `ResultStatus`.

В этом документе спецификации подробно описаны принципы проектирования кодов состояний, спецификации ключей семантических идентификаторов и выделенные структуры полей различных типов состояний, чтобы помочь пользователям базы данных и разработчикам самостоятельно реализовать разрешение состояний.

---

## 1. Основные Принципы Проектирования

### 1.1 Числовая Спецификация Кода Состояния (code)

Все числовые коды состояний (`code`) определяются с использованием фиксированной длины в 5 цифр (за исключением состояния успешного выполнения):

- **Состояние успешного выполнения (Специальный код успеха)**: Специально зафиксировано как `0`.
- **Другие состояния (Коды ошибок и диагностики)**: Унифицированы до 5 цифр.
- **Код класса**: Первые две цифры кода состояния, используемые для быстрой идентификации основной категории.
- **Код листа**: Последние три цифры кода состояния, представляющие конкретный сценарий ошибки.

> [!TIP]
> При разработке автоматизированных операций (Ops), агентов ИИ или внешних тестовых скриптов разработчики могут маршрутизировать запросы к соответствующим обработчикам исключений, используя первые две цифры (код класса) или диапазон, а затем выполнять точную обработку на основе кода листа.

> [!IMPORTANT]
> **Лучшая практика проверки в памяти (In-Memory Check)**:
> При чтении результатов операций базы данных в памяти (например, в клиентском коде или коде Dart/Flutter) **наиболее рекомендуемым и эффективным методом является непосредственное использование встроенных свойств только для чтения (геттеров)** `ResultStatus` или `ResultType` (таких как `isBusinessError`, `isCriticalError` и т.д., см. [Раздел 3.2](#32-вспомогательные-геттеры-в-памяти)), избегая ручного разбора числовых диапазонов или сопоставления префиксов строк.

### 1.2 Спецификация Семантического Идентификатора Состояния (codeKey)

Каждому состоянию соответствует уникальный строковый идентификатор `codeKey`:

- **Формат именования**: `[Префикс_Основной_Категории]_[Многоуровневый_Детальный_Идентификатор]`.
- **Правило именования**: Состоит из заглавных английских букв и символов подчеркивания `_`, без пробелов и специальных символов.
- **Префикс основной категории**: Указывает, к какой основной бизнес-категории относится состояние. Если существует несколько уровней категорий, самый общий префикс помещается в начало для облегчения поиска по префиксу и фильтрации диапазонов.

---

## 2. Таблица Быстрого Доступа для Кодов Классов

Ниже приведено определение сопоставления всех кодов классов в ToStore:

| Диапазон Кодов | Код Класса (Первые 2 цифры) | Семантический Префикс | Категория | Стратегия Исключений |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `00` | `SUCCESS` | **Операция успешна** | Не генерирует исключение, возвращается нормально. |
| `10000 - 19999` | `10 - 19` | `BIZ_` | **Бизнес-ошибка** (Ошибки ввода конечного пользователя, например, нарушения ограничений) | Не генерирует исключение, всегда возвращается через `DbResult` или `QueryResult`. |
| `20000 - 49999` | `20 - 49` | `DEV_` | **Ошибка разработчика** (Недопустимые параметры API, неверная конфигурация схемы таблицы и т. д.) | **Генерирует `DbException` напрямую в средах отладки**, чтобы предупредить разработчиков; **нормально возвращается в качестве результата в рабочих (production) средах**. *(Примечание: Несовместимость версий ядра и критические сбои выполнения пакетов миграции являются критическими ошибками, которые генерируют исключения даже в продакшене)* |
| `50000 - 79999` | `50 - 79` | `SYS_` | **Системная ошибка** (Диск заполнен, исключения ввода-вывода, таймаут получения блокировки и т. д.) | Генерирует исключение, когда нормальное выполнение заблокировано; другие (например, конфликт транзакций) возвращаются в виде результатов. |
| `99000 - 99999` | `99` | `ENG_` | **Ошибка ядра** (Логическая ошибка ядра, повреждение файла данных, неизвестная внутренняя ошибка) | Обычно не генерирует исключения; генерирует исключения в тяжелых случаях. |

---

## 3. Общая Структура Полей ResultStatus и Помощники в Памяти

### 3.1 Общие Поля (Сериализованная Структура JSON)

Все типы `ResultStatus` при сериализации в JSON содержат следующие 4 базовых общих поля. Пользователи могут читать эти поля напрямую для предварительной проверки.

| Поле | Тип | Описание |
| :--- | :--- | :--- |
| `index` | `int` | Индекс последовательности в пакетных операциях. Для одиночных операций зафиксирован как `0`. |
| `code` | `int` | Числовой код состояния (`0` для успеха, 5-значное число для исключения). |
| `codeKey` | `String` | Ключ семантического идентификатора состояния, например, `CONSTRAINT_VIOLATION_UNIQUE`. |
| `message` | `String` | Человекочитаемое описание деталей состояния. |

### 3.2 Вспомогательные Геттеры в Памяти

В Dart/Flutter `ResultStatus` и `ResultType` инкапсулируют высокоэффективные свойства только для чтения (геттеры) со сложностью `O(1)` для проверки категории и серьезности в памяти без ручных проверок диапазонов или сопоставления строк:

| Свойство | Тип | Описание |
| :--- | :--- | :--- |
| `isBusinessError` | `bool` | Является ли это **Бизнес-ошибкой** (например, конфликт ограничений, сбой приведения типов; диапазон `10000 - 19999`). |
| `isDeveloperError` | `bool` | Является ли это **Ошибкой разработчика** (например, недопустимая схема, несоответствие параметров, таблица не найдена; диапазон `20000 - 49999`). |
| `isSystemError` | `bool` | Является ли это **Системной ошибкой** (например, таймаут блокировки, диск заполнен, блокировка файла; диапазон `50000 - 79999`). |
| `isEngineError` | `bool` | Является ли это **Ошибкой ядра** (диапазон `99000 - 99999`). |
| `isCriticalError` | `bool` | Является ли это **Критической ошибкой / Событием уровня катастрофы** (требует ручного или оперативного вмешательства, например, диск заполнен, нехватка памяти, серьезное повреждение файлов данных, сбой несовместимой миграции и т. д.). |

---

## 4. Детальные Структуры Разрешения и Выделенные Поля

В зависимости от диапазона `code` / `codeKey` и конкретного подкласса `ResultStatus`, сериализованная структура JSON будет содержать различные **выделенные диагностические поля**. Ниже приведены спецификации полей и сопоставление приложений для 5 подклассов состояний.

### 4.1 SuccessStatus (Операция успешна)

- **Диапазон категорий**: `code == 0`, `codeKey == "SUCCESS"`
- **Применимый сценарий**: Записи успешно вставлены, изменены или удалены.
- **Определение выделенного поля**:

  | Поле | Тип | Детали |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Необязательно**. Возвращается только при записи одной строки (например, `insert`) или обновлении (например, `update`), представляя физически сгенерированный или измененный первичный ключ записи. |

- **Пример JSON**:
  ```json
  {
    "index": 0,
    "code": 0,
    "codeKey": "SUCCESS",
    "message": "Operation successful",
    "primaryKey": "usr_9a8f4c2b"
  }
  ```

---

### 4.2 ConstraintStatus (Целостность данных и конфликты ограничений)

- **Диапазон категорий**: `code` внутри `[10000, 19999]` (в основном конфликты валидации и ограничений целостности).
- **Определение выделенного поля**:

  | Поле | Тип | Детали |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Обязательно**. Имя таблицы, в которой произошел конфликт ограничения целостности или ошибка отсутствия записи. |
  | `constraintName` | `String?` | **Необязательно**. Имя конкретного ограничения, вызвавшего ошибку (например, `fk_users_profile` для внешнего ключа, имя индекса для конфликта уникальности или `null` для ошибок not-null или приведения типов). |
  | `fields` | `List<String>` | **Обязательно**. Список полей, вызвавших конфликт. |
  | `conflictingKeys` | `List<dynamic>` | **Обязательно**. Список входных значений, вызвавших конфликт, сопоставляемый 1:1 с `fields`. Если поле равно null, соответствующий элемент в списке будет `null`. |
  | `primaryKey` | `String?` | **Необязательно**. Связанный первичный ключ записи. Если это не запись одной строки или операция была заблокирована на этапе работы с памятью, это поле будет `null`. |
  | `referencedTable` | `String?` | **Необязательно**. Имя родительской таблицы при конфликтах внешнего ключа. |

- **Руководство по кодам листьев**:

  | Код и ResultType | Сценарий | Руководство по полям |
  | :--- | :--- | :--- |
  | `10000`<br>`bizValidationFailed` | Ошибка валидации формата или диапазона данных | <ul><li>`tableName`: Затронутая таблица</li><li>`constraintName`: `null`</li><li>`fields`: Поля, нарушившие валидацию, например `["email"]`</li><li>`conflictingKeys`: Недопустимые значения, вызвавшие сбой, например `["invalid-email"]`</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |
  | `10001`<br>`bizNotNullViolation` | Нарушение ограничения NOT NULL | <ul><li>`tableName`: Затронутая таблица</li><li>`constraintName`: `null`</li><li>`fields`: Поля, нарушившие ограничение NOT NULL, например `["email"]`</li><li>`conflictingKeys`: Всегда `[null]`</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |
  | `10002`<br>`bizTypeCastFailed` | Ошибка преобразования или приведения типов данных | <ul><li>`tableName`: Затронутая таблица</li><li>`constraintName`: `null`</li><li>`fields`: Поля, для которых не удалось приведение типов, например `["age"]`</li><li>`conflictingKeys`: Недопустимые значения, вызвавшие сбой, например `["not_a_number"]`</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |
  | `11001`<br>`bizPrimaryKeyViolation` | Конфликт первичного ключа (уже существует) | <ul><li>`tableName`: Затронутая таблица</li><li>`constraintName`: `"PRIMARY"` или имя ограничения</li><li>`fields`: Поля первичного ключа, например `["id"]`</li><li>`conflictingKeys`: Дублирующиеся значения, например `["usr_101"]`</li><li>`primaryKey`: Конфликтующее значение, например `"usr_101"`</li></ul> |
  | `11002`<br>`bizUniqueViolation` | Нарушение ограничения уникальности | <ul><li>`tableName`: Затронутая таблица</li><li>`constraintName`: Имя уникального индекса, например `"uk_email"`</li><li>`fields`: Поля, составляющие уникальность, например `["email"]`</li><li>`conflictingKeys`: Значения, вызвавшие конфликт, например `["test@a.com"]`</li><li>`primaryKey`: Первичный ключ конфликтующей записи (при наличии)</li></ul> |
  | `11003`<br>`bizForeignKeyViolation` | Нарушение ограничения внешнего ключа (Общее) | <ul><li>`tableName`: Дочерняя таблица</li><li>`constraintName`: Имя ограничения внешнего ключа</li><li>`fields`: Столбцы внешнего ключа</li><li>`conflictingKeys`: Входные значения, вызвавшие конфликт</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li><li>`referencedTable`: Родительская таблица</li></ul> |
  | `11004`<br>`bizCheckViolation` | Нарушение проверочного ограничения (CHECK) | <ul><li>`tableName`: Затронутая таблица</li><li>`constraintName`: Имя ограничения CHECK</li><li>`fields`: Проверяемые поля</li><li>`conflictingKeys`: Значения, нарушающие проверку</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |
  | `11005`<br>`bizForeignKeyParentNotExist` | Ссылочный родительский ключ не существует | <ul><li>`tableName`: Дочерняя таблица</li><li>`constraintName`: Имя ограничения внешнего ключа</li><li>`fields`: Столбцы внешнего ключа, например `["userId"]`</li><li>`conflictingKeys`: Несуществующее ссылочное значение, например `["non_parent"]`</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li><li>`referencedTable`: Родительская таблица</li></ul> |
  | `11006`<br>`bizForeignKeyChildRestrict` | Удаление/обновление ограничено дочерними записями | <ul><li>`tableName`: Родительская таблица</li><li>`constraintName`: Имя ограничения внешнего ключа</li><li>`fields`: Столбцы родительской таблицы, на которые есть ссылки</li><li>`conflictingKeys`: Значения родительских ключей, на которые ссылается дочерняя таблица</li><li>`primaryKey`: Значения родительских ключей</li><li>`referencedTable`: Дочерняя таблица</li></ul> |
  | `11007`<br>`bizForeignKeyCompositeMismatch` | Неполные составные значения внешнего ключа | <ul><li>`tableName`: Дочерняя таблица</li><li>`constraintName`: Имя ограничения внешнего ключа</li><li>`fields`: Столбцы составного внешнего ключа</li><li>`conflictingKeys`: Входные значения (содержат частичные null)</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li><li>`referencedTable`: Родительская таблица</li></ul> |
  | `11008`<br>`bizForeignKeyTypeMismatch` | Несоответствие типов внешнего ключа | <ul><li>`tableName`: Дочерняя таблица</li><li>`constraintName`: Имя ограничения внешнего ключа</li><li>`fields`: Столбцы внешнего ключа</li><li>`conflictingKeys`: Значения, для которых не удалось приведение типов</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li><li>`referencedTable`: Родительская таблица</li></ul> |
  | `11009`<br>`bizValueExceedsMaxLength` | Длина значения превышает ограничение схемы | <ul><li>`tableName`: Затронутая таблица</li><li>`constraintName`: `null`</li><li>`fields`: Поля, нарушившие лимит, например `["name"]`</li><li>`conflictingKeys`: Выходящие за рамки значения, например `["a" * 1000]`</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |
  | `11010`<br>`bizValueLessThanMinLength` | Длина значения меньше ограничения схемы | <ul><li>`tableName`: Затронутая таблица</li><li>`constraintName`: `null`</li><li>`fields`: Поля, нарушившие лимит, например `["code"]`</li><li>`conflictingKeys`: Значения короче минимума, например `["ab"]`</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |
  | `11011`<br>`bizValueLessThanMinValue` | Числовое значение меньше ограничения схемы | <ul><li>`tableName`: Затронутая таблица</li><li>`constraintName`: `null`</li><li>`fields`: Поля, нарушившие лимит, например `["age"]`</li><li>`conflictingKeys`: Значения меньше минимума, например `[-5]`</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |
  | `11012`<br>`bizValueExceedsMaxValue` | Числовое значение превышает ограничение схемы | <ul><li>`tableName`: Затронутая таблица</li><li>`constraintName`: `null`</li><li>`fields`: Поля, нарушившие лимит, например `["score"]`</li><li>`conflictingKeys`: Значения, превышающие максимум, например `[105]`</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |
  | `12002`<br>`bizRecordNotFound` | Ресурс не существует / Запись не найдена | <ul><li>`tableName`: Затронутая таблица</li><li>`constraintName`: `null`</li><li>`fields`: Поля поиска цели, например `["id"]`</li><li>`conflictingKeys`: Ненайденные целевые ключи, например `["non_exist_id"]`</li><li>`primaryKey`: Значение отсутствующего ключа, например `"non_exist_id"`</li></ul> |

- **Пример JSON** (Родительская запись внешнего ключа не существует):
  ```json
  {
    "index": 0,
    "code": 11005,
    "codeKey": "BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST",
    "message": "Foreign key constraint violation on table \"profiles\" (Constraint: \"fk_profiles_userId\"): Referenced record does not exist in table \"users\" for fields (userId) referencing (id). Conflicting values: [usr_999]",
    "tableName": "profiles",
    "constraintName": "fk_profiles_userId",
    "fields": ["userId"],
    "conflictingKeys": ["usr_999"],
    "primaryKey": "prof_112233",
    "referencedTable": "users"
  }
  ```

---

### 4.3 SchemaValidationStatus (Валидация схемы таблицы и несовместимая миграция)

- **Диапазон категорий**: `code` внутри `[30000, 39999]` (ошибки валидации конфигурации схемы и несоответствия физической миграции).
- **Определение выделенного поля**:

  | Поле | Тип | Детали |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Обязательно**. Имя таблицы, проходящей валидацию или физическую миграцию. |
  | `field` | `String?` | **Необязательно**. Имя конкретного поля, вызвавшего ошибку схемы или миграции. |
  | `wrongValue` | `dynamic` | **Необязательно**. Недопустимое значение конфигурации или конфигурация различий миграции, вызвавшая конфликт. |

- **Руководство по кодам листьев**:

  | Код и ResultType | Сценарий | Руководство по полям |
  | :--- | :--- | :--- |
  | `30000`<br>`devInvalidSchema` | Недопустимое определение схемы таблицы | <ul><li>`tableName`: Имя таблицы</li><li>`field`: `null`</li><li>`wrongValue`: Недопустимая карта конфигурации или `null`</li></ul> |
  | `30001`<br>`devInvalidSchemaTableName` | Ошибка валидации имени таблицы (недопустимые символы или слишком длинное) | <ul><li>`tableName`: Нарушающее правила имя</li><li>`field`: `null`</li><li>`wrongValue`: Нарушающая правила строка</li></ul> |
  | `30002`<br>`devInvalidSchemaFieldName` | Ошибка валидации имени поля (недопустимые символы) | <ul><li>`tableName`: Имя таблицы</li><li>`field`: Нарушающее правила имя поля</li><li>`wrongValue`: Нарушающая правила строка</li></ul> |
  | `30003`<br>`devInvalidSchemaPrimaryKey` | Ошибка валидации первичного ключа (отсутствует или неверный формат) | <ul><li>`tableName`: Имя таблицы</li><li>`field`: `"primaryKey"` или имя поля первичного ключа</li><li>`wrongValue`: Детали конфигурации первичного ключа</li></ul> |
  | `30004`<br>`devInvalidSchemaIndexLimit` | Количество индексов таблицы превышает системный лимит в 16 | <ul><li>`tableName`: Имя таблицы</li><li>`field`: `null`</li><li>`wrongValue`: Список конфигураций индексов</li></ul> |
  | `30005`<br>`devSchemaTableExists` | Таблица уже существует | <ul><li>`tableName`: Имя таблицы</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30006`<br>`devSchemaFieldExists` | Обновление схемы: добавление поля, которое уже существует | <ul><li>`tableName`: Имя таблицы</li><li>`field`: Конфликтующее имя поля</li><li>`wrongValue`: `null`</li></ul> |
  | `30007`<br>`devSchemaIndexExists` | Обновление схемы: добавление индекса, который уже существует | <ul><li>`tableName`: Имя таблицы</li><li>`field`: Имя индекса</li><li>`wrongValue`: `null`</li></ul> |
  | `30008`<br>`devInvalidSchemaForeignKey` | Недопустимое определение внешнего ключа (например, несоответствие столбцов) | <ul><li>`tableName`: Имя таблицы</li><li>`field`: Имя внешнего ключа</li><li>`wrongValue`: Детали конфигурации внешнего ключа</li></ul> |
  | `30009`<br>`devInvalidSchemaSpaceMismatch` | Глобальное/Специфичное для пространства несоответствие границ | <ul><li>`tableName`: Имя таблицы</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30010`<br>`devMigrationNotAllowedWithData` | Миграция требует изменения данных и не была явно разрешена | <ul><li>`tableName`: Имя таблицы</li><li>`field`: `null`</li><li>`wrongValue`: Карта различий обновления миграции</li></ul> |
  | `30011`<br>`devMigrationUnsafeTypeConversion` | Физическая миграция: неподдерживаемое преобразование типов для поля | <ul><li>`tableName`: Имя таблицы</li><li>`field`: Имя поля</li><li>`wrongValue`: Карта конфликтующих типов, например `{ "from": "text", "to": "integer" }`</li></ul> |
  | `30013`<br>`devMigrationCannotAddNonNullField` | Невозможно добавить поле non-nullable без значения по умолчанию в непустую таблицу | <ul><li>`tableName`: Имя таблицы</li><li>`field`: Нарушающее правила имя поля</li><li>`wrongValue`: Параметры миграции, например `{ "nullable": false, "defaultValue": null }`</li></ul> |
  | `30014`<br>`devMigrationNullableToNonNullNotAllowed` | Физическая миграция: изменение поля с nullable на non-nullable | <ul><li>`tableName`: Имя таблицы</li><li>`field`: Имя поля</li><li>`wrongValue`: Параметры миграции, аналогично 30013</li></ul> |
  | `30015`<br>`devMigrationUniqueTighteningNotAllowed` | Физическая миграция: ужесточение ограничения поля до UNIQUE | <ul><li>`tableName`: Имя таблицы</li><li>`field`: Имя поля</li><li>`wrongValue`: Определение индекса, вызывающее ограничение уникальности</li></ul> |
  | `30016`<br>`devInvalidSchemaTtlConfig` | Ошибка валидации конфигурации TTL | <ul><li>`tableName`: Имя таблицы</li><li>`field`: Поле временной метки TTL</li><li>`wrongValue`: Недопустимая карта конфигурации TTL, например, `{ "enabled": true, "fieldName": "expire_at" }`</li></ul> |
  | `30017`<br>`devInvalidSchemaDuplicateFieldName` | Дублирующееся имя поля в схеме таблицы | <ul><li>`tableName`: Имя таблицы</li><li>`field`: Дублирующееся имя поля</li><li>`wrongValue`: `null`</li></ul> |
  | `30018`<br>`devInvalidSchemaIndexField` | Индекс ссылается на несуществующее поле | <ul><li>`tableName`: Имя таблицы</li><li>`field`: Имя индекса</li><li>`wrongValue`: Имя поля, вызывающее несоответствие</li></ul> |

- **Пример JSON** (Добавление non-nullable поля без значения по умолчанию в непустую таблицу):
  ```json
  {
    "index": 0,
    "code": 30013,
    "codeKey": "DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD",
    "message": "Cannot add non-nullable field \"phone\" without a default value to non-empty table \"users\". This operation is physically impossible and would fail during data write.",
    "tableName": "users",
    "field": "phone",
    "wrongValue": {
      "nullable": false,
      "defaultValue": null
    }
  }
  ```

---

### 4.4 InvalidArgumentStatus (Аргументы API и валидация пагинации курсора)

- **Диапазон категорий**: `code` внутри `[20000, 20999]` (ошибки валидации параметров API, структур запросов или токенов пагинации).
- **Определение выделенного поля**:

  | Поле | Тип | Детали |
  | :--- | :--- | :--- |
  | `parameterName` | `String` | **Обязательно**. Имя аргумента, вызвавшего ошибку валидации (например, `"cursor"`, `"orderBy"` или конкретный ключ столбца). |
  | `passedValue` | `dynamic` | **Необязательно**. Несоответствующее входное значение, переданное вызывающим объектом. Сложные объекты преобразуются в строки. |
  | `primaryKey` | `String?` | **Необязательно**. Связанный первичный ключ записи. |

- **Руководство по кодам листьев**:

  | Код и ResultType | Сценарий | Руководство по полям |
  | :--- | :--- | :--- |
  | `20001`<br>`devInvalidArgumentFormat` | Ошибка формата аргумента | <ul><li>`parameterName`: Имя недопустимого аргумента</li><li>`passedValue`: Переданное значение, например `"twenty"`</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |
  | `20002`<br>`devInvalidArgumentType` | Несоответствие типа аргумента | <ul><li>`parameterName`: Имя параметра</li><li>`passedValue`: Переданное значение, например `{"foo": "bar"}` (когда ожидается String)</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |
  | `20003`<br>`devInvalidArgumentMissing` | Обязательный аргумент отсутствует | <ul><li>`parameterName`: Имя отсутствующего параметра, например `"dbPath"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |
  | `20005`<br>`devInvalidPrimaryKeyFormat` | Недопустимый формат первичного ключа | <ul><li>`parameterName`: `"primaryKey"` или поле первичного ключа</li><li>`passedValue`: Недопустимое значение первичного ключа, например, `"invalid_id_value"`</li><li>`primaryKey`: Недопустимое значение первичного ключа</li></ul> |
  | `20010`<br>`devVectorDimensionMismatch` | Несоответствие размерностей векторов | <ul><li>`parameterName`: `"other"`</li><li>`passedValue`: Нарушающий правила размер размерности</li><li>`primaryKey`: `null`</li></ul> |
  | `20011`<br>`devIndexFieldMissing` | В записи для курсора отсутствует обязательное поле индекса | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Отсутствующее поле индекса</li><li>`primaryKey`: `null`</li></ul> |
  | `20201`<br>`devInvalidCursorPagination` | Пагинация курсора и смещение (offset) взаимно исключают друг друга | <ul><li>`parameterName`: `"cursor"` / `"offset"`</li><li>`passedValue`: Конфликтующие параметры пагинации</li><li>`primaryKey`: `null`</li></ul> |
  | `20202`<br>`devInvalidCursorTable` | Курсор не соответствует целевой таблице | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Токен курсора</li><li>`primaryKey`: `null`</li></ul> |
  | `20203`<br>`devInvalidCursorSignature` | Несоответствие подписи курсора (изменено) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Токен курсора</li><li>`primaryKey`: `null`</li></ul> |
  | `20204`<br>`devInvalidCursorOrderBy` | Конфигурация orderBy курсора недопустима или не соответствует запросу | <ul><li>`parameterName`: `"orderBy"`</li><li>`passedValue`: Список orderBy, например `["-age", "id"]`</li><li>`primaryKey`: `null`</li></ul> |
  | `20205`<br>`devInvalidCursorMode` | Несоответствие режима токена курсора | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Режим токена, например, `"sortKey"`</li><li>`primaryKey`: `null`</li></ul> |
  | `20206`<br>`devInvalidCursorPayload` | Недопустимая полезная нагрузка курсора (не поддается декодированию) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: `null`</li></ul> |
  | `20301`<br>`devInvalidQuerySelectField` | Поле выборки запроса (select) должно быть String или QueryAggregation | <ul><li>`parameterName`: `"select"`</li><li>`passedValue`: Недопустимое определение поля select</li><li>`primaryKey`: `null`</li></ul> |
  | `20302`<br>`devInvalidQueryForeignKeyJoin` | Отсутствует связь по внешнему ключу для автоматического объединения (join) | <ul><li>`parameterName`: `"join"` / `"tableName"`</li><li>`passedValue`: Целевая таблица без связи</li><li>`primaryKey`: `null`</li></ul> |
  | `20303`<br>`devInvalidQueryFieldAlias` | Недопустимый формат псевдонима поля запроса | <ul><li>`parameterName`: `"alias"`</li><li>`passedValue`: Недопустимая строка псевдонима</li><li>`primaryKey`: `null`</li></ul> |
  | `20304`<br>`devInvalidExpression` | Недопустимая конфигурация выражения или исключение выполнения | <ul><li>`parameterName`: Аспект ошибки (например, `"arguments"`, `"functionName"`, `"node"`)</li><li>`passedValue`: Недопустимое значение или количество</li><li>`primaryKey`: `null`</li></ul> |
  | `22005`<br>`devFieldNotFound` | Поле не найдено | <ul><li>`parameterName`: Неизвестное имя поля, например `"extra"`</li><li>`passedValue`: Входное значение, переданное для поля</li><li>`primaryKey`: Первичный ключ записи (при наличии)</li></ul> |

- **Пример JSON** (Поля orderBy курсора не соответствуют orderBy текущего запроса):
  ```json
  {
    "index": 0,
    "code": 20204,
    "codeKey": "DEV_INVALID_CURSOR_ORDERBY",
    "message": "Cursor orderBy fields do not match current query orderBy.",
    "parameterName": "orderBy",
    "passedValue": ["age DESC", "id ASC"],
    "primaryKey": null
  }
  ```

---

### 4.5 TransactionOperationStatus (Конфликт и прерывание транзакции)

- **Диапазон категорий**: `code` внутри `[50000, 50999]` (откат транзакции, явное прерывание или конфликты сериализуемости).
- **Определение выделенного поля**:

  | Поле | Тип | Детали |
  | :--- | :--- | :--- |
  | `txId` | `String` | **Обязательно**. Глобально уникальный идентификатор потока транзакции. Используется для отслеживания жизненного цикла транзакции. |

- **Руководство по кодам листьев**:

  | Код и ResultType | Сценарий | Руководство по полям |
  | :--- | :--- | :--- |
  | `50001`<br>`sysTransactionAborted` | Транзакция прервана (явный откат или каскадный сбой) | <ul><li>`txId`: Идентификатор активной транзакции</li></ul> |
  | `50002`<br>`sysTransactionConflict` | Конфликт транзакции (одновременные обновления одного и того же ключа в SSI/WAL) | <ul><li>`txId`: Идентификатор конфликтующей транзакции</li></ul> |

- **Пример JSON** (Конфликт одновременной записи SSI):
  ```json
  {
    "index": 0,
    "code": 50002,
    "codeKey": "SYS_TRANSACTION_CONFLICT",
    "message": "Transaction conflict, concurrent updates detected on entity version mismatch (record: usr_123456)",
    "txId": "tx_88ff3b2a99c1"
  }
  ```

---

### 4.6 GeneralStatus (Общие системные исключения)

- **Диапазон категорий**: Резервный вариант для любых других кодов состояний (низкоуровневый ввод-вывод, аппаратные ошибки, системные таймауты и т. д.).
- **Определение выделенного поля**:

  | Поле | Тип | Детали |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Необязательно**. Связанный первичный ключ записи. |
  | `target` | `String?` | **Необязательно**. Целевой физический ресурс, например, пути к физическим файлам, блокировки или URL-адреса. |
  | `operation` | `String?` | **Необязательно**. Имя активного системного вызова, например `'readAsString'`, `'delete'`, `'acquire'`. |

- **Руководство по кодам листьев**:

  | Код и ResultType | Сценарий / Уровень | Руководство по полям |
  | :--- | :--- | :--- |
  | `20007`<br>`devIndexOutOfBounds` | Индекс или диапазон вне границ (Ошибка разработчика) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `20008`<br>`devUnsupportedOperation` | Операция не поддерживается в текущем контексте (Ошибка разработчика) | <ul><li>`primaryKey`: `null`</li><li>`target`: Целевая таблица/ресурс (при наличии)</li><li>`operation`: Имя метода (при наличии)</li></ul> |
  | `22001`<br>`devTableNotFound` | Таблица не найдена (Ошибка разработчика) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22003`<br>`devIndexNotFound` | Индекс не найден (Ошибка разработчика) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22004`<br>`devSpaceNotFound` | Пространство (Space) не найдено (Ошибка разработчика) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23001`<br>`devLargeScaleOperationBypassRequired` | Требуется пропуск деталей для предотвращения OOM (Ошибка разработчика) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `24001`<br>`devEngineIncompatible` | **Критично**: Версия ядра несовместима | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50003`<br>`sysMigrationBatchExecutionFailed` | Сбой выполнения пакета миграции (Системная ошибка) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51001`<br>`sysTimeoutLockAcquisition` | Таймаут получения блокировки (Системная ошибка) | <ul><li>`primaryKey`: Целевой ключ (при наличии)</li><li>`target`: ID ресурса блокировки</li><li>`operation`: `"acquire"`</li></ul> |
  | `51002`<br>`sysTimeout` | Таймаут операции (Системная ошибка) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51003`<br>`sysCancellation` | Операция была отменена (Системная ошибка) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52001`<br>`sysResourceExhaustedMemory` | Ресурсы памяти исчерпаны (Системная ошибка) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52002`<br>`sysResourceExhausted` | Системные ресурсы исчерпаны, например диск заполнен (Системная ошибка) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `53001`<br>`sysIoNotFound` | Физический файл или путь не существует (Системная ошибка) | <ul><li>`primaryKey`: `null`</li><li>`target`: Путь к файлу или папке</li><li>`operation`: Операция ввода-вывода</li></ul> |
  | `53002`<br>`sysIoPermissionDenied` | Доступ к файлу запрещен (Системная ошибка) | <ul><li>`primaryKey`: `null`</li><li>`target`: Путь к файлу</li><li>`operation`: Операция ввода-вывода</li></ul> |
  | `53003`<br>`sysIoDiskFull` | Диск заполнен или превышена квота хранилища (Системная ошибка) | <ul><li>`primaryKey`: `null`</li><li>`target`: Путь к файлу</li><li>`operation`: Операция ввода-вывода</li></ul> |
  | `53004`<br>`sysIoFileLocked` | Файл заблокирован или используется другим процессом (Системная ошибка) | <ul><li>`primaryKey`: `null`</li><li>`target`: Путь к файлу</li><li>`operation`: Операция ввода-вывода</li></ul> |
  | `53005`<br>`sysIoDeviceFault` | Сбой устройства хранения или носителя (Системная ошибка) | <ul><li>`primaryKey`: `null`</li><li>`target`: Путь к файлу</li><li>`operation`: Операция ввода-вывода</li></ul> |
  | `53006`<br>`sysIoWebStorageUnavailable` | Web IndexedDB или хранилище недоступно (Системная ошибка) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ресурс IndexedDB</li><li>`operation`: Операция ввода-вывода</li></ul> |
  | `53007`<br>`sysBackupCorrupted` | Пакет резервной копии поврежден или отсутствуют метаданные (Системная ошибка) | <ul><li>`primaryKey`: `null`</li><li>`target`: Путь к резервной копии</li><li>`operation`: Чтение/запись резервной копии</li></ul> |
  | `53008`<br>`sysIoDataCorrupted` | Файл данных базы данных поврежден или не удалась контрольная сумма (Системная ошибка) | <ul><li>`primaryKey`: `null`</li><li>`target`: Путь к файлу данных</li><li>`operation`: Операция ввода-вывода</li></ul> |
  | `53009`<br>`sysInvalidDataFormat` | Сбой форматирования или синтаксического анализа потока данных (Системная ошибка) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ключ потока данных</li><li>`operation`: `"decode"` / `"deserialize"`</li></ul> |
  | `53099`<br>`sysIoGeneric` | Общая ошибка ввода-вывода системы (Системная ошибка) | <ul><li>`primaryKey`: `null`</li><li>`target`: Путь к файлу</li><li>`operation`: Операция ввода-вывода</li></ul> |
  | `99001`<br>`engError` | Ошибка ядра (Ошибка ядра) | <ul><li>`primaryKey`: `null`</li></ul> |

- **Пример JSON** (Ошибка таблицы «таблица не найдена»):
  ```json
  {
    "index": 0,
    "code": 22001,
    "codeKey": "DEV_NOT_FOUND_TABLE",
    "message": "Table \"orders\" not found in database metadata schema.",
    "primaryKey": null
  }
  ```

---

## 5. Рекомендации по Разрешению Состояний и Обработке Исключений (Примеры на Dart/Flutter)

В ToStore все основные операции записи (Insert, Update, Delete) возвращают `DbResult`. Запросы возвращают `QueryResult`, а операции транзакций возвращают `TransactionResult`. Ошибки структурной конфигурации генерируют исключение `DbException`.

Ниже приведены примеры кода, иллюстрирующие, как клиентские приложения должны получать, анализировать и корректно обрабатывать состояния базы данных:

### 5.1 Обработка Ответов Операций Записи (`DbResult`)

```dart
import 'package:tostore/tostore.dart';

void handleDatabaseWriteResult(DbResult result) {
  // 1. Мгновенно проверяем, завершилась ли запись полностью без ошибок
  if (!result.hasErrors) {
    print("Все операции записи выполнены успешно. Затронуто: ${result.successCount}");

    // Для записи одной строки получаем ключ напрямую без обхода статусов
    if (result.firstPrimaryKey != null) {
      print("Первичный ключ первой успешной записи: ${result.firstPrimaryKey}");
    }
  } else {
    print("🛑 Обнаружена ошибка. Успешно: ${result.successCount}, Сбой: ${result.failedCount}");
    print("Первая ошибка: ${result.firstType.codeKey} (${result.firstType.code})");

    // 2. Обходим статусы (индекс сопоставляется 1:1 с входным пакетным массивом)
    for (final status in result.statuses) {
      final int idx = status.index;

      // 3. Сопоставление с образцом подклассов для маршрутизации логики обработки
      if (status is SuccessStatus) {
        print("Индекс [$idx] Успешно. Первичный ключ: ${status.primaryKey}");
      } 
      else if (status is ConstraintStatus) {
        // Обработка нарушения ограничений (первичный ключ, уникальность, проверочное ограничение, внешний ключ и т. д.)
        print("Индекс [$idx] Нарушение ограничения! Таблица: ${status.tableName}, Столбцы: ${status.fields}");
        print("Конфликтующие значения: ${status.conflictingKeys}, PK: ${status.primaryKey}");
        print("Сообщение об ошибке: ${status.message}");
      } 
      else if (status is InvalidArgumentStatus) {
        // Обработка ошибок параметров
        print("Индекс [$idx] Недопустимый параметр! Параметр: ${status.parameterName}, Переданное значение: ${status.passedValue}");
      } 
      else if (status is GeneralStatus) {
        // Обработка таймаута блокировки, переполнения диска, системного ввода-вывода и т. д.
        print("Индекс [$idx] Общее исключение! Код: ${status.code} (${status.codeKey})");
        print("Сообщение: ${status.message}");
      }
    }
  }
}
```

### 5.2 Перехват Ошибок Схемы Таблицы и Операций (`DbException`)

При создании таблицы (`createTable`) или изменении схемы (`updateSchema`), либо в случаях, когда определения схемы не проходят проверки на уровне кода, ToStore генерирует исключение `DbException` в рабочей среде:

```dart
try {
  // Открытие базы данных с обновлениями схемы
  await ToStore.open(schemas: [..]);
} on DbException catch (e) {
  print("❌ Фатальное исключение базы данных! Агрегированная ошибка: \n${e.message}");
  
  // Обход отдельных статусов в исключении
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // Проблемы валидатора схемы
      print("Сбой валидации схемы! Таблица: ${status.tableName}");
      if (status.field != null) {
        print("Нарушающее правила поле: ${status.field}, Недопустимая конфигурация: ${status.wrongValue}");
      }
    } else {
      print("Диагностика: [${status.codeKey}] (Код ${status.code}): ${status.message}");
    }
  }
}
```

### 5.3 Обработка Операций Запроса (`QueryResult`) и Управления Транзакциями (`TransactionResult`)

- **Для Запросов**:
  ```dart
  final queryResult = await db.query('users').where('age', '>', 18);
  if (queryResult.hasErrors) {
    // Обработка исключений запроса (например, неверный курсор, отсутствие таблицы)
    print("Запрос отклонен! Код: ${queryResult.type.code}, Сообщение: ${queryResult.message}");
  } else {
    // Запрос выполнен успешно
    final List<Map<String, dynamic>> users = queryResult.data;
    print("Получено записей: ${users.length}. Есть еще данные: ${queryResult.hasMore}");
  }
  ```
- **Для Транзакций**:
  ```dart
  final txnResult = await db.transaction(() async {
    await db.insert('users', newUser);
  });

  if (txnResult.hasErrors) {
    print("Транзакция откачена! TxId: ${txnResult.txId}");
    // Извлечение детальных сбоев отдельных подопераций
    for (final status in txnResult.statuses) {
      if (status.type != ResultType.success) {
        print("Причина сбоя: [${status.codeKey}] ${status.message}");
      }
    }
  }
  ```

---

## 6. Полный Справочник Кодов Состояний Листьев и Семантических Идентификаторов

Точную маршрутизацию и разбор состояний см. в таблице ниже:

| Код Состояния (Code) | Идентификатор (CodeKey) | Enum в Памяти (ResultType) | Категория | Описание |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `ResultType.success` | Успех | Операция выполнена успешно |
| **10000** | `BIZ_VALIDATION_FAILED` | `ResultType.bizValidationFailed` | Бизнес-ошибка | Ошибка валидации формата или диапазона данных |
| **10001** | `BIZ_NOT_NULL_VIOLATION` | `ResultType.bizNotNullViolation` | Бизнес-ошибка | Нарушение ограничения NOT NULL |
| **10002** | `BIZ_VALIDATION_TYPE_CAST` | `ResultType.bizTypeCastFailed` | Бизнес-ошибка | Ошибка преобразования или приведения типов данных |
| **11001** | `BIZ_CONSTRAINT_PRIMARY_KEY` | `ResultType.bizPrimaryKeyViolation` | Бизнес-ошибка | Конфликт первичного ключа (уже существует) |
| **11002** | `BIZ_CONSTRAINT_UNIQUE` | `ResultType.bizUniqueViolation` | Бизнес-ошибка | Нарушение ограничения уникальности |
| **11003** | `BIZ_CONSTRAINT_FOREIGN_KEY` | `ResultType.bizForeignKeyViolation` | Бизнес-ошибка | Нарушение ограничения внешнего ключа (Общее) |
| **11004** | `BIZ_CONSTRAINT_CHECK` | `ResultType.bizCheckViolation` | Бизнес-ошибка | Нарушение проверочного ограничения (CHECK) |
| **11005** | `BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST` | `ResultType.bizForeignKeyParentNotExist` | Бизнес-ошибка | Ссылочный родительский ключ не существует |
| **11006** | `BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT` | `ResultType.bizForeignKeyChildRestrict` | Бизнес-ошибка | Удаление/обновление ограничено дочерними записями |
| **11007** | `BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH` | `ResultType.bizForeignKeyCompositeMismatch` | Бизнес-ошибка | Неполные составные значения внешнего ключа |
| **11008** | `BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH` | `ResultType.bizForeignKeyTypeMismatch` | Бизнес-ошибка | Несоответствие типов внешнего ключа |
| **11009** | `BIZ_CONSTRAINT_MAX_LENGTH` | `ResultType.bizValueExceedsMaxLength` | Бизнес-ошибка | Длина значения превышает ограничение схемы |
| **11010** | `BIZ_CONSTRAINT_MIN_LENGTH` | `ResultType.bizValueLessThanMinLength` | Бизнес-ошибка | Длина значения меньше ограничения схемы |
| **11011** | `BIZ_CONSTRAINT_MIN_VALUE` | `ResultType.bizValueLessThanMinValue` | Бизнес-ошибка | Числовое значение меньше ограничения схемы |
| **11012** | `BIZ_CONSTRAINT_MAX_VALUE` | `ResultType.bizValueExceedsMaxValue` | Бизнес-ошибка | Числовое значение превышает ограничение схемы |
| **12002** | `BIZ_NOT_FOUND_RECORD` | `ResultType.bizRecordNotFound` | Бизнес-ошибка | Ресурс не существует / Запись не найдена |
| **20001** | `DEV_INVALID_ARGUMENT_FORMAT` | `ResultType.devInvalidArgumentFormat` | Ошибка разработчика | Ошибка формата аргумента |
| **20002** | `DEV_INVALID_ARGUMENT_TYPE` | `ResultType.devInvalidArgumentType` | Ошибка разработчика | Несоответствие типа аргумента |
| **20003** | `DEV_INVALID_ARGUMENT_MISSING` | `ResultType.devInvalidArgumentMissing` | Ошибка разработчика | Обязательный аргумент отсутствует |
| **20005** | `DEV_INVALID_PRIMARY_KEY_FORMAT` | `ResultType.devInvalidPrimaryKeyFormat` | Ошибка разработчика | Недопустимый формат первичного ключа |
| **20007** | `DEV_INDEX_OUT_OF_BOUNDS` | `ResultType.devIndexOutOfBounds` | Ошибка разработчика | Индекс или диапазон вне границ |
| **20008** | `DEV_UNSUPPORTED_OPERATION` | `ResultType.devUnsupportedOperation` | Ошибка разработчика | Операция не поддерживается в текущем контексте |
| **20010** | `DEV_VECTOR_DIMENSION_MISMATCH` | `ResultType.devVectorDimensionMismatch` | Ошибка разработчика | Несоответствие размерностей векторов |
| **20011** | `DEV_INDEX_FIELD_MISSING` | `ResultType.devIndexFieldMissing` | Ошибка разработчика | В записи для курсора отсутствует обязательное поле индекса |
| **20201** | `DEV_INVALID_CURSOR_PAGINATION` | `ResultType.devInvalidCursorPagination` | Ошибка разработчика | Пагинация курсора и смещение взаимно исключают друг друга |
| **20202** | `DEV_INVALID_CURSOR_TABLE` | `ResultType.devInvalidCursorTable` | Ошибка разработчика | Курсор не соответствует целевой таблице |
| **20203** | `DEV_INVALID_CURSOR_SIGNATURE` | `ResultType.devInvalidCursorSignature` | Ошибка разработчика | Несоответствие подписи курсора (изменено) |
| **20204** | `DEV_INVALID_CURSOR_ORDERBY` | `ResultType.devInvalidCursorOrderBy` | Ошибка разработчика | Конфигурация orderBy курсора недопустима или не соответствует запросу |
| **20205** | `DEV_INVALID_CURSOR_MODE` | `ResultType.devInvalidCursorMode` | Ошибка разработчика | Несоответствие режима токена курсора |
| **20206** | `DEV_INVALID_CURSOR_PAYLOAD` | `ResultType.devInvalidCursorPayload` | Ошибка разработчика | Недопустимая полезная нагрузка курсора (не поддается декодированию) |
| **20301** | `DEV_INVALID_QUERY_SELECT_FIELD` | `ResultType.devInvalidQuerySelectField` | Ошибка разработчика | Поле выборки запроса должно быть String или QueryAggregation |
| **20302** | `DEV_INVALID_QUERY_FOREIGN_KEY_JOIN` | `ResultType.devInvalidQueryForeignKeyJoin` | Ошибка разработчика | Отсутствует связь по внешнему ключу для автоматического объединения |
| **20303** | `DEV_INVALID_QUERY_FIELD_ALIAS` | `ResultType.devInvalidQueryFieldAlias` | Ошибка разработчика | Недопустимый формат псевдонима поля запроса |
| **20304** | `DEV_INVALID_EXPRESSION` | `ResultType.devInvalidExpression` | Ошибка разработчика | Недопустимая конфигурация выражения или исключение выполнения |
| **22001** | `DEV_NOT_FOUND_TABLE` | `ResultType.devTableNotFound` | Ошибка разработчика | Таблица не найдена |
| **22003** | `DEV_NOT_FOUND_INDEX` | `ResultType.devIndexNotFound` | Ошибка разработчика | Индекс не найден |
| **22004** | `DEV_NOT_FOUND_SPACE` | `ResultType.devSpaceNotFound` | Ошибка разработчика | Пространство не найдено |
| **22005** | `DEV_NOT_FOUND_FIELD` | `ResultType.devFieldNotFound` | Ошибка разработчика | Поле не найдено |
| **23001** | `DEV_LARGE_SCALE_OPERATION_REQUIRED_BYPASS` | `ResultType.devLargeScaleOperationBypassRequired` | Ошибка разработчика | Крупномасштабная операция требует пропуска деталей для предотвращения OOM |
| **24001** | `DEV_ENGINE_INCOMPATIBLE` | `ResultType.devEngineIncompatible` | Ошибка разработчика | **Критично**: Версия ядра несовместима |
| **30000** | `DEV_INVALID_SCHEMA` | `ResultType.devInvalidSchema` | Ошибка разработчика | Недопустимое определение схемы таблицы |
| **30001** | `DEV_INVALID_SCHEMA_TABLE_NAME` | `ResultType.devInvalidSchemaTableName` | Ошибка разработчика | Ошибка валидации имени таблицы |
| **30002** | `DEV_INVALID_SCHEMA_FIELD_NAME` | `ResultType.devInvalidSchemaFieldName` | Ошибка разработчика | Ошибка валидации имени поля |
| **30003** | `DEV_INVALID_SCHEMA_PRIMARY_KEY` | `ResultType.devInvalidSchemaPrimaryKey` | Ошибка разработчика | Ошибка валидации первичного ключа |
| **30004** | `DEV_INVALID_SCHEMA_INDEX_LIMIT` | `ResultType.devInvalidSchemaIndexLimit` | Ошибка разработчика | Ошибка валидации количества индексов |
| **30005** | `DEV_SCHEMA_TABLE_EXISTS` | `ResultType.devSchemaTableExists` | Ошибка разработчика | Таблица уже существует |
| **30006** | `DEV_SCHEMA_FIELD_EXISTS` | `ResultType.devSchemaFieldExists` | Ошибка разработчика | Поле уже существует |
| **30007** | `DEV_SCHEMA_INDEX_EXISTS` | `ResultType.devSchemaIndexExists` | Ошибка разработчика | Индекс уже существует |
| **30008** | `DEV_INVALID_SCHEMA_FOREIGN_KEY` | `ResultType.devInvalidSchemaForeignKey` | Ошибка разработчика | Недопустимое определение внешнего ключа |
| **30009** | `DEV_INVALID_SCHEMA_SPACE_MISMATCH` | `ResultType.devInvalidSchemaSpaceMismatch` | Ошибка разработчика | Глобальное/Специфичное для пространства несоответствие границ |
| **30010** | `DEV_MIGRATION_NOT_ALLOWED_WITH_DATA` | `ResultType.devMigrationNotAllowedWithData` | Ошибка разработчика | Миграция требует изменения данных и не была явно разрешена |
| **30011** | `DEV_MIGRATION_UNSAFE_TYPE_CONVERSION` | `ResultType.devMigrationUnsafeTypeConversion` | Ошибка разработчика | Неподдерживаемое изменение типа данных для поля |
| **30013** | `DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD` | `ResultType.devMigrationCannotAddNonNullField` | Ошибка разработчика | Добавление non-nullable поля без значения по умолчанию не допускается |
| **30014** | `DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED` | `ResultType.devMigrationNullableToNonNullNotAllowed` | Ошибка разработчика | Изменение поля с nullable на non-nullable не допускается |
| **30015** | `DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED` | `ResultType.devMigrationUniqueTighteningNotAllowed` | Ошибка разработчика | Ужесточение до UNIQUE не допускается |
| **30016** | `DEV_INVALID_SCHEMA_TTL_CONFIG` | `ResultType.devInvalidSchemaTtlConfig` | Ошибка разработчика | Ошибка валидации конфигурации TTL |
| **30017** | `DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME` | `ResultType.devInvalidSchemaDuplicateFieldName` | Ошибка разработчика | Дублирующееся имя поля в схеме таблицы |
| **30018** | `DEV_INVALID_SCHEMA_INDEX_FIELD` | `ResultType.devInvalidSchemaIndexField` | Ошибка разработчика | Индекс ссылается на несуществующее поле |
| **50001** | `SYS_TRANSACTION_ABORTED` | `ResultType.sysTransactionAborted` | Системная ошибка | Транзакция прервана |
| **50002** | `SYS_TRANSACTION_CONFLICT` | `ResultType.sysTransactionConflict` | Системная ошибка | Конфликт транзакции |
| **50003** | `SYS_MIGRATION_BATCH_EXECUTION_FAILED` | `ResultType.sysMigrationBatchExecutionFailed` | Системная ошибка | **Критично**: Сбой выполнения пакета миграции |
| **51001** | `SYS_TIMEOUT_LOCK_ACQUISITION` | `ResultType.sysTimeoutLockAcquisition` | Системная ошибка | Таймаут получения блокировки |
| **51002** | `SYS_TIMEOUT` | `ResultType.sysTimeout` | Системная ошибка | Таймаут операции |
| **51003** | `SYS_CANCELLATION` | `ResultType.sysCancellation` | Системная ошибка | Операция была отменена |
| **52001** | `SYS_RESOURCE_EXHAUSTED_MEMORY` | `ResultType.sysResourceExhaustedMemory` | Системная ошибка | **Критично**: Ресурсы памяти исчерпаны |
| **52002** | `SYS_RESOURCE_EXHAUSTED` | `ResultType.sysResourceExhausted` | Системная ошибка | **Критично**: Системные ресурсы исчерпаны |
| **53001** | `SYS_IO_NOT_FOUND` | `ResultType.sysIoNotFound` | Системная ошибка | Физический файл или путь не существует |
| **53002** | `SYS_IO_PERMISSION_DENIED` | `ResultType.sysIoPermissionDenied` | Системная ошибка | Доступ к файлу запрещен |
| **53003** | `SYS_IO_DISK_FULL` | `ResultType.sysIoDiskFull` | Системная ошибка | **Критично**: Диск заполнен или превышена квота хранилища |
| **53004** | `SYS_IO_FILE_LOCKED` | `ResultType.sysIoFileLocked` | Системная ошибка | Файл заблокирован или используется другим процессом |
| **53005** | `SYS_IO_DEVICE_FAULT` | `ResultType.sysIoDeviceFault` | Системная ошибка | **Критично**: Сбой устройства хранения или носителя |
| **53006** | `SYS_IO_WEB_STORAGE_UNAVAILABLE` | `ResultType.sysIoWebStorageUnavailable` | Системная ошибка | Web IndexedDB или хранилище недоступно |
| **53007** | `SYS_BACKUP_CORRUPTED` | `ResultType.sysBackupCorrupted` | Системная ошибка | Пакет резервной копии поврежден или отсутствуют метаданные |
| **53008** | `SYS_IO_DATA_CORRUPTED` | `ResultType.sysIoDataCorrupted` | Системная ошибка | **Критично**: Файл данных базы данных поврежден или не удалась контрольная сумма |
| **53009** | `SYS_INVALID_DATA_FORMAT` | `ResultType.sysInvalidDataFormat` | Системная ошибка | Сбой форматирования или синтаксического анализа потока данных |
| **53099** | `SYS_IO_GENERIC` | `ResultType.sysIoGeneric` | Системная ошибка | Общая ошибка ввода-вывода системы |
| **99001** | `ENG_ERROR` | `ResultType.engError` | Ошибка ядра | Ошибка ядра |
