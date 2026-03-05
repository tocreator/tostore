# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | Deutsch | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)


## Warum Tostore wählen?

Tostore ist die einzige Hochleistungs-Speicher-Engine für verteilte Vektordatenbanken im Dart/Flutter-Ökosystem. Basierend auf einer neuronalen netzwerkähnlichen Architektur bietet es eine intelligente Vernetzung und Zusammenarbeit zwischen den Knoten und unterstützt eine unendliche horizontale Skalierung. Es baut ein flexibles Datentopologie-Netzwerk auf und bietet präzise Identifizierung von Schemaänderungen, Verschlüsselungsschutz sowie Multi-Space-Datentrennung. Tostore nutzt Multi-Core-CPUs für extrem parallele Verarbeitung voll aus und unterstützt nativ die plattformübergreifende Zusammenarbeit von mobilen Edge-Geräten bis hin zur Cloud. Mit verschiedenen verteilten Primärschlüssel-Algorithmen bietet es eine leistungsstarke Datengrundlage für Szenarien wie immersive Virtual Reality, multimodale Interaktion, Spatial Computing, generative KI und semantische Vektorraumodellierung.

Da generative KI und Spatial Computing das Rechenzentrum an den Rand (Edge) verschieben, entwickeln sich Endgeräte von reinen Inhaltsanzeigen zu Kernpunkten für lokale Generierung, Umgebungswahrnehmung und Echtzeit-Entscheidungsfindung. Traditionelle eingebettete Datenbanken mit nur einer Datei sind durch ihr Architekturdesign begrenzt und haben oft Schwierigkeiten, die unmittelbaren Reaktionsanforderungen intelligenter Anwendungen bei hohen parallelen Schreibvorgängen, massiver Vektorsuche und Cloud-Edge-kollaborativer Generierung zu unterstützen. Tostore wurde für Edge-Geräte entwickelt und verleiht ihnen verteilte Speicherfähigkeiten, die ausreichen, um komplexe lokale KI-Generierung und großflächigen Datenfluss zu unterstützen – eine echte tiefe Zusammenarbeit zwischen Cloud und Edge.

**Stromausfall- und absturzsicher**: Selbst bei einem unerwarteten Stromausfall oder Anwendungsabsturz können Daten automatisch wiederhergestellt werden, was einen echten Null-Verlust bedeutet. Sobald eine Datenoperation bestätigt wird, wurden die Daten bereits sicher gespeichert, sodass kein Risiko eines Datenverlusts besteht.

**Leistungsgrenzen sprengen**: Tests zeigen, dass selbst bei über 100 Millionen Datensätzen ein typisches Smartphone eine konstante Suchleistung unabhängig vom Datenvolumen beibehält und ein Erlebnis bietet, das herkömmliche Datenbanken bei weitem übertrifft.




...... Von den Fingerspitzen bis zu Cloud-Anwendungen hilft Tostore Ihnen, die Datenrechenleistung freizusetzen und die Zukunft zu gestalten ......




## Tostore-Funktionen

- 🌐 **Nahtlose Unterstützung aller Plattformen**
  - Führen Sie denselben Code auf allen Plattformen aus, von mobilen Apps bis hin zu Cloud-Servern.
  - Passt sich intelligent an verschiedene Plattform-Speicher-Backends an (IndexedDB, Dateisystem usw.).
  - Einheitliche API-Schnittstelle für sorgenfreie plattformübergreifende Datensynchronisation.
  - Nahtloser Datenfluss von Edge-Geräten zu Cloud-Servern.
  - Lokale Vektorberechnung auf Edge-Geräten, wodurch Netzwerklatenz und Cloud-Abhängigkeit reduziert werden.

- 🧠 **Neuronale netzwerkähnliche verteilte Architektur**
  - Vernetzte Knotentopologie für eine effiziente Organisation des Datenflusses.
  - Hochleistungs-Datenpartitionierungsmechanismus für echte verteilte Verarbeitung.
  - Intelligenter dynamischer Workload-Ausgleich zur Maximierung der Ressourcennutzung.
  - Unendliche horizontale Skalierung von Knoten zum einfachen Aufbau komplexer Datennetzwerke.

