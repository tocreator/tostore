# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | Español | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

Tostore es un motor de base de datos con arquitectura distribuida multiplataforma que se integra profundamente en tu proyecto. Su modelo de procesamiento de datos inspirado en redes neuronales implementa una gestión de datos similar al cerebro. Los mecanismos de paralelismo multi-partición y la topología de interconexión de nodos crean una red de datos inteligente, mientras que el procesamiento paralelo con Isolate aprovecha al máximo las capacidades multi-núcleo. Con varios algoritmos de clave primaria distribuidos y extensión ilimitada de nodos, puede servir como una capa de datos para infraestructuras de computación distribuida y entrenamiento de datos a gran escala, permitiendo un flujo de datos fluido desde dispositivos periféricos hasta servidores en la nube. Características como la detección precisa de cambios de esquema, migración inteligente, cifrado ChaCha20Poly1305 y arquitectura multi-espacio soportan perfectamente varios escenarios de aplicación, desde aplicaciones móviles hasta sistemas del lado del servidor.

## ¿Por qué elegir Tostore?

### 1. Procesamiento Paralelo de Particiones vs. Almacenamiento en Archivo Único
| Tostore | Bases de Datos Tradicionales |
|:---------|:-----------|
| ✅ Mecanismo de particionamiento inteligente, datos distribuidos en múltiples archivos de tamaño adecuado | ❌ Almacenamiento en un único archivo de datos, degradación lineal del rendimiento con el crecimiento de datos |
| ✅ Lee solo los archivos de partición relevantes, rendimiento de consulta desacoplado del volumen total de datos | ❌ Necesidad de cargar todo el archivo de datos, incluso para consultar un solo registro |
| ✅ Mantiene tiempos de respuesta de milisegundos incluso con volúmenes de datos a nivel de TB | ❌ Aumento significativo en la latencia de lectura/escritura en dispositivos móviles cuando los datos exceden 5MB |
| ✅ Consumo de recursos proporcional a la cantidad de datos consultados, no al volumen total de datos | ❌ Dispositivos con recursos limitados sujetos a presión de memoria y errores OOM |
| ✅ La tecnología Isolate permite un verdadero procesamiento paralelo multi-núcleo | ❌ Un solo archivo no puede procesarse en paralelo, desperdicio de recursos de CPU |

### 2. Integración Incorporada vs. Almacenes de Datos Independientes
| Tostore | Bases de Datos Tradicionales |
|:---------|:-----------|
| ✅ Utiliza el lenguaje Dart, se integra perfectamente con proyectos Flutter/Dart | ❌ Requiere aprender SQL o lenguajes de consulta específicos, aumentando la curva de aprendizaje |
| ✅ El mismo código soporta frontend y backend, sin necesidad de cambiar la pila tecnológica | ❌ Frontend y backend típicamente requieren diferentes bases de datos y métodos de acceso |
| ✅ Estilo de API encadenada que coincide con estilos de programación modernos, excelente experiencia para desarrolladores | ❌ Concatenación de cadenas SQL vulnerable a ataques y errores, falta de seguridad de tipos |
| ✅ Soporte para programación reactiva, se adapta naturalmente a frameworks de UI | ❌ Requiere capas de adaptación adicionales para conectar UI y capa de datos |
| ✅ No hay necesidad de configuración compleja de mapeo ORM, uso directo de objetos Dart | ❌ Complejidad del mapeo objeto-relacional, altos costos de desarrollo y mantenimiento |

### 3. Detección Precisa de Cambios de Esquema vs. Gestión Manual de Migración
| Tostore | Bases de Datos Tradicionales |
|:---------|:-----------|
| ✅ Detecta automáticamente cambios de esquema, no necesita gestión de números de versión | ❌ Dependencia del control manual de versiones y código de migración explícito |
| ✅ Detección a nivel de milisegundos de cambios de tabla/campo y migración automática de datos | ❌ Necesidad de mantener lógica de migración para actualizaciones entre versiones |
| ✅ Identifica con precisión renombres de tabla/campo, preserva todos los datos históricos | ❌ Los renombres de tabla/campo pueden llevar a pérdida de datos |
| ✅ Operaciones de migración atómicas asegurando consistencia de datos | ❌ Interrupciones de migración pueden causar inconsistencias de datos |
| ✅ Actualizaciones de esquema totalmente automatizadas sin intervención manual | ❌ Lógica de actualización compleja y altos costos de mantenimiento con versiones crecientes |

