# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | Русский | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

ToStore - это высокопроизводительный движок хранения данных, специально разработанный для мобильных приложений. Реализованный на чистом Dart, он достигает исключительной производительности благодаря индексированию B+ деревьев и интеллектуальным стратегиям кэширования. Его мультипространственная архитектура решает проблемы изоляции пользовательских данных и совместного использования глобальных данных, в то время как корпоративные функции, такие как защита транзакций, автоматическое восстановление, инкрементное резервное копирование и нулевые затраты при простое, обеспечивают надежное хранение данных для мобильных приложений.

## Почему ToStore?

- 🚀 **Максимальная производительность**: 
  - Индексирование B+ деревьев с интеллектуальной оптимизацией запросов
  - Интеллектуальная стратегия кэширования с миллисекундным откликом
  - Неблокирующее параллельное чтение/запись со стабильной производительностью
- 🔄 **Умная эволюция схем**: 
  - Автоматическое обновление структуры таблиц через схемы
  - Без ручных миграций версия за версией
  - Цепочечный API для сложных изменений
  - Обновления без простоев
- 🎯 **Простота использования**: 
  - Плавный цепочечный дизайн API
  - Поддержка SQL/Map стиля запросов
  - Умный вывод типов с полными подсказками кода
  - Готов к использованию без сложной настройки
- 🔄 **Инновационная архитектура**: 
  - Изоляция данных в мультипространстве, идеально для мультипользовательских сценариев
  - Совместное использование глобальных данных решает проблемы синхронизации
  - Поддержка вложенных транзакций
  - Загрузка пространства по требованию минимизирует использование ресурсов
  - Автоматические операции с данными (upsert)
- 🛡️ **Корпоративная надежность**: 
  - Защита транзакций ACID обеспечивает согласованность данных
  - Механизм инкрементного резервного копирования с быстрым восстановлением
  - Проверка целостности данных с автоматическим исправлением

## Быстрый старт

Базовое использование:

```dart
// Инициализация базы данных
final db = ToStore(
  version: 2, // каждый раз при увеличении номера версии структура таблицы в schemas будет автоматически создана или обновлена
  schemas: [
    // Просто определите вашу последнюю схему, ToStore автоматически обрабатывает обновление
    const TableSchema(
      name: 'users',
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
  ],
  // сложные обновления и миграции можно выполнить с помощью db.updateSchema
  // если количество таблиц небольшое, рекомендуется напрямую настроить структуру в schemas для автоматического обновления
  onUpgrade: (db, oldVersion, newVersion) async {
    if (oldVersion == 1) {
      await db.updateSchema('users')
          .addField("fans", type: DataType.array, comment: "подписчики")
          .addIndex("follow", fields: ["follow", "name"])
          .removeField("last_login")
          .modifyField('email', unique: true)
          .renameField("last_login", "last_login_time");
    }
  },
);
await db.initialize(); // Опционально, гарантирует полную инициализацию базы данных перед операциями

// Вставка данных
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// Обновление данных
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Удаление данных
await db.delete('users').where('id', '!=', 1);

// Цепочка запросов со сложными условиями
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Подсчет записей
final count = await db.query('users').count();

// Запрос в стиле SQL
final users = await db.queryBySql(
  'users',
  where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)',
  limit: 10
);

// Запрос в стиле Map
final users = await db.queryByMap(
  'users',
  where: {
    'age': {'>=': 30},
    'name': {'like': '%John%'},
  },
  orderBy: ['age'],
  limit: 10,
);

// Пакетная вставка
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## Мультипространственная архитектура

Мультипространственная архитектура ToStore делает управление многопользовательскими данными простым:

```dart
// Переключение на пространство пользователя
await db.switchBaseSpace(spaceName: 'user_123');

// Запрос данных пользователя
final followers = await db.query('followers');

// Установка или обновление данных ключ-значение, isGlobal: true означает глобальные данные
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Получение глобальных данных ключ-значение
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```


### Автоматическое Хранение Данных

```dart
// Автоматическое хранение с использованием условия
await db.upsert('users', {'name': 'John'})
  .where('email', '=', 'john@example.com');

// Автоматическое хранение с использованием первичного ключа
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});
``` 

## Производительность

В сценариях высокой конкурентности, включая пакетную запись, случайное чтение/запись и условные запросы, ToStore демонстрирует исключительную производительность, значительно превосходя другие основные базы данных, доступные для Dart/Flutter.

## Дополнительные функции

- 💫 Элегантный цепочечный API
- 🎯 Умный вывод типов
- 📝 Полные подсказки кода
- 🔐 Автоматическое инкрементное резервное копирование
- 🛡️ Проверка целостности данных
- 🔄 Автоматическое восстановление после сбоев
- 📦 Умное сжатие данных
- 📊 Автоматическая оптимизация индексов
- 💾 Многоуровневая стратегия кэширования

Наша цель - не просто создать еще одну базу данных. ToStore извлечен из фреймворка Toway для предоставления альтернативного решения. Если вы разрабатываете мобильные приложения, мы рекомендуем использовать фреймворк Toway, который предлагает полную экосистему разработки Flutter. С Toway вам не придется напрямую работать с базой данных - запросы данных, загрузка, хранение, кэширование и отображение данных обрабатываются фреймворком автоматически.
Для получения дополнительной информации о фреймворке Toway посетите [Репозиторий Toway](https://github.com/tocreator/toway)

## Документация

Посетите нашу [Wiki](https://github.com/tocreator/tostore) для подробной документации.

## Поддержка и обратная связь

- Отправить проблему: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Присоединиться к обсуждениям: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Внести вклад: [Руководство по участию](CONTRIBUTING.md)

## Лицензия

Этот проект лицензирован по лицензии MIT - подробности см. в файле [LICENSE](LICENSE).

---

<p align="center">Если вы находите ToStore полезным, пожалуйста, поставьте нам ⭐️</p> 