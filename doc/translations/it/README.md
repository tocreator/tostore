<h1 align="center">
  <img src="../../resource/logo-tostore.svg" width="400" alt="ToStore">
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
  <a href="../../../README.md">English</a> |
  <a href="../zh-CN/README.md">简体中文</a> |
  <a href="../ja/README.md">日本語</a> |
  <a href="../ko/README.md">한국어</a> |
  <a href="../es/README.md">Español</a> |
  <a href="../pt-BR/README.md">Português (Brasil)</a> |
  <a href="../ru/README.md">Русский</a> |
  <a href="../de/README.md">Deutsch</a> |
  <a href="../fr/README.md">Français</a> |
  Italiano |
  <a href="../tr/README.md">Türkçe</a>
</p>

## Navigazione rapida
- [Perché ToStore](#why-tostore) | [Caratteristiche principali](#key-features) | [Guida all'installazione](#installation) | [Modalità KV](#quick-start-kv) | [Modalità tabella](#quick-start-table) | [Modalità memoria](#quick-start-memory)
- [Definizione dello schema](#schema-definition) | [Architettura distribuita](#distributed-architecture) | [Chiavi esterne a cascata](#foreign-keys) | [Cellulare/Desktop](#mobile-integration) | [Server/Agente](#server-integration) | [Algoritmi a chiave primaria](#primary-key-examples)
- [Query avanzate (JOIN)](#query-advanced) | [Aggregazione e statistiche](#aggregation-stats) | [Logica complessa (Condizione query)](#query-condition) | [Query reattiva (guarda)](#reactive-query) | [Query sullo streaming](#streaming-query)
- [KV avanzate](#kv-advanced) | [Operazioni in blocco](#bulk-operations) | [Recupero vettoriale e ibrido](#vector-advanced) | [TTL a livello di tabella](#ttl-config) | [Paginazione efficiente](#query-pagination) | [Sonda di memoria e recupero sincrono (peek)](#query-peek) | [Cache delle query](#query-cache) | [Espressioni atomiche](#atomic-expressions) | [Transazioni](#transactions)
- [Amministrazione](#database-maintenance) | [Configurazione sicurezza](#security-config) | [Gestione degli errori](#error-handling) | [Prestazioni e diagnostica](#performance) | [Contribuire](#contribute) | [Assistenti IA](#for-ai-coding-assistants)

## <a id="why-tostore"></a>Perché scegliere ToStore?

ToStore è un motore di dati moderno progettato per l'era dell'AGI e scenari di edge intelligence. Basato su un'architettura di nodi self-routing (Self-Routing), offre ai nodi elevata autonomia e scalabilità orizzontale elastica, disaccoppiando logicamente le prestazioni dalla scala dei dati.

La modellazione a runtime e i percorsi di esecuzione non bloccanti mantengono l'evoluzione dell'architettura sempre online e totalmente trasparente per le operazioni aziendali: le modifiche dichiarative dello schema, la rotazione delle chiavi di codifica dei dati e la ristrutturazione massiva dei dati avvengono senza interruzioni. Orientato ad Agent e O&M automatizzato, sostiene la loro evoluzione autonoma e l'iterazione continua senza interrompere il servizio.

Un motore di dati unificato che supporta nativamente dati strutturati relazionali, vettori ad alta dimensione e dati non strutturati, con recupero ibrido integrato e fusione del richiamo multiplo, oltre a capacità di database di livello enterprise che includono transazioni ACID, query relazionali complesse (JOIN, chiavi esterne in cascata), TTL a livello di tabella, aggregazioni, nonché algoritmi di chiave primaria distribuita, espressioni atomiche, crittografia, isolamento multi-spazio e ripristino automatico.

Mentre l'informatica continua a spostarsi verso l'intelligenza periferica, i dispositivi non sono più semplici "visualizzatori di contenuti", ma nodi intelligenti responsabili della generazione locale, della percezione ambientale, del processo decisionale in tempo reale e del coordinamento dei dati. ToStore fornisce al perimetro capacità distribuite per set di dati massivi e generazione locale complessa di IA. La profonda collaborazione intelligente tra nodi periferici e cloud fornisce una base dati affidabile per l'interazione multimodale, il recupero ibrido di vettori semantici, la modellazione spaziale, la collaborazione autonoma edge e scenari simili.

## <a id="key-features"></a>Caratteristiche principali

- 🤖 **Evoluzione a runtime e O&M intelligente**
  - Definizione dichiarativa, ristrutturazione automatica, senza gestione delle versioni
  - Rotazione delle chiavi, modifiche dello schema, ristrutturazione massiva—tutto online, senza interruzioni
  - Specifica di stato integrata per O&M automatizzato e riconoscimento degli Agent
  - Aggiornamenti a caldo senza interruzione del servizio per stabilità a lungo termine

- 🧠 **Architettura distribuita self-routing**
  - Architettura di nodi self-routing che disaccoppia l'indirizzamento fisico dalla scala dei dati
  - Nodi altamente autonomi collaborano per costruire una topologia di dati flessibile
  - Scalabilità orizzontale elastica con profonda interconnessione tra nodi periferici e cloud

- 🌐 **Motore di dati unificato multipiattaforma**
  - API unificata in ambienti mobili, desktop, Web e server
  - Copre dati strutturati relazionali, vettori ad alta dimensione e dati non strutturati
  - Pipeline di dati completa dall'archiviazione locale alla collaborazione edge-cloud

- 🔍 **Query strutturate e recupero ibrido**
  - Predicati complessi, JOIN, aggregazioni e TTL a livello di tabella
  - Il richiamo multicanale può essere composto sulla stessa catena di query (vettoriale, strutturato e altro)
  - Ranking di fusione del richiamo multiplo, con punteggi e diagnostica dei canali restituiti nel risultato della query

- ⚡ **Esecuzione parallela e pianificazione delle risorse**
  - Pianificazione intelligente del carico con consapevolezza delle risorse per alta disponibilità
  - Collaborazione parallela multi-nodo e scomposizione delle attività
  - Time-slicing che mantiene le animazioni dell'interfaccia fluide anche sotto carico pesante

- 🔐 **Sicurezza e isolamento dei dati**
  - Isolamento multi-spazio con condivisione globale opzionale, ideale per scenari multiutente e multitenant
  - Crittografia ChaCha20-Poly1305 e AES-256-GCM integrata
  - Verificato tramite molteplici scenari complessi di ripristino da disastri

## <a id="installation"></a>Installazione

> [!IMPORTANT]
> **Aggiornamento da v2.x?** Leggi la [Guida all'aggiornamento v3.x](../../UPGRADE_GUIDE_v3.md) per i passaggi critici della migrazione e le modifiche importanti.

Aggiungi `tostore` al tuo `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Please use the latest version
```

### For AI Coding Assistants

Quando generi codice client ToStore con un assistente IA, forniscigli il corpus in un unico file [`llms-full.txt`](../../../llms-full.txt) — ad esempio `@llms-full.txt` nell'IDE, carica/incolla il file, oppure indica la [raw URL](https://raw.githubusercontent.com/tocreator/tostore/main/llms-full.txt) nella documentazione dell'assistente. Contiene firme API, vincoli e anti-pattern per allineare il modello alla superficie pubblica reale. Indice: [`llms.txt`](../../../llms.txt).

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
> Per operazioni avanzate come la lettura sicura dei tipi (`getInt`, `getBool`), l'incremento atomico, la ricerca per prefisso, le **query a catena paginate sui record** (`db.kv.query()`) e l'esplorazione dello spazio delle chiavi, consulta [**Operazioni avanzate chiave-valore (db.kv)**](#kv-advanced).

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
// It is recommended to check hasErrors
if (!result.hasErrors) {
  print('Insert succeeded, generated primary key ID: ${result.firstPrimaryKey}');
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
      type: IndexType.btree, // Index type: btree/vector
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

### <a id="schema-evolution"></a>Evoluzione dello schema (Schema Evolution)

Il motore rileva automaticamente le modifiche strutturali (aggiunta, rimozione o ridenominazione di tabelle/campi, aggiornamenti degli attributi, modifiche agli indici, ecc.) e completa la migrazione dei dati — senza versioning manuale né script. Gli `schemas` dichiarativi evolvono in `ToStore.open()`; a runtime si può anche usare `updateSchema` — **trasparente per il business**, senza interrompere letture e scritture.

#### <a id="promote-primary-key"></a>Promuovere un campo univoco a chiave primaria

È possibile promuovere un campo esistente **univoco e non null** a chiave primaria (rinomina opzionale; con dati esistenti; trasparente per il business). **Non combinare** con `setPrimaryKeyConfig`.

- **Mobile (`schemas` dichiarativi)**: Rilevamento automatico in `ToStore.open()`. La chiave primaria di destinazione **deve** essere `PrimaryKeyType.none` (i valori provengono dal campo univoco di origine; altri tipi auto-generati non sono supportati). Se i nomi coincidono, basta il nome; per rinominare, impostare `fromFieldId` sul `fieldId` del campo di origine.
- **Server (runtime)**: Chiamare `updateSchema(...).promoteFieldToPrimaryKey(sourceFieldName: ..., targetPrimaryKeyName: ...)`. `targetPrimaryKeyName` è opzionale; ometterlo mantiene il nome del campo di origine.

### Scelta di un metodo di integrazione

- **Mobile/Desktop**: migliore quando si passa `appSchemas` direttamente in `ToStore.open(...)`
- **Server/Agente**: migliore quando si creano dinamicamente schemi in fase di runtime tramite `createTables(appSchemas)`


## <a id="mobile-integration"></a>Integrazione per dispositivi mobili, desktop e altri scenari di avvio frequenti

📱 **Esempio**: [mobile_quickstart.dart](../../../example/lib/mobile_quickstart.dart)

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

### Monitoraggio del progresso di avvio

Le modifiche normali allo schema sono trasparenti per la logica di business e non bloccano l'avvio. Solo in rari casi eccezionali specifici per app mobili frequentemente chiuse forzatamente (ad esempio, una breve convalida dei dati e il ripristino dei crash dopo un'uscita anomala) l'inizializzazione può richiedere un tempo percettibile — usa `onStartupProgress` per mostrare una schermata iniziale o un indicatore di avanzamento:

```dart
final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
  onStartupProgress: (progress, stage) {
    // progress: 0.0 – 1.0  |  stage: opening → recovering → optimizing → ready
    print('Progresso avvio ${(progress * 100).toStringAsFixed(0)}% [$stage]');
    // Aggiorna schermata iniziale / barra di avanzamento
  },
);
// Database completamente pronto
```

Fasi:
- `opening` — Caricamento configurazione, preparazione del motore di base
- `recovering` — Controlli di sicurezza e ripristino dopo crash
- `optimizing` — Messa a punto interna del motore e ottimizzazione strutturale
- `ready` — Inizializzazione completata, pronto all'uso


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

🖥️ **Esempio**: [server_quickstart.dart](../../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Create table structures while the process is running
await db.createTables(appSchemas);

// Online schema updates
final result = await db.updateSchema('users')
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
  .setPrimaryKeyConfig(                    // Change auto-generated PK strategy; avoid when the table already has data
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
// Promote a unique field to PK (see promote-primary-key section; do not chain with the above):
// await db.updateSchema('users').promoteFieldToPrimaryKey(
//   sourceFieldName: 'user_id',
//   targetPrimaryKeyName: 'uid', // optional; omit to keep the source field name
// );

// Monitor migration progress
final taskId = result.taskId;
if (taskId != null) {
  // Inspect migration metadata
  print('Estimated duration: ${result.estimateDuration?.inMilliseconds} ms');
  print('Migration write mode: ${result.writeMode}'); // e.g. MigrationWriteMode.indexOnly

  final status = await db.queryMigrationTaskStatus(taskId);
  print('Migration progress: ${status?.progressPercentage}%');
}


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

Per scenari chiave-valore più complessi, si consiglia di utilizzare lo spazio dei nomi `db.kv`. Fornisce un set completo di API con isolamento dello spazio, condivisione globale, diversi tipi di dati, nonché query e filtri complessi a catena (ad es. `db.kv.query().prefix(...).orderBy...().limit(...)` per paginazione, ordinamento, filtro di scadenza, ecc.).

- **Accesso di base (Basic Access)**
  ```dart
  // Imposta valore (supporta String, int, bool, double, Map, List, ecc.)
  await db.kv.set('key', 'value', ttl: Duration(hours: 1));
  
  // Ottieni valore dinamico grezzo
  dynamic val = await db.kv.get('key');

  // Rimuovi una singola chiave
  await db.kv.remove('key');
  ```

- **Getter sicuri per i tipi (Type-Safe Getters)**
  Recupera i dati direttamente nel formato di destinazione senza conversione manuale:
  ```dart
  String? name = await db.kv.getString('user_name');
  int? age = await db.kv.getInt('user_age');
  bool? isVip = await db.kv.getBool('is_vip');
  Map<String, dynamic>? profile = await db.kv.getMap('profile');
  List<String>? tags = await db.kv.getList<String>('tags');
  ```

- **Operazioni in blocco (Bulk Operations)**
  Elabora in modo efficiente più coppie chiave-valore in un'unica operazione:
  ```dart
  // Imposta in blocco
  await db.kv.setMany({
    'theme': 'dark',
    'language': 'it_IT',
  });

  // Rimuovi in blocco
  await db.kv.removeKeys(['temp_1', 'temp_2']);
  ```

- **Contatori atomici (Atomic Increment)**
  Aumenta o diminuisci i valori numerici in modo sicuro in scenari ad alta concorrenza:
  ```dart
  // Incrementa di 1 (predefinito)
  await db.kv.setIncrement('view_count');
  // Decrementa di 5 (passa un valore negativo)
  await db.kv.setIncrement('stock_count', amount: -5);
  ```

- **Query a catena sui record (db.kv.query)**
  API a catena simile a `db.query()` per interrogare **record** chiave-valore (con `value` decodificato) e con paginazione. A differenza di `getKeys` (solo nomi chiave), restituisce record completi.


  ```dart
  // Prima pagina: filtra per prefisso, ordina per updated_at discendente, 20 per pagina
  final page = await db.kv.query()
      .prefix('setting_')
      .orderByUpdatedAtDesc() // oppure orderByKeyAsc / orderByKeyDesc / orderByUpdatedAtAsc
      .limit(20);

  for (final record in page.data) {
    // record contiene: key, value, updated_at, expires_at
    print('${record['key']} = ${record['value']}');
  }

  // Consigliato: paginare con next() / prev() (come le query di tabella, il più semplice)
  if (page.hasMore) {
    final page2 = await page.next();
    print('Pagina successiva: ${page2.data.length}');
    if (page2.hasPrev) {
      final back = await page2.prev();
      print('Pagina precedente: ${back.data.length}');
    }
  }

  // Paginazione per offset (esclusiva rispetto a cursor; per deep paging preferire next() sopra)
  final byOffset = await db.kv.query()
      .orderByKeyAsc()
      .limit(20)
      .offset(20);

  // Totale record corrispondenti (senza prefix: statistica metadati O(1))
  final total = await db.kv.query().prefix('setting_').count();

  // Prendi il primo record corrispondente
  final first = await db.kv.query().prefix('setting_').orderByKeyAsc().first();

  // Spazio KV globale
  final globalPage = await db.kv.query(isGlobal: true).limit(50);

  // Di default i scaduti sono filtrati; per includere quelli non ancora ripuliti:
  final withExpired = await db.kv.query()
      .includeExpired()
      .limit(20);
  ```

  Metodi a catena comuni:

  | Metodo | Descrizione |
  | --- | --- |
  | `prefix(String)` | Filtra per prefisso di key |
  | `orderByKeyAsc` / `orderByKeyDesc` | Ordina per key (chiave primaria) |
  | `orderByUpdatedAtAsc` / `orderByUpdatedAtDesc` | Ordina per `updated_at` |
  | `limit(n)` | Massimo elementi per pagina (si consiglia di specificarlo sempre) |
  | `offset(n)` | Paginazione con scostamento (cancella cursor) |
  | `cursor(token)` | Solo casi speciali: token di paginazione tra processi/rete |
  | `includeExpired([true])` | Includere record scaduti non ancora ripuliti |
  | `count()` | Contare le corrispondenze |
  | `first()` | Restituire il primo record (non altera il limit del builder) |

  Risultato `QueryResult`: nell'uso quotidiano, paginare con `hasMore` / `hasPrev` + `next()` / `prev()`; `nextCursorToken` / `prevCursorToken` solo per trasferimento cross-end, ecc. (come le query di tabella).

- **Esplorazione e gestione (Discovery & Management)**
  ```dart
  // Solo nomi chiave (senza value); opzionali prefix / limit / offset
  final keys = await db.kv.getKeys(prefix: 'setting_');
  final pageKeys = await db.kv.getKeys(
    prefix: 'setting_',
    limit: 100,
    offset: 0,
  );

  // Conta il totale delle chiavi nello spazio attuale
  final count = await db.kv.count();

  // Verifica se una chiave esiste e non è scaduta
  final exists = await db.kv.exists('config_cache');

  // Sonda di memoria (sincrona, solo cache — vedi [Sonda di memoria e recupero sincrono (peek)](#query-peek))
  final theme = db.kv.peekGet('theme') ?? await db.kv.get('theme');
  if (db.kv.peekExists('config_cache')) { /* ... */ }

  // Cancella tutti i dati KV nello spazio attuale
  await db.kv.clear();
  ```

- **Gestione del ciclo di vita (TTL)**
  Ispeziona o aggiorna le impostazioni di scadenza per le chiavi esistenti:
  ```dart
  // Ottieni la durata rimanente
  Duration? ttl = await db.kv.getTtl('token');

  // Aggiorna il TTL per una chiave esistente (scade tra 7 giorni)
  await db.kv.setTtl('token', Duration(days: 7));
  ```

- **Monitoraggio reattivo (Reactive Watch)**
  ```dart
  // Monitora una singola chiave
  db.kv.watch<int>('unread_count').listen((count) => print(count));

  // Monitora uno snapshot di più chiavi
  db.kv.watchValues(['theme', 'font_size']).listen((map) => print(map));
  ```

- **Condivisione globale (isGlobal)**
  Tutti i metodi sopra indicati supportano il parametro opzionale `isGlobal`: `true` per lo spazio globale (condiviso tra tutti gli spazi), `false` (predefinito) per lo spazio isolato attuale.


### <a id="bulk-operations"></a>Operazioni in blocco (Bulk Operations)

ToStore fornisce interfacce di elaborazione in blocco specializzate, ottimizzate per throughput di dati su larga scala. Queste interfacce integrano la distribuzione parallela dei compiti e la pianificazione time-slicing per garantire la reattività dell'interfaccia utente durante operazioni di scrittura intensive.

| Metodo | Scopo principale | Requisiti dei dati | Caratteristiche |
| :--- | :--- | :--- | :--- |
| `batchInsert` | Inserimento record in blocco | Deve contenere tutti i campi non nullabili | Inserimento puro, massime prestazioni |
| `batchUpsert` | Sincronizzazione intelligente (Upsert) | **Deve contenere tutti i campi non nullabili** | Sincronizzazione completa, identificata da chiave primaria o campo univoco |
| `batchUpdate` | Aggiornamento record in blocco | **Chiave primaria o campo univoco** + Campi da aggiornare | Aggiornamenti parziali per record esistenti |

- **Inserimento in blocco (batchInsert)**
  ```dart
  await db.batchInsert('users', [
    {'username': 'user1', 'email': '1@ex.com'},
    {'username': 'user2', 'email': '2@ex.com'},
  ]);
  ```

- **Sincronizzazione intelligente in blocco (batchUpsert)**
  Identifica automaticamente "Inserimento" o "Aggiornamento" in base alla chiave primaria o ai campi univoci. Comune per la sincronizzazione completa dei dati.
  > [!IMPORTANT]
  > **Requisiti dei dati**: Poiché potrebbe essere attivato un inserimento, `batchUpsert` richiede che ogni record contenga tutti i campi non nullabili (`nullable: false`).

- **Aggiornamento in blocco ad alte prestazioni (batchUpdate)**
  Specifico per l'aggiornamento di record esistenti. Ogni record deve includere una chiave primaria o un campo univoco come identificatore, insieme ai campi da modificare.
  > [!TIP]
  > **Aggiornamenti parziali**: `batchUpdate` modifica solo i campi forniti e non richiede tutti i campi non nullabili, rendendolo ideale per aggiornamenti incrementali.
  ```dart
  await db.batchUpdate('users', [
    {'username': 'john', 'age': 27}, // Identifica tramite campo univoco 'username' e aggiorna 'age'
    {'id': '1002', 'status': 'active'}, // Può anche usare direttamente la chiave primaria
  ]);
  ```

> [!TIP]
> È possibile impostare `allowPartialErrors: true` per garantire che i fallimenti di singoli record (ad esempio, una violazione di vincolo univoco) non rifiutino l'intera operazione in blocco.


### <a id="vector-advanced"></a>Campi vettoriali, indici vettoriali e recupero ibrido

Il recupero vettoriale usa la catena unificata `db.query(...).matchVector(...)`: può essere combinato con predicati strutturati sulla stessa catena, o fuso con altri rami di richiamo. Punteggi e diagnostica di canale tornano in `QueryResult.retrieval`, allineati 1:1 con le righe di `data`. Gli esempi attuali si concentrano su percorsi vettoriale + strutturato; canali lessicali, a grafo e altri seguiranno lo stesso modello di recupero ibrido a catena.

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
        name: 'category',
        type: DataType.text,
        nullable: false,
        createIndex: true,
      ),
      FieldSchema(
        name: 'embedding',
        type: DataType.vector, // Declare a vector field
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: 128, // Written and queried vectors must match this width
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'], // Field to index
        type: IndexType.vector, // Build a vector index
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh, // ToStore built-in proprietary dense index
          distanceMetric: VectorDistanceMetric.cosine, // Good for normalized embeddings
        ),
      ),
    ],
  ),
]);

final queryVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.01)); // Must match dimensions

// 1) Recommended: chained hybrid retrieval (pure vector ANN)
final result = await db
    .query('embeddings')
    .matchVector('embedding', queryVector) // searchDepth predefinito = 50 (~95 % intento di recall)
    .limit(5);

for (var i = 0; i < result.data.length; i++) {
  final row = result.data[i];
  final entry = result.retrieval?.entries[i];
  final score = entry?.score;
  final distance = entry?.meta?['distance'];
  print('pk=${row['id']}, title=${row['document_title']}, '
      'score=$score, distance=$distance');
}

// 2) Structured filter + vector (AND hybrid)
final filtered = await db
    .query('embeddings')
    .whereEqual('category', 'tech')
    .matchVector('embedding', queryVector)
    .limit(5);

// 3) Multi-way fused recall (vector + structured paths, engine-side RRF)
final otherVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.012));
final fused = await db
    .query('embeddings')
    .matchVector('embedding', queryVector, weight: 1.0)
    .orMatchVector('embedding', otherVector, weight: 0.6, minScore: 0.2)
    .or()
    .whereEqual('category', 'tech')
    .limit(10);