- ⚡ **Extreme parallele Verarbeitungsfähigkeit**
  - Echtes paralleles Lesen/Schreiben mit Isolates, mit voller Geschwindigkeit auf Multi-Core-CPUs.
  - Intelligente Ressourcenplanung gleicht die Last automatisch aus, um die Multi-Core-Leistung zu maximieren.
  - Kollaboratives Multi-Knoten-Rechennetzwerk verdoppelt die Effizienz der Aufgabenverarbeitung.
  - Ressourcenbewusstes Planungs-Framework optimiert automatisch Ausführungspläne, um Ressourcenkonflikte zu vermeiden.
  - Streaming-Abfrageschnittstelle verarbeitet massive Datensätze mühelos.

- 🔑 **Vielfältige verteilte Primärschlüssel-Algorithmen**
  - Sequenzieller Inkrement-Algorithmus - Passen Sie die zufälligen Schrittweiten frei an, um das Geschäftsvolumen zu verbergen.
  - Zeitstempel-basierter Algorithmus - Die beste Wahl für Szenarien mit hoher Parallelität.
  - Datums-Präfix-Algorithmus - Perfekte Unterstützung für die Anzeige von Daten in Zeiträumen.
  - Kurzcode-Algorithmus - Erzeugt kurze, gut lesbare eindeutige Identifikatoren.

- 🔄 **Intelligente Schema-Migration & Datenintegrität**
  - Identifiziert präzise umbenannte Tabellenfelder ohne Datenverlust.
  - Automatische Erkennung von Schemaänderungen und Datenmigration in Millisekunden.
  - Upgrades ohne Ausfallzeiten, nahtlos für den Betrieb.
  - Sichere Migrationsstrategien für komplexe Strukturänderungen.
  - Automatische Fremdschlüssel-Validierung mit Kaskadierung zur Sicherstellung der referenziellen Integrität.

- 🛡️ **Sicherheit & Langlebigkeit auf Unternehmensebene**
  - Doppeltes Schutzmechanismus: Echtzeit-Protokollierung von Datenänderungen stellt sicher, dass nichts verloren geht.
  - Automatische Wiederherstellung nach Absturz: Setzt unvollständige Operationen nach Stromausfall oder Absturz automatisch fort.
  - Datenkonsistenzgarantie: Operationen sind entweder vollständig erfolgreich oder werden komplett zurückgesetzt (Rollback).
  - Atomare Berechnungs-Updates: Das Ausdruckssystem unterstützt komplexe Berechnungen, die atomar ausgeführt werden, um Parallelitätskonflikte zu vermeiden.
  - Sofortige sichere Speicherung: Daten sind sicher gespeichert, sobald die Operation erfolgreich war.
  - Hochfeste ChaCha20Poly1305-Verschlüsselung schützt sensible Daten.
  - Ende-zu-Ende-Verschlüsselung für Sicherheit bei Speicherung und Übertragung.

- 🚀 **Intelligentes Caching & Abfrageleistung**
  - Mehrstufiger intelligenter Caching-Mechanismus für blitzschnelle Datenabfragen.
  - Caching-Strategien, die tief in die Speicher-Engine integriert sind.
  - Adaptive Skalierung behält die stabile Leistung bei wachsendem Datenvolumen bei.
  - Echtzeit-Benachrichtigungen über Datenänderungen mit automatischer Aktualisierung der Abfrageergebnisse.

- 🔄 **Intelligenter Datenworkflow**
  - Multi-Space-Architektur bietet Datentrennung bei gleichzeitiger globaler Teilung.
  - Intelligente Workload-Verteilung über Rechenknoten hinweg.
  - Bietet eine solide Grundlage für groß angelegtes Datentraining und Analysen.