### 4. Arquitectura Multi-Espacio vs. Espacio de Almacenamiento Único
| Tostore | Bases de Datos Tradicionales |
|:---------|:-----------|
| ✅ Arquitectura multi-espacio, aislando perfectamente datos de diferentes usuarios | ❌ Espacio de almacenamiento único, almacenamiento mixto de datos de múltiples usuarios |
| ✅ Cambio de espacio con una línea de código, simple y efectivo | ❌ Requiere múltiples instancias de base de datos o lógica de aislamiento compleja |
| ✅ Mecanismo flexible de aislamiento de espacio y compartición de datos global | ❌ Difícil equilibrar el aislamiento y la compartición de datos de usuario |
| ✅ API simple para copiar o migrar datos entre espacios | ❌ Operaciones complejas para migración de inquilinos o copia de datos |
| ✅ Consultas automáticamente limitadas al espacio actual, sin necesidad de filtrado adicional | ❌ Las consultas para diferentes usuarios requieren filtrado complejo |

### 5. Soporte Multiplataforma vs. Limitaciones de Plataforma
| Tostore | Bases de Datos Tradicionales |
|:---------|:-----------|
| ✅ API unificada en plataformas Linux, Web, Mobile, Desktop | ❌ Diferentes plataformas requieren diferentes motores de almacenamiento y APIs |
| ✅ Adaptación automática a varios backends de almacenamiento multiplataforma, experiencia de desarrollo consistente | ❌ El desarrollo multiplataforma debe manejar diferencias de plataforma |
| ✅ Define una vez, usa modelos de datos en todas las plataformas | ❌ Requiere rediseñar modelos de datos para diferentes plataformas |
| ✅ Rendimiento multiplataforma optimizado, mantiene experiencia de usuario consistente | ❌ Características de rendimiento inconsistentes entre plataformas |
| ✅ Estándares de seguridad unificados implementados en todas las plataformas | ❌ Mecanismos y configuraciones de seguridad específicos de plataforma |

### 6. Algoritmos de Clave Primaria Distribuidos vs. IDs Autoincremental Tradicionales
| Tostore | Bases de Datos Tradicionales |
|:---------|:-----------|
| ✅ Cuatro algoritmos de clave primaria distribuidos adaptados a varios requisitos de escenario | ❌ IDs autoincremental simples, sujetos a conflictos en entornos de cluster |
| ✅ Generación de ID distribuida, soporta operaciones paralelas extremadamente altas | ❌ La generación de ID serial se convierte en cuello de botella en alto paralelismo |
| ✅ Longitud de paso aleatorio y algoritmos distribuidos evitando exposición de escala de negocio | ❌ Los IDs filtran información de volumen de negocio, creando riesgos de seguridad |
| ✅ Desde códigos cortos hasta marcas de tiempo, satisface varios requisitos de legibilidad y rendimiento | ❌ Tipos de ID limitados y opciones de personalización |

### 7. Procesamiento de Datos en Streaming vs. Carga por Lotes
| Tostore | Bases de Datos Tradicionales |
|:---------|:-----------|
| ✅ Interfaz de consulta en streaming, procesamiento de datos bajo demanda, bajo uso de memoria | ❌ Carga todos los resultados a la vez, susceptible a OOM con grandes conjuntos de datos |
| ✅ Soporte para iteración asíncrona y patrones de programación reactiva | ❌ Modelo de procesamiento síncrono bloquea el hilo de UI, afectando la experiencia del usuario |
| ✅ Procesamiento paralelo de datos en streaming, maximiza el rendimiento multi-núcleo | ❌ Procesamiento secuencial de datos masivos, baja utilización de CPU |
| ✅ Soporte para tuberías de datos y operaciones de transformación | ❌ Requiere implementación personalizada de lógica de procesamiento de datos |
| ✅ Mecanismos incorporados de limitación y manejo de contrapresión | ❌ Falta de control de flujo, fácil agotamiento de recursos |