print('fusion=${fused.retrieval?.fusionMethod}'); // Multi-way is typically rrf
```

**Configurazione schema / indice vettoriale** (`VectorFieldConfig`, `VectorIndexConfig`):

- `dimensions`: deve corrispondere alla larghezza effettiva dell'embedding scritto
- `indexType`: identificatore dell'algoritmo denso; attualmente `ngh`
- `distanceMetric`: metrica di similarità lato indice (build e ricerca); `cosine` è comune per embedding semantici, `l2` per distanza euclidea, `innerProduct` per prodotto scalare. Dopo la scrittura dei dati, modificarla richiede in genere la ricostruzione dell'indice vettoriale.

**Parametri di recupero a catena** (`matchVector` / `orMatchVector`, più `limit` sulla catena):

- `field` / `vector`: campo vettoriale di destinazione e vettore di query (`VectorData` / `List<num>` / `Float32List`)
- `searchDepth`: profondità opzionale `[1, 100]`, mappata all'**intento** di recall `[90 %, 100 %]` (`0.90 + depth/1000`; `50` → ~95 % baseline produzione, `80` → ~98 %); il motore sceglie un budget minimo di sonde — ANN best-effort, **non** recall@K garantito; omesso → default `50`
- `weight`: peso di fusione di questo canale di richiamo in multi-via; default `1.0`
- `minScore`: soglia inferiore di similarità normalizzata `[0.0 ~ 1.0]`; i candidati sotto vengono scartati
- `distanceThreshold`: soglia superiore di distanza; oltre, il candidato è escluso
- `limit`: numero di risultati da restituire (equivalente a topK nell'ANN tipico)

**Note sul risultato** (`QueryResult`):

- Le righe di business sono in `data`; punteggi e info di canale in `retrieval.entries`, allineati **1:1** con `data`
- `entry.score`: punteggio di similarità / fusione normalizzato, tipicamente `0 ~ 1`; più alto = più rilevante
- `entry.meta['distance']`: distanza grezza (comune sul canale vettoriale); per `l2` / `cosine`, più piccolo di solito significa più vicino
- `retrieval.fusionMethod`: di solito `single` per un canale; il richiamo multi-via è tipicamente `rrf` (Reciprocal Rank Fusion)

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
ToStore decide se aggiornare o inserire in base alla chiave primaria o al campo univoco incluso in `data`. `where` non è supportato qui; l'obiettivo del conflitto è determinato dai dati stessi.

```dart
// Per chiave primaria
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// Per chiave univoca (il record deve contenere tutti i campi che partecipano a un vincolo univoco più i campi obbligatori)
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// Batch upsert (supporta modalità atomica o modalità successo parziale)
// allowPartialErrors: true significa che alcune righe possono fallire mentre altre hanno comunque successo
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