## Installation

> [!IMPORTANT]
> **Upgrade von v2.x?** Bitte lesen Sie den [v3.0 Upgrade-Leitfaden](../UPGRADE_GUIDE_v3.md) für wichtige Migrationsschritte und bahnbrechende Änderungen.

Fügen Sie `tostore` als Abhängigkeit in Ihre `pubspec.yaml` ein:

```yaml
dependencies:
  tostore: any # Bitte verwenden Sie die neueste Version
```

## Schnellstart

> [!IMPORTANT]
> **Die Definition des Tabellenschemas ist der erste Schritt**: Bevor Sie CRUD-Operationen durchführen, müssen Sie das Tabellenschema definieren. Die spezifische Definition Methode hängt von Ihrem Szenario ab:
> - **Mobil/Desktop**: Empfohlen [Statische Definition](#integration-für-szenarien-mit-häufigem-start).
> - **Serverseitig**: Empfohlen [Dynamische Erstellung](#serverseitige-integration).

```dart
// 1. Datenbank initialisieren
final db = await ToStore.open();

// 2. Daten einfügen
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Verkettete Abfragen ([Abfrageoperatoren](#abfrageoperatoren), unterstützt =, !=, >, <, LIKE, IN usw.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. Aktualisieren und Löschen
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Echtzeit-Überwachung (UI aktualisiert sich automatisch bei Datenänderungen)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Passende Benutzer aktualisiert: $users');
});
```

### Key-Value-Speicher (KV)
Geeignet für Szenarien, die es nicht erfordern, strukturierte Tabellen zu definieren. Es ist einfach, praktisch und enthält einen integrierten Hochleistungs-KV-Speicher für Konfigurationen, Status und andere verstreute Daten. Daten in verschiedenen Spaces sind von Natur aus isoliert, können aber für die globale Freigabe konfiguriert werden.

```dart
// 1. Key-Value-Paare setzen (Unterstützt String, int, bool, double, Map, List usw.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 2. Daten abrufen
final theme = await db.getValue('theme'); // 'dark'

// 3. Daten löschen
await db.removeValue('theme');

// 4. Globaler Key-Value (Space-übergreifend geteilt)
// Standardmäßig sind KV-Daten Space-spezifisch. Verwenden Sie isGlobal: true für globale Freigabe.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



## Integration für Szenarien mit häufigem Start

📱 **Beispiel**: [mobile_quickstart.dart](example/lib/mobile_quickstart.dart)

```dart
// Schemadefinition geeignet für mobile/Desktop-Apps mit häufigen Starts.
// Erkennt Schemaänderungen präzise und migriert Daten automatisch ohne Code-Wartung.
final db = await ToStore.open(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // Globale Tabelle, für alle Spaces zugänglich
            fields: [],
    ),
    const TableSchema(
      name: 'users', // Tabellenname
      tableId: "users",  // Eindeutige ID für 100%ige Erkennung von Umbenennungen
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // Primärschlüssel-Name
      ),
      fields: [        // Felddefinitionen (ohne Primärschlüssel)
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true, // Erstellt automatisch einen eindeutigen Index
          fieldId: 'username',  // Eindeutige Feld-ID
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true // Erstellt automatisch einen eindeutigen Index
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime,
          createIndex: true // Erstellt automatisch einen Index (idx_last_login)
        ),
      ],
      // Beispiel für zusammengesetzten Index
      indexes: [
        IndexSchema(fields: ['username', 'last_login']),
      ],
    ),
    // Beispiel für Fremdschlüssel-Einschränkung
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
          fields: ['user_id'],              // Aktuelle Tabellenfelder
          referencedTable: 'users',         // Referenzierte Tabelle
          referencedFields: ['id'],         // Referenzierte Felder
          onDelete: ForeignKeyCascadeAction.cascade,  // Kaskadierendes Löschen
          onUpdate: ForeignKeyCascadeAction.cascade,  // Kaskadierendes Aktualisieren
        ),
      ],
    ),
  ],
);

