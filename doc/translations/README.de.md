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
  <a href="README.ru.md">Русский</a> | 
  Deutsch | 
  <a href="README.fr.md">Français</a> | 
  <a href="README.it.md">Italiano</a> | 
  <a href="README.tr.md">Türkçe</a>
</p>


## Schnellnavigation

- [Warum ToStore?](#why-tostore) | [Hauptmerkmale](#key-features) | [Installation](#installation) | [Schnellstart](#quick-start)
- [Schema-Definition](#schema-definition) | [Mobil/Desktop-Integration](#mobile-integration) | [Server-Integration](#server-integration)
- [Vektoren & ANN-Suche](#vector-advanced) | [TTL auf Tabellenebene](#ttl-config) | [Abfrage & Paginierung](#query-pagination) | [Fremdschlüssel](#foreign-keys) | [Abfrageoperatoren](#query-operators)
- [Verteilte Architektur](#distributed-architecture) | [Beispiele für Primärschlüssel](#primary-key-examples) | [Atomare Operationen](#atomic-expressions) | [Transaktionen](#transactions) | [Fehlerbehandlung](#error-handling)
- [Sicherheitskonfiguration](#security-config) | [Leistung](#performance) | [Weitere Ressourcen](#more-resources)


<a id="why-tostore"></a>
## Warum ToStore?

ToStore ist eine moderne Daten-Engine, die für die Ära der AGI und Edge-Intelligence-Szenarien entwickelt wurde. Sie unterstützt nativ verteilte Systeme, multimodale Fusion, relationale strukturierte Daten, hochdimensionale Vektoren und die Speicherung unstrukturierter Daten. Basierend auf einer neuronalen Netzwerk-ähnlichen Architektur zeichnen sich die Knoten durch hohe Autonomie und elastische horizontale Skalierbarkeit aus. So entsteht ein flexibles Daten-Topologie-Netzwerk für eine nahtlose plattformübergreifende Zusammenarbeit zwischen Edge und Cloud. ToStore bietet ACID-Transaktionen, komplexe relationale Abfragen (JOIN, kaskadierende Fremdschlüssel), TTL auf Tabellenebene und Aggregationsberechnungen. Es umfasst mehrere Algorithmen für verteilte Primärschlüssel, atomare Ausdrücke, Schema-Änderungserkennung, Verschlüsselungsschutz, Datentrennung in mehreren Spaces, ressourceneffiziente Lastverteilung sowie automatische Wiederherstellung nach Abstürzen.

Da sich der Schwerpunkt der Datenverarbeitung zunehmend auf Edge Intelligence verlagert, werden Endgeräte wie Agenten und Sensoren zu intelligenten Knoten, die für lokale Generierung, Umgebungswahrnehmung, Echtzeit-Entscheidungen und Datenkollaboration verantwortlich sind. Traditionelle Datenbanklösungen stoßen hierbei aufgrund ihrer Architektur oft an Grenzen bei Latenz und Stabilität, wenn es um hochfrequente Schreibvorgänge, massive Datenmengen, Vektorsuche und kollaborative Generierung geht.

ToStore befähigt die Edge mit verteilten Funktionen, um massive Datenmengen, komplexe lokale KI-Generierung und großflächige Datenströme zu unterstützen. Die tiefe intelligente Zusammenarbeit zwischen Edge- und Cloud-Knoten bildet die Grundlage für Szenarien wie AR/VR-Fusion, multimodale Interaktion, semantische Vektoren und räumliche Modellierung.


<a id="key-features"></a>
## Hauptmerkmale

- 🌐 **Einheitliche plattformübergreifende Daten-Engine**
  - Einheitliche API für Mobile, Desktop, Web und Server.
  - Unterstützung für relationale strukturierte Daten, hochdimensionale Vektoren und unstrukturierte Daten.
  - Ideal für den gesamten Datenlebenszyklus von der lokalen Speicherung bis zur Edge-Cloud-Kollaboration.

- 🧠 **Neuronale Netzwerk-ähnliche verteilte Architektur**
  - Hohe Autonomie der Knoten; vernetzte Zusammenarbeit baut flexible Datentopologien auf.
  - Unterstützung für Knotenkollaboration und elastische horizontale Skalierbarkeit.
  - Tiefe Vernetzung zwischen intelligenten Edge-Knoten und der Cloud.

- ⚡ **Parallele Ausführung und Ressourcen-Scheduling**
  - Ressourceneffiziente Lastverteilung für hohe Verfügbarkeit.
  - Multi-Knoten paralleles kollaboratives Computing und Aufgabenzerlegung.

- 🔍 **Strukturierte Abfrage und Vektorsuche**
  - Unterstützung für komplexe Bedingungen, JOINs, Aggregationsberechnungen und TTL auf Tabellenebene.
  - Unterstützung für Vektorfelder, Vektorindizes und Approximate Nearest Neighbor (ANN) Suche.
  - Strukturierte und Vektordaten können kooperativ in derselben Engine genutzt werden.

- 🔑 **Primärschlüssel, Indexierung und Schema-Evolution**
  - Integrierte Algorithmen: sequenzielles Inkrement, Zeitstempel, Datumspräfix und Short-Code.
  - Unterstützung für Unique Indizes, zusammengesetzte Indizes, Vektorindizes und Fremdschlüssel.
  - Intelligente Erkennung von Schemaänderungen und automatisierte Datenmigration.

- 🛡️ **Transaktionen, Sicherheit und Wiederherstellung**
  - ACID-Transaktionen, atomare Updates von Ausdrücken und kaskadierende Fremdschlüssel.
  - Crash-Recovery, Persistenzgarantien und Datenintegrität.
  - Unterstützung für ChaCha20-Poly1305 und AES-256-GCM Verschlüsselung.

- 🔄 **Multi-Space und Daten-Workflow**
  - Datentrennung über Spaces mit konfigurierbarem globalem Sharing.
  - Echtzeit-Abfragelistener, mehrstufiges intelligentes Caching und Cursor-Paginierung.
  - Perfekt für Multi-User-, Local-First- und Offline-Kollaborationsanwendungen.


<a id="installation"></a>
## Installation

> [!IMPORTANT]
> **Upgrade von v2.x?** Lesen Sie den [v3.x Upgrade Guide](../UPGRADE_GUIDE_v3.md) für kritische Migrationsschritte.

Fügen Sie `tostore` als Abhängigkeit in Ihrer `pubspec.yaml` hinzu:

```yaml
dependencies:
  tostore: any # Verwenden Sie die neueste Version
```

<a id="quick-start"></a>
## Schnellstart

> [!IMPORTANT]
> **Die Definition des Tabellenschemas ist der erste Schritt**: Sie müssen das Tabellenschema definieren, bevor Sie CRUD-Operationen ausführen können (außer bei reiner KV-Speicherung).
> - Details zu Definitionen und Einschränkungen finden Sie unter [Schema-Definition](#schema-definition).
> - **Mobil/Desktop**: Übergeben Sie `schemas` bei der Initialisierung; siehe [Mobile Integration](#mobile-integration).
> - **Server**: Verwenden Sie `createTables` zur Laufzeit; siehe [Server-Integration](#server-integration).

```dart
// 1. Datenbank initialisieren
final db = await ToStore.open();

// 2. Daten einfügen
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Verkettete Abfrage (siehe [Abfrageoperatoren](#query-operators); unterstützt =, !=, >, <, LIKE, IN etc.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. Aktualisieren und Löschen
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Echtzeit-Listening (UI wird bei Datenänderungen automatisch aktualisiert)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Passende Nutzer aktualisiert: $users');
});
```

### Key-Value Speicher (KV)
Geeignet für Szenarien ohne strukturierte Tabellen. Einfach und leistungsstark für Konfigurationen und Statusdaten. Daten in verschiedenen Spaces sind standardmäßig isoliert, können aber global geteilt werden.

```dart
// Initialisierung
final db = await ToStore.open();

// KV-Paar setzen (unterstützt String, int, bool, double, Map, List etc.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// Daten abrufen
final theme = await db.getValue('theme'); // 'dark'

// Daten löschen
await db.removeValue('theme');

// Globale KV-Daten (Space-übergreifend)
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```


<a id="schema-definition"></a>
## Schema-Definition
Die Beispiele für Mobil und Server nutzen die hier definierten `appSchemas`.

### Überblick TableSchema

```dart
const userSchema = TableSchema(
  name: 'users', // Tabellenname, erforderlich
  tableId: 'users', // Eindeutige ID, optional; für präzise Erkennung von Umbenennungen
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // PK-Feldname, Standard ist 'id'
    type: PrimaryKeyType.sequential, // Auto-Generierungstyp
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
      comment: 'Anmeldename', 
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0,
      maxValue: 150,
      defaultValue: 0,
      createIndex: true, // Index zur Leistungssteigerung erstellen
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // Automatischer Zeitstempel
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
  foreignKeys: const [], // Optionaler Fremdschlüssel (siehe unten)
  isGlobal: false, // Globale Tabelle (in allen Spaces zugänglich)
  ttlConfig: null, // TTL auf Tabellenebene (siehe unten)
);

const appSchemas = [userSchema];
```

`DataType` unterstützt `integer`, `bigInt`, `double`, `text`, `blob`, `boolean`, `datetime`, `array`, `json`, `vector`. 

### Einschränkungen und Validierung

Einschränkungen werden beim Schreibvorgang validiert:

- `nullable: false`: Pflichtfeld.
- `minLength` / `maxLength`: Textlänge.
- `minValue` / `maxValue`: Wertebereich.
- `defaultValue`: Standardwerte.
- `unique`: Eindeutigkeit (erstellt automatisch einen Unique Index).
- `createIndex`: Erstellt einen Index für häufige Filter oder Sortierungen.


<a id="mobile-integration"></a>
## Mobil/Desktop-Integration

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Android/iOS: Bestimmen Sie den Pfad für die DB
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// Multi-Space Architektur - Trennung von Nutzerdaten
await db.switchSpace(spaceName: 'user_123');
```

### Login-Status erhalten (Aktiver Space)

Damit bleibt der aktuelle Nutzer nach einem App-Neustart erhalten.

- **Login-Persistenz**: Beim Wechsel zum Space das Flag `keepActive: true` setzen.
- **Logout**: DB mit `keepActiveSpace: false` schließen.

```dart
// Nach Login: Aktiven Space speichern
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Beim Logout: Aktiven Space löschen
await db.close(keepActiveSpace: false);
```


<a id="server-integration"></a>
## Server-Integration

```dart
final db = await ToStore.open();

// Tabellenstruktur beim Servicestart erstellen oder validieren
await db.createTables(appSchemas);

// Online-Schema-Updates
final taskId = await db.updateSchema('users')
  .renameTable('users_new')
  .modifyField('username', minLength: 5, unique: true)
  .addField('created_at', type: DataType.datetime)
  .removeIndex(fields: ['age']);
    
// Migrationsfortschritt überwachen
final status = await db.queryMigrationTaskStatus(taskId);
print('Fortschritt: ${status?.progressPercentage}%');


// Manueller Abfrage-Cache
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Cache ungültig machen
await db.query('users').where('is_active', '=', true).clearQueryCache();
```


<a id="advanced-usage"></a>
## Fortgeschrittene Nutzung


<a id="vector-advanced"></a>
### Vektoren und ANN-Suche

```dart
await db.createTables([
  const TableSchema(
    name: 'embeddings',
    fields: [
      FieldSchema(name: 'title', type: DataType.text, nullable: false),
      FieldSchema(
        name: 'embedding',
        type: DataType.vector,
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
        ),
      ),
    ],
  ),
]);

final queryVector = VectorData.fromList(List.generate(128, (i) => i * 0.01));

// Vektorsuche
final results = await db.vectorSearch(
  'embeddings', 
  fieldName: 'embedding', 
  queryVector: queryVector, 
  topK: 5,
);
```


<a id="ttl-config"></a>
### Tabellen-TTL (Automatischer Ablauf)

Für Protokolle: Daten werden nach Ablauf automatisch im Hintergrund gelöscht.

```dart
const TableSchema(
  name: 'event_logs',
  fields: [/* Felder mit created_at */],
  ttlConfig: TableTtlConfig(ttlMs: 7 * 24 * 60 * 60 * 1000), // 7 Tage
);
```


### Intelligentes Speichern (Upsert)
Aktualisiert, wenn der Key existiert, andernfalls wird eingefügt.

```dart
await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});
```


### JOIN & Aggregation
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .limit(20);

// Aggregationsfunktionen
final count = await db.query('users').count();
final sum = await db.query('orders').sum('total');
```


<a id="query-pagination"></a>
### Effiziente Paginierung

- **Offset-Modus**: Für kleine Datensätze oder Seitensprünge.
- **Cursor-Modus**: Empfohlen für massive Datenmengen (O(1)).

```dart
// Paginierung über Cursor
final page1 = await db.query('users').orderByDesc('id').limit(20);

if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor);
}
```


<a id="foreign-keys"></a>
### Fremdschlüssel und Kaskadierung

```dart
foreignKeys: [
    ForeignKeySchema(
      name: 'fk_posts_user',
      fields: ['user_id'],
      referencedTable: 'users',
      referencedFields: ['id'],
      onDelete: ForeignKeyCascadeAction.cascade, // Löscht Posts, wenn User gelöscht wird
    ),
],
```


<a id="query-operators"></a>
### Abfrageoperatoren

Unterstützt: `=`, `!=`, `>`, `>=`, `<`, `<=`, `IN`, `NOT IN`, `BETWEEN`, `LIKE`, `IS NULL`, `IS NOT NULL`.

```dart
db.query('users').whereEqual('name', 'John').whereGreaterThan('age', 18).limit(20);
```


<a id="atomic-expressions"></a>
## Atomare Operationen

Berechnungen auf Datenbankebene zur Vermeidung von Parallelitätskonflikten:

```dart
// balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', id);

// In einem Upsert: Inkrement bei Update, sonst 1
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(Expr.isUpdate(), Expr.field('count') + 1, 1),
});
```


<a id="transactions"></a>
## Transaktionen

Garantieren Atomarität: Entweder alle Operationen sind erfolgreich oder keine.

```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {...});
  await db.update('users', {...});
});
```


<a id="security-config"></a>
## Sicherheit

> [!WARNING]
> **Key Management**: `encodingKey` ist änderbar (Auto-Migration). `encryptionKey` ist kritisch; eine Änderung ohne manuelle Migration führt zu Datenverlust.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      encryptionType: EncryptionType.chacha20Poly1305, 
      encodingKey: '...', 
      encryptionKey: '...',
    ),
  ),
);
```

### Feldverschlüsselung (ToCrypto)
Zum Verschlüsseln einzelner sensibler Felder ohne Beeinträchtigung der Gesamtgeschwindigkeit.


<a id="performance"></a>
## Leistung

- 📱 **Beispiel**: Ein vollständiges Flutter-Beispiel finden Sie im Verzeichnis `example`.
- 🚀 **Produktion**: Performance im Release-Modus ist deutlich höher als im Debug-Modus.
- ✅ **Zuverlässig**: Kernfunktionen werden durch umfangreiche Tests abgesichert.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore Leistungsdemo" width="320" />
</p>

- **Leistungsdemo**: Flüssiges Scrollen und Suchen selbst bei über 100 Mio. Datensätzen. ([Video](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4))

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore Wiederherstellung" width="320" />
</p>

- **Wiederherstellung**: Automatische Selbstreparatur bei plötzlichem Stromausfall. ([Video](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4))


Wenn ToStore Ihnen hilft, geben Sie uns bitte ein ⭐️! Das ist die größte Unterstützung für Open Source.

---

> **Empfehlung**: Nutzen Sie das [ToApp Framework](https://github.com/tocreator/toapp) für das Frontend — eine Full-Stack-Lösung für Daten-, Lade- und Statusmanagement.