### <a id="query-pagination"></a>Query e paginazione efficiente

> [!TIP]
> **Specificare sempre `limit` come dimensione della pagina**: Si raccomanda caldamente di specificare sempre `limit` nelle query. Se omesso, il motore imposterà un limite predefinito di 1.000 record per evitare di caricare troppi dati in una sola volta.

ToStore supporta la paginazione in modalità doppia. Per lo scorrimento infinito o il caricamento di elenchi, consigliamo vivamente l'uso della **paginazione nativa e continua tramite cursore**; per saltare direttamente a pagine specifiche, la paginazione di base con offset è sufficiente:

#### 1. Paginazione di base (Modalità Offset)
Adatta per scenari con volumi di dati ridotti (ad esempio, inferiori a 10.000 righe) o quando è necessario saltare a una pagina specifica con precisione.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Salta le prime 40 righe
    .limit(20); // Recupera 20 righe
```
> [!TIP]
> Quando l'`offset` diventa molto grande, il database deve scansionare e scartare una grande quantità di record, riducendo linearmente le prestazioni. Per la paginazione profonda o set di dati più grandi, si consiglia di utilizzare la **Modalità Cursore**.

#### 2. Paginazione tramite Cursore (Modalità Cursore - Consigliata)
Ideale per set di dati enormi e scorrimento infinito. Registrando la posizione iniziale del flusso di dati della pagina corrente, il motore si posiziona direttamente in quel punto durante la paginazione (seek), evitando di scansionare e scartare i dati storici e mantenendo costante la velocità di paginazione profonda.

* **Gestione Automatica**: Imposta un limite per la dimensione della pagina e chiama semplicemente `next()` o `prev()` sulle pagine successive per ottenere prestazioni di paginazione ottimali in modo semplice e veloce.
* **Spostamento del punto di partenza**: Supporta la combinazione con `.offset(N)` nella query iniziale per localizzare la finestra di avvio, dopo la quale la chiamata a `next()` recupera direttamente le pagine successive.

```dart
// 1. Avvia la query iniziale
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// 2. Recupera la pagina successiva
if (page1.hasMore) {
  final page2 = await page1.next(); 
  print('Numero di elementi nella pagina successiva: \${page2.data.length}');
  
  // 3. Recupera la pagina precedente
  if (page2.hasPrev) {
    final prevPage = await page2.prev();
    print('Dati della pagina precedente: \${prevPage.data}');
  }
}
```

##### Scenario avanzato: Paginazione tramite token senza stato (Token-based Cursor)
Per la paginazione ordinaria nell'app, preferisci `next()` / `prev()` sopra. Usa i token del cursore solo per API client-server o quando serializzi lo stato di paginazione tra processi/reti:
* La query iniziale restituisce le stringhe di token `nextCursorToken` e `prevCursorToken`.
* La query successiva passa il token tramite `.cursor(token)` per il posizionamento diretto (seek).
* **Nota**: `cursor` e `offset` sono mutuamente esclusivi; impostarne uno cancella l'altro.

```dart
// Query iniziale (ad esempio, sul lato server API)
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

