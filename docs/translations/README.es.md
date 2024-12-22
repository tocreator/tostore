# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | Español | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

ToStore es un motor de almacenamiento de alto rendimiento diseñado específicamente para aplicaciones móviles. Implementado puramente en Dart, logra un rendimiento excepcional a través de indexación B+ tree y estrategias de caché inteligentes. Su arquitectura multi-espacio resuelve los desafíos de aislamiento de datos de usuario y compartición de datos globales, mientras que características de nivel empresarial como protección de transacciones, reparación automática, respaldo incremental y costo cero en inactividad aseguran un almacenamiento de datos confiable para aplicaciones móviles.

## ¿Por qué ToStore?

- 🚀 **Rendimiento Máximo**: 
  - Indexación B+ tree con optimización inteligente de consultas
  - Estrategia de caché inteligente con respuesta en milisegundos
  - Lectura/escritura concurrente sin bloqueo con rendimiento estable
- 🎯 **Fácil de Usar**: 
  - Diseño de API fluido y encadenable
  - Soporte para consultas estilo SQL/Map
  - Inferencia de tipos inteligente con sugerencias de código completas
  - Sin configuración, listo para usar
- 🔄 **Arquitectura Innovadora**: 
  - Aislamiento de datos multi-espacio, perfecto para escenarios multi-usuario
  - Compartición de datos globales resuelve desafíos de sincronización
  - Soporte para transacciones anidadas
  - Carga de espacio bajo demanda minimiza el uso de recursos
- 🛡️ **Fiabilidad de Nivel Empresarial**: 
  - Protección de transacciones ACID asegura consistencia de datos
  - Mecanismo de respaldo incremental con recuperación rápida
  - Validación de integridad de datos con reparación automática de errores

## Inicio Rápido

Uso básico:

```dart
// Inicializar base de datos
final db = ToStore(
  version: 1,
  onCreate: (db) async {
    // Crear tabla
    await db.createTable(
      'users',
      TableSchema(
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
    );
  },
);
await db.initialize(); // Opcional, asegura que la base de datos esté inicializada antes de operaciones

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