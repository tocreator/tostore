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


## Navigazione Rapida

- [Perché ToStore?](#why-tostore) | [Caratteristiche Principali](#key-features) | [Installazione](#installation) | [Inizio Rapido](#quick-start)
- [Definizione dello Schema](#schema-definition) | [Integrazione Mobile/Desktop](#mobile-integration) | [Integrazione Server](#server-integration)
- [Vettori e Ricerca ANN](#vector-advanced) | [TTL a Livello di Tabella](#ttl-config) | [Query e Paginazione](#query-pagination) | [Chiavi Esterne](#foreign-keys) | [Operatori di Query](#query-operators)
- [Architettura Distribuita](#distributed-architecture) | [Esempi di Chiavi Primarie](#primary-key-examples) | [Operazioni Atomiche](#atomic-expressions) | [Transazioni](#transactions) | [Gestione degli Errori](#error-handling)
- [Configurazione di Sicurezza](#security-config) | [Prestazioni](#performance) | [Altre Risorse](#more-resources)


<a id="why-tostore"></a>
## Perché scegliere ToStore?

ToStore è un motore di dati moderno progettato per l'era dell'AGI e scenari di intelligenza edge (edge intelligence). Supporta nativamente sistemi distribuiti, fusione multimodale, dati relazionali strutturati, vettori ad alta dimensione e archiviazione di dati non strutturati. Basato su un'architettura sottostante simile a una rete neurale, i nodi possiedono un'elevata autonomia e una scalabilità orizzontale elastica, costruendo una rete di topologia dei dati flessibile per una collaborazione fluida tra edge e cloud su più piattaforme. Offre transazioni ACID, query relazionali complesse (JOIN, chiavi esterne a cascata), TTL a livello di tabella e calcoli di aggregazione. Include molteplici algoritmi di chiavi primarie distribuite, espressioni atomiche, identificazione dei cambiamenti di schema, protezione tramite crittografia, isolamento dei dati in più spazi, pianificazione intelligente del carico sensibile alle risorse e ripristino automatico in caso di disastri o crash.

Poiché il centro di gravità del calcolo continua a spostarsi verso l'intelligenza edge, diversi terminali come agenti e sensori non sono più semplici "dispositivi di visualizzazione", ma diventano nodi intelligenti responsabili della generazione locale, della percezione dell'ambiente, del processo decisionale in tempo reale e della collaborazione dei dati. Le soluzioni di database tradizionali, limitate dalla loro architettura e dalle estensioni di tipo "plug-in", faticano a soddisfare i requisiti di bassa latenza e stabilità delle applicazioni intelligenti edge e cloud quando si trovano di fronte a scritture ad alta frequenza, dati enormi, ricerca vettoriale e generazione collaborativa.

ToStore conferisce all'edge capacità distribuite sufficienti per supportare dati massivi, generazione complessa di IA locale e flussi di dati su larga scala. La profonda collaborazione intelligente tra i nodi edge e cloud fornisce una base di dati affidabile per scenari come la fusione immersiva AR/VR, l'interazione multimodale, i vettori semantici e la modellazione spaziale.


<a id="key-features"></a>
## Caratteristiche Principali

- 🌐 **Motore di Dati Unificato Cross-Platform**
  - API unificata per Mobile, Desktop, Web e Server.
  - Supporta dati strutturati relazionali, vettori ad alta dimensione e archiviazione di dati non strutturati.
  - Ideale per cicli di vita dei dati dall'archiviazione locale alla collaborazione edge-cloud.

- 🧠 **Architettura Distribuita Simile a una Rete Neurale**
  - Elevata autonomia dei nodi; la collaborazione interconnessa costruisce topologie di dati flessibili.
  - Supporta la collaborazione dei nodi e la scalabilità orizzontale elastica.
  - Interconnessione profonda tra i nodi intelligenti edge e il cloud.

- ⚡ **Esecuzione Parallela e Pianificazione delle Risorse**
  - Pianificazione intelligente del carico sensibile alle risorse con alta disponibilità.
  - Calcolo collaborativo parallelo multi-nodo e scomposizione dei compiti.

- 🔍 **Query Strutturata e Ricerca Vettoriale**
  - Supporta query con condizioni complesse, JOIN, calcoli di aggregazione e TTL a livello di tabella.
  - Supporta campi vettoriali, indici vettoriali e ricerca di vicini più prossimi (ANN).
  - I dati strutturati e vettoriali possono essere usati collaborativamente all'interno dello stesso motore.

- 🔑 **Chiavi Primarie, Indicizzazione ed Evoluzione dello Schema**
  - Algoritmi integrati di incremento sequenziale, timestamp, prefisso data e short-code.
  - Supporta indici univoci, indici composti, indici vettoriali e vincoli di chiave esterna.
  - Identifica intelligentemente i cambiamenti di schema e automatizza la migrazione dei dati.

- 🛡️ **Transazioni, Sicurezza e Ripristino**
  - Offre transazioni ACID, aggiornamenti di espressioni atomiche e chiavi esterne a cascata.
  - Supporta il ripristino post-crash, la persistenza su disco e garanzie di coerenza dei dati.
  - Supporta la crittografia ChaCha20-Poly1305 e AES-256-GCM.

- 🔄 **Multi-Space e Flusso di Lavoro dei Dati**
  - Supporta l'isolamento dei dati tramite Spazi con condivisione globale configurabile.
  - Listener di query in tempo reale, cache intelligente multilivello e paginazione tramite cursore.
  - Perfetto per applicazioni multi-utente, local-first e di collaborazione offline.


<a id="installation"></a>
## Installazione

> [!IMPORTANT]
> **Aggiornamento dalla v2.x?** Leggere la [Guida all'aggiornamento v3.x](../UPGRADE_GUIDE_v3.md) per i passaggi critici di migrazione e i cambiamenti importanti.

Aggiungere `tostore` come dipendenza nel file `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Usa la versione più recente
```

<a id="quick-start"></a>
## Inizio Rapido

> [!IMPORTANT]
> **Definire lo schema della tabella è il primo passo**: È necessario definire lo schema della tabella prima di eseguire operazioni CRUD (tranne se si utilizza solo l'archiviazione KV).
> - Vedere [Definizione dello Schema](#schema-definition) per dettagli su definizioni e vincoli.
> - **Mobile/Desktop**: Passare `schemas` durante l'inizializzazione dell'istanza; vedere [Integrazione Mobile](#mobile-integration).
> - **Server**: Usare `createTables` a runtime; vedere [Integrazione Server](#server-integration).

```dart
// 1. Inizializzare il database
final db = await ToStore.open();

// 2. Inserire dati
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Query concatenate (vedere [Operatori di Query](#query-operators); supporta =, !=, >, <, LIKE, IN, ecc.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. Aggiornare e Eliminare
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Ascolto in tempo reale (l'interfaccia si aggiorna automaticamente quando i dati cambiano)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Utenti corrispondenti aggiornati: $users');
});
```

### Archiviazione Chiave-Valore (KV)
Adatto per scenari che non richiedono tabelle strutturate. Semplice e pratico, integra un'archiviazione KV ad alte prestazioni per configurazione, stato e altri dati sparsi. I dati in diversi Spazi sono isolati per impostazione predefinita, ma possono essere configurati per la condivisione globale.

```dart
final db = await ToStore.open();

// Impostare coppie chiave-valore (supporta String, int, bool, double, Map, List, ecc.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// Ottenere dati
final theme = await db.getValue('theme'); // 'dark'

// Eliminare dati
await db.removeValue('theme');

// Chiave-valore globale (condiviso tra gli Spazi)
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```


<a id="schema-definition"></a>
## Definizione dello Schema

### Panoramica di TableSchema

```dart
const userSchema = TableSchema(
  name: 'users', // Nome della tabella, obbligatorio
  tableId: 'users', // ID univoco, per il rilevamento preciso della ridenominazione
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // Campo PK, predefinito 'id'
    type: PrimaryKeyType.sequential, 
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
      comment: 'Nome di login', 
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0,
      maxValue: 150,
      defaultValue: 0,
      createIndex: true, // Crea un indice per le prestazioni
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // Timestamp automatico
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
  foreignKeys: const [], // Vincoli di chiave esterna (vedere sezione)
  isGlobal: false, // Tabella globale (accessibile in tutti gli Spazi)
  ttlConfig: null, // TTL a livello di tabella (vedere sezione)
);
```

`DataType` supporta `integer`, `bigInt`, `double`, `text`, `blob`, `boolean`, `datetime`, `array`, `json`, `vector`. 

### Vincoli e Auto-validazione

Puoi scrivere regole di validazione comuni direttamente nello schema tramite `FieldSchema`:

- `nullable: false`: Vincolo non nullo.
- `minLength` / `maxLength`: Lunghezza del testo.
- `minValue` / `maxValue`: Intervallo numerico.
- `defaultValue`: Valori predefiniti.
- `unique`: Unicità (genera un indice univoco).
- `createIndex`: Crea un indice per filtri frequenti.


<a id="mobile-integration"></a>
## Integrazione Mobile/Desktop

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// Multi-space - Isolare i dati degli utenti
await db.switchSpace(spaceName: 'user_123');
```

### Persistenza del Login e Logout (Spazio Attivo)

Usa lo **Spazio Attivo** per mantenere l'utente attuale dopo il riavvio.

- **Persistenza**: Segna lo spazio come attivo durante il cambio (`keepActive: true`).
- **Logout**: Chiudi il database con `keepActiveSpace: false`.

```dart
// Dopo il login: Salvare lo spazio utente come attivo
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Logout: Chiudere e cancellare lo spazio attivo per il prossimo avvio
await db.close(keepActiveSpace: false);
```


<a id="server-integration"></a>
## Integrazione Server

```dart
final db = await ToStore.open();

// Creare o convalidare la struttura all'avvio
await db.createTables(appSchemas);

// Aggiornamento dello schema online
final taskId = await db.updateSchema('users')
  .renameTable('users_new')
  .modifyField('username', minLength: 5, unique: true)
  .renameField('old', 'new')
  .removeField('deprecated')
  .addField('created_at', type: DataType.datetime)
  .removeIndex(fields: ['age']);
    
// Monitorare il progresso della migrazione
final status = await db.queryMigrationTaskStatus(taskId);
print('Progresso: ${status?.progressPercentage}%');


// Gestione Manuale della Cache delle Query
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Invalida la cache specifica
await db.query('users').where('is_active', '=', true).clearQueryCache();
```


<a id="advanced-usage"></a>
## Uso Avanzato


<a id="vector-advanced"></a>
### Vettori e Ricerca ANN

```dart
await db.createTables([
  const TableSchema(
    name: 'embeddings',
    fields: [
      FieldSchema(name: 'document_title', type: DataType.text, nullable: false),
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

// Ricerca vettoriale
final results = await db.vectorSearch(
  'embeddings', 
  fieldName: 'embedding', 
  queryVector: queryVector, 
  topK: 5,
);
```


<a id="ttl-config"></a>
### TTL a Livello di Tabella (Scadenza Automatica)

Per log o eventi: i dati scaduti vengono puliti automaticamente in background.

```dart
const TableSchema(
  name: 'event_logs',
  fields: [/* ... */],
  ttlConfig: TableTtlConfig(ttlMs: 7 * 24 * 60 * 60 * 1000), // Conserva per 7 giorni
);
```


### Scrittura Intelligente (Upsert)
Aggiorna se la PK o la chiave univoca esiste, altrimenti inserisce.

```dart
await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});
```


### JOIN e Aggregazione
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .limit(20);

// Aggregazione
final count = await db.query('users').count();
final sum = await db.query('orders').sum('total');
```


<a id="query-pagination"></a>
### Query e Paginazione Efficiente

- **Modalità Offset**: Per piccoli dataset o salti di pagina.
- **Modalità Cursore**: Consigliato per dati enormi e scroll infinito (O(1)).

```dart
final page1 = await db.query('users').orderByDesc('id').limit(20);

if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor);
}
```


<a id="foreign-keys"></a>
### Chiavi Esterne e Cascata

```dart
foreignKeys: [
    ForeignKeySchema(
      name: 'fk_posts_user',
      fields: ['user_id'],
      referencedTable: 'users',
      referencedFields: ['id'],
      onDelete: ForeignKeyCascadeAction.cascade, // Elimina i post se l'utente viene eliminato
    ),
],
```


<a id="query-operators"></a>
### Operatori di Query

Supportati: `=`, `!=`, `>`, `>=`, `<`, `<=`, `IN`, `NOT IN`, `BETWEEN`, `LIKE`, `IS NULL`, `IS NOT NULL`.

```dart
db.query('users').whereEqual('name', 'John').whereGreaterThan('age', 18).limit(20);
```


<a id="atomic-expressions"></a>
## Operazioni Atomiche

Calcoli a livello di database per evitare conflitti di concorrenza:

```dart
// balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', id);

// In un Upsert: Incrementa se update, altrimenti imposta a 1
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(Expr.isUpdate(), Expr.field('count') + 1, 1),
});
```


<a id="transactions"></a>
## Transazioni

Garantiscono l'atomicità: o tutte le operazioni hanno successo o tutte vengono annullate.

```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {...});
  await db.update('users', {...});
});
```


<a id="security-config"></a>
## Sicurezza

> [!WARNING]
> **Gestione delle chiavi**: `encodingKey` può essere cambiata (auto-migrazione). `encryptionKey` è critica; il suo cambiamento senza migrazione rende i vecchi dati illeggibili.

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

### Crittografia di campo (ToCrypto)
Per crittografare selettivamente campi sensibili senza influire sulle prestazioni globali.


<a id="performance"></a>
## Prestazioni

- 📱 **Esempio**: Progetto completo nella cartella `example`.
- 🚀 **Release Mode**: Molto più performante della modalità Debug.
- ✅ **Testato**: Funzioni di base coperte da suite di test.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="Demo prestazioni ToStore" width="320" />
</p>

- **Demo Prestazioni**: Fluido con oltre 100M+ di voci. ([Video](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4))

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="Ripristino di emergenza ToStore" width="320" />
</p>

- **Ripristino**: Ripristino automatico dopo interruzione di corrente. ([Video](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4))


Se ToStore ti aiuta, dacci una ⭐️! È il miglior supporto per l'open source.

---

> **Raccomandazione**: Usa il [ToApp Framework](https://github.com/tocreator/toapp) per il front-end. Una soluzione full-stack per query, cache e state management.