final String? nextToken = page1.nextCursorToken; // Serializza e restituisci questo token al client

// Quando il client richiede la pagina successiva con il token:
if (nextToken != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(nextToken); // Passa il token per posizionarti e leggere con precisione
}
```

| Funzionalità | Modalità Offset | Modalità Cursore |
| :--- | :--- | :--- |
| **Prestazioni della query** | Degrada con l'aumentare delle pagine | Velocità costante per la paginazione profonda |
| **Ideale per** | Set di dati più piccoli, salti di pagina precisi | **Set di dati enormi, scorrimento infinito** |
| **Coerenza con le modifiche** | Le modifiche ai dati possono causare righe duplicate o saltate | Evita duplicati e omissioni causati dalle modifiche ai dati |


### <a id="query-peek"></a>Sonda di memoria e recupero sincrono (peek)

Per scenari con requisiti estremi di throughput e latenza, ToStore fornisce la serie `peek` di recupero sincrono puramente in memoria, assorbendo letture hot in burst direttamente nel processo: i **dispositivi edge** possono sostenere milioni di letture al secondo; i **server** con hardware più potente possono raggiungere decine di milioni per macchina (vedi [Benchmark](#performance)).

> [!NOTE]
> **Solo cache in memoria**: `peek` è un bypass puramente in memoria senza scheduling. In caso di cache miss restituisce immediatamente vuoto/`null`; il motore non esegue I/O su file sincrono (evitando il blocco dell'event loop sotto alta concorrenza). Per risultati persistenti completi, usare `await query()` nell'applicazione.

#### Metodi peek
| Metodo | Tipo di ritorno | Descrizione |
| :--- | :--- | :--- |
| `peekFirst()` | `Map<String, dynamic>?` | Record singolo; `null` in caso di cache miss |
| `peek()` | `QueryResult<T>` | `QueryResult` con lista `data` e metadati di paginazione (`hasMore`, cursori, ecc.); dati solo con cache hit |
| `peekExists()` | `bool` | Verifica sincronamente l'esistenza di un record corrispondente in cache |
| `peekCount()` | `int` | Conta sincronamente i record corrispondenti in cache |
| `result.peekNext()` | `QueryResult<T>` | Pagina successiva sincrona quando il risultato paginato è in cache |
| `result.peekPrev()` | `QueryResult<T>` | Pagina precedente sincrona quando il risultato paginato è in cache |

#### Best practice: sonda di memoria prima (Peek-Through)
```dart
// Record singolo: sonda di memoria prima, query asincrona standard in caso di miss
final q = db.query('users').where('id', '=', userId);
final user = q.peekFirst() ?? await q.first();