// Multi-Space-Architektur - perfekte Trennung von Daten verschiedener Benutzer
await db.switchSpace(spaceName: 'user_123');
```

### Login-Zustand beibehalten und Abmelden (aktiver Space)

Multi-Space eignet sich für **Daten pro Benutzer**: ein Space pro Benutzer und Wechsel beim Login. Mit **aktivem Space** und der **close**-Option bleibt der aktuelle Benutzer über Neustarts erhalten und Abmelden wird unterstützt.

- **Login-Zustand beibehalten**: Wenn der Benutzer in seinen Space wechselt, diesen als aktiven Space speichern, damit der nächste Start mit default direkt in diesen Space öffnet (kein „erst default öffnen, dann wechseln“ nötig).
- **Abmelden**: Beim Abmelden die Datenbank mit `keepActiveSpace: false` schließen, damit beim nächsten Öffnen nicht automatisch der Space des vorherigen Benutzers geöffnet wird.

```dart

// Nach dem Login: in den Space dieses Benutzers wechseln und für den nächsten Start merken (Login beibehalten)
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Optional: strikt nur mit default öffnen (z. B. nur Login-Bildschirm) — gespeicherten aktiven Space nicht verwenden
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// Beim Abmelden: schließen und aktiven Space löschen, damit der nächste Start default verwendet
await db.close(keepActiveSpace: false);
```

## Serverseitige Integration

🖥️ **Beispiel**: [server_quickstart.dart](example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Massenweise Schemaerstellung zur Laufzeit - geeignet für kontinuierlichen Betrieb
await db.createTables([
  // Speicher für 3D-räumliche Merkmalsvektoren
  const TableSchema(
    name: 'spatial_embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,   // Zeitstempel-PK für hohe Parallelität
    ),
    fields: [
      FieldSchema(
        name: 'video_name',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'spatial_features',
        type: DataType.vector,                // Vektorspeichertyp
        vectorConfig: VectorFieldConfig(
          dimensions: 1024,                   // Hochdimensionaler Vektor
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
        type: IndexType.vector,              // Vektorindex
        fields: ['spatial_features'],
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,   // NGH-Algorithmus für effiziente ANN
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,
            'efConstruction': 200,
          },
        ),
      ),
    ],
  ),
  // Weitere Tabellen...
]);

// Online-Schema-Updates - Nahtlos für den Betrieb
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // Tabelle umbenennen
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // Feldattribute ändern
  .renameField('old_name', 'new_name')     // Feld umbenennen
  .removeField('deprecated_field')         // Feld entfernen
  .addField('created_at', type: DataType.datetime)  // Feld hinzufügen
  .removeIndex(fields: ['age'])            // Index entfernen
  .setPrimaryKeyConfig(                    // PK-Konfiguration ändern
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// Migrationsfortschritt überwachen
final status = await db.queryMigrationTaskStatus(taskId);
print('Migrationsfortschritt: ${status?.progressPercentage}%');


// Manuelle Abfrage-Cache-Verwaltung (Serverseite)
// Für Abfragen auf Primärschlüsseln oder indizierten Feldern (Gleichheit, IN-Abfragen) ist die Leistung bereits extrem hoch und eine manuelle Cache-Verwaltung in der Regel unnötig.

// Ein Abfrageergebnis manuell für 5 Minuten zwischenspeichern.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Bestimmten Cache bei Datenänderungen ungültig machen, um Konsistenz zu gewährleisten.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// Cache explizit deaktivieren für Abfragen, die Echtzeitdaten erfordern.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```



## Fortgeschrittene Nutzung

Tostore bietet eine Vielzahl fortgeschrittener Funktionen für komplexe Geschäftsanforderungen:

### Tabellenbasiertes TTL (zeitbasierte automatische Löschung)