### 8. Estrategias de Caché Inteligentes vs. Caché Tradicional
| Tostore | Bases de Datos Tradicionales |
|:---------|:-----------|
| ✅ Estrategias de caché inteligentes multinivel, adaptativas a patrones de acceso | ❌ Caché LRU simple, falta de flexibilidad |
| ✅ Ajuste automático de estrategia de caché basado en patrones de uso | ❌ Configuración de caché fija, difícil de ajustar dinámicamente |
| ✅ Mecanismo de caché de inicio reduciendo dramáticamente tiempos de inicio en frío | ❌ Sin caché de inicio, inicios en frío lentos, necesidad de reconstruir caché |
| ✅ Motor de almacenamiento profundamente integrado con caché para rendimiento óptimo | ❌ Lógica de caché y almacenamiento separada, requiriendo mecanismos de sincronización adicionales |
| ✅ Sincronización automática de caché y gestión de invalidación, sin código adicional necesario | ❌ La consistencia de caché requiere mantenimiento manual, propensa a errores |

## Aspectos Técnicos Destacados

- 🌐 **Soporte Multiplataforma Transparente**:
  - Experiencia consistente en plataformas Web, Linux, Windows, Mobile, Mac
  - Interfaz API unificada, sincronización de datos multiplataforma sin problemas
  - Adaptación automática a varios backends de almacenamiento multiplataforma (IndexedDB, sistemas de archivos, etc.)
  - Flujo de datos fluido desde computación de borde hasta la nube

- 🧠 **Arquitectura Distribuida Inspirada en Redes Neuronales**:
  - Topología similar a redes neuronales de nodos interconectados
  - Mecanismo eficiente de particionamiento de datos para procesamiento distribuido
  - Equilibrio de carga de trabajo dinámico inteligente
  - Soporte para extensión ilimitada de nodos, fácil construcción de redes de datos complejas

- ⚡ **Capacidades Definitivas de Procesamiento Paralelo**:
  - Lectura/escritura verdaderamente paralela con Isolates, utilización completa de CPU multi-núcleo
  - Red de cómputo multi-nodo cooperando para eficiencia multiplicada de múltiples tareas
  - Marco de procesamiento distribuido consciente de recursos, optimización automática de rendimiento
  - Interfaz de consulta en streaming optimizada para procesar conjuntos de datos masivos

- 🔑 **Varios Algoritmos de Clave Primaria Distribuidos**:
  - Algoritmo de incremento secuencial - longitud de paso aleatorio libremente ajustable
  - Algoritmo basado en marcas de tiempo - ideal para escenarios de ejecución paralela de alto rendimiento
  - Algoritmo con prefijo de fecha - adecuado para datos con indicación de rango de tiempo
  - Algoritmo de código corto - identificadores únicos concisos

- 🔄 **Migración de Esquema Inteligente**:
  - Identificación precisa de comportamientos de renombrado de tabla/campo
  - Actualización automática de datos y migración durante cambios de esquema
  - Actualizaciones sin tiempo de inactividad, sin impacto en operaciones de negocio
  - Estrategias de migración seguras que previenen pérdida de datos

- 🛡️ **Seguridad a Nivel Empresarial**:
  - Algoritmo de cifrado ChaCha20Poly1305 para proteger datos sensibles
  - Cifrado de extremo a extremo, asegurando la seguridad de datos almacenados y transmitidos
  - Control de acceso a datos de grano fino

- 🚀 **Caché Inteligente y Rendimiento de Búsqueda**:
  - Mecanismo de caché inteligente multinivel para recuperación eficiente de datos
  - Caché de inicio mejorando dramáticamente la velocidad de lanzamiento de aplicaciones
  - Motor de almacenamiento profundamente integrado con caché, sin código de sincronización adicional necesario
  - Escalado adaptativo, manteniendo rendimiento estable incluso con datos crecientes

- 🔄 **Flujos de Trabajo Innovadores**:
  - Aislamiento de datos multi-espacio, soporte perfecto para escenarios multi-inquilino, multi-usuario
  - Asignación inteligente de carga de trabajo entre nodos de cómputo
  - Proporciona base de datos robusta para entrenamiento y análisis de datos a gran escala
  - Almacenamiento automático de datos, actualizaciones e inserciones inteligentes