// Query paginata con sonda
final listQ = db.query('users').orderByDesc('id').limit(20);
var page = listQ.peek();
if (page.data.isEmpty) page = await listQ;

if (page.hasMore) {
  final next = page.peekNext(); // cache hit: cambio pagina sincrono
  if (next.data.isEmpty) await page.next();
}
```

#### Sonda KV (`db.kv`)

| Metodo | Equivalente async | Descrizione |
| :--- | :--- | :--- |
| `peekGet(key)` | `get(key)` | Sonda puntale in memoria; chiavi scadute → `null` |
| `peekExists(key)` | `exists(key)` | Verifica esistenza in memoria |
| `db.kv.query().peek()` | `await db.kv.query()` | Sonda paginata (prefisso / ordinamento / limit) |
| `db.kv.query().peekFirst()` | `await db.kv.query().first()` | Sonda del primo record |

```dart
// Punto: sonda prima, async in fallback
final theme = db.kv.peekGet('theme', isGlobal: true) ?? await db.kv.get('theme', isGlobal: true);

// Sonda KV paginata
var page = db.kv.query().prefix('setting_').limit(20).peek();
if (page.data.isEmpty) page = await db.kv.query().prefix('setting_').limit(20);
```

> [!TIP]
> **Raccomandazione**: Le query asincrone standard (`await query()`) usano lo scheduling degli eventi per stabilità a lungo termine ed equità multitasking; 100k+ QPS sono sufficienti per la maggior parte dei carichi. La serie `peek` è progettata per picchi estremi di lettura hot a milioni/decine di milioni di QPS per macchina.


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

if (!txResult.hasErrors) {
  print('Transazione confermata con successo');
} else {
  print('Rollback della transazione a causa di:');
  for (final status in txResult.statuses) {
    if (status.type != ResultType.success) {
      print(' - [$status.codeKey}] $status.message}');
    }
  }
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
  - `getTableNames({isGlobal})`: elenca i nomi delle tabelle nell'inventario schema globale (tabelle utente). Opzionale `isGlobal`: `true` solo globali, `false` solo non globali, omesso = entrambe. Gli schema non globali sono condivisi tra spazi; solo i dati sono isolati.
  - `getTableInfo(tableName)`: statistiche runtime (`totalRecordCount`, `totalTableDataSizeBytes`, `totalIndexDataSizeBytes`, `indexCount`, creazione, se globale)
  - `clear(tableName)`: cancella tutti i dati della tabella conservando in modo sicuro schema, indici e vincoli di chiave interni/esterni
  - `dropTable(tableName)`: distrugge completamente una tabella e il suo schema; non reversibile
- **Gestione dello spazio**
  - `currentSpaceName`: ottieni lo spazio attivo corrente in tempo reale
  - `listSpaces()`: elenca tutti gli spazi allocati nell'istanza del database corrente
  - `getSpaceInfo(useCache: true)`: aggregati locali dello spazio (`totalRecordCount`, dimensione dati tabella/indice). Usare `useCache: false` per riconciliare da meta.
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
final tableNames = await db.getTableNames();
final spaceInfo = await db.getSpaceInfo(useCache: false);
final tableSchema = await db.getTableSchema('users');
final tableInfo = await db.getTableInfo('users');

print('spaces: $spaces');
print('tables: $tableNames');
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

Ci sono due canali per il feedback di errori ed eccezioni in ToStore:

> [!NOTE]
> **Base diagnostica unificata**: Sia che vengano restituiti tramite il modello di risultato della risposta (`statuses` in `DbResult`/`QueryResult`) o generati tramite eccezioni fatali (`statuses` in `DbException`), tutti gli stati diagnostici si basano uniformemente sul sistema strutturato **`ResultStatus`** e condividono gli stessi codici di stato, garantendo coerenza.

1. Modello di risultato della risposta (Result-based Response)
Per le operazioni quotidiane come inserimento, aggiornamento, cancellazione, query, transazioni e modifiche dello schema della tabella in runtime. Queste operazioni **non genereranno eccezioni** in caso di violazioni dei vincoli, errori di validazione o argomenti non validi. Al contrario, ToStore avvolge i risultati utilizzando `DbResult` o `QueryResult`, registrando tutte le informazioni diagnostiche nell'elenco degli stati. Ciò garantisce che i normali errori di logica aziendale non interrompano il database.

- **`hasErrors`: Indica se ci sono errori nell'operazione corrente. Nelle operazioni batch o transazioni, se è presente almeno un errore, questa proprietà è `true`.**
- **`statuses`: Un elenco dettagliato di tutte le diagnosi `ResultStatus` per l'operazione. Supporta una corrispondenza d'ordine 1:1, utile per le operazioni batch.**
- **`firstPrimaryKey`: Legge la chiave primaria fisicamente generata direttamente durante una singola operazione di inserimento/scrittura senza analizzare `statuses` manualmente.**
- **`ResultType`: Enumerazione per la categoria di stato, comoda per la gestione dei rami e controlli (es. `isBusinessError`, `isDeveloperError`).**

2. Generazione di eccezioni (Exception-based Throwing)
Per errori fatali causati da sviste dello sviluppatore o difetti di progettazione (es. errore di verifica dello schema durante `ToStore.open`, incompatibilità della versione dell'engine, corruzione fatale della migrazione dei dati, ecc.). In questi casi, ToStore genera `DbException` per arrestare l'eccezione, sollecitando lo sviluppatore a correggere il problema.

> [!WARNING]
> Linee guida per lo sviluppo: I normali errori aziendali non devono generare eccezioni; devono essere restituiti nel modello di risultato della risposta per evitare di interrompere il runtime dell'applicazione.

---

### Esempi di errori ed eccezioni

#### 1. Gestione della risposta per una singola scrittura

```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (result.hasErrors) {
  // Ottieni il primo tipo di errore e la descrizione
  print('Operation failed: [\${result.firstType.codeKey}] \${result.message}');
} else {
  print('Scrittura riuscita, la chiave primaria è: \${result.firstPrimaryKey}');
}
```

#### 2. Diagnosi dettagliata nella scrittura batch

```dart
final batchResult = await db.batchInsert('users', [
  {'username': 'alice', 'email': 'alice@example.com'},
  {'username': 'bob', 'email': 'invalid-email-format'}, // Validation fails
]);