Für Logs, Events und andere zeitbasierte Daten können Sie auf Tabellenebene ein TTL über `ttlConfig` definieren. Abgelaufene Daten werden im Hintergrund in kleinen Batches automatisch bereinigt, ohne dass Geschäftslogik alle Datensätze manuell durchlaufen muss:

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
    ttlMs: 7 * 24 * 60 * 60 * 1000, // 7 Tage aufbewahren
    // Wenn sourceField weggelassen wird, verwendet die Engine die Schreibzeit
    // und verwaltet die dafür benötigten Indizes automatisch.
    // Optional: Wenn ein benutzerdefiniertes sourceField verwendet wird, muss es:
    // 1) den Typ DataType.datetime haben
    // 2) nicht-nullbar sein (nullable: false)
    // 3) DefaultValueType.currentTimestamp als defaultValueType verwenden
    // sourceField: 'created_at',
  ),
);
```

### Verschachtelte Abfragen & Benutzerdefinierte Filterung
Unterstützt unendliche Verschachtelung von Bedingungen und flexible benutzerdefinierte Funktionen.

```dart
// Verschachtelung von Bedingungen: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// Benutzerdefinierte Bedingungsfunktion
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('empfohlen') ?? false);
```

### Intelligentes Upsert
Aktualisieren, falls vorhanden, andernfalls einfügen.

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


### Joins & Feldauswahl
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### Streaming & Statistiken
```dart
// Datensätze zählen
final count = await db.query('users').count();

// Prüfen, ob die Tabelle im Datenbankschema definiert ist (Space-unabhängig)
// Hinweis: Das bedeutet NICHT, dass die Tabelle Daten enthält
final usersTableDefined = await db.tableExists('users');

// Effiziente Existenzprüfung anhand von Bedingungen (ohne vollständige Datensätze zu laden)
final emailExists = await db.query('users')
    .where('email', '=', 'test@example.com')
    .exists();

// Aggregatfunktionen
final totalAge = await db.query('users').where('age', '>', 18).sum('age');
final avgAge = await db.query('users').avg('age');
final maxAge = await db.query('users').max('age');
final minAge = await db.query('users').min('age');

// Gruppierung und Filterung
final result = await db.query('orders')
    .select(['status', Agg.sum('amount', alias: 'total')])
    .groupBy(['status'])
    .having(Agg.sum('amount'), '>', 1000)
    .limit(20);

// Eindeutige Abfrage
final uniqueCities = await db.query('users').distinct(['city']);

// Streaming-Abfrage (geeignet für massive Daten)
db.streamQuery('users').listen((data) => print(data));
```



### Abfragen & Effiziente Paginierung

> [!TIP]
> **Explizites `limit` für beste Performance**: Es wird dringend empfohlen, bei Abfragen immer ein `limit` anzugeben. Wenn es weggelassen wird, begrenzt die Engine standardmäßig auf 1000 Datensätze. Obwohl der Kern der Abfrage extrem schnell ist, kann die Serialisierung einer großen Anzahl von Datensätzen in UI-sensitiven Anwendungen zu unnötigen Zeitverzögerungen führen.

Tostore bietet Unterstützung für Dual-Mode-Paginierung passend zu verschiedenen Datenskalen:

#### 1. Offset-Modus
Geeignet für kleine Datensätze (z.B. unter 10k Datensätzen) oder wenn spezifische Seitensprünge erforderlich sind.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Überspringe die ersten 40
    .limit(20); // Nimm 20
```
> [!TIP]
> Wenn `offset` sehr groß ist, muss die Datenbank viele Datensätze scannen und verwerfen, was zu Leistungseinbußen führt. Verwenden Sie den **Cursor-Modus** für Paginierung in der Tiefe.

#### 2. Hochleistungs-Cursor-Modus
**Empfolen für massive Daten und unendliches Scrollen**. Nutzt `nextCursor` für O(1)-Leistung und gewährleistet eine konstante Abfragegeschwindigkeit unabhängig von der Seitentiefe.