- 💼 **La Experiencia del Desarrollador es Prioridad**:
  - Documentación detallada bilingüe y comentarios de código (Chino e Inglés)
  - Rica información de depuración y métricas de rendimiento
  - Capacidades incorporadas de validación de datos y recuperación de corrupción
  - Configuración cero listo para usar, inicio rápido

## Inicio Rápido

Uso básico:

```dart
// Inicialización de base de datos
final db = ToStore();
await db.initialize(); // Opcional, asegura que la inicialización de la base de datos se complete antes de las operaciones

// Inserción de datos
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// Actualización de datos
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Eliminación de datos
await db.delete('users').where('id', '!=', 1);

// Soporte para consultas encadenadas complejas
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Almacenamiento automático de datos, actualiza si existe, inserta si no
await db.upsert('users', {'name': 'John','email': 'john@example.com'})
  .where('email', '=', 'john@example.com');
// O
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});

// Conteo eficiente de registros
final count = await db.query('users').count();

// Procesamiento de datos masivos usando consultas en streaming
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // Procesa cada registro según sea necesario, evitando presión de memoria
    print('Procesando usuario: ${userData['username']}');
  });

// Establecer pares clave-valor globales
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Obtener datos de pares clave-valor globales
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## Ejemplo de Aplicación Móvil

```dart
// Definición de estructura de tabla adecuada para escenarios de inicio frecuente como aplicaciones móviles, detección precisa de cambios de estructura de tabla, actualización automática de datos y migración
final db = ToStore(
  schemas: [
    const TableSchema(
      name: 'users', // Nombre de tabla
      tableId: "users",  // Identificador único de tabla, opcional, usado para identificación 100% de requisitos de renombrado, incluso sin él puede lograr >98% tasa de precisión
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id', // Clave primaria
      ),
      fields: [ // Definición de campo, no incluye clave primaria
        FieldSchema(name: 'username', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'email', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [ // Definición de índice
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// Cambiar a espacio de usuario - aislamiento de datos
await db.switchSpace(spaceName: 'user_123');
```

## Ejemplo de Servidor Backend

```dart
await db.createTables([
      const TableSchema(
        name: 'users', // Nombre de tabla
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id', // Clave primaria
          type: PrimaryKeyType.timestampBased,  // Tipo de clave primaria
        ),
        fields: [
          // Definición de campo, no incluye clave primaria
          FieldSchema(
              name: 'username',
              type: DataType.text,
              nullable: false,
              unique: true),
          FieldSchema(name: 'vector_data', type: DataType.blob),  // Almacenamiento de datos vectoriales
          // Otros campos...
        ],
        indexes: [
          // Definición de índice
          IndexSchema(fields: ['username']),
          IndexSchema(fields: ['email']),
        ],
      ),
      // Otras tablas...
]);


// Actualización de estructura de tabla
final taskId = await db.updateSchema('users')
    .renameTable('newTableName')  // Renombrar tabla
    .modifyField('username',minLength: 5,maxLength: 20,unique: true)  // Modificar propiedades de campo
    .renameField('oldName', 'newName')  // Renombrar campo
    .removeField('fieldName')  // Eliminar campo
    .addField('name', type: DataType.text)  // Añadir campo
    .removeIndex(fields: ['age'])  // Eliminar índice
    .setPrimaryKeyConfig(  // Establecer configuración de clave primaria
      const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
    );
    
// Consultar estado de tarea de migración
final status = await db.queryMigrationTaskStatus(taskId);  
print('Progreso de migración: ${status?.progressPercentage}%');
```


## Arquitectura Distribuida

```dart
// Configuración de nodo distribuido
final db = ToStore(
    config: DataStoreConfig(
        distributedNodeConfig: const DistributedNodeConfig(
            enableDistributed: true,  // Habilitar modo distribuido
            clusterId: 1,  // Configuración de pertenencia a cluster
            centralServerUrl: 'http://127.0.0.1:8080',
            accessToken: 'b7628a4f9b4d269b98649129'))
);

// Inserción por lotes de datos vectoriales
await db.batchInsert('vector', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Miles de registros
]);

// Procesamiento en streaming de grandes conjuntos de datos para análisis
await for (final record in db.streamQuery('vector')
    .where('vector_name', '=', 'face_2366')
    .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
    .stream) {
  // La interfaz de streaming soporta extracción y transformación de características a gran escala
  print(record);
}
```

## Ejemplos de Clave Primaria
Varios algoritmos de clave primaria, todos soportando generación distribuida, no se recomienda generar claves primarias usted mismo para evitar el impacto de claves primarias desordenadas en las capacidades de búsqueda.
Clave primaria secuencial PrimaryKeyType.sequential: 238978991
Clave primaria basada en marca de tiempo PrimaryKeyType.timestampBased: 1306866018836946
Clave primaria con prefijo de fecha PrimaryKeyType.datePrefixed: 20250530182215887631
Clave primaria de código corto PrimaryKeyType.shortCode: 9eXrF0qeXZ

```dart
// Clave primaria secuencial PrimaryKeyType.sequential
// Cuando el sistema distribuido está habilitado, el servidor central asigna rangos que los nodos generan por sí mismos, compacto y fácil de recordar, adecuado para IDs de usuario y números atractivos
await db.createTables([
      const TableSchema(
        name: 'users',
        primaryKeyConfig: PrimaryKeyConfig(
          type: PrimaryKeyType.sequential,  // Tipo de clave primaria secuencial
          sequentialConfig:  SequentialIdConfig(
              initialValue: 10000, // Valor inicial de autoincremento
              increment: 50,  // Paso de incremento
              useRandomIncrement: true,  // Usar paso aleatorio para evitar revelar volumen de negocio
            ),
        ),
        // Definición de campo e índice...
        fields: []
      ),
      // Otras tablas...
 ]);
```


## Configuración de Seguridad

```dart
// Renombrado de tabla y campo - reconocimiento automático y preservación de datos
final db = ToStore(
      config: DataStoreConfig(
        enableEncoding: true, // Habilitar codificación segura para datos de tabla
        encodingKey: 'YouEncodingKey', // Clave de codificación, puede ajustarse arbitrariamente
        encryptionKey: 'YouEncryptionKey', // Clave de cifrado, nota: cambiar esto impedirá decodificar datos antiguos
      ),
    );
```

## Pruebas de Rendimiento

Tostore 2.0 implementa escalabilidad de rendimiento lineal, cambios fundamentales en procesamiento paralelo, mecanismos de particionamiento y arquitectura distribuida han mejorado significativamente las capacidades de búsqueda de datos, proporcionando tiempos de respuesta de milisegundos incluso con crecimiento masivo de datos. Para procesar grandes conjuntos de datos, la interfaz de consulta en streaming puede procesar volúmenes masivos de datos sin agotar recursos de memoria.



## Planes Futuros
Tostore está desarrollando soporte para vectores de alta dimensión para adaptarse al procesamiento de datos multimodales y búsqueda semántica.


Nuestro objetivo no es crear una base de datos; Tostore es simplemente un componente extraído del framework Toway para tu consideración. Si estás desarrollando aplicaciones móviles, recomendamos usar el framework Toway con su ecosistema integrado, que cubre la solución full-stack para desarrollo de aplicaciones Flutter. Con Toway, no necesitarás tocar la base de datos subyacente, todas las operaciones de consulta, carga, almacenamiento, caché y visualización de datos serán realizadas automáticamente por el framework.
Para más información sobre el framework Toway, por favor visita el [repositorio de Toway](https://github.com/tocreator/toway).

## Documentación

Visita nuestra [Wiki](https://github.com/tocreator/tostore) para documentación detallada.

## Soporte y Retroalimentación

- Envía problemas: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Únete a la discusión: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Contribuye código: [Guía de Contribución](CONTRIBUTING.md)

## Licencia

Este proyecto está licenciado bajo la Licencia MIT - consulta el archivo [LICENSE](LICENSE) para más detalles.

---

<p align="center">Si encuentras Tostore útil, por favor danos una ⭐️</p>
