# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | Español | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

ToStore es un motor de almacenamiento de alto rendimiento diseñado específicamente para aplicaciones móviles. Implementado en Dart puro, logra un rendimiento excepcional a través de indexación B+ tree y estrategias de caché inteligentes. Su arquitectura multiespacio resuelve los desafíos de aislamiento de datos de usuario y compartición de datos globales, mientras que características de nivel empresarial como protección de transacciones, reparación automática, respaldo incremental y cero costos en inactividad proporcionan almacenamiento de datos confiable para aplicaciones móviles.

## ¿Por qué ToStore?

- 🚀 **Rendimiento Máximo**: 
  - Indexación B+ tree con optimización inteligente de consultas
  - Estrategia de caché inteligente con respuesta en milisegundos
  - Lectura/escritura concurrente sin bloqueo con rendimiento estable
- 🔄 **Evolución Inteligente de Esquemas**: 
  - Actualización automática de estructura de tablas a través de esquemas
  - Sin migraciones manuales versión por versión
  - API encadenable para cambios complejos
  - Actualizaciones sin tiempo de inactividad
- 🎯 **Fácil de Usar**: 
  - Diseño de API encadenable fluido
  - Soporte para consultas estilo SQL/Map
  - Inferencia de tipos inteligente con sugerencias de código completas
  - Listo para usar sin configuración compleja
- 🔄 **Arquitectura Innovadora**: 
  - Aislamiento de datos multiespacio, perfecto para escenarios multiusuario
  - Compartición de datos globales resuelve desafíos de sincronización
  - Soporte para transacciones anidadas
  - Carga de espacio bajo demanda minimiza uso de recursos
  - Operaciones automáticas de datos (upsert)
- 🛡️ **Fiabilidad Empresarial**: 
  - Protección de transacciones ACID garantiza consistencia de datos
  - Mecanismo de respaldo incremental con recuperación rápida
  - Verificación de integridad de datos con reparación automática

## Inicio Rápido

Uso básico:

```dart
// Inicializar base de datos
final db = ToStore(
  version: 2, // cada vez que se incrementa el número de versión, la estructura de tabla en schemas se creará o actualizará automáticamente
  schemas: [
    // Simplemente define tu esquema más reciente, ToStore maneja la actualización automáticamente
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
  // actualizaciones y migraciones complejas pueden hacerse usando db.updateSchema
  // si el número de tablas es pequeño, se recomienda ajustar directamente la estructura en schemas para actualización automática
  onUpgrade: (db, oldVersion, newVersion) async {
    if (oldVersion == 1) {
      await db.updateSchema('users')
          .addField("fans", type: DataType.array, comment: "seguidores")
          .addIndex("follow", fields: ["follow", "name"])
          .removeField("last_login")
          .modifyField('email', unique: true)
          .renameField("last_login", "last_login_time");
    }
  },
);
await db.initialize(); // Opcional, asegura que la base de datos esté completamente inicializada antes de operaciones

// Insertar datos
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// Actualizar datos
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Eliminar datos
await db.delete('users').where('id', '!=', 1);

// Consulta encadenada con condiciones complejas
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Contar registros
final count = await db.query('users').count();

// Consulta estilo SQL
final users = await db.queryBySql(
  'users',
  where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)',
  limit: 10
);

// Consulta estilo Map
final users = await db.queryByMap(
  'users',
  where: {
    'age': {'>=': 30},
    'name': {'like': '%John%'},
  },
  orderBy: ['age'],
  limit: 10,
);

// Inserción por lotes
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## Arquitectura Multi-espacio

La arquitectura multi-espacio de ToStore hace que la gestión de datos multi-usuario sea sencilla:

```dart
// Cambiar a espacio de usuario
await db.switchBaseSpace(spaceName: 'user_123');

// Consultar datos de usuario
final followers = await db.query('followers');

// Establecer o actualizar datos clave-valor, isGlobal: true significa datos globales
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Obtener datos clave-valor globales
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

### Almacenamiento Automático de Datos

```dart
// Almacenamiento automático usando condición
await db.upsert('users', {'name': 'John'})
  .where('email', '=', 'john@example.com');

// Almacenamiento automático usando clave primaria
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});
``` 

## Rendimiento

En escenarios de alta concurrencia incluyendo escrituras por lotes, lecturas/escrituras aleatorias y consultas condicionales, ToStore demuestra un rendimiento excepcional, superando ampliamente a otras bases de datos principales disponibles para Dart/Flutter.

## Más Características

- 💫 API encadenable elegante
- 🎯 Inferencia de tipos inteligente
- 📝 Sugerencias de código completas
- 🔐 Respaldo incremental automático
- 🛡️ Validación de integridad de datos
- 🔄 Recuperación automática de fallos
- 📦 Compresión inteligente de datos
- 📊 Optimización automática de índices
- 💾 Estrategia de caché por niveles

Nuestro objetivo no es solo crear otra base de datos. ToStore es extraído del framework Toway para proporcionar una solución alternativa. Si estás desarrollando aplicaciones móviles, recomendamos usar el framework Toway, que ofrece un ecosistema completo de desarrollo Flutter. Con Toway, no necesitarás tratar directamente con la base de datos subyacente - las solicitudes de datos, carga, almacenamiento, caché y visualización son manejados automáticamente por el framework.
Para más información sobre el framework Toway, visita el [Repositorio Toway](https://github.com/tocreator/toway)

## Documentación

Visita nuestra [Wiki](https://github.com/tocreator/tostore) para documentación detallada.

## Soporte y Retroalimentación

- Enviar Issues: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Unirse a Discusiones: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Contribuir: [Guía de Contribución](CONTRIBUTING.md)

## Licencia

Este proyecto está licenciado bajo la Licencia MIT - ver el archivo [LICENSE](LICENSE) para más detalles.

---

<p align="center">Si encuentras útil ToStore, por favor danos una ⭐️</p> 