if (batchResult.hasErrors) {
  print('Operazione batch parzialmente fallita: riusciti \${batchResult.successCount}, falliti \${batchResult.failedCount}');
  
  for (final status in batchResult.statuses) {
    final int idx = status.index;
    
    if (status is ConstraintStatus) {
      print('Index [\$idx] Violazione del vincolo! Tabella! Tabella: \${status.tableName}, campi: \${status.fields}');
    } else if (status is InvalidArgumentStatus) {
      print('Index [\$idx] Errore di argomento! Parametro! Parameter: \${status.parameterName}, valore passato: \${status.passedValue}');
    } else if (status.type != ResultType.success) {
      print('Index [\$idx] Si è verificato un errore: [\${status.codeKey}] \${status.message}');
    }
  }
}
```

#### 3. Errore fatale e cattura dell'eccezione di inizializzazione (DbException)

```dart
try {
  // Initialize database with schemas that might have validation issues
  final db = await ToStore.open(schemas: appSchemas);
} on DbException catch (e) {
  print('❌ Eccezione database fatale! Messaggio di errore: \n\${e.message}');
  
  // Iterate through the detailed status list in the exception
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      print('Validazione schema fallita! Tabella! Tabella: \${status.tableName}, campo: \${status.field}, configurazione no valida: \${status.wrongValue}');
    } else {
      print('Informazioni diagnostiche: [\${status.codeKey}] \${status.message}');
    }
  }
}
```

Per l'elenco completo dei tipi di errore, codici di stato foglia, formati di serializzazione JSON e mappature dei campi, fare riferimento alla specifica completa: [Specifica di diagnosi automatica e risoluzione dello stato di ToStore ResultStatus](result_status_specification.md).

### <a id="logging-diagnostics"></a>Registra richiamate e diagnostica del database
ToStore può instradare i registri del ciclo de vida del database al livello aziendale tramite `ToStore.setLogConfig(...)`.

- La callback `onLog` riceve tutti i record di log `LogRecord` che superano i filtri correnti `enableLog` e `logLevel`.
  - **LogLevel.error**: Si è verificato un errore locale, non influisce sul normale funzionamento.
  - **LogLevel.critical**: Errore globale a livello di disastro (come disco pieno, memoria insufficiente, grave errore di migração, ecc.) che richiede l'intervento manuale. Si consiglia di attivare notifiche di allarme a questo livello.
- Chiamare `ToStore.setLogConfig(...)` prima dell'inizializzazione in modo che vengano acquisiti anche i log generati durante l'inizializzazione e la migrazione automatica.

```dart
  // Configura i parametri di log o la callback
  ToStore.setLogConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    logLabel: 'my_app_db', // Titolo grigio chiaro in alto nel log per distinguere app o istanze di database,
    onLog: (log) {
      // In produzione, warn/error/critical possono essere segnalati al backend o alla piattaforma di log
      // log.level corrisponde al livello di log (LogLevel.debug, info, warn, error, critical)
      // log.message corrisponde al testo del log elaborato
      // log.status corrisponde allo stato di diagnostica ResultStatus sottostante (contiene code e codeKey)
      if (!debugMode && (log.level == LogLevel.warn || log.level == LogLevel.error || log.level == LogLevel.critical)) {
        developer.log(log.message, name: 'my_app_db', time: log.timestamp);
      }
    },
  );

  final db = await ToStore.open();