> [!IMPORTANT]
> Bei Sortierung nach einem nicht indizierten Feld oder bei bestimmten komplexen Abfragen fällt die Engine auf einen vollständigen Tabellenscan zurück und gibt einen `null`-Cursor zurück (was bedeutet, dass die Paginierung für diese spezifische Abfrage noch nicht unterstützt wird).

```dart
// Seite 1
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Nächste Seite mit dem Cursor abrufen
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Direkt zur Position springen
}

// Effizient rückwärts springen mit prevCursor
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Funktion | Offset-Modus | Cursor-Modus |
| :--- | :--- | :--- |
| **Abfrageleistung** | Sinkt mit steigender Seitenzahl | **Konstant (O(1))** |
| **Komplexität** | Kleine Daten, Seitensprünge | **Massive Daten, unendliches Scrollen** |
| **Konsistenz** | Änderungen können zu Sprüngen führen | **Vermeidet Duplikate/Auslassungen bei Änderungen** |



### Abfrageoperatoren

Alle Operatoren (groß-/kleinschreibungsunabhängig) für `where(field, operator, value)`:

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

### Semantische Abfragemethoden (empfohlen)

Semantische Methoden vermeiden manuelle Operatoreingabe und verbessern die IDE-Unterstützung.

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

## Verteilte Architektur

```dart
// Verteilte Knoten konfigurieren
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

// Hochleistungs-Batch-Einfügen
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Datensätze effizient in großen Mengen einfügen
]);

// Große Datensätze streamen - Konstanter Speicherverbrauch
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Verarbeitet TB-Daten effizient ohne hohen Speicherverbrauch
  print(record);
}
```

## Primärschlüssel-Beispiele

Tostore bietet verschiedene verteilte Primärschlüssel-Algorithmen:

- **Sequentiell** (PrimaryKeyType.sequential): 238978991
- **Zeitstempel-basiert** (PrimaryKeyType.timestampBased): 1306866018836946
- **Datums-Präfix** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **Kurzcode** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// Beispiel für sequenzielle Primärschlüssel-Konfiguration
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // Geschäftsvolumen verbergen
      ),
    ),
    fields: [/* Felddefinitionen */]
  ),
]);
```


## Atomare Ausdrucksoperationen

Das Ausdruckssystem bietet typsichere atomare Feldupdates. Alle Berechnungen werden atomar auf Datenbankebene ausgeführt, um Parallelitätskonflikte zu vermeiden:

```dart
// Einfaches Inkrement: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Komplexe Berechnung: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// Verschachtelte Klammern: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Verwendung von Funktionen: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Zeitstempel: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

## Transaktionen

Transaktionen stellen die Atomarität mehrerer Operationen sicher – entweder alle erfolgreich oder alle Rollback, was die Datenkonsistenz garantiert.

**Transaktionsmerkmale**:
- Atomare Ausführung mehrerer Operationen.
- Automatische Wiederherstellung unvollständiger Operationen nach Absturz.
- Daten sind sicher gespeichert nach erfolgreichem Commit.

```dart
// Basis-Transaktion - Atomares Commit mehrerer Operationen
final txResult = await db.transaction(() async {
  // Benutzer einfügen
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // Atomares Update mittels Ausdrücken
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // Schlägt eine Operation fehl, werden alle Änderungen automatisch zurückgesetzt.
});

if (txResult.isSuccess) {
  print('Transaktion erfolgreich abgeschlossen');
} else {
  print('Transaktion zurückgesetzt: ${txResult.error?.message}');
}

// Automatischer Rollback bei Fehler
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('Geschäftslogikfehler'); // Löst Rollback aus
}, rollbackOnError: true);
```

### Reiner In-Memory-Modus (Memory Mode)

Für Szenarien wie Daten-Caching, temporäre Berechnungen oder laufwerkslose Umgebungen, bei denen keine Persistenz auf der Festplatte erforderlich ist, können Sie eine reine In-Memory-Datenbank mithilfe von `ToStore.memory()` initialisieren. In diesem Modus werden alle Daten (einschließlich Schemata, Indizes und Schlüssel-Wert-Paare) streng im Speicher gehalten.

**Hinweis**: Daten, die im Memory-Modus erstellt wurden, gehen beim Schließen oder Neustarten der Anwendung vollständig verloren.

```dart
// Datenbank im reinen Memory-Modus initialisieren
final db = await ToStore.memory(
  schemas: [],
);

