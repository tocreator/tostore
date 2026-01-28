# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | Deutsch | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)


## Warum Tostore wählen?

Tostore ist die einzige Hochleistungs-Speicher-Engine für verteilte Vektordatenbanken im Dart/Flutter-Ökosystem. Basierend auf einer neuronalen netzwerkähnlichen Architektur bietet es eine intelligente Vernetzung und Zusammenarbeit zwischen den Knoten und unterstützt eine unendliche horizontale Skalierung. Es baut ein flexibles Datentopologie-Netzwerk auf und bietet präzise Identifizierung von Schemaänderungen, Verschlüsselungsschutz sowie Multi-Space-Datentrennung. Tostore nutzt Multi-Core-CPUs für extrem parallele Verarbeitung voll aus und unterstützt nativ die plattformübergreifende Zusammenarbeit von mobilen Edge-Geräten bis hin zur Cloud. Mit verschiedenen verteilten Primärschlüssel-Algorithmen bietet es eine leistungsstarke Datengrundlage für Szenarien wie immersive Virtual Reality, multimodale Interaktion, Spatial Computing, generative KI und semantische Vektorraumodellierung.

Da generative KI und Spatial Computing das Rechenzentrum an den Rand (Edge) verschieben, entwickeln sich Endgeräte von reinen Inhaltsanzeigen zu Kernpunkten für lokale Generierung, Umgebungswahrnehmung und Echtzeit-Entscheidungsfindung. Traditionelle eingebettete Datenbanken mit nur einer Datei sind durch ihr Architekturdesign begrenzt und haben oft Schwierigkeiten, die unmittelbaren Reaktionsanforderungen intelligenter Anwendungen bei hohen parallelen Schreibvorgängen, massiver Vektorsuche und Cloud-Edge-kollaborativer Generierung zu unterstützen. Tostore wurde für Edge-Geräte entwickelt und verleiht ihnen verteilte Speicherfähigkeiten, die ausreichen, um komplexe lokale KI-Generierung und großflächigen Datenfluss zu unterstützen – eine echte tiefe Zusammenarbeit zwischen Cloud und Edge.

**Stromausfall- und absturzsicher**: Selbst bei einem unerwarteten Stromausfall oder Anwendungsabsturz können Daten automatisch wiederhergestellt werden, was einen echten Null-Verlust bedeutet. Sobald eine Datenoperation bestätigt wird, wurden die Daten bereits sicher gespeichert, sodass kein Risiko eines Datenverlusts besteht.

**Leistungsgrenzen sprengen**: Leistungstests zeigen, dass selbst bei 10 Millionen Datensätzen ein typisches Smartphone sofort startet und Abfrageergebnisse augenblicklich anzeigt. Unabhängig vom Datenvolumen genießen Sie ein reibungsloses Erlebnis, das herkömmliche Datenbanken bei weitem übertrifft.




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

// 3. Verkettete Abfragen (Unterstützt =, !=, >, <, LIKE, IN usw.)
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
          unique: true,
          fieldId: 'username',  // Eindeutige Feld-ID
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime
        ),
      ],
      indexes: [ // Indexdefinitionen
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
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

## Serverseitige Integration

```dart
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
          indexType: VectorIndexType.hnsw,   // HNSW-Algorithmus für effiziente ANN
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
await db.upsert('users', {
  'email': 'john@example.com',
  'name': 'John New'
}).where('email', '=', 'john@example.com');
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

## Sicherheitskonfiguration

**Datensicherheitsmechanismen**:
- Doppelte Schutzmechanismen stellen sicher, dass Daten nie verloren gehen.
- Automatische Crash-Wiederherstellung für unvollständige Operationen.
- Sofortige sichere Persistenz bei Erfolg der Operation.
- Hochfeste Verschlüsselung schützt sensible Daten.

> [!WARNING]
> **Schlüsselverwaltung**: Eine Änderung des `encryptionKey` macht alte Daten unlesbar (außer bei Durchführung einer Migration). Codieren Sie keine sensiblen Schlüssel fest ein; beziehen Sie diese von einem sicheren Server.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Unterstützte Algorithmen: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // Kodierungsschlüssel (muss bei Initialisierung bereitgestellt werden)
      encodingKey: 'Ihr-32-Byte-langer-Kodierungsschlüssel...', 
      
      // Verschlüsselungsschlüssel für kritische Daten
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


## Leistung & Erfahrung

### Leistungsdaten

- **Startgeschwindigkeit**: Sofortiger Start und Datenanzeige selbst bei 10 Mio.+ Datensätzen auf durchschnittlichen Smartphones.
- **Abfrageleistung**: Skalenunabhängig, konstant blitzschneller Abruf bei jedem Datenvolumen.
- **Datensicherheit**: ACID-Transaktionsgarantien + Crash-Recovery für null Datenverlust.

### Empfehlungen

- 📱 **Beispielprojekt**: Ein vollständiges Flutter-App-Beispiel finden Sie im Verzeichnis `example`.
- 🚀 **Produktion**: Verwenden Sie den Release-Modus für eine Leistung, die den Debug-Modus weit übertrifft.
- ✅ **Standardtests**: Alle Kernfunktionen haben Standard-Integrationstests bestanden.




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

Dieses Projekt lizenziert unter der MIT-Lizenz – siehe die [LICENSE](LICENSE)-Datei für Details.

---
