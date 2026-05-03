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

## Schnelle Navigation
- [Why ToStore](#why-tostore) | [Hauptmerkmale](#key-features) | [Installationsanleitung](#installation) | [KV-Modus](#quick-start-kv) | [Tabellenmodus](#quick-start-table) | [Speichermodus](#quick-start-memory)
- [Schemadefinition](#schema-definition) | [Verteilte Architektur](#distributed-architecture) | [Kaskadierende Fremdschlüssel](#foreign-keys) | [Mobil/Desktop](#mobile-integration) | [Server/Agent](#server-integration) | [Primärschlüsselalgorithmen](#primary-key-examples)
- [Erweiterte Abfragen (JOIN)](#query-advanced) | [Aggregation & Statistik](#aggregation-stats) | [Komplexe Logik (Abfragebedingung)](#query-condition) | [Reaktive Abfrage (beobachten)](#reactive-query) | [Streaming-Anfrage](#streaming-query)
- [Fortgeschrittenes KV](#kv-advanced) | [Stapeloperationen](#bulk-operations) | [Vektorsuche](#vector-advanced) | [TTL auf Tabellenebene](#ttl-config) | [Effiziente Paginierung](#query-pagination) | [Abfrage-Cache](#query-cache) | [Atomare Ausdrücke](#atomic-expressions) | [Transaktionen](#transactions)
- [Administration](#database-maintenance) | [Sicherheitskonfiguration](#security-config) | [Fehlerbehandlung](#error-handling) | [Leistung und Diagnose](#performance) | [Weitere Ressourcen](#more-resources)

## <a id="why-tostore"></a>Warum ToStore wählen?

ToStore ist eine moderne Daten-Engine, die für die AGI-Ära und Edge-Intelligence-Szenarien entwickelt wurde. Es unterstützt nativ verteilte Systeme, multimodale Fusion, relationale strukturierte Daten, hochdimensionale Vektoren und unstrukturierte Datenspeicherung. Es basiert auf einer Self-Routing-Knotenarchitektur und einer von neuronalen Netzwerken inspirierten Engine und verleiht den Knoten eine hohe Autonomie und elastische horizontale Skalierbarkeit, während es gleichzeitig die Leistung logisch von der Datenskala entkoppelt. Es umfasst ACID-Transaktionen, komplexe relationale Abfragen (JOINs und kaskadierende Fremdschlüssel), TTL auf Tabellenebene und Aggregationen sowie mehrere verteilte Primärschlüsselalgorithmen, atomare Ausdrücke, Erkennung von Schemaänderungen, Verschlüsselung, Multispace-Datenisolierung, ressourcenbewusste intelligente Lastplanung und selbstheilende Wiederherstellung nach einem Notfall/Absturz.

Da sich die Datenverarbeitung immer weiter in Richtung Edge Intelligence verlagert, sind Agenten, Sensoren und andere Geräte nicht mehr nur „Inhaltsanzeigen“. Sie sind intelligente Knoten, die für die lokale Erzeugung, das Umweltbewusstsein, die Entscheidungsfindung in Echtzeit und den koordinierten Datenfluss verantwortlich sind. Herkömmliche Datenbanklösungen sind durch ihre zugrunde liegende Architektur und angehängte Erweiterungen eingeschränkt, wodurch es immer schwieriger wird, die Anforderungen an niedrige Latenz und Stabilität intelligenter Edge-Cloud-Anwendungen bei Schreibvorgängen mit hoher Parallelität, umfangreichen Datensätzen, Vektorabruf und kollaborativer Generierung zu erfüllen.

ToStore bietet dem Edge verteilte Funktionen, die stark genug für riesige Datensätze, komplexe lokale KI-Generierung und groß angelegte Datenbewegungen sind. Die tiefgreifende intelligente Zusammenarbeit zwischen Edge- und Cloud-Knoten bietet eine zuverlässige Datengrundlage für immersive Mixed Reality, multimodale Interaktion, semantische Vektoren, räumliche Modellierung und ähnliche Szenarien.

## <a id="key-features"></a>Hauptmerkmale

- 🌐 **Einheitliche plattformübergreifende Daten-Engine**
  - Einheitliche API für Mobil-, Desktop-, Web- und Serverumgebungen
  - Unterstützt relationale strukturierte Daten, hochdimensionale Vektoren und unstrukturierte Datenspeicherung
  - Baut eine Datenpipeline vom lokalen Speicher bis zur Edge-Cloud-Zusammenarbeit auf

- 🧠 **Verteilte Architektur im Stil eines neuronalen Netzwerks**
  - Selbstrouting-Knotenarchitektur, die die physische Adressierung von der Skalierung entkoppelt
  - Hochgradig autonome Knoten arbeiten zusammen, um eine flexible Datentopologie aufzubauen
  - Unterstützt Knotenkooperation und elastische horizontale Skalierung
  - Tiefe Verbindung zwischen Edge-intelligenten Knoten und der Cloud

- ⚡ **Parallele Ausführung und Ressourcenplanung**
  - Ressourcenbewusste intelligente Lastplanung mit hoher Verfügbarkeit
  - Parallele Zusammenarbeit mit mehreren Knoten und Aufgabenzerlegung
  - Time-Slicing sorgt dafür, dass UI-Animationen auch unter hoher Last flüssig bleiben

- 🔍 **Strukturierte Abfragen und Vektorabfrage**
  - Unterstützt komplexe Prädikate, JOINs, Aggregationen und TTL auf Tabellenebene
  - Unterstützt Vektorfelder, Vektorindizes und den Abruf des nächsten Nachbarn
  - Strukturierte und Vektordaten können innerhalb derselben Engine zusammenarbeiten

- 🔑 **Primärschlüssel, Indizes und Schemaentwicklung**
  - Integrierte Primärschlüsselalgorithmen, einschließlich sequentieller, Zeitstempel-, Datums-Präfix- und Kurzcode-Strategien
  – Unterstützt eindeutige Indizes, zusammengesetzte Indizes, Vektorindizes und Fremdschlüsseleinschränkungen
  - Erkennt automatisch Schemaänderungen und schließt die Migrationsarbeit ab

- 🛡️ **Transaktionen, Sicherheit und Wiederherstellung**
  – Bietet ACID-Transaktionen, atomare Ausdrucksaktualisierungen und kaskadierende Fremdschlüssel
  – Unterstützt Crash Recovery, dauerhafte Commits und Konsistenzgarantien
  - Unterstützt die Verschlüsselung ChaCha20-Poly1305 und AES-256-GCM

- 🔄 **Multi-Space- und Daten-Workflows**
  – Unterstützt isolierte Räume mit optional global gemeinsam genutzten Daten
  - Unterstützt Echtzeit-Abfrage-Listener, mehrstufiges intelligentes Caching und Cursor-Paginierung
  - Geeignet für Mehrbenutzer-, Local-First- und Offline-Kollaborationsanwendungen

## <a id="installation"></a>Installation

> [!IMPORTANT]
> **Upgrade von v2.x?** Bitte lesen Sie den [v3.x-Upgrade-Leitfaden](../UPGRADE_GUIDE_v3.md) für wichtige Migrationsschritte und wichtige Änderungen.

Fügen Sie `tostore` zu Ihrem `pubspec.yaml` hinzu:

```yaml
dependencies:
  tostore: any # Please use the latest version
```

## <a id="quick-start"></a>Schnellstart

> [!TIP]
> **Wie sollten Sie einen Speichermodus auswählen?**
> 1. [**Schlüsselwertmodus (KV)**](#quick-start-kv): Am besten für Konfigurationszugriff, verteilte Statusverwaltung oder JSON-Datenspeicherung geeignet. Dies ist der schnellste Weg, um loszulegen.
> 2. [**Strukturierter Tabellenmodus**](#quick-start-table): Am besten für Kerngeschäftsdaten geeignet, die komplexe Abfragen, Einschränkungsvalidierung oder umfangreiche Datenverwaltung erfordern. Indem Sie die Integritätslogik in die Engine integrieren, können Sie die Entwicklungs- und Wartungskosten auf der Anwendungsebene erheblich senken.
> 3. [**Speichermodus**](#quick-start-memory): Am besten für temporäre Berechnungen, Unit-Tests oder **ultraschnelle globale Zustandsverwaltung**. Mit globalen Abfragen und `watch`-Listenern können Sie die Anwendungsinteraktion umgestalten, ohne einen Stapel globaler Variablen verwalten zu müssen.

### <a id="quick-start-kv"></a>Schlüsselwertspeicher (KV)
Dieser Modus eignet sich, wenn Sie keine vordefinierten strukturierten Tabellen benötigen. Es ist einfach, praktisch und wird von einer leistungsstarken Speicher-Engine unterstützt. **Seine effiziente Indexierungsarchitektur sorgt dafür, dass die Abfrageleistung selbst auf normalen Mobilgeräten bei sehr großen Datenmengen äußerst stabil und extrem reaktionsfähig bleibt.** Daten in verschiedenen Spaces werden natürlich isoliert, während auch die globale Freigabe unterstützt wird.

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

> [!TIP]
> **Benötigen Sie weitere Key-Value-Funktionen?**
> Für fortgeschrittene Operationen wie typsicheres Lesen (`getInt`, `getBool`), atomares Inkrementieren, Präfixsuche und Key-Space-Exploration lesen Sie bitte [**Fortgeschrittene Key-Value-Operationen (db.kv)**](#kv-advanced).

#### Beispiel für die automatische Aktualisierung der Flutter-Benutzeroberfläche
In Flutter erhalten Sie mit `StreamBuilder` plus `watchValue` einen sehr prägnanten reaktiven Aktualisierungsfluss:

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

### <a id="quick-start-table"></a>Strukturierter Tabellenmodus
CRUD für strukturierte Tabellen erfordert, dass das Schema im Voraus erstellt wird (siehe [Schemadefinition](#schema-definition)). Empfohlene Integrationsansätze für verschiedene Szenarien:
- **Mobil/Desktop**: Für [häufige Startszenarien](#mobile-integration) wird empfohlen, `schemas` während der Initialisierung zu übergeben.
- **Server/Agent**: Für [Szenarien mit langer Laufzeit](#server-integration) wird empfohlen, Tabellen dynamisch über `createTables` zu erstellen.

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

### <a id="quick-start-memory"></a>Speichermodus

Für Szenarien wie Caching, temporäre Berechnungen oder Arbeitslasten, die keine Persistenz auf der Festplatte benötigen, können Sie eine reine In-Memory-Datenbank über `ToStore.memory()` initialisieren. In diesem Modus verbleiben alle Daten, einschließlich Schemata, Indizes und Schlüssel-Wert-Paare, vollständig im Speicher, um eine maximale Lese-/Schreibleistung zu gewährleisten.

#### 💡 Funktioniert auch als Global State Management
Sie benötigen keinen Haufen globaler Variablen oder ein schwergewichtiges Zustandsverwaltungs-Framework. Durch die Kombination des Speichermodus mit `watchValue` oder `watch()` können Sie eine vollautomatische Aktualisierung der Benutzeroberfläche über Widgets und Seiten hinweg erreichen. Es behält die leistungsstarken Abruffähigkeiten einer Datenbank bei und bietet Ihnen gleichzeitig ein reaktives Erlebnis, das weit über gewöhnliche Variablen hinausgeht, was es ideal für den Anmeldestatus, die Live-Konfiguration oder globale Nachrichtenzähler macht.

> [!CAUTION]
> **Hinweis**: Im reinen Speichermodus erstellte Daten gehen vollständig verloren, nachdem die App geschlossen oder neu gestartet wird. Verwenden Sie es nicht für Kerngeschäftsdaten.

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


## <a id="schema-definition"></a>Schemadefinition
**Definieren Sie es einmal und überlassen Sie die Engine die automatisierte End-to-End-Governance, sodass für Ihre Anwendung keine aufwändige Validierungswartung mehr erforderlich ist.**

Die folgenden mobilen, serverseitigen und Agent-Beispiele verwenden alle das hier definierte `appSchemas` wieder.


### TableSchema-Übersicht

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
      type: IndexType.btree, // Index type: btree/vector
    ),
  ],
  foreignKeys: const [], // Optional foreign-key constraints; see "Foreign Keys & Cascading"
  isGlobal: false, // Whether this is a global table; true means it can be shared across spaces
  ttlConfig: null, // Optional table-level TTL; see "Table-level TTL"
);

const appSchemas = [userSchema];
```

- **Gemeinsame `DataType`-Zuordnungen**:
  | Geben Sie | ein Entsprechender Darttyp | Beschreibung |
  | :--- | :--- | :--- |
| `integer` | `int` | Standard-Ganzzahl, geeignet für IDs, Zähler und ähnliche Daten |
  | `bigInt` | `BigInt` / `String` | Große ganze Zahlen; empfohlen, wenn Zahlen mehr als 18 Ziffern umfassen, um Genauigkeitsverluste zu vermeiden |
  | `double` | `double` | Gleitkommazahl, geeignet für Preise, Koordinaten und ähnliche Daten |
  | `text` | `String` | Textzeichenfolge mit optionalen Längenbeschränkungen |
  | `blob` | `Uint8List` | Rohe Binärdaten |
  | `boolean` | `bool` | Boolescher Wert |
  | `datetime` | `DateTime` / `String` | Datum/Uhrzeit; intern als ISO8601 | gespeichert
  | `array` | `List` | Listen- oder Array-Typ |
  | `json` | `Map<String, dynamic>` | JSON-Objekt, geeignet für dynamisch strukturierte Daten |
  | `vector` | `VectorData` / `List<num>` | Hochdimensionale Vektordaten für den semantischen Retrieval der KI (Einbettungen) |

- **`PrimaryKeyType` Strategien zur automatischen Generierung**:
  | Strategie | Beschreibung | Eigenschaften |
  | :--- | :--- | :--- |
| `none` | Keine automatische Generierung | Sie müssen den Primärschlüssel beim Einfügen manuell angeben |
  | `sequential` | Sequentielles Inkrement | Gut für benutzerfreundliche IDs, aber weniger geeignet für verteilte Leistung |
  | `timestampBased` | Zeitstempelbasiert | Empfohlen für verteilte Umgebungen |
  | `datePrefixed` | Datum mit Präfix | Nützlich, wenn die Lesbarkeit des Datums für das Unternehmen wichtig ist |
  | `shortCode` | Kurzcode-Primärschlüssel | Kompakt und für externe Anzeige geeignet |

> Alle Primärschlüssel werden standardmäßig als `text` (`String`) gespeichert.


### Einschränkungen und automatische Validierung

Sie können allgemeine Validierungsregeln direkt in `FieldSchema` schreiben und so doppelte Logik im Anwendungscode vermeiden:

- `nullable: false`: Nicht-Null-Einschränkung
- `minLength` / `maxLength`: Einschränkungen der Textlänge
- `minValue` / `maxValue`: Ganzzahl- oder Gleitkomma-Bereichseinschränkungen
- `defaultValue` / `defaultValueType`: statische Standardwerte und dynamische Standardwerte
- `unique`: eindeutige Einschränkung
- `createIndex`: Erstellen Sie Indizes für Hochfrequenzfilterung, Sortierung oder Beziehungen
- `fieldId` / `tableId`: Unterstützt die Umbenennungserkennung für Felder und Tabellen während der Migration

Darüber hinaus erstellt `unique: true` automatisch einen eindeutigen Einzelfeldindex. `createIndex: true` und Fremdschlüssel erstellen automatisch normale Einzelfeldindizes. Verwenden Sie `indexes`, wenn Sie zusammengesetzte Indizes, benannte Indizes oder Vektorindizes benötigen.


### Auswahl einer Integrationsmethode

- **Mobil/Desktop**: Am besten, wenn `appSchemas` direkt an `ToStore.open(...)` übergeben wird
- **Server/Agent**: Am besten geeignet, wenn Schemata zur Laufzeit dynamisch über `createTables(appSchemas)` erstellt werden.


## <a id="mobile-integration"></a>Integration für Mobilgeräte, Desktops und andere häufige Startszenarien

📱 **Beispiel**: [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

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

### Schemaentwicklung

Während `ToStore.open()` erkennt die Engine automatisch strukturelle Änderungen in `schemas`, wie das Hinzufügen, Entfernen, Umbenennen oder Ändern von Tabellen und Feldern sowie Indexänderungen, und führt dann die erforderlichen Migrationsarbeiten durch. Sie müssen die Datenbankversionsnummern nicht manuell verwalten oder Migrationsskripts schreiben.


### Anmeldestatus und Abmeldung beibehalten (aktiver Bereich)

Multi-Space ist ideal zum **Isolieren von Benutzerdaten**: ein Space pro Benutzer, eingeschaltet bei der Anmeldung. Mit **Active Space** und Schließoptionen können Sie den aktuellen Benutzer über App-Neustarts hinweg behalten und ein sauberes Abmeldeverhalten unterstützen.

- **Anmeldestatus beibehalten**: Nachdem Sie einen Benutzer in seinen eigenen Bereich versetzt haben, markieren Sie diesen Bereich als aktiv. Beim nächsten Start kann dieser Bereich direkt beim Öffnen der Standardinstanz aufgerufen werden, ohne den Schritt „Zuerst Standard, dann wechseln“.
- **Abmelden**: Wenn sich der Benutzer abmeldet, schließen Sie die Datenbank mit `keepActiveSpace: false`. Beim nächsten Start wird nicht automatisch der Bereich des vorherigen Benutzers betreten.

```dart
// After login: switch to the user's space and mark it active
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Optional: strictly stay in default when needed (for example, login screen only)
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// On logout: close and clear the active space so the next launch starts from default
await db.close(keepActiveSpace: false);
```


## <a id="server-integration"></a>Serverseitige / Agenten-Integration (Langzeitszenarien)

🖥️ **Beispiel**: [server_quickstart.dart](../../example/lib/server_quickstart.dart)

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


## <a id="advanced-usage"></a>Erweiterte Nutzung

ToStore bietet eine Vielzahl erweiterter Funktionen für komplexe Geschäftsszenarien:


### <a id="kv-advanced"></a>Fortgeschrittene Key-Value-Operationen (db.kv)

Für komplexere Key-Value-Szenarien wird empfohlen, den Namespace `db.kv` zu verwenden. Er bietet einen vollständigen Satz von APIs mit Speicherplatzisolierung, globaler Freigabe und mehreren Datentypen.

- **Grundlegender Zugriff (Basic Access)**
  ```dart
  // Wert setzen (unterstützt String, int, bool, double, Map, List usw.)
  await db.kv.set('key', 'value', ttl: Duration(hours: 1));
  
  // Rohwert für dynamischen Typ abrufen
  dynamic val = await db.kv.get('key');

  // Einzelnen Schlüssel entfernen
  await db.kv.remove('key');
  ```

- **Typsichere Getter (Type-Safe Getters)**
  Rufen Sie Daten direkt im Zielformat ab, ohne manuelle Konvertierung:
  ```dart
  String? name = await db.kv.getString('user_name');
  int? age = await db.kv.getInt('user_age');
  bool? isVip = await db.kv.getBool('is_vip');
  Map<String, dynamic>? profile = await db.kv.getMap('profile');
  List<String>? tags = await db.kv.getList<String>('tags');
  ```

- **Stapeloperationen (Bulk Operations)**
  Verarbeiten Sie effizient mehrere Key-Value-Paare in einer einzigen Operation:
  ```dart
  // Stapelweises Setzen
  await db.kv.setMany({
    'theme': 'dark',
    'language': 'de_DE',
  });

  // Stapelweises Entfernen
  await db.kv.removeKeys(['temp_1', 'temp_2']);
  ```

- **Atomare Zähler (Atomic Increment)**
  Erhöhen oder verringern Sie numerische Werte sicher in Szenarien mit hoher Parallelität:
  ```dart
  // Um 1 erhöhen (Standard)
  await db.kv.setIncrement('view_count');
  // Um 5 verringern (einen negativen Wert übergeben)
  await db.kv.setIncrement('stock_count', amount: -5);
  ```

- **Erkundung & Verwaltung (Discovery & Management)**
  ```dart
  // Alle Schlüssel abrufen, die mit 'setting_' beginnen
  final keys = await db.kv.getKeys(prefix: 'setting_');

  // Gesamtzahl der Schlüssel im aktuellen Bereich zählen
  final count = await db.kv.count();

  // Prüfen, ob ein Schlüssel existiert und nicht abgelaufen ist
  final exists = await db.kv.exists('config_cache');

  // Alle KV-Daten im aktuellen Bereich löschen
  await db.kv.clear();
  ```

- **Lebenszyklus-Management (TTL)**
  Ablauf-Einstellungen für vorhandene Schlüssel prüfen oder aktualisieren:
  ```dart
  // Verbleibende Dauer abrufen
  Duration? ttl = await db.kv.getTtl('token');

  // TTL für einen vorhandenen Schlüssel aktualisieren (läuft in 7 Tagen ab)
  await db.kv.setTtl('token', Duration(days: 7));
  ```

- **Reaktive Überwachung (Reactive Watch)**
  ```dart
  // Einzelnen Schlüssel überwachen
  db.kv.watch<int>('unread_count').listen((count) => print(count));

  // Snapshot mehrerer Schlüssel überwachen
  db.kv.watchValues(['theme', 'font_size']).listen((map) => print(map));
  ```

- **Globale Freigabe (isGlobal)**
  Alle oben genannten Methoden unterstützen den optionalen Parameter `isGlobal`: `true` für den globalen Bereich (über alle Bereiche hinweg geteilt), `false` (Standard) für den aktuellen isolierten Bereich.


### <a id="bulk-operations"></a>Stapeloperationen (Bulk Operations)

ToStore bietet spezialisierte Schnittstellen für die Stapelverarbeitung, die für einen hohen Datendurchsatz optimiert sind. Diese Schnittstellen nutzen parallele Aufgabenverteilung und Time-Slicing, um die Reaktionsfähigkeit der Benutzeroberfläche bei intensiven Schreibvorgängen zu gewährleisten.

| Methode | Hauptzweck | Datenanforderungen | Merkmale |
| :--- | :--- | :--- | :--- |
| `batchInsert` | Datensätze stapelweise einfügen | Muss alle nicht-nullbaren Felder enthalten | Reines Einfügen, höchste Leistung |
| `batchUpsert` | Intelligente Synchronisation (Upsert) | **Muss alle nicht-nullbaren Felder enthalten** | Vollständige Synchronisation, Identifizierung über Primärschlüssel oder eindeutiges Feld |
| `batchUpdate` | Datensätze stapelweise aktualisieren | **Primärschlüssel oder eindeutiges Feld** + Aktualisierungsfelder | Partielle Aktualisierungen für vorhandene Datensätze |

- **Stapelweises Einfügen (batchInsert)**
  ```dart
  await db.batchInsert('users', [
    {'username': 'user1', 'email': '1@ex.com'},
    {'username': 'user2', 'email': '2@ex.com'},
  ]);
  ```

- **Intelligente Stapel-Synchronisation (batchUpsert)**
  Identifiziert automatisch "Einfügen" oder "Aktualisieren" basierend auf dem Primärschlüssel oder eindeutigen Feldern. Häufig für die vollständige Datensynchronisation verwendet.
  > [!IMPORTANT]
  > **Datenanforderungen**: Da ein Einfügevorgang ausgelöst werden kann, erfordert `batchUpsert`, dass jeder Datensatz alle nicht-nullbaren (`nullable: false`) Felder enthält.

- **Hochleistungs-Stapelaktualisierung (batchUpdate)**
  Speziell für die Aktualisierung vorhandener Datensätze. Jeder Datensatz muss einen Primärschlüssel oder ein eindeutiges Feld als Bezeichner enthalten, zusammen mit den zu ändernden Feldern.
  > [!TIP]
  > **Partielle Aktualisierungen**: `batchUpdate` ändert nur die bereitgestellten Felder und erfordert nicht alle nicht-nullbaren Felder, was es ideal für inkrementelle Aktualisierungen macht.
  ```dart
  await db.batchUpdate('users', [
    {'username': 'john', 'age': 27}, // Über eindeutiges Feld 'username' identifizieren und 'age' aktualisieren
    {'id': '1002', 'status': 'active'}, // Kann auch den Primärschlüssel direkt verwenden
  ]);
  ```

> [!TIP]
> Sie können `allowPartialErrors: true` festlegen, um sicherzustellen, dass Fehler bei einzelnen Datensätzen (z. B. eine Verletzung einer eindeutigen Einschränkung) nicht die gesamte Stapeloperation ablehnen.


### <a id="vector-advanced"></a>Vektorfelder, Vektorindizes und Vektorsuche

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

Parameterhinweise:

- `dimensions`: muss mit der tatsächlichen Einbettungsbreite übereinstimmen, die Sie schreiben
- `precision`: gängige Optionen sind `float64`, `float32` und `int8`; Eine höhere Präzision kostet normalerweise mehr Speicherplatz
- `distanceMetric`: `cosine` ist für semantische Einbettungen üblich, `l2` entspricht der euklidischen Distanz und `innerProduct` eignet sich für die Skalarproduktsuche
- `maxDegree`: Obergrenze der pro Knoten im NGH-Diagramm beibehaltenen Nachbarn; Höhere Werte verbessern in der Regel den Rückruf auf Kosten von mehr Speicher und Erstellungszeit
- `efSearch`: Suchzeit-Erweiterungsbreite; Eine Erhöhung verbessert normalerweise die Erinnerung, erhöht jedoch die Latenz
- `constructionEf`: Erweiterungsbreite zur Build-Zeit; Eine Erhöhung verbessert normalerweise die Indexqualität, erhöht jedoch die Erstellungszeit
- `topK`: Anzahl der zurückzugebenden Ergebnisse

Ergebnisnotizen:

- `score`: normalisierter Ähnlichkeitswert, typischerweise im `0 ~ 1` Bereich; größer bedeutet ähnlicher
- `distance`: Distanzwert; für `l2` und `cosine` bedeutet kleiner normalerweise ähnlicher

### <a id="ttl-config"></a>TTL auf Tabellenebene (automatischer zeitbasierter Ablauf)

Für Protokolle, Telemetrie, Ereignisse und andere Daten, die mit der Zeit ablaufen sollen, können Sie TTL auf Tabellenebene über `ttlConfig` definieren. Die Engine bereinigt abgelaufene Datensätze automatisch im Hintergrund:

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


### Intelligenter Speicher (Upsert)
ToStore entscheidet basierend auf dem Primärschlüssel oder dem eindeutigen Feld in `data`, ob aktualisiert oder eingefügt wird. `where` wird hier nicht unterstützt; das Ziel des Konflikts wird durch die Daten selbst bestimmt.

```dart
// Nach Primärschlüssel
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// Nach eindeutigem Schlüssel (der Datensatz muss alle Felder enthalten, die an einer eindeutigen Einschränkung beteiligt sind, plus Pflichtfelder)
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// Batch Upsert (unterstützt atomaren Modus oder Modus für Teilerfolg)
// allowPartialErrors: true bedeutet, dass einige Zeilen fehlschlagen können, während andere erfolgreich sind
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### <a id="query-advanced"></a>Erweiterte Abfragen

ToStore bietet eine deklarativ verkettbare Abfrage-API mit flexibler Feldverarbeitung und komplexen Beziehungen mit mehreren Tabellen.

#### 1. Feldauswahl (`select`)
Die Methode `select` gibt an, welche Felder zurückgegeben werden. Wenn Sie es nicht aufrufen, werden standardmäßig alle Felder zurückgegeben.
- **Aliase**: unterstützt die `field as alias`-Syntax (ohne Berücksichtigung der Groß- und Kleinschreibung), um Schlüssel im Ergebnissatz umzubenennen
- **Tabellenqualifizierte Felder**: Bei Verknüpfungen mit mehreren Tabellen vermeidet `table.field` Namenskonflikte
- **Aggregationsmischung**: `Agg` Objekte können direkt in der `select` Liste platziert werden

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

#### 2. Tritt bei (`join`)
Unterstützt den Standard `join` (Inner Join), `leftJoin` und `rightJoin`.

#### 3. Intelligente fremdschlüsselbasierte Verknüpfungen (empfohlen)
Wenn `foreignKeys` in `TableSchema` korrekt definiert ist, müssen Sie die Join-Bedingungen nicht handschriftlich verfassen. Die Engine kann Referenzbeziehungen auflösen und automatisch den optimalen JOIN-Pfad generieren.

- **`joinReferencedTable(tableName)`**: Verbindet automatisch die übergeordnete Tabelle, auf die die aktuelle Tabelle verweist
- **`joinReferencingTable(tableName)`**: Verbindet automatisch untergeordnete Tabellen, die auf die aktuelle Tabelle verweisen

```dart
// Assume posts defines a foreign key to users
final posts = await db.query('posts')
    .joinReferencedTable('users') // Automatically resolves to ON posts.user_id = users.id
    .select(['posts.title', 'users.username'])
    .limit(20);
```

---

### <a id="aggregation-stats"></a>Aggregation, Gruppierung und Statistik (Agg & GroupBy)

#### 1. Aggregation (`Agg` Fabrik)
Aggregatfunktionen berechnen Statistiken über einen Datensatz. Mit dem Parameter `alias` können Sie Ergebnisfeldnamen anpassen.

| Methode | Zweck | Beispiel |
| :--- | :--- | :--- |
| `Agg.count(field)` | Nicht-Null-Datensätze zählen | `Agg.count('id', alias: 'total')` |
| `Agg.sum(field)` | Summenwerte | `Agg.sum('amount', alias: 'total_price')` |
| `Agg.avg(field)` | Durchschnittswert | `Agg.avg('score', alias: 'average_score')` |
| `Agg.max(field)` | Maximalwert | `Agg.max('age')` |
| `Agg.min(field)` | Mindestwert | `Agg.min('price')` |

> [!TIP]
> **Zwei gängige Aggregationsstile**
> 1. **Abkürzungsmethoden (empfohlen für einzelne Metriken)**: Rufen Sie direkt die Kette auf und erhalten Sie den berechneten Wert sofort zurück.
> `num? totalAge = await db.query('users').sum('age');`
> 2. **Eingebettet in `select` (für mehrere Metriken oder Gruppierung)**: Übergeben Sie `Agg`-Objekte an die `select`-Liste.
> `final stats = await db.query('orders').select(['status', Agg.sum('amount')]).groupBy(['status']);`

#### 2. Gruppieren und Filtern (`groupBy` / `having`)
Verwenden Sie `groupBy`, um Datensätze zu kategorisieren, und dann `having`, um aggregierte Ergebnisse zu filtern, ähnlich dem HAVING-Verhalten von SQL.

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

#### 3. Hilfsabfragemethoden
- **`exists()` (Hochleistung)**: prüft, ob ein Datensatz übereinstimmt. Im Gegensatz zu `count() > 0` wird es kurzgeschlossen, sobald eine Übereinstimmung gefunden wird, was sich hervorragend für sehr große Datensätze eignet.
- **`count()`**: Gibt effizient die Anzahl der übereinstimmenden Datensätze zurück.
- **`first()`**: eine praktische Methode, die `limit(1)` entspricht und die erste Zeile direkt als `Map` zurückgibt.
- **`distinct([fields])`**: dedupliziert Ergebnisse. Wenn `fields` angegeben werden, wird die Eindeutigkeit anhand dieser Felder berechnet.

```dart
// Efficient existence check
if (await db.query('users').whereEqual('email', 'test@test.com').exists()) {
  print('Email is already registered');
}

// Get a deduplicated city list
final cities = await db.query('users').distinct(['city']);
```

#### <a id="query-condition"></a>4. Komplexe Logik mit `QueryCondition`
`QueryCondition` ist das Kerntool von ToStore für verschachtelte Logik und die Erstellung von Abfragen in Klammern. Wenn einfache verkettete `where`-Aufrufe für Ausdrücke wie `(A AND B) OR (C AND D)` nicht ausreichen, ist dies das richtige Werkzeug.

- **`condition(QueryCondition sub)`**: öffnet eine `AND` verschachtelte Gruppe
- **`orCondition(QueryCondition sub)`**: öffnet eine `OR` verschachtelte Gruppe
- **`or()`**: Ändert den nächsten Connector zu `OR` (Standard ist `AND`)

##### Beispiel 1: Gemischte ODER-Bedingungen
Äquivalentes SQL: `WHERE is_active = true AND (role = 'admin' OR fans >= 1000)`

```dart
final subGroup = QueryCondition()
    .whereEqual('role', 'admin')
    .or()
    .whereGreaterThanOrEqualTo('fans', 1000);

final results = await db.query('users')
    .whereEqual('is_active', true)
    .condition(subGroup);
```

##### Beispiel 2: Wiederverwendbare Bedingungsfragmente
Sie können wiederverwendbare Geschäftslogikfragmente einmalig definieren und sie in verschiedenen Abfragen kombinieren:

```dart
final hotUser = QueryCondition().whereGreaterThan('fans', 5000);
final recentLogin = QueryCondition().whereGreaterThan('last_login', '2024-01-01');

final targetUsers = await db.query('users')
    .condition(hotUser)
    .condition(recentLogin);
```


#### <a id="streaming-query"></a>5. Streaming-Abfrage
Geeignet für sehr große Datensätze, wenn Sie nicht alles auf einmal in den Speicher laden möchten. Die Ergebnisse können beim Lesen verarbeitet werden.

```dart
db.streamQuery('users').listen((data) {
  print('Processing one record: $data');
});
```

#### <a id="reactive-query"></a>6. Reaktive Abfrage
Mit der `watch()`-Methode können Sie Abfrageergebnisse in Echtzeit überwachen. Es gibt ein `Stream` zurück und führt die Abfrage automatisch erneut aus, wenn sich übereinstimmende Daten in der Zieltabelle ändern.
- **Automatische Entprellung**: Die integrierte intelligente Entprellung vermeidet redundante Abfragestöße
- **UI-Synchronisierung**: Funktioniert natürlich mit Flutter `StreamBuilder` für die Live-Aktualisierung von Listen

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

### <a id="query-cache"></a>Manuelles Zwischenspeichern von Abfrageergebnissen (optional)

> [!IMPORTANT]
> **ToStore enthält intern bereits einen effizienten mehrstufigen intelligenten LRU-Cache.**
> **Eine routinemäßige manuelle Cache-Verwaltung wird nicht empfohlen.** Erwägen Sie dies nur in besonderen Fällen:
> 1. Teure vollständige Scans nicht indizierter Daten, die sich selten ändern
> 2. Anhaltende Anforderungen an extrem niedrige Latenzzeiten, auch für nicht heiße Abfragen

- `useQueryCache([Duration? expiry])`: Cache aktivieren und optional einen Ablauf festlegen
- `noQueryCache()`: Cache für diese Abfrage explizit deaktivieren
- `clearQueryCache()`: Den Cache für dieses Abfragemuster manuell ungültig machen

```dart
final results = await db.query('heavy_table')
    .where('non_indexed_field', '=', 'value')
    .useQueryCache(const Duration(minutes: 10)); // Manual acceleration for a heavy query only
```


### <a id="query-pagination"></a>Abfrage und effiziente Paginierung

> [!TIP]
> **Für optimale Leistung immer `limit` angeben**: Es wird dringend empfohlen, in jeder Abfrage explizit `limit` anzugeben. Wenn es weggelassen wird, verwendet die Engine standardmäßig 1000 Zeilen. Die Kernabfrage-Engine ist schnell, aber die Serialisierung sehr großer Ergebnismengen in der Anwendungsschicht kann dennoch zu unnötigem Overhead führen.

ToStore bietet zwei Paginierungsmodi, sodass Sie je nach Skalierungs- und Leistungsanforderungen eine Auswahl treffen können:

#### 1. Grundlegende Paginierung (Offset-Modus)
Geeignet für relativ kleine Datensätze oder Fälle, in denen Sie präzise Seitensprünge benötigen.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Skip the first 40 rows
    .limit(20); // Take 20 rows
```
> [!TIP]
> Wenn `offset` sehr groß wird, muss die Datenbank viele Zeilen scannen und verwerfen, sodass die Leistung linear abnimmt. Für eine tiefe Paginierung bevorzugen Sie den **Cursormodus**.

#### 2. Cursor-Paginierung (Cursor-Modus)
Ideal für große Datensätze und unendliches Scrollen. Durch die Verwendung von `nextCursor` fährt die Engine an der aktuellen Position fort und vermeidet die zusätzlichen Scankosten, die mit tiefen Offsets einhergehen.

> [!IMPORTANT]
> Bei einigen komplexen Abfragen oder Sortierungen für nicht indizierte Felder greift die Engine möglicherweise auf einen vollständigen Scan zurück und gibt einen `null`-Cursor zurück, was bedeutet, dass die Paginierung derzeit für diese bestimmte Abfrage nicht unterstützt wird.

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

| Funktion | Offset-Modus | Cursormodus |
| :--- | :--- | :--- |
| **Abfrageleistung** | Verliert mit zunehmender Seitentiefe | Stabil für Deep Paging |
| **Am besten für** | Kleinere Datensätze, exakte Seitensprünge | **Massive Datensätze, unendliches Scrollen** |
| **Konsistenz bei Änderungen** | Datenänderungen können dazu führen, dass Zeilen übersprungen werden | Vermeidet Duplikate und Auslassungen durch Datenänderungen |


### <a id="foreign-keys"></a>Fremdschlüssel und Kaskadierung

Fremdschlüssel garantieren referenzielle Integrität und ermöglichen die Konfiguration kaskadierender Aktualisierungen und Löschungen. Beziehungen werden beim Schreiben und Aktualisieren validiert. Wenn Kaskadenrichtlinien aktiviert sind, werden zugehörige Daten automatisch aktualisiert, wodurch der Konsistenzaufwand im Anwendungscode reduziert wird.

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


### <a id="query-operators"></a>Abfrageoperatoren

Alle `where(field, operator, value)`-Bedingungen unterstützen die folgenden Operatoren (ohne Berücksichtigung der Groß-/Kleinschreibung):

| Operator | Beschreibung | Beispiel / Leistung |
| :--- | :--- | :--- |
| `=` | Gleich | `where('status', '=', 'val')` — **[Empfohlen]** Index-Seek |
| `!=`, `<>` | Ungleich | `where('role', '!=', 'val')` — **[Vorsicht]** Vollständiger Tabellenscan |
| `>` , `>=`, `<`, `<=` | Vergleich | `where('age', '>', 18)` — **[Empfohlen]** Index-Scan |
| `IN` | In Liste | `where('id', 'IN', [...])` — **[Empfohlen]** Index-Seek |
| `NOT IN` | Nicht in der Liste | `where('status', 'NOT IN', [...])` — **[Vorsicht]** Vollständiger Tabellenscan |
| `BETWEEN` | Bereich | `where('age', 'BETWEEN', [18, 65])` — **[Empfohlen]** Index-Scan |
| `LIKE` | Musterübereinstimmung (`%` = beliebige Zeichen, `_` = einzelnes Zeichen) | `where('name', 'LIKE', 'John%')` — **[Vorsicht]** Siehe Hinweis unten |
| `NOT LIKE` | Musterkonflikt | `where('email', 'NOT LIKE', '...')` — **[Vorsicht]** Vollständiger Tabellenscan |
| `IS` | Ist null | `where('deleted_at', 'IS', null)` — **[Empfohlen]** Index-Seek |
| `IS NOT` | Ist nicht null | `where('email', 'IS NOT', null)` — **[Vorsicht]** Vollständiger Tabellenscan |

### Semantische Abfragemethoden (empfohlen)

Empfohlen, um handgeschriebene Operatorzeichenfolgen zu vermeiden und eine bessere IDE-Unterstützung zu erhalten.

#### 1. Vergleich
Wird für direkte numerische Vergleiche oder Zeichenfolgenvergleiche verwendet.

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

#### 2. Kollektion und Sortiment
Wird verwendet, um zu testen, ob ein Feld innerhalb einer Menge oder eines Bereichs liegt.

```dart
db.query('users').whereIn('id', ['id1', 'id2']);                 // In list
db.query('users').whereNotIn('status', ['banned', 'pending']);   // Not in list
db.query('users').whereBetween('age', 18, 65);                   // In range (inclusive)
```

#### 3. Nullprüfung
Wird verwendet, um zu testen, ob ein Feld einen Wert hat.

```dart
db.query('users').whereNull('deleted_at');    // Is null
db.query('users').whereNotNull('email');      // Is not null
db.query('users').whereEmpty('nickname');     // Is null or empty string
db.query('users').whereNotEmpty('bio');       // Is not null and not empty
```

#### 4. Mustervergleich
Unterstützt die Platzhaltersuche im SQL-Stil ((`%` entspricht einer beliebigen Anzahl von Zeichen, `_` entspricht einem einzelnen Zeichen).

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
> **Leitfaden zur Abfrageleistung (Index vs. Vollscan)**
>
> Befolgen Sie in Szenarien mit großen Datenmengen (Millionen von Zeilen oder mehr) diese Prinzipien, um Verzögerungen im Haupt-Thread und Abfrage-Timeouts zu vermeiden:
>
> 1. **Index-optimiert - [Empfohlen]**:
>    *   **Semantische Methoden**: `whereEqual`, `whereGreaterThan`, `whereLessThan`, `whereIn`, `whereBetween`, `whereNull`, `whereTrue`, `whereFalse` und **`whereStartsWith`** (Präfix-Übereinstimmung).
>    *   **Operatoren**: `=`, `>`, `<`, `>=`, `<=`, `IN`, `BETWEEN`, `IS null`, `LIKE 'prefix%'`.
>    *   *Erklärung: Diese Operationen erreichen eine superschnelle Positionierung über Indizes. Bei `whereStartsWith` / `LIKE 'abc%'` kann der Index weiterhin einen Präfix-Bereichsscan durchführen.*
>
> 2. **Risiken bei Vollscan - [Vorsicht]**:
>    *   **Unscharfe Übereinstimmung**: `whereContains` (`LIKE '%val%'`), `whereEndsWith` (`LIKE '%val'`), `whereContainsAny`.
>    *   **Negationsabfragen**: `whereNotEqual` (`!=`, `<>`), `whereNotIn` (`NOT IN`), `whereNotNull` (`IS NOT null`/`whereNotEmpty`).
>    *   **Musterkonflikt**: `NOT LIKE`.
>    *   *Erklärung: Die oben genannten Operationen erfordern in der Regel das Durchlaufen des gesamten Datenspeicherbereichs, selbst wenn ein Index erstellt wurde. Während die Auswirkungen auf mobilen oder kleinen Datensätzen minimal sind, sollten sie in verteilten oder extrem großen Datenanalyseszenarien mit Vorsicht verwendet werden, kombiniert mit anderen Indexbedingungen (z. B. Filtern nach ID oder Zeitbereich) und der `limit`-Klausel.*

## <a id="distributed-architecture"></a>Verteilte Architektur

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

## <a id="primary-key-examples"></a>Beispiele für Primärschlüssel

ToStore bietet mehrere verteilte Primärschlüsselalgorithmen für verschiedene Geschäftsszenarien:

- **Sequentieller Primärschlüssel** (`PrimaryKeyType.sequential`): `238978991`
- **Zeitstempelbasierter Primärschlüssel** (`PrimaryKeyType.timestampBased`): `1306866018836946`
- **Primärschlüssel mit Datumspräfix** (`PrimaryKeyType.datePrefixed`): `20250530182215887631`
- **Kurzcode-Primärschlüssel** (`PrimaryKeyType.shortCode`): `9eXrF0qeXZ`

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


## <a id="atomic-expressions"></a>Atomare Ausdrücke

Das Ausdruckssystem stellt typsichere Aktualisierungen atomarer Felder bereit. Alle Berechnungen werden atomar auf der Datenbankebene ausgeführt, wodurch gleichzeitige Konflikte vermieden werden:

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

**Bedingte Ausdrücke (z. B. Unterscheidung zwischen Update und Insert in einem Upsert)**: Verwenden Sie `Expr.isUpdate()` / `Expr.isInsert()` zusammen mit `Expr.ifElse` oder `Expr.when`, sodass der Ausdruck nur bei der Aktualisierung oder nur beim Einfügen ausgewertet wird.

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

## <a id="transactions"></a>Transaktionen

Transaktionen stellen die Atomizität über mehrere Vorgänge hinweg sicher: Entweder ist alles erfolgreich oder alles wird zurückgesetzt, wodurch die Datenkonsistenz gewahrt bleibt.

**Transaktionsmerkmale**
- Mehrere Vorgänge sind entweder alle erfolgreich oder werden alle rückgängig gemacht
- Unvollendete Arbeiten werden nach Abstürzen automatisch wiederhergestellt
- Erfolgreiche Vorgänge werden sicher aufrechterhalten

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


### <a id="database-maintenance"></a>Verwaltung und Wartung

Die folgenden APIs decken die Datenbankverwaltung, Diagnose und Wartung für die Entwicklung im Plugin-Stil, Admin-Panels und Betriebsszenarien ab:

- **Tischverwaltung**
  - `createTable(schema)`: eine einzelne Tabelle manuell erstellen; Nützlich zum Laden von Modulen oder zum Erstellen von Laufzeittabellen bei Bedarf
  - `getTableSchema(tableName)`: Rufen Sie die definierten Schemainformationen ab; nützlich für die automatisierte Validierung oder UI-Modellgenerierung
  - `getTableInfo(tableName)`: Laufzeittabellenstatistiken abrufen, einschließlich Datensatzanzahl, Indexanzahl, Datendateigröße, Erstellungszeit und ob die Tabelle global ist
  - `clear(tableName)`: Alle Tabellendaten löschen und dabei Schema, Indizes und interne/externe Schlüsseleinschränkungen sicher beibehalten
  - `dropTable(tableName)`: Eine Tabelle und ihr Schema vollständig zerstören; nicht reversibel
- **Raumverwaltung**
  - `currentSpaceName`: Erhalten Sie den aktuell aktiven Bereich in Echtzeit
  - `listSpaces()`: Listet alle zugewiesenen Bereiche in der aktuellen Datenbankinstanz auf
  - `getSpaceInfo(useCache: true)`: Prüfen Sie den aktuellen Bereich; Verwenden Sie `useCache: false`, um den Cache zu umgehen und den Echtzeitstatus zu lesen
  - `deleteSpace(spaceName)`: Löschen Sie einen bestimmten Bereich und alle seine Daten, außer `default` und den aktuell aktiven Bereich
- **Instanzerkennung**
  - `config`: Überprüfen Sie den endgültigen gültigen `DataStoreConfig` Snapshot für die Instanz
  - `instancePath`: Lokalisieren Sie das physische Speicherverzeichnis genau
  - `getVersion()` / `setVersion(version)`: geschäftsdefinierte Versionskontrolle für Migrationsentscheidungen auf Anwendungsebene (nicht die Engine-Version)
- **Wartung**
  - `flush(flushStorage: true)`: Ausstehende Daten auf die Festplatte erzwingen; Wenn `flushStorage: true`, wird das System auch aufgefordert, Speicherpuffer auf niedrigerer Ebene zu leeren
  - `deleteDatabase()`: alle physischen Dateien und Metadaten für die aktuelle Instanz entfernen; mit Vorsicht verwenden
- **Diagnose**
  - `db.status.memory()`: Überprüfen Sie die Cache-Trefferquoten, die Indexseitennutzung und die gesamte Heap-Zuordnung
  - `db.status.space()` / `db.status.table(tableName)`: Überprüfen Sie Live-Statistiken und Gesundheitsinformationen für Räume und Tabellen
  - `db.status.config()`: Überprüfen Sie den aktuellen Snapshot der Laufzeitkonfiguration
  - `db.status.migration(taskId)`: Verfolgen Sie den Fortschritt der asynchronen Migration in Echtzeit

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


### <a id="backup-restore"></a>Sichern und Wiederherstellen

Besonders nützlich für den lokalen Import/Export für Einzelbenutzer, die Migration großer Offline-Daten und das System-Rollback nach einem Fehler:

- **Sicherung (`backup`)**
  - `compress`: ob die Komprimierung aktiviert werden soll; empfohlen und standardmäßig aktiviert
  - `scope`: steuert den Backup-Bereich
    - `BackupScope.database`: Sichert die **gesamte Datenbankinstanz**, einschließlich aller Leerzeichen und globalen Tabellen
    - `BackupScope.currentSpace`: Sichert nur den **aktuell aktiven Speicherplatz**, ausgenommen globale Tabellen
    - `BackupScope.currentSpaceWithGlobal`: Sichert den **aktuellen Speicherplatz und die zugehörigen globalen Tabellen**, ideal für die Migration einzelner Mandanten oder einzelner Benutzer
- **Wiederherstellen (`restore`)**
  - `backupPath`: physischer Pfad zum Backup-Paket
  - `cleanupBeforeRestore`: ob zugehörige aktuelle Daten vor der Wiederherstellung stillschweigend gelöscht werden sollen; `true` wird empfohlen, um gemischte logische Zustände zu vermeiden
  - `deleteAfterRestore`: Nach erfolgreicher Wiederherstellung wird die Sicherungsquelldatei automatisch gelöscht

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

### <a id="error-handling"></a>Statuscodes und Fehlerbehandlung


ToStore verwendet ein einheitliches Antwortmodell für Datenoperationen:

- `ResultType`: die einheitliche Statusaufzählung, die für die Verzweigungslogik verwendet wird
- `result.code`: ein stabiler numerischer Code entsprechend `ResultType`
- `result.message`: eine lesbare Nachricht, die den aktuellen Fehler beschreibt
- `successKeys` / `failedKeys`: Listen erfolgreicher und fehlgeschlagener Primärschlüssel bei Massenvorgängen


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

Beispiele für häufige Statuscodes:
Der Erfolg kehrt zurück `0`; Negative Zahlen weisen auf Fehler hin.
- `ResultType.success` (`0`): Vorgang erfolgreich
- `ResultType.partialSuccess` (`1`): Massenvorgang teilweise erfolgreich
- `ResultType.unknown` (`-1`): unbekannter Fehler
- `ResultType.uniqueViolation` (`-2`): eindeutiger Indexkonflikt
- `ResultType.primaryKeyViolation` (`-3`): Primärschlüsselkonflikt
- `ResultType.foreignKeyViolation` (`-4`): Fremdschlüsselreferenz erfüllt nicht die Einschränkungen
- `ResultType.notNullViolation` (`-5`): Ein erforderliches Feld fehlt oder ein unzulässiges `null` wurde übergeben
- `ResultType.validationFailed` (`-6`): Länge, Bereich, Format oder andere Validierung ist fehlgeschlagen
- `ResultType.notFound` (`-11`): Zieltabelle, Zielbereich oder Zielressource ist nicht vorhanden
- `ResultType.resourceExhausted` (`-15`): unzureichende Systemressourcen; Reduzieren Sie die Last oder versuchen Sie es erneut
- `ResultType.dbError` (`-91`): Datenbankfehler
- `ResultType.ioError` (`-90`): Dateisystemfehler
- `ResultType.timeout` (`-92`): Zeitüberschreitung

### Handhabung von Transaktionsergebnissen
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

Transaktionsfehlertypen:
- `TransactionErrorType.operationError`: Ein regulärer Vorgang ist innerhalb der Transaktion fehlgeschlagen, z. B. ein Feldvalidierungsfehler, ein ungültiger Ressourcenstatus oder ein anderer Fehler auf Unternehmensebene
- `TransactionErrorType.integrityViolation`: Integritäts- oder Einschränkungskonflikt, z. B. Primärschlüssel, eindeutiger Schlüssel, Fremdschlüssel oder Nicht-Null-Fehler
- `TransactionErrorType.timeout`: Zeitüberschreitung
- `TransactionErrorType.io`: zugrunde liegender Speicher- oder Dateisystem-E/A-Fehler
- `TransactionErrorType.conflict`: Ein Konflikt hat dazu geführt, dass die Transaktion fehlgeschlagen ist
- `TransactionErrorType.userAbort`: Vom Benutzer initiierter Abbruch (ein wurfbasierter manueller Abbruch wird derzeit nicht unterstützt)
- `TransactionErrorType.unknown`: irgendein anderer Fehler


### <a id="logging-diagnostics"></a>Protokollrückruf und Datenbankdiagnose

ToStore kann Start-, Wiederherstellungs-, automatische Migrations- und Laufzeiteinschränkungskonfliktprotokolle über `LogConfig.setConfig(...)` zurück an die Geschäftsschicht weiterleiten.

- `onLogHandler` empfängt alle Protokolle, die die aktuellen Filter `enableLog` und `logLevel` bestehen.
- Rufen Sie `LogConfig.setConfig(...)` vor der Initialisierung auf, damit auch die während der Initialisierung und der automatischen Migration generierten Protokolle erfasst werden.

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


## <a id="security-config"></a>Sicherheitskonfiguration

> [!WARNING]
> **Schlüsselverwaltung**: **`encodingKey`** kann frei geändert werden und die Engine migriert Daten automatisch, sodass die Daten wiederherstellbar bleiben. **`encryptionKey`** darf nicht leichtfertig geändert werden. Einmal geänderte alte Daten können nicht entschlüsselt werden, es sei denn, Sie migrieren sie explizit. Sensible Schlüssel niemals fest codieren; Es wird empfohlen, sie von einem sicheren Dienst abzurufen.

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

### Verschlüsselung auf Wertebene (ToCrypto)

Die vollständige Datenbankverschlüsselung schützt alle Tabellen- und Indexdaten, kann jedoch die Gesamtleistung beeinträchtigen. Wenn Sie nur wenige sensible Werte schützen müssen, verwenden Sie stattdessen **ToCrypto**. Es ist von der Datenbank entkoppelt, erfordert keine `db`-Instanz und ermöglicht Ihrer Anwendung das Kodieren/Dekodieren von Werten vor dem Schreiben oder nach dem Lesen. Die Ausgabe ist Base64, was natürlich in JSON- oder TEXT-Spalten passt.

- **`key`** (erforderlich): `String` oder `Uint8List`. Wenn es nicht 32 Bytes sind, wird SHA-256 verwendet, um einen 32-Byte-Schlüssel abzuleiten.
- **`type`** (optional): Verschlüsselungstyp von `ToCryptoType`, z. B. `ToCryptoType.chacha20Poly1305` oder `ToCryptoType.aes256Gcm`. Standardmäßig ist `ToCryptoType.chacha20Poly1305`.
- **`aad`** (optional): zusätzliche authentifizierte Daten vom Typ `Uint8List`. Wenn sie während der Codierung bereitgestellt werden, müssen genau dieselben Bytes auch während der Decodierung bereitgestellt werden.

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


## <a id="advanced-config"></a>Erweiterte Konfiguration erklärt (DataStoreConfig)

> [!TIP]
> **Zero-Config-Intelligenz**
> ToStore erkennt automatisch die Plattform, Leistungsmerkmale, verfügbaren Speicher und E/A-Verhalten, um Parameter wie Parallelität, Shard-Größe und Cache-Budget zu optimieren. **In 99 % der gängigen Geschäftsszenarien ist keine manuelle Feinabstimmung von `DataStoreConfig` erforderlich.** Die Standardeinstellungen bieten bereits eine hervorragende Leistung für die aktuelle Plattform.


| Parameter | Standard | Zweck & Empfehlung |
| :--- | :--- | :--- |
| **`yieldDurationMs`** | **8ms** | **Kernempfehlung.** Der Zeitabschnitt, der verwendet wird, wenn lange Aufgaben nachgeben. `8ms` passt gut zum 120-fps-/60-fps-Rendering und trägt dazu bei, dass die Benutzeroberfläche bei großen Abfragen oder Migrationen reibungslos bleibt. |
| **`maxQueryOffset`** | **10000** | **Abfrageschutz.** Wenn `offset` diesen Schwellenwert überschreitet, wird ein Fehler ausgelöst. Dadurch wird verhindert, dass pathologische E/A durch eine tiefe Offset-Paginierung verursacht werden. |
| **`defaultQueryLimit`** | **1000** | **Ressourcenleitplanke.** Wird angewendet, wenn eine Abfrage nicht `limit` angibt, um ein versehentliches Laden großer Ergebnismengen und potenzielle OOM-Probleme zu verhindern. |
| **`cacheMemoryBudgetMB`** | (automatisch) | **Feingranulare Speicherverwaltung.** Gesamtcache-Speicherbudget. Die Engine nutzt es, um die LRU-Rückgewinnung automatisch voranzutreiben. |
| **`enableJournal`** | **wahr** | **Selbstheilung bei Abstürzen.** Wenn diese Option aktiviert ist, kann sich der Motor nach Abstürzen oder Stromausfällen automatisch erholen. |
| **`persistRecoveryOnCommit`** | **wahr** | **Starke Haltbarkeitsgarantie.** Wenn dies zutrifft, werden festgeschriebene Transaktionen mit dem physischen Speicher synchronisiert. Bei „false“ erfolgt die Löschung asynchron im Hintergrund, um die Geschwindigkeit zu erhöhen, wobei bei extremen Abstürzen ein geringes Risiko besteht, dass eine kleine Datenmenge verloren geht. |
| **`ttlCleanupIntervalMs`** | **300000** | **Globale TTL-Abfrage.** Das Hintergrundintervall zum Scannen abgelaufener Daten, wenn die Engine nicht im Leerlauf ist. Niedrigere Werte löschen abgelaufene Daten früher, kosten aber mehr Overhead. |
| **`maxConcurrency`** | (automatisch) | **Computing-Parallelitätskontrolle.** Legt die maximale Anzahl paralleler Worker für intensive Aufgaben wie Vektorberechnung und Verschlüsselung/Entschlüsselung fest. Normalerweise ist es am besten, es automatisch zu lassen. |

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

## <a id="performance"></a>Leistung und Erfahrung

### Benchmarks

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore Basic Performance Demo" width="320" />
</p>

- **Basis-Performance-Demo** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4" target="_blank" rel="noopener">basic-demo.mp4</a>): In der GIF-Vorschau wird möglicherweise nicht alles angezeigt. Bitte öffnen Sie das Video für die vollständige Demonstration. Selbst auf normalen Mobilgeräten bleiben Start, Paging und Abruf stabil und reibungslos, selbst wenn der Datensatz 100 Millionen Datensätze überschreitet.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore Disaster Recovery Stress Test" width="320" />
</p>

- **Stresstest für die Notfallwiederherstellung** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4" target="_blank" rel="noopener">disaster-recovery.mp4</a>): Bei hochfrequenten Schreibvorgängen wird der Vorgang absichtlich immer wieder unterbrochen, um Abstürze und Stromausfälle zu simulieren. ToStore kann sich schnell erholen.


### Erlebnistipps

- 📱 **Beispielprojekt**: Das Verzeichnis `example` enthält eine vollständige Flutter-Anwendung
- 🚀 **Produktions-Builds**: Paket und Test im Release-Modus; Die Release-Leistung geht weit über den Debug-Modus hinaus
- ✅ **Standardtests**: Kernkompetenzen werden durch standardisierte Tests abgedeckt


Wenn ToStore Ihnen hilft, geben Sie uns bitte ein ⭐️
Es ist eine der besten Möglichkeiten, das Projekt zu unterstützen. Vielen Dank.


> **Empfehlung**: Ziehen Sie für die Entwicklung von Frontend-Apps das [ToApp-Framework](https://github.com/tocreator/toapp) in Betracht, das eine Full-Stack-Lösung bietet, die Datenanfragen, Laden, Speichern, Caching und Präsentation automatisiert und vereinheitlicht.


## <a id="more-resources"></a>Weitere Ressourcen

- 📖 **Dokumentation**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Problemberichterstattung**: [GitHub-Probleme](https://github.com/tocreator/tostore/issues)
- 💬 **Technische Diskussion**: [GitHub-Diskussionen](https://github.com/tocreator/tostore/discussions)