```
## <a id="security-config"></a>Configurazione della sicurezza

> [!WARNING]
> **Gestione delle chiavi**
>
> | Chiave | Ruolo | Come cambiare | Riscrittura completa dei dati? |
> | :--- | :--- | :--- | :--- |
> | **`encodingKey`** | Chiave di crittografia dei dati | Impostare un nuovo valore e ripetere `open` | **Sì** (lento) |
> | **`encryptionKey`** | Chiave di sicurezza; protegge `encodingKey` | Chiamare `db.rotateEncryptionKey` a runtime | **No** (veloce) |
>
> Non codificare mai chiavi sensibili. Per associarle al dispositivo, salva `encryptionKey` nel Keychain / Keystore / secure enclave del sistema e passalo al motore.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Supported: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305,

      // Data encryption key: encrypts table/index/log data; changing it triggers a background rewrite
      encodingKey: 'Your-Encoding-Key...',

      // Security key: protects encodingKey; rotate online via db.rotateEncryptionKey
      encryptionKey: 'Your-Secure-Encryption-Key...',

      // standard: critical table data, B-tree indexes, and log payloads
      // full: encrypts the entire engine files
      encryptionScope: EncryptionScope.standard,
    ),
    // Enable crash recovery logging (Write-Ahead Logging), enabled by default
    enableJournal: true,
    // Whether transactions force data to disk on commit; set false to reduce sync overhead
    persistRecoveryOnCommit: true,
  ),
);
```