// Alle Vorgänge (CRUD und Suche) werden sofort im Speicher ausgeführt
await db.insert('temp_cache', {'key': 'session_1', 'value': {'user': 'admin'}});

```


## Sicherheitskonfiguration

**Datensicherheitsmechanismen**:
- Doppelte Schutzmechanismen stellen sicher, dass Daten nie verloren gehen.
- Automatische Crash-Wiederherstellung für unvollständige Operationen.
- Sofortige sichere Persistenz bei Erfolg der Operation.
- Hochfeste Verschlüsselung schützt sensible Daten.

> [!WARNING]
> **Schlüsselverwaltung**: **`encodingKey`** kann frei geändert werden; der Motor migriert die Daten bei Änderung automatisch, Datenverlust ist nicht zu befürchten. **`encryptionKey`** darf nicht beliebig geändert werden—eine Änderung macht alte Daten unlesbar (außer bei Durchführung einer Migration). Codieren Sie keine sensiblen Schlüssel fest ein; beziehen Sie diese von einem sicheren Server.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Unterstützte Algorithmen: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // Kodierungsschlüssel (kann frei geändert werden; Daten werden automatisch migriert)
      encodingKey: 'Ihr-32-Byte-langer-Kodierungsschlüssel...', 
      
      // Verschlüsselungsschlüssel für kritische Daten (nicht beliebig ändern; alte Daten unlesbar ohne Migration)
      encryptionKey: 'Ihr-sicherer-Verschlüsselungsschlüssel...',
      
      // Gerätebindung (Pfad-basiert)
      // Falls aktiviert, werden Schlüssel an Pfad und Gerätemerkmale gebunden.
      // Erhöht Sicherheit gegen Kopieren der Datenbankdateien, aber die 
      // Datenwiederherstellung hängt vom Installationspfad ab.
      deviceBinding: false, 
    ),
    // Write-Ahead Logging (WAL) standardmäßig aktiviert
    enableJournal: true, 
    // Erzwungenes Speichern auf Disk beim Commit (für Leistung auf false setzen)
    persistRecoveryOnCommit: true,
  ),
);
```

### Wert-Level-Verschlüsselung (ToCrypto)

Die oben beschriebene Voll-Datenbank-Verschlüsselung verschlüsselt alle Tabellen- und Indexdaten und kann die Gesamtleistung beeinträchtigen. Um nur sensible Felder zu verschlüsseln, verwenden Sie **ToCrypto**: Es ist unabhängig von der Datenbank (keine db-Instanz nötig). Sie kodieren bzw. dekodieren Werte selbst vor dem Schreiben oder nach dem Lesen; der Schlüssel wird vollständig von Ihrer App verwaltet. Die Ausgabe ist Base64 und eignet sich für JSON- oder TEXT-Spalten.

- **key** (erforderlich): `String` oder `Uint8List`. Bei nicht 32 Bytes wird ein 32-Byte-Schlüssel per SHA-256 abgeleitet.
- **type** (optional): Verschlüsselungstyp [ToCryptoType]: [ToCryptoType.chacha20Poly1305] oder [ToCryptoType.aes256Gcm]. Standard [ToCryptoType.chacha20Poly1305]. Weglassen für Standard.
- **aad** (optional): Zusätzliche authentifizierte Daten — `Uint8List`. Wenn beim Kodieren übergeben, müssen beim Dekodieren dieselben Bytes übergeben werden (z. B. Tabellenname + Feldname zur Kontextbindung). Bei einfacher Nutzung weglassen.

