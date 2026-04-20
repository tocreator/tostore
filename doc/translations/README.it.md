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
  <a href="README.de.md">Deutsch</a> | 
  <a href="README.fr.md">Français</a> | 
  Italiano | 
  <a href="README.tr.md">Türkçe</a>
</p>

## Navigazione rapida
- **Per iniziare**: [Perché ToStore](#why-tostore) | [Caratteristiche principali](#key-features) | [Guida all'installazione](#installation) | [Modalità KV](#quick-start-kv) | [Modalità tabella](#quick-start-table) | [Modalità memoria](#quick-start-memory)
- **Architettura e modello**: [Definizione dello schema](#schema-definition) | [Architettura distribuita](#distributed-architecture) | [Chiavi esterne a cascata](#foreign-keys) | [Cellulare/Desktop](#mobile-integration) | [Server/Agente](#server-integration) | [Algoritmi a chiave primaria](#primary-key-examples)
- **Query avanzate**: [Query avanzate (JOIN)](#query-advanced) | [Aggregazione e statistiche](#aggregation-stats) | [Logica complessa (Condizione query)](#query-condition) | [Query reattiva (guarda)](#reactive-query) | [Query sullo streaming](#streaming-query)
- **Avanzate e prestazioni**: [Operazioni avanzate KV](#kv-advanced) | [Ricerca vettoriale](#vector-advanced) | [TTL a livello di tabella](#ttl-config) | [Impostazione efficiente](#query-pagination) | [Query Cache](#query-cache) | [Espressioni atomiche](#atomic-expressions) | [Transazioni](#transactions)
- **Operazioni e sicurezza**: [Amministrazione](#database-maintenance) | [Configurazione sicurezza](#security-config) | [Gestione degli errori](#error-handling) | [Prestazioni e diagnostica](#performance) | [Altre risorse](#more-resources)

## <a id="why-tostore"></a>Perché scegliere ToStore?

ToStore è un moderno motore di dati progettato per l'era AGI e gli scenari di edge intelligence. Supporta nativamente sistemi distribuiti, fusione multimodale, dati strutturati relazionali, vettori ad alta dimensione e archiviazione di dati non strutturati. Costruito su un'architettura di nodi Self-Routing e un motore ispirato alla rete neurale, offre ai nodi un'elevata autonomia e una scalabilità orizzontale elastica, disaccoppiando logicamente le prestazioni dalla scalabilità dei dati. Include transazioni ACID, query relazionali complesse (JOIN e chiavi esterne a cascata), TTL a livello di tabella e aggregazioni, insieme a più algoritmi di chiave primaria distribuiti, espressioni atomiche, riconoscimento delle modifiche dello schema, crittografia, isolamento dei dati multi-spazio, pianificazione del carico intelligente basata sulle risorse e ripristino con autoriparazione in caso di disastro/arresto anomalo.

Mentre l'informatica continua a spostarsi verso l'intelligenza periferica, agenti, sensori e altri dispositivi non sono più solo "visualizzazioni di contenuti". Sono nodi intelligenti responsabili della generazione locale, della consapevolezza ambientale, del processo decisionale in tempo reale e dei flussi di dati coordinati. Le soluzioni di database tradizionali sono limitate dall'architettura sottostante e dalle estensioni integrate, rendendo sempre più difficile soddisfare i requisiti di bassa latenza e stabilità delle applicazioni intelligenti edge-cloud con scritture ad alta concorrenza, set di dati di grandi dimensioni, recupero di vettori e generazione collaborativa.

ToStore offre funzionalità distribuite all'edge sufficientemente potenti per set di dati di grandi dimensioni, generazione di intelligenza artificiale locale complessa e spostamento di dati su larga scala. Una collaborazione profonda e intelligente tra nodi edge e cloud fornisce una base dati affidabile per realtà mista immersiva, interazione multimodale, vettori semantici, modellazione spaziale e scenari simili.

## <a id="key-features"></a>Caratteristiche principali

- 🌐 **Motore dati multipiattaforma unificato**
  - API unificata in ambienti mobili, desktop, Web e server
  - Supporta dati strutturati relazionali, vettori ad alta dimensione e archiviazione di dati non strutturati
  - Costruisce una pipeline di dati dall'archiviazione locale alla collaborazione edge-cloud

- 🧠 **Architettura distribuita in stile rete neurale**
  - Architettura del nodo di auto-instradamento che disaccoppia l'indirizzamento fisico dalla scala
  - Nodi altamente autonomi collaborano per costruire una topologia di dati flessibile
  - Supporta la cooperazione tra nodi e il ridimensionamento orizzontale elastico
  - Profonda interconnessione tra i nodi edge-intelligenti e il cloud

- ⚡ **Esecuzione parallela e pianificazione delle risorse**
  - Pianificazione del carico intelligente in base alle risorse con elevata disponibilità
  - Collaborazione parallela multi-nodo e scomposizione delle attività
  - Il time-slicing mantiene fluide le animazioni dell'interfaccia utente anche in caso di carico pesante

- 🔍 **Query strutturate e recupero di vettori**
  - Supporta predicati complessi, JOIN, aggregazioni e TTL a livello di tabella
  - Supporta campi vettoriali, indici vettoriali e recupero del vicino più vicino
  - I dati strutturati e vettoriali possono funzionare insieme all'interno dello stesso motore

- 🔑 **Chiavi primarie, indici ed evoluzione dello schema**
  - Algoritmi di chiave primaria integrati tra cui strategie sequenziali, timestamp, con prefisso di data e codici brevi
  - Supporta indici univoci, indici compositi, indici vettoriali e vincoli di chiave esterna
  - Rileva automaticamente le modifiche allo schema e completa il lavoro di migrazione

- 🛡️ **Transazioni, sicurezza e recupero**
  - Fornisce transazioni ACID, aggiornamenti delle espressioni atomiche e chiavi esterne a cascata
  - Supporta il ripristino in caso di arresto anomalo del sistema, commit durevoli e garanzie di coerenza
  - Supporta la crittografia ChaCha20-Poly1305 e AES-256-GCM

- 🔄 **Flussi di lavoro multi-spazio e dati**
  - Supporta spazi isolati con dati condivisi a livello globale opzionali
  - Supporta ascoltatori di query in tempo reale, memorizzazione nella cache intelligente multilivello e impaginazione del cursore
  - Adatto ad applicazioni multiutente, local-first e collaborative offline

## <a id="installation"></a>Installazione

> [!IMPORTANT]
> **Aggiornamento da v2.x?** Leggi la [Guida all'aggiornamento v3.x](../UPGRADE_GUIDE_v3.md) per i passaggi critici della migrazione e le modifiche importanti.

Aggiungi `tostore` al tuo `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Please use the latest version
```

## <a id="quick-start"></a>Avvio rapido

> [!TIP]
> **Come dovresti scegliere una modalità di archiviazione?**
> 1. [**Modalità valore-chiave (KV)**](#quick-start-kv): ideale per l'accesso alla configurazione, la gestione degli stati sparsi o l'archiviazione di dati JSON. È il modo più veloce per iniziare.
> 2. [**Modalità tabella strutturata**](#quick-start-table): ideale per i dati aziendali principali che richiedono query complesse, convalida dei vincoli o governance dei dati su larga scala. Inserendo la logica dell'integrità nel motore, è possibile ridurre significativamente i costi di sviluppo e manutenzione a livello di applicazione.
> 3. [**Modalità memoria**](#quick-start-memory): ideale per calcoli temporanei, test unitari o **gestione ultrarapida dello stato globale**. Con le query globali e i listener `watch`, puoi rimodellare l'interazione dell'applicazione senza mantenere una pila di variabili globali.

### <a id="quick-start-kv"></a>Archiviazione valori-chiave (KV)
Questa modalità è adatta quando non sono necessarie tabelle strutturate predefinite. È semplice, pratico e supportato da un motore di archiviazione ad alte prestazioni. **La sua efficiente architettura di indicizzazione mantiene le prestazioni delle query altamente stabili ed estremamente reattive anche sui normali dispositivi mobili su scale di dati molto grandi.** I dati in spazi diversi sono naturalmente isolati, mentre è supportata anche la condivisione globale.

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
> **Hai bisogno di più funzioni chiave-valore?**
> Per operazioni avanzate come la lettura sicura dei tipi (`getInt`, `getBool`), l'incremento atomico, la ricerca per prefisso e l'esplorazione dello spazio delle chiavi, consulta [**Operazioni avanzate chiave-valore (db.kv)**](#kv-advanced).

#### Esempio di aggiornamento automatico dell'interfaccia utente Flutter
In Flutter, `StreamBuilder` plus `watchValue` offre un flusso di aggiornamento reattivo molto conciso:

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

### <a id="quick-start-table"></a>Modalità tabella strutturata
CRUD su tabelle strutturate richiede la creazione anticipata dello schema (vedere [Definizione dello schema](#schema-definition)). Approcci di integrazione consigliati per diversi scenari:
- **Mobile/Desktop**: per [scenari di avvio frequenti](#mobile-integration), si consiglia di passare `schemas` durante l'inizializzazione.
- **Server/Agente**: per [scenari di lunga esecuzione](#server-integration), si consiglia di creare tabelle dinamicamente tramite `createTables`.

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

### <a id="quick-start-memory"></a>Modalità memoria

Per scenari quali memorizzazione nella cache, calcoli temporanei o carichi di lavoro che non richiedono la persistenza su disco, è possibile inizializzare un database in memoria puro tramite `ToStore.memory()`. In questa modalità, tutti i dati, inclusi schemi, indici e coppie chiave-valore, risiedono interamente in memoria per le massime prestazioni di lettura/scrittura.

#### 💡 Funziona anche come gestione dello stato globale
Non c’è bisogno di un mucchio di variabili globali o di un pesante quadro di gestione statale. Combinando la modalità memoria con `watchValue` o `watch()`, puoi ottenere un aggiornamento dell'interfaccia utente completamente automatico su widget e pagine. Mantiene le potenti capacità di recupero di un database offrendo allo stesso tempo un'esperienza reattiva ben oltre le normali variabili, rendendolo ideale per lo stato di accesso, la configurazione live o i contatori di messaggi globali.

> [!CAUTION]
> **Nota**: i dati creati in modalità memoria pura vengono completamente persi dopo la chiusura o il riavvio dell'app. Non utilizzarlo per i dati aziendali principali.

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


## <a id="schema-definition"></a>Definizione dello schema
**Definisci una volta e lascia che sia il motore a gestire la governance automatizzata end-to-end in modo che la tua applicazione non debba più sostenere una pesante manutenzione di convalida.**

I seguenti esempi di dispositivi mobili, lato server e agenti riutilizzano tutti `appSchemas` definito qui.


### Panoramica dello schema tabella

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
      type: IndexType.btree, // Index type: btree/hash/bitmap/vector
    ),
  ],
  foreignKeys: const [], // Optional foreign-key constraints; see "Foreign Keys & Cascading"
  isGlobal: false, // Whether this is a global table; true means it can be shared across spaces
  ttlConfig: null, // Optional table-level TTL; see "Table-level TTL"
);

const appSchemas = [userSchema];
```

- **Mappature comuni `DataType`**:
  | Digitare | Tipo di dardo corrispondente | Descrizione |
  | :--- | :--- | :--- |
| `integer` | `int` | Intero standard, adatto per ID, contatori e dati simili |
  | `bigInt` | `BigInt` / `String` | Interi grandi; consigliato quando i numeri superano le 18 cifre per evitare perdite di precisione |
  | `double` | `double` | Numero in virgola mobile, adatto per prezzi, coordinate e dati simili |
  | `text` | `String` | Stringa di testo con vincoli di lunghezza opzionali |
  | `blob` | `Uint8List` | Dati binari grezzi |
  | `boolean` | `bool` | Valore booleano |
  | `datetime` | `DateTime` / `String` | Data/ora; memorizzato internamente come ISO8601 |
  | `array` | `List` | Tipo elenco o array |
  | `json` | `Map<String, dynamic>` | Oggetto JSON, adatto per dati strutturati dinamici |
  | `vector` | `VectorData` / `List<num>` | Dati vettoriali ad alta dimensione per il recupero semantico dell'intelligenza artificiale (embedding) |

- **`PrimaryKeyType` strategie di generazione automatica**:
  | Strategia | Descrizione | Caratteristiche |
  | :--- | :--- | :--- |
| `none` | Nessuna generazione automatica | È necessario fornire manualmente la chiave primaria durante l'inserimento |
  | `sequential` | Incremento sequenziale | Buono per ID user-friendly, ma meno adatto per prestazioni distribuite |
  | `timestampBased` | Basato su timestamp | Consigliato per ambienti distribuiti |
  | `datePrefixed` | Con prefisso data | Utile quando la leggibilità della data è importante per l'azienda |
  | `shortCode` | Chiave primaria del codice funzione | Compatto e adatto per display esterno |

> Per impostazione predefinita, tutte le chiavi primarie vengono memorizzate come `text` (`String`).


### Vincoli e convalida automatica

Puoi scrivere regole di convalida comuni direttamente in `FieldSchema`, evitando la logica duplicata nel codice dell'applicazione:

- `nullable: false`: vincolo non nullo
- `minLength` / `maxLength`: vincoli di lunghezza del testo
- `minValue` / `maxValue`: vincoli di intervallo di numeri interi o in virgola mobile
- `defaultValue` / `defaultValueType`: valori predefiniti statici e valori predefiniti dinamici
- `unique`: vincolo univoco
- `createIndex`: crea indici per filtri, ordinamenti o relazioni ad alta frequenza
- `fieldId` / `tableId`: aiuta il rilevamento della ridenominazione di campi e tabelle durante la migrazione

Inoltre, `unique: true` crea automaticamente un indice univoco a campo singolo. `createIndex: true` e le chiavi esterne creano automaticamente indici normali a campo singolo. Utilizzare `indexes` quando sono necessari indici compositi, indici denominati o indici vettoriali.


### Scelta di un metodo di integrazione

- **Mobile/Desktop**: migliore quando si passa `appSchemas` direttamente in `ToStore.open(...)`
- **Server/Agente**: migliore quando si creano dinamicamente schemi in fase di runtime tramite `createTables(appSchemas)`


## <a id="mobile-integration"></a>Integrazione per dispositivi mobili, desktop e altri scenari di avvio frequenti

📱 **Esempio**: [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

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

### Evoluzione dello schema

Durante `ToStore.open()`, il motore rileva automaticamente le modifiche strutturali in `schemas`, come l'aggiunta, la rimozione, la ridenominazione o la modifica di tabelle e campi, nonché le modifiche dell'indice, quindi completa il lavoro di migrazione necessario. Non è necessario gestire manualmente i numeri di versione del database o scrivere script di migrazione.


### Mantenimento dello stato di accesso e disconnessione (spazio attivo)

Il multi-spazio è ideale per **isolare i dati utente**: uno spazio per utente, accesso attivato. Con lo **Spazio attivo** e le opzioni di chiusura, puoi mantenere l'utente corrente durante i riavvii dell'app e supportare un comportamento di disconnessione pulito.

- **Mantieni lo stato di accesso**: dopo aver spostato un utente nel proprio spazio, contrassegna quello spazio come attivo. Il lancio successivo può accedere a quello spazio direttamente all'apertura dell'istanza predefinita, senza un passaggio "prima predefinito, quindi cambia".
- **Logout**: quando l'utente si disconnette, chiude il database con `keepActiveSpace: false`. Il lancio successivo non entrerà automaticamente nello spazio dell'utente precedente.

```dart
// After login: switch to the user's space and mark it active
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Optional: strictly stay in default when needed (for example, login screen only)
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// On logout: close and clear the active space so the next launch starts from default
await db.close(keepActiveSpace: false);
```


## <a id="server-integration"></a>Integrazione lato server/agente (scenari di lunga esecuzione)

🖥️ **Esempio**: [server_quickstart.dart](../../example/lib/server_quickstart.dart)

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


## <a id="advanced-usage"></a>Utilizzo avanzato

ToStore fornisce un ricco set di funzionalità avanzate per scenari aziendali complessi:


### <a id="kv-advanced"></a>Operazioni avanzate chiave-valore (db.kv)

Per scenari chiave-valore più complessi, si consiglia di utilizzare lo spazio dei nomi `db.kv`. Fornisce un set più completo di metodi.
Tutti i metodi seguenti supportano il parametro opzionale `isGlobal`: `true` indica dati condivisi a livello globale, `false` (predefinito) per lo spazio corrente.

- **Lettura sicura dei tipi (Type-Safe Getters)**
  Ottieni i dati direttamente nel formato di destinazione senza conversione manuale dei tipi:
  ```dart
  String? name = await db.kv.getString('user_name');
  int? age = await db.kv.getInt('user_age');
  bool? isVip = await db.kv.getBool('is_vip');
  Map<String, dynamic>? profile = await db.kv.getMap('profile');
  List<String>? tags = await db.kv.getList<String>('tags');
  ```

- **Contatore atomico (Atomic Increment)**
  Aumenta o diminuisci i valori numerici in modo sicuro in scenari ad alta concorrenza:
  ```dart
  // Incrementa di 1 (predefinito)
  await db.kv.setIncrement('view_count');
  // Decrementa di 5 (passando un valore negativo)
  await db.kv.setIncrement('stock_count', amount: -5);
  ```

- **Esplorazione e gestione dello spazio delle chiavi**
  Supporta il recupero delle chiavi basato su prefisso, statistiche totali e cancellazione di massa:
  ```dart
  // Ottieni tutte le chiavi che iniziano con 'setting_'
  final keys = await db.kv.getKeys(prefix: 'setting_');

  // Ottieni il numero totale di coppie chiave-valore nello spazio corrente
  final count = await db.kv.count();

  // Verifica se una chiave esiste e non è scaduta
  final exists = await db.kv.exists('config_cache');

  // Rimuovi più chiavi contemporaneamente
  await db.kv.removeKeys(['temp_1', 'temp_2']);

  // Cancella tutti i dati KV dello spazio corrente
  await db.kv.clear();
  ```

- **Gestione del ciclo di vita (TTL)**
  Ottieni o aggiorna il tempo di scadenza delle chiavi esistenti:
  ```dart
  // Ottieni il tempo di scadenza rimanente
  Duration? ttl = await db.kv.getTtl('token');

  // Aggiorna il tempo di scadenza di una chiave esistente (scade tra 7 giorni)
  await db.kv.setTtl('token', Duration(days: 7));
  ```


### <a id="vector-advanced"></a>Campi vettoriali, indici vettoriali e ricerca vettoriale

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

Note sui parametri:

- `dimensions`: deve corrispondere alla larghezza effettiva di incorporamento che scrivi
- `precision`: le scelte comuni includono `float64`, `float32` e `int8`; una maggiore precisione di solito costa più spazio di archiviazione
- `distanceMetric`: `cosine` è comune per gli incorporamenti semantici, `l2` si adatta alla distanza euclidea e `innerProduct` si adatta alla ricerca di prodotti scalari
- `maxDegree`: limite superiore dei vicini mantenuti per nodo nel grafo NGH; valori più alti di solito migliorano il richiamo al costo di più memoria e tempo di costruzione
- `efSearch`: ampiezza espansione tempo di ricerca; aumentandolo di solito si migliora il ricordo ma si aumenta la latenza
- `constructionEf`: larghezza di espansione in fase di compilazione; aumentandolo in genere si migliora la qualità dell'indice ma si aumenta il tempo di compilazione
- `topK`: numero di risultati da restituire

Note sui risultati:

- `score`: punteggio di somiglianza normalizzato, tipicamente nell'intervallo `0 ~ 1`; più grande significa più simile
- `distance`: valore della distanza; per `l2` e `cosine`, più piccolo solitamente significa più simile

### <a id="ttl-config"></a>TTL a livello di tabella (scadenza automatica basata sul tempo)

Per log, telemetria, eventi e altri dati che dovrebbero scadere nel tempo, è possibile definire TTL a livello di tabella tramite `ttlConfig`. Il motore pulirà automaticamente i record scaduti in background:

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


### Archiviazione intelligente (Upsert)
ToStore decide se aggiornare o inserire in base alla chiave primaria o chiave univoca inclusa in `data`. `where` non è supportato qui; l'obiettivo del conflitto è determinato dai dati stessi.

```dart
// By primary key
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// By unique key (the record must contain all fields from a unique index plus required fields)
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// Batch upsert (supports atomic mode or partial-success mode)
// allowPartialErrors: true means some rows may fail while others still succeed
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### <a id="query-advanced"></a>Query avanzate

ToStore fornisce un'API di query dichiarativa concatenabile con gestione flessibile dei campi e complesse relazioni multitabella.

#### 1. Selezione campo (`select`)
Il metodo `select` specifica quali campi vengono restituiti. Se non lo chiami, tutti i campi vengono restituiti per impostazione predefinita.
- **Alias**: supporta la sintassi `field as alias` (senza distinzione tra maiuscole e minuscole) per rinominare le chiavi nel set di risultati
- **Campi qualificati come tabella**: nelle unioni di più tabelle, `table.field` evita conflitti di denominazione
- **Miscelazione di aggregazioni**: gli oggetti `Agg` possono essere posizionati direttamente all'interno dell'elenco `select`

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

#### 2. Si unisce (`join`)
Supporta lo standard `join` (inner join), `leftJoin` e `rightJoin`.

#### 3. Join intelligenti basati su chiave esterna (consigliato)
Se `foreignKeys` sono definiti correttamente in `TableSchema`, non è necessario scrivere a mano le condizioni di unione. Il motore è in grado di risolvere le relazioni di riferimento e generare automaticamente il percorso JOIN ottimale.

- **`joinReferencedTable(tableName)`**: si unisce automaticamente alla tabella padre a cui fa riferimento la tabella corrente
- **`joinReferencingTable(tableName)`**: unisce automaticamente le tabelle figlie che fanno riferimento alla tabella corrente

```dart
// Assume posts defines a foreign key to users
final posts = await db.query('posts')
    .joinReferencedTable('users') // Automatically resolves to ON posts.user_id = users.id
    .select(['posts.title', 'users.username'])
    .limit(20);
```

---

### <a id="aggregation-stats"></a>Aggregazione, raggruppamento e statistiche (Agg e GroupBy)

#### 1. Aggregazione (`Agg` fabbrica)
Le funzioni aggregate calcolano le statistiche su un set di dati. Con il parametro `alias` è possibile personalizzare i nomi dei campi dei risultati.

| Metodo | Scopo | Esempio |
| :--- | :--- | :--- |
| `Agg.count(field)` | Conta record non nulli | `Agg.count('id', alias: 'total')` |
| `Agg.sum(field)` | Somma valori | `Agg.sum('amount', alias: 'total_price')` |
| `Agg.avg(field)` | Valore medio | `Agg.avg('score', alias: 'average_score')` |
| `Agg.max(field)` | Valore massimo | `Agg.max('age')` |
| `Agg.min(field)` | Valore minimo | `Agg.min('price')` |

> [!TIP]
> **Due stili di aggregazione comuni**
> 1. **Metodi scorciatoia (consigliati per metriche singole)**: chiamano direttamente sulla catena e ottengono immediatamente il valore calcolato.
> `num? totalAge = await db.query('users').sum('age');`
> 2. **Incorporato in `select` (per più metriche o raggruppamenti)**: passa gli oggetti `Agg` nell'elenco `select`.
> `final stats = await db.query('orders').select(['status', Agg.sum('amount')]).groupBy(['status']);`

#### 2. Raggruppamento e filtro (`groupBy` / `having`)
Utilizzare `groupBy` per classificare i record, quindi `having` per filtrare i risultati aggregati, in modo simile al comportamento HAVING di SQL.

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

#### 3. Metodi di query dell'helper
- **`exists()` (alte prestazioni)**: controlla se qualche record corrisponde. A differenza di `count() > 0`, va in cortocircuito non appena viene trovata una corrispondenza, il che è eccellente per set di dati molto grandi.
- **`count()`**: restituisce in modo efficiente il numero di record corrispondenti.
- **`first()`**: un metodo pratico equivalente a `limit(1)` e che restituisce la prima riga direttamente come `Map`.
- **`distinct([fields])`**: deduplica i risultati. Se vengono forniti `fields`, l'unicità viene calcolata in base a tali campi.

```dart
// Efficient existence check
if (await db.query('users').whereEqual('email', 'test@test.com').exists()) {
  print('Email is already registered');
}

// Get a deduplicated city list
final cities = await db.query('users').distinct(['city']);
```

#### <a id="query-condition"></a>4. Logica complessa con `QueryCondition`
`QueryCondition` è lo strumento principale di ToStore per la logica annidata e la costruzione di query tra parentesi. Quando le semplici chiamate `where` concatenate non sono sufficienti per espressioni come `(A AND B) OR (C AND D)`, questo è lo strumento da utilizzare.

- **`condition(QueryCondition sub)`**: apre un gruppo nidificato `AND`
- **`orCondition(QueryCondition sub)`**: apre un gruppo nidificato `OR`
- **`or()`**: cambia il connettore successivo in `OR` (il valore predefinito è `AND`)

##### Esempio 1: condizioni OR miste
SQL equivalente: `WHERE is_active = true AND (role = 'admin' OR fans >= 1000)`

```dart
final subGroup = QueryCondition()
    .whereEqual('role', 'admin')
    .or()
    .whereGreaterThanOrEqualTo('fans', 1000);

final results = await db.query('users')
    .whereEqual('is_active', true)
    .condition(subGroup);
```

##### Esempio 2: frammenti di condizione riutilizzabili
È possibile definire frammenti di logica aziendale riutilizzabili una volta e combinarli in query diverse:

```dart
final hotUser = QueryCondition().whereGreaterThan('fans', 5000);
final recentLogin = QueryCondition().whereGreaterThan('last_login', '2024-01-01');

final targetUsers = await db.query('users')
    .condition(hotUser)
    .condition(recentLogin);
```


#### <a id="streaming-query"></a>5. Richiesta di streaming
Adatto per set di dati molto grandi quando non si desidera caricare tutto in memoria in una volta. I risultati possono essere elaborati man mano che vengono letti.

```dart
db.streamQuery('users').listen((data) {
  print('Processing one record: $data');
});
```

#### <a id="reactive-query"></a>6. Query reattiva
Il metodo `watch()` consente di monitorare i risultati delle query in tempo reale. Restituisce un `Stream` ed esegue automaticamente nuovamente la query ogni volta che i dati corrispondono alle modifiche nella tabella di destinazione.
- **Debounce automatico**: il debounce intelligente integrato evita raffiche ridondanti di query
- **Sincronizzazione dell'interfaccia utente**: funziona in modo naturale con Flutter `StreamBuilder` per gli elenchi aggiornati in tempo reale

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

### <a id="query-cache"></a>Memorizzazione manuale nella cache dei risultati delle query (facoltativo)

> [!IMPORTANT]
> **ToStore include già internamente un'efficiente cache LRU intelligente multilivello.**
> **La gestione manuale della cache di routine non è consigliata.** Considerala solo in casi particolari:
> 1. Scansioni complete costose su dati non indicizzati che cambiano raramente
> 2. Requisiti persistenti di latenza estremamente bassa anche per query non urgenti

- `useQueryCache([Duration? expiry])`: abilita la cache e facoltativamente imposta una scadenza
- `noQueryCache()`: disabilita esplicitamente la cache per questa query
- `clearQueryCache()`: invalida manualmente la cache per questo modello di query

```dart
final results = await db.query('heavy_table')
    .where('non_indexed_field', '=', 'value')
    .useQueryCache(const Duration(minutes: 10)); // Manual acceleration for a heavy query only
```


### <a id="query-pagination"></a>Query e impaginazione efficiente

> [!TIP]
> **Specificare sempre `limit` per ottenere prestazioni ottimali**: si consiglia vivamente di fornire esplicitamente `limit` in ogni query. Se omesso, il motore utilizza per impostazione predefinita 1000 righe. Il motore di query principale è veloce, ma la serializzazione di set di risultati molto grandi nel livello dell'applicazione può comunque aggiungere un sovraccarico non necessario.

ToStore prevede due modalità di impaginazione tra cui puoi scegliere in base alle esigenze di scalabilità e prestazioni:

#### 1. Impaginazione di base (modalità Offset)
Adatto per set di dati relativamente piccoli o casi in cui sono necessari salti di pagina precisi.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Skip the first 40 rows
    .limit(20); // Take 20 rows
```
> [!TIP]
> Quando `offset` diventa molto grande, il database deve scansionare e scartare molte righe, quindi le prestazioni diminuiscono in modo lineare. Per un'impaginazione approfondita, preferisci la **Modalità Cursore**.

#### 2. Impaginazione del cursore (modalità cursore)
Ideale per set di dati di grandi dimensioni e scorrimento infinito. Utilizzando `nextCursor`, il motore continua dalla posizione corrente ed evita i costi di scansione aggiuntivi derivanti dagli offset profondi.

> [!IMPORTANT]
> Per alcune query complesse o ordinamenti su campi non indicizzati, il motore potrebbe ricorrere a una scansione completa e restituire un cursore `null`, il che significa che l'impaginazione non è attualmente supportata per quella query specifica.

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

| Caratteristica | Modalità offset | Modalità cursore |
| :--- | :--- | :--- |
| **Prestazioni query** | Degrada man mano che le pagine approfondiscono | Stabile per il paging profondo |
| **Ideale per** | Set di dati più piccoli, salti di pagina esatti | **Set di dati enormi, scorrimento infinito** |
| **Coerenza sotto modifiche** | Le modifiche ai dati possono causare righe saltate | Evita duplicati e omissioni causate da modifiche ai dati |


### <a id="foreign-keys"></a>Chiavi esterne e cascata

Le chiavi esterne garantiscono l'integrità referenziale e consentono di configurare aggiornamenti ed eliminazioni a cascata. Le relazioni vengono convalidate in fase di scrittura e aggiornamento. Se le policy a cascata sono abilitate, i dati correlati vengono aggiornati automaticamente, riducendo il lavoro di coerenza nel codice dell'applicazione.

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


### <a id="query-operators"></a>Operatori di query

Tutte le condizioni `where(field, operator, value)` supportano i seguenti operatori (senza distinzione tra maiuscole e minuscole):

| Operatore | Descrizione | Esempio / Prestazioni |
| :--- | :--- | :--- |
| `=` | Uguale | `where('status', '=', 'val')` — **[Consigliato]** Index Seek |
| `!=`, `<>` | Non uguale | `where('role', '!=', 'val')` — **[Cautela]** Scansione completa della tabella |
| `>` , `>=`, `<`, `<=` | Confronto | `where('age', '>', 18)` — **[Consigliato]** Index Scan |
| `IN` | Nella lista | `where('id', 'IN', [...])` — **[Consigliato]** Index Seek |
| `NOT IN` | Non nell'elenco | `where('status', 'NOT IN', [...])` — **[Cautela]** Scansione completa della tabella |
| `BETWEEN` | Intervallo | `where('age', 'BETWEEN', [18, 65])` — **[Consigliato]** Index Scan |
| `LIKE` | Corrispondenza modello (`%` = qualsiasi carattere, `_` = carattere singolo) | `where('name', 'LIKE', 'John%')` — **[Cautela]** Vedere nota sotto |
| `NOT LIKE` | Mancata corrispondenza del modello | `where('email', 'NOT LIKE', '...')` — **[Cautela]** Scansione completa della tabella |
| `IS` | È null | `where('deleted_at', 'IS', null)` — **[Consigliato]** Index Seek |
| `IS NOT` | Non è null | `where('email', 'IS NOT', null)` — **[Cautela]** Scansione completa della tabella |

### Metodi di query semantica (consigliati)

Consigliato per evitare stringhe operatore scritte a mano e per ottenere una migliore assistenza IDE.

#### 1. Confronto
Utilizzato per confronti diretti numerici o di stringhe.

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

#### 2. Collezione e gamma
Utilizzato per verificare se un campo rientra in un set o in un intervallo.

```dart
db.query('users').whereIn('id', ['id1', 'id2']);                 // In list
db.query('users').whereNotIn('status', ['banned', 'pending']);   // Not in list
db.query('users').whereBetween('age', 18, 65);                   // In range (inclusive)
```

#### 3. Controllo Null
Utilizzato per verificare se un campo ha un valore.

```dart
db.query('users').whereNull('deleted_at');    // Is null
db.query('users').whereNotNull('email');      // Is not null
db.query('users').whereEmpty('nickname');     // Is null or empty string
db.query('users').whereNotEmpty('bio');       // Is not null and not empty
```

#### 4. Corrispondenza dei modelli
Supporta la ricerca con caratteri jolly in stile SQL (`%` corrisponde a qualsiasi numero di caratteri, `_` corrisponde a un singolo carattere).

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
> **Guarda alle prestazioni delle query (Indice vs Scansione completa)**
>
> In scenari di dati su larga scala (milioni di righe o più), seguire questi principi per evitare ritardi nel thread principale e timeout delle query:
>
> 1. **Ottimizzato per l'indice - [Consigliato]**:
>    *   **Metodi semantici**: `whereEqual`, `whereGreaterThan`, `whereLessThan`, `whereIn`, `whereBetween`, `whereNull`, `whereTrue`, `whereFalse` e **`whereStartsWith`** (corrispondenza di prefisso).
>    *   **Operatori**: `=`, `>`, `<`, `>=`, `<=`, `IN`, `BETWEEN`, `IS null`, `LIKE 'prefix%'`.
>    *   *Spiegazione: Queste operazioni ottengono un posizionamento ultra-rapido tramite gli indici. Per `whereStartsWith` / `LIKE 'abc%'`, l'indice può comunque eseguire una scansione dell'intervallo di prefissi.*
>
> 2. **Rischi di scansione completa - [Cautela]**:
>    *   **Corrispondenza approssimativa**: `whereContains` (`LIKE '%val%'`), `whereEndsWith` (`LIKE '%val'`), `whereContainsAny`.
>    *   **Query di negazione**: `whereNotEqual` (`!=`, `<>`), `whereNotIn` (`NOT IN`), `whereNotNull` (`IS NOT null`/`whereNotEmpty`).
>    *   **Mancata corrispondenza del modello**: `NOT LIKE`.
>    *   *Spiegazione: Le operazioni precedenti richiedono solitamente l'attraversamento dell'intera area di memorizzazione dei dati anche se è stato creato un indice. Sebbene l'impatto sia minimo su dispositivi mobili o piccoli set di dati, in scenari di analisi dati distribuiti o ultra-grandi, dovrebbero essere utilizzate con cautela, combinate con altre condizioni di indice (ad esempio, limitare i dati per ID o intervallo temporale) e la clausola `limit`.*

## <a id="distributed-architecture"></a>Architettura distribuita

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

## <a id="primary-key-examples"></a>Esempi di chiavi primarie

ToStore fornisce più algoritmi di chiave primaria distribuiti per diversi scenari aziendali:

- **Chiave primaria sequenziale** (`PrimaryKeyType.sequential`): `238978991`
- **Chiave primaria basata su timestamp** (`PrimaryKeyType.timestampBased`): `1306866018836946`
- **Chiave primaria con prefisso data** (`PrimaryKeyType.datePrefixed`): `20250530182215887631`
- **Chiave primaria codice breve** (`PrimaryKeyType.shortCode`): `9eXrF0qeXZ`

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


## <a id="atomic-expressions"></a>Espressioni atomiche

Il sistema di espressione fornisce aggiornamenti del campo atomico indipendenti dal tipo. Tutti i calcoli vengono eseguiti atomicamente a livello di database, evitando conflitti simultanei:

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

**Espressioni condizionali (ad esempio, differenziare aggiornamento vs inserimento in un upsert)**: utilizzare `Expr.isUpdate()` / `Expr.isInsert()` insieme a `Expr.ifElse` o `Expr.when` in modo che l'espressione venga valutata solo all'aggiornamento o solo all'inserimento.

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

## <a id="transactions"></a>Transazioni

Le transazioni garantiscono l'atomicità tra più operazioni: tutto ha successo o tutto viene ripristinato, preservando la coerenza dei dati.

**Caratteristiche della transazione**
- più operazioni hanno tutte successo o tutte vengono ripristinate
- Il lavoro incompiuto viene ripristinato automaticamente dopo gli arresti anomali
- le operazioni riuscite vengono mantenute in modo sicuro

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


### <a id="database-maintenance"></a>Amministrazione e manutenzione

Le seguenti API coprono l'amministrazione del database, la diagnostica e la manutenzione per lo sviluppo in stile plug-in, i pannelli di amministrazione e gli scenari operativi:

- **Gestione tabelle**
  - `createTable(schema)`: crea manualmente un'unica tabella; utile per il caricamento dei moduli o la creazione di tabelle runtime su richiesta
  - `getTableSchema(tableName)`: recupera le informazioni sullo schema definito; utile per la convalida automatizzata o la generazione di modelli di interfaccia utente
  - `getTableInfo(tableName)`: recupera le statistiche della tabella di runtime, incluso il conteggio dei record, il conteggio degli indici, la dimensione del file di dati, l'ora di creazione e se la tabella è globale
  - `clear(tableName)`: cancella tutti i dati della tabella conservando in modo sicuro schema, indici e vincoli di chiave interni/esterni
  - `dropTable(tableName)`: distrugge completamente una tabella e il suo schema; non reversibile
- **Gestione dello spazio**
  - `currentSpaceName`: ottieni lo spazio attivo corrente in tempo reale
  - `listSpaces()`: elenca tutti gli spazi allocati nell'istanza del database corrente
  - `getSpaceInfo(useCache: true)`: controlla lo spazio corrente; utilizzare `useCache: false` per ignorare la cache e leggere lo stato in tempo reale
  - `deleteSpace(spaceName)`: elimina uno spazio specifico e tutti i suoi dati, tranne `default` e lo spazio attivo corrente
- **Individuazione delle istanze**
  - `config`: esamina lo snapshot finale `DataStoreConfig` effettivo per l'istanza
  - `instancePath`: individua con precisione la directory di archiviazione fisica
  - `getVersion()` / `setVersion(version)`: controllo della versione definito dal business per le decisioni di migrazione a livello di applicazione (non la versione del motore)
- **Manutenzione**
  - `flush(flushStorage: true)`: forza i dati in sospeso su disco; se `flushStorage: true`, al sistema viene richiesto anche di svuotare i buffer di archiviazione di livello inferiore
  - `deleteDatabase()`: rimuove tutti i file fisici e i metadati per l'istanza corrente; utilizzare con cura
- **Diagnostica**
  - `db.status.memory()`: controlla i rapporti di riscontro della cache, l'utilizzo della pagina indice e l'allocazione complessiva dell'heap
  - `db.status.space()` / `db.status.table(tableName)`: esamina le statistiche in tempo reale e le informazioni sanitarie per spazi e tabelle
  - `db.status.config()`: controlla lo snapshot della configurazione di runtime corrente
  - `db.status.migration(taskId)`: monitora l'avanzamento della migrazione asincrona in tempo reale

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


### <a id="backup-restore"></a>Backup e ripristino

Particolarmente utile per l'importazione/esportazione locale di un singolo utente, la migrazione di dati offline di grandi dimensioni e il rollback del sistema dopo un errore:

- **Backup (`backup`)**
  - `compress`: se abilitare la compressione; consigliato e abilitato per impostazione predefinita
  - `scope`: controlla l'intervallo di backup
    - `BackupScope.database`: esegue il backup dell'**intera istanza del database**, inclusi tutti gli spazi e le tabelle globali
    - `BackupScope.currentSpace`: esegue il backup solo dello **spazio attivo corrente**, escluse le tabelle globali
    - `BackupScope.currentSpaceWithGlobal`: esegue il backup dello **spazio corrente più le relative tabelle globali**, ideale per la migrazione a tenant singolo o utente singolo
- **Ripristina (`restore`)**
  - `backupPath`: percorso fisico al pacchetto di backup
  - `cleanupBeforeRestore`: se cancellare silenziosamente i dati correnti correlati prima del ripristino; Si consiglia `true` per evitare stati logici misti
  - `deleteAfterRestore`: elimina automaticamente il file di origine del backup dopo il ripristino riuscito

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

### <a id="error-handling"></a>Codici di stato e gestione degli errori


ToStore utilizza un modello di risposta unificato per le operazioni sui dati:

- `ResultType`: l'enumerazione di stato unificata utilizzata per la logica di ramificazione
- `result.code`: un codice numerico stabile corrispondente a `ResultType`
- `result.message`: un messaggio leggibile che descrive l'errore corrente
- `successKeys` / `failedKeys`: elenchi delle chiavi primarie riuscite e non riuscite nelle operazioni di massa


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

Esempi comuni di codici di stato:
Il successo restituisce `0`; i numeri negativi indicano errori.
- `ResultType.success` (`0`): operazione riuscita
- `ResultType.partialSuccess` (`1`): operazione in blocco parzialmente riuscita
- `ResultType.unknown` (`-1`): errore sconosciuto
- `ResultType.uniqueViolation` (`-2`): conflitto di indici univoci
- `ResultType.primaryKeyViolation` (`-3`): conflitto di chiave primaria
- `ResultType.foreignKeyViolation` (`-4`): il riferimento a chiave esterna non soddisfa i vincoli
- `ResultType.notNullViolation` (`-5`): manca un campo obbligatorio oppure è stato superato un campo `null` non consentito
- `ResultType.validationFailed` (`-6`): lunghezza, intervallo, formato o altra convalida non riuscita
- `ResultType.notFound` (`-11`): la tabella, lo spazio o la risorsa di destinazione non esiste
- `ResultType.resourceExhausted` (`-15`): risorse di sistema insufficienti; ridurre il carico o riprovare
- `ResultType.dbError` (`-91`): errore del database
- `ResultType.ioError` (`-90`): errore del file system
- `ResultType.timeout` (`-92`): timeout

### Gestione dei risultati della transazione
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

Tipi di errori di transazione:
- `TransactionErrorType.operationError`: un'operazione regolare non è riuscita all'interno della transazione, ad esempio un errore di convalida del campo, uno stato della risorsa non valido o un altro errore a livello aziendale
- `TransactionErrorType.integrityViolation`: conflitto di integrità o vincolo, come chiave primaria, chiave univoca, chiave esterna o errore non nullo
- `TransactionErrorType.timeout`: timeout
- `TransactionErrorType.io`: errore di I/O della memoria sottostante o del file system
- `TransactionErrorType.conflict`: un conflitto ha causato il fallimento della transazione
- `TransactionErrorType.userAbort`: interruzione avviata dall'utente (l'interruzione manuale basata sul lancio non è attualmente supportata)
- `TransactionErrorType.unknown`: qualsiasi altro errore


### <a id="logging-diagnostics"></a>Registra richiamate e diagnostica del database

ToStore può instradare i registri di avvio, ripristino, migrazione automatica e conflitti tra vincoli di runtime al livello aziendale tramite `LogConfig.setConfig(...)`.

- `onLogHandler` riceve tutti i registri che superano gli attuali filtri `enableLog` e `logLevel`.
- Chiamare `LogConfig.setConfig(...)` prima dell'inizializzazione in modo che vengano acquisiti anche i log generati durante l'inizializzazione e la migrazione automatica.

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


## <a id="security-config"></a>Configurazione della sicurezza

> [!WARNING]
> **Gestione delle chiavi**: **`encodingKey`** può essere modificato liberamente e il motore migrerà i dati automaticamente, in modo che i dati rimangano recuperabili. **`encryptionKey`** non deve essere modificato casualmente. Una volta modificati, i vecchi dati non possono essere decrittografati a meno che non ne venga eseguita esplicitamente la migrazione. Non codificare mai i tasti sensibili; si consiglia di recuperarli da un servizio sicuro.

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

### Crittografia a livello di valore (ToCrypto)

La crittografia dell'intero database protegge tutti i dati delle tabelle e degli indici, ma può influire sulle prestazioni generali. Se hai solo bisogno di proteggere alcuni valori sensibili, usa invece **ToCrypto**. È disaccoppiato dal database, non richiede alcuna istanza `db` e consente all'applicazione di codificare/decodificare i valori prima della scrittura o dopo la lettura. L'output è Base64, che si adatta naturalmente alle colonne JSON o TEXT.

- **`key`** (richiesto): `String` o `Uint8List`. Se non è di 32 byte, viene utilizzato SHA-256 per derivare una chiave di 32 byte.
- **`type`** (opzionale): tipo di crittografia da `ToCryptoType`, ad esempio `ToCryptoType.chacha20Poly1305` o `ToCryptoType.aes256Gcm`. Il valore predefinito è `ToCryptoType.chacha20Poly1305`.
- **`aad`** (facoltativo): dati aggiuntivi autenticati di tipo `Uint8List`. Se forniti durante la codifica, gli stessi byte devono essere forniti anche durante la decodifica.

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


## <a id="advanced-config"></a>Spiegazione della configurazione avanzata (DataStoreConfig)

> [!TIP]
> **Intelligenza di configurazione zero**
> ToStore rileva automaticamente la piattaforma, le caratteristiche prestazionali, la memoria disponibile e il comportamento I/O per ottimizzare parametri quali concorrenza, dimensione degli shard e budget della cache. **Nel 99% degli scenari aziendali comuni, non è necessario ottimizzare manualmente `DataStoreConfig`.** Le impostazioni predefinite forniscono già prestazioni eccellenti per la piattaforma attuale.


| Parametro | Predefinito | Scopo e raccomandazione |
| :--- | :--- | :--- |
| **`yieldDurationMs`** | **8ms** | **Raccomandazione principale.** L'intervallo di tempo utilizzato quando le attività lunghe producono risultati. `8ms` si allinea bene con il rendering a 120 fps/60 fps e aiuta a mantenere l'interfaccia utente fluida durante query o migrazioni di grandi dimensioni. |
| **`maxQueryOffset`** | **10000** | **Protezione delle query.** Quando `offset` supera questa soglia, viene generato un errore. Ciò impedisce l'I/O patologico derivante dall'impaginazione con offset profondo. |
| **`defaultQueryLimit`** | **1000** | **Guardrail delle risorse.** Applicato quando una query non specifica `limit`, impedendo il caricamento accidentale di enormi set di risultati e potenziali problemi OOM. |
| **`cacheMemoryBudgetMB`** | (automatico) | **Gestione approfondita della memoria.** Budget totale della memoria cache. Il motore lo utilizza per gestire automaticamente il recupero LRU. |
| **`enableJournal`** | **vero** | **Riparazione automatica in caso di crash.** Se abilitata, il motore può ripristinarsi automaticamente dopo arresti anomali o interruzioni di corrente. |
| **`persistRecoveryOnCommit`** | **vero** | **Forte garanzia di durabilità.** Se vera, le transazioni confermate vengono sincronizzate con l'archivio fisico. Se falso, lo svuotamento viene eseguito in modo asincrono in background per una migliore velocità, con un piccolo rischio di perdere una piccola quantità di dati in caso di arresti anomali estremi. |
| **`ttlCleanupIntervalMs`** | **300000** | **Polling TTL globale.** L'intervallo in background per la scansione dei dati scaduti quando il motore non è inattivo. Valori più bassi eliminano i dati scaduti prima ma comportano costi maggiori. |
| **`maxConcurrency`** | (automatico) | **Controllo della concorrenza di calcolo.** Imposta il numero massimo di lavoratori paralleli per attività intensive come il calcolo vettoriale e la crittografia/decrittografia. Di solito è meglio mantenerlo automatico. |

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

## <a id="performance"></a>Prestazioni ed esperienza

### Benchmark

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore Basic Performance Demo" width="320" />
</p>

- **Demo delle prestazioni di base** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4" target="_blank" rel="noopener">basic-demo.mp4</a>): l'anteprima GIF potrebbe non mostrare tutto. Si prega di aprire il video per la dimostrazione completa. Anche sui normali dispositivi mobili, l'avvio, il paging e il recupero rimangono stabili e fluidi anche quando il set di dati supera i 100 milioni di record.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore Disaster Recovery Stress Test" width="320" />
</p>

- **Test di stress per il ripristino di emergenza** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4" target="_blank" rel="noopener">disaster-recovery.mp4</a>): durante le scritture ad alta frequenza, il processo viene intenzionalmente interrotto più e più volte per simulare arresti anomali e interruzioni di corrente. ToStore è in grado di ripristinare rapidamente.


### Suggerimenti per l'esperienza

- 📱 **Progetto di esempio**: la directory `example` include un'applicazione Flutter completa
- 🚀 **Build di produzione**: pacchetto e test in modalità rilascio; le prestazioni di rilascio vanno ben oltre la modalità di debug
- ✅ **Test standard**: le capacità principali sono coperte da test standardizzati


Se ToStore ti è d'aiuto, lasciaci un ⭐️
È uno dei modi migliori per sostenere il progetto. Grazie mille.


> **Raccomandazione**: per lo sviluppo di app frontend, prendi in considerazione il [framework ToApp](https://github.com/tocreator/toapp), che fornisce una soluzione full-stack che automatizza e unifica richieste di dati, caricamento, archiviazione, memorizzazione nella cache e presentazione.


## <a id="more-resources"></a>Più risorse

- 📖 **Documentazione**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Segnalazione dei problemi**: [Problemi GitHub](https://github.com/tocreator/tostore/issues)
- 💬 **Discussione tecnica**: [Discussioni GitHub](https://github.com/tocreator/tostore/discussions)