**Modificare `encodingKey`**: impostare il nuovo valore in `EncryptionConfig` e ripetere `open`. Il motore rileva la modifica e migra i dati automaticamente in background, senza intervento dell'applicazione.

**Ruotare `encryptionKey`** (rotazione periodica per sicurezza/conformità): nessuna riscrittura dei dati; eseguibile online.

```dart
// If encryptionKey was never set explicitly, oldKey can be omitted
final result = await db.rotateEncryptionKey(newKey: 'new-secure-key');
// Or: await db.rotateEncryptionKey(oldKey: 'old-key', newKey: 'new-key');
if (result.hasErrors) {
  // Gestire l'errore (oldKey errato, migrazione encodingKey in corso, ecc.)
  return;
}
// Successo: config in memoria aggiornata; passare l'encryptionKey più recente al prossimo ToStore.open
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


Se ToStore ti è d'aiuto, lasciaci un ⭐️, è uno dei modi migliori per sostenere il progetto. Grazie mille!

## <a id="contribute"></a>🤝 Contribuire

ToStore è un motore di dati moderno in continua evoluzione, e accogliamo con piacere i contributi della comunità.
Che si tratti di correggere bug, migliorare la documentazione, perfezionare l'architettura o proporre nuove idee, puoi partecipare tramite PR:

- 🔗 **Invia PR**: [Pull Requests](https://github.com/tocreator/tostore/pulls)
- 📖 **Documentazione**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Segnalazione dei problemi**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Discussione tecnica**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