```dart
const key = 'my-secret-key';
// Kodieren: Klartext → Base64-Chiffre (in DB oder JSON speichern)
final cipher = ToCrypto.encode('sensitive data', key: key);
// Beim Lesen dekodieren
final plain = ToCrypto.decode(cipher, key: key);

// Optional: Kontext mit aad binden (gleiches aad beim Kodieren und Dekodieren)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```

## Leistung & Erfahrung

### Leistungsdaten

- **Startgeschwindigkeit**: Sofortiger Start und Datenanzeige selbst bei 100 Mio.+ Datensätzen auf durchschnittlichen Smartphones.
- **Abfrageleistung**: Skalenunabhängig, konstant blitzschneller Abruf bei jedem Datenvolumen.
- **Datensicherheit**: ACID-Transaktionsgarantien + Crash-Recovery für null Datenverlust.

### Empfehlungen

- 📱 **Beispielprojekt**: Ein vollständiges Flutter-App-Beispiel finden Sie im Verzeichnis `example`.
- 🚀 **Produktion**: Verwenden Sie den Release-Modus für eine Leistung, die den Debug-Modus weit übertrifft.
- ✅ **Standardtests**: Alle Kernfunktionen haben Standard-Integrationstests bestanden.

### Demo-Videos

<p align="center">
  <img src="../media/basic-demo.gif" alt="Tostore Basis-Performance-Demo" width="320" />
  </p>

<p align="center">
  <img src="../media/disaster-recovery.gif" alt="Tostore Desaster-Recovery-Stresstest" width="320" />
  </p>

- **Basis-Performance-Demo** (<a href="../media/basic-demo.mp4?raw=1" target="_blank" rel="noopener">basic-demo.mp4</a>): Die GIF-Vorschau kann abgeschnitten sein – klicken Sie auf das Video, um die vollständige Demo zu sehen. Zeigt, dass selbst auf einem durchschnittlichen Smartphone mit mehr als 100 M Datensätzen Startzeit, Blätter- und Such-Performance konstant und flüssig bleiben. Solange genügend Speicherplatz vorhanden ist, können Edge-Geräte auch TB- und PB-Skalierung tragen, ohne dass die Interaktivität spürbar einbricht.
- **Desaster-Recovery-Stresstest** (<a href="../media/disaster-recovery.mp4?raw=1" target="_blank" rel="noopener">disaster-recovery.mp4</a>): Unterbricht absichtlich den Prozess während intensiver Schreiblast, um Abstürze und Stromausfälle zu simulieren. Selbst wenn zehntausende Schreiboperationen abrupt abgebrochen werden, stellt Tostore die Daten auf einem typischen Smartphone sehr schnell wieder her, ohne den nächsten Start oder die Datenverfügbarkeit zu beeinträchtigen.




Falls Tostore Ihnen hilft, geben Sie uns bitte ein ⭐️




## Roadmap

Tostore entwickelt aktiv Funktionen zur weiteren Stärkung der Dateninfrastruktur im KI-Zeitalter:

- **Hochdimensionale Vektoren**: Hinzufügen von Vektorabruf und semantischen Suchalgorithmen.
- **Multimodale Daten**: Bereitstellung von Ende-zu-Ende-Verarbeitung von Rohdaten zu Merkmalsvektoren.
- **Graph-Datenstrukturen**: Unterstützung für effiziente Speicherung und Abfrage von Wissensgraphen und komplexen relationalen Netzwerken.





> **Empfehlung**: Mobile Entwickler sollten auch das [Toway Framework](https://github.com/tocreator/toway) in Betracht ziehen, eine Full-Stack-Lösung, die Datenabfragen, Laden, Speichern, Caching und Anzeige automatisiert.




## Weitere Ressourcen

- 📖 **Dokumentation**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Feedback**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Diskussion**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


## Lizenz

Dieses Projekt lizenziert unter der Apache License 2.0 – siehe die [LICENSE](LICENSE)-Datei für Details.

---
