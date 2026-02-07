# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | Italiano | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)


## Perché scegliere Tostore?

Tostore è l'unico motore di archiviazione ad alte prestazioni per database vettoriali distribuiti nell'ecosistema Dart/Flutter. Utilizzando un'architettura di tipo rete neurale, presenta un'interconnettività intelligente e una collaborazione tra i nodi, supportando una scalabilità orizzontale infinita. Costruisce una rete di topologia dati flessibile e fornisce un'identificazione precisa dei cambi di schema, protezione tramite crittografia e isolamento dei dati multi-spazio. Tostore sfrutta appieno le CPU multi-core per un'elaborazione parallela estrema e supporta nativamente la collaborazione cross-platform dagli edge device mobili al cloud. Con vari algoritmi di chiavi primarie distribuite, fornisce una potente base dati per scenari come la realtà virtuale immersiva, l'interazione multimodale, il calcolo spaziale, l'IA generativa e la modellazione dello spazio vettoriale semantico.

Mentre l'IA generativa e il calcolo spaziale spostano il baricentro verso l'edge, i dispositivi terminali si stanno evolvendo da semplici visualizzatori di contenuti a centri di generazione locale, percezione ambientale e processo decisionale in tempo reale. I database integrati tradizionali a file singolo sono limitati dal loro design architettonico, spesso faticando a supportare i requisiti di risposta immediata delle applicazioni intelligenti di fronte a scritture ad alta concorrenza, recupero vettoriale massiccio e generazione collaborativa cloud-edge. Tostore è nato per gli edge device, conferendo loro capacità di archiviazione distribuita sufficienti a supportare la generazione locale di IA complessa e il flusso di dati su larga scala, realizzando una vera collaborazione profonda tra cloud ed edge.

**Resistente a interruzioni di corrente e crash**: Anche in caso di interruzione improvvisa di corrente o crash dell'applicazione, i dati possono essere recuperati automaticamente, ottenendo una perdita zero reale. Quando un'operazione sui dati risponde, i dati sono già stati salvati in modo sicuro, eliminando il rischio di perdita dei dati.

**Superamento dei limiti di prestazioni**: I test di prestazioni mostrano che anche con 10 milioni di record, un tipico smartphone può avviarsi immediatamente e mostrare i risultati della query all'istante. Indipendentemente dal volume dei dati, è possibile godere di un'esperienza fluida che supera di gran lunga quella dei database tradizionali.




...... Dalla punta delle dita alle applicazioni cloud, Tostore ti aiuta a liberare la potenza di calcolo dei dati e a potenziare il futuro ......




## Caratteristiche di Tostore

- 🌐 **Supporto fluido per tutte le piattaforme**
  - Esegui lo stesso codice su tutte le piattaforme, dalle app mobili ai server cloud.
  - Si adatta intelligentemente ai diversi backend di archiviazione della piattaforma (IndexedDB, file system, ecc.).
  - Interfaccia API unificata per una sincronizzazione dei dati cross-platform senza preoccupazioni.
  - Flusso di dati fluido dagli edge device ai server cloud.
  - Calcolo vettoriale locale sugli edge device, riducendo la latenza di rete e la dipendenza dal cloud.

- 🧠 **Architettura distribuita di tipo rete neurale**
  - Struttura a topologia di nodi interconnessi per un'organizzazione efficiente del flusso di dati.
  - Meccanismo di partizionamento dei dati ad alte prestazioni per un vero processamento distribuito.
  - Bilanciamento dinamico intelligente del carico di lavoro per massimizzare l'utilizzo delle risorse.
  - Scalabilità orizzontale infinita dei nodi per costruire facilmente reti di dati complesse.

- ⚡ **Massima capacità di elaborazione parallela**
  - Lettura/scrittura parallela reale utilizzando gli Isolate, funzionando alla massima velocità su CPU multi-core.
  - La pianificazione intelligente delle risorse bilancia automaticamente il carico per massimizzare le prestazioni multi-core.
  - La rete di calcolo multi-nodo collaborativa raddoppia l'efficienza di elaborazione delle attività.
  - Il framework di pianificazione consapevole delle risorse ottimizza automaticamente i piani di esecuzione per evitare conflitti di risorse.
  - L'interfaccia di query in streaming gestisce facilmente set di dati massivi.

- 🔑 **Vari algoritmi di chiavi primarie distribuite**
  - Algoritmo di incremento sequenziale - Regola liberamente le dimensioni del passo casuale per nascondere la scala del business.
  - Algoritmo basato su timestamp - La scelta migliore per scenari ad alta concorrenza.
  - Algoritmo con prefisso data - Supporto perfetto per la visualizzazione di dati in intervalli temporali.
  - Algoritmo di codice breve - Genera identificatori unici brevi e facili da leggere.

- 🔄 **Migrazione intelligente dello schema e integrità dei dati**
  - Identifica con precisione i campi della tabella rinominati con zero perdita di dati.
  - Rilevamento automatico dei cambiamenti di schema e migrazione dei dati in pochi millisecondi.
  - Aggiornamenti senza tempi di inattività, impercettibili per il business.
  - Strategie di migrazione sicure per modifiche strutturali complesse.
  - Validazione automatica dei vincoli di chiave esterna con supporto per operazioni a cascata che garantiscono l'integrità referenziale.

- 🛡️ **Sicurezza e durabilità di livello aziendale**
  - Meccanismo di doppia protezione: la registrazione in tempo reale dei cambiamenti dei dati garantisce che nulla vada mai perduto.
  - Recupero automatico dai crash: riprende automaticamente le operazioni non completate dopo un'interruzione di corrente o un crash.
  - Garanzia di coerenza dei dati: le operazioni hanno successo completamente o vengono annullate del tutto (rollback).
  - Aggiornamenti computazionali atomici: il sistema di espressioni supporta calcoli complessi, eseguiti atomicamente per evitare conflitti di concorrenza.
  - Persistenza sicura istantanea: i dati vengono salvati in modo sicuro quando l'operazione ha successo.
  - L'algoritmo di crittografia ad alta resistenza ChaCha20Poly1305 protegge i dati sensibili.
  - Crittografia end-to-end per la sicurezza durante l'archiviazione e la trasmissione.

- 🚀 **Cache intelligente e prestazioni di recupero**
  - Meccanismo di cache intelligente a più livelli per un recupero dati ultra-veloce.
  - Strategie di cache profondamente integrate con il motore di archiviazione.
  - La scalabilità adattiva mantiene prestazioni stabili all'aumentare della dimensione dei dati.
  - Notifiche in tempo reale dei cambiamenti dei dati con aggiornamento automatico dei risultati della query.

- 🔄 **Flusso di lavoro dei dati intelligente**
  - L'architettura multi-spazio fornisce isolamento dei dati associato alla condivisione globale.
  - Distribuzione intelligente del carico di lavoro tra i nodi di calcolo.
  - Fornisce una solida base per l'addestramento e l'analisi di dati su larga scala.


## Installazione

> [!IMPORTANT]
> **Aggiornamento da v2.x?** Leggi la [Guida all'aggiornamento v3.0](../UPGRADE_GUIDE_v3.md) per i passaggi critici di migrazione e le modifiche radicali.

Aggiungi `tostore` come dipendenza nel tuo `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Usa la versione più recente
```

## Guida rapida

> [!IMPORTANT]
> **La definizione dello schema della tabella è il primo passo**: Prima di eseguire operazioni CRUD, è necessario definire lo schema della tabella. Il metodo di definizione specifico dipende dal tuo scenario:
> - **Mobile/Desktop**: Raccomandata [Definizione statica](#integrazione-per-scenari-di-avvio-frequente).
> - **Lato server**: Raccomandata [Creazione dinamica](#integrazione-lato-server).

```dart
// 1. Inizializzare il database
final db = await ToStore.open();

// 2. Inserire dati
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Query concatenate ([operatori di query](#operatori-di-query), supporta =, !=, >, <, LIKE, IN, ecc.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(10);

// 4. Aggiornare ed Eliminare
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Ascolto in tempo reale (l'interfaccia si aggiorna automaticamente)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Utenti corrispondenti aggiornati: $users');
});
```

### Archiviazione Chiave-Valore (KV)
Adatto per scenari che non richiedono di definire tabelle strutturate. È semplice, pratico e include uno store KV ad alte prestazioni integrato per configurazioni, stati e altri dati sparsi. I dati in Spaces diversi sono naturalmente isolati ma possono essere impostati per la condivisione globale.

```dart
// 1. Impostare coppie chiave-valore (Supporta String, int, bool, double, Map, List, ecc.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 2. Ottenere dati
final theme = await db.getValue('theme'); // 'dark'

// 3. Rimuovere dati
await db.removeValue('theme');

// 4. Chiave-valore globale (Condiviso tra Spaces)
// Per impostazione predefinita, i dati KV sono specifici dello spazio. Usa isGlobal: true per la condivisione.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



## Integrazione per scenari di avvio frequente

📱 **Esempio**: [mobile_quickstart.dart](example/lib/mobile_quickstart.dart)

```dart
// Definizione dello schema adatta per app mobili/desktop ad avvio frequente.
// Identifica con precisione i cambiamenti dello schema e migra i dati automaticamente.
final db = await ToStore.open(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // Tabella globale accessibile a tutti gli spazi
            fields: [],
    ),
    const TableSchema(
      name: 'users', // Nome tabella
      tableId: "users",  // Identificativo unico per rilevamento rinomina al 100%
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // Nome chiave primaria
      ),
      fields: [        // Definizioni campi (esclusa chiave primaria)
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true, // Crea automaticamente un indice univoco
          fieldId: 'username',  // Identificativo campo unico
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true // Crea automaticamente un indice univoco
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime,
          createIndex: true // Crea automaticamente un indice (idx_last_login)
        ),
      ],
      // Esempio di indice composto
      indexes: [
        IndexSchema(fields: ['username', 'last_login']),
      ],
    ),
    // Esempio di vincolo di chiave esterna
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
          fields: ['user_id'],              // Campi tabella corrente
          referencedTable: 'users',         // Tabella riferita
          referencedFields: ['id'],         // Campi riferiti
          onDelete: ForeignKeyCascadeAction.cascade,  // Eliminazione a cascata
          onUpdate: ForeignKeyCascadeAction.cascade,  // Aggiornamento a cascata
        ),
      ],
    ),
  ],
);

// Architettura multi-spazio - isolamento perfetto dei dati dei diversi utenti
await db.switchSpace(spaceName: 'user_123');
```

### Mantenere lo stato di accesso e logout (spazio attivo)

Il multi-spazio è adatto ai **dati per utente**: uno spazio per utente e cambio al login. Con lo **spazio attivo** e l’opzione **close** mantieni l’utente corrente tra i riavvii e supporti il logout.

- **Mantenere lo stato di accesso**: quando l’utente passa al proprio spazio, salvalo come spazio attivo così al prossimo avvio con default si apre direttamente quello spazio (non serve «aprire default e poi cambiare»).
- **Logout**: al logout chiudi il database con `keepActiveSpace: false` così al prossimo avvio non si apre automaticamente lo spazio dell’utente precedente.

```dart

// Dopo il login: passare allo spazio di questo utente e ricordarlo per il prossimo avvio (mantenere accesso)
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Opzionale: aprire rigorosamente in default (es. solo schermata di login) — non usare lo spazio attivo salvato
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// Al logout: chiudere e cancellare lo spazio attivo così il prossimo avvio usa lo spazio default
await db.close(keepActiveSpace: false);
```

## Integrazione lato server

🖥️ **Esempio**: [server_quickstart.dart](example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Creazione massiva di schemi a runtime
await db.createTables([
  // Tabella per l'archiviazione di vettori di caratteristiche spaziali 3D
  const TableSchema(
    name: 'spatial_embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,   // PK timestamp per alta concorrenza
    ),
    fields: [
      FieldSchema(
        name: 'video_name',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'spatial_features',
        type: DataType.vector,                // Tipo archiviazione vettoriale
        vectorConfig: VectorFieldConfig(
          dimensions: 1024,                   // Vettore ad alta dimensione
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
        type: IndexType.vector,              // Indice vettoriale
        fields: ['spatial_features'],
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.hnsw,   // Algoritmo HNSW per ANN efficiente
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,
            'efConstruction': 200,
          },
        ),
      ),
    ],
  ),
  // Altre tabelle...
]);

// Aggiornamenti dello schema online - Trasparente per il business
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // Rinomina tabella
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // Modifica attributi campo
  .renameField('old_name', 'new_name')     // Rinomina campo
  .removeField('deprecated_field')         // Rimuovi campo
  .addField('created_at', type: DataType.datetime)  // Aggiungi campo
  .removeIndex(fields: ['age'])            // Rimuovi indice
  .setPrimaryKeyConfig(                    // Cambia config PK
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// Monitoraggio del progresso della migrazione
final status = await db.queryMigrationTaskStatus(taskId);
print('Progresso migrazione: ${status?.progressPercentage}%');


// Gestione manuale della cache delle query (Server)
// Gestita automaticamente sulle piattaforme client.
// Per server o dati su larga scala, usa queste API per un controllo preciso.

// Memorizza manualmente il risultato di una query per 5 minuti.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Invalida una specifica cache quando i dati cambiano.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// Disabilita esplicitamente la cache per query che richiedono dati in tempo reale.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```



## Utilizzo avanzato

Tostore fornisce un ricco set di funzionalità avanzate per requisiti aziendali complessi:

### Query annidate e filtraggio personalizzato
Supporta l'annidamento infinito di condizioni e funzioni personalizzate flessibili.

```dart
// Annidamento condizioni: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// Funzione di condizione personalizzata
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('consigliato') ?? false);
```

### Upsert intelligente
Aggiorna se esiste, altrimenti inserisce.

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


### Join e selezione dei campi
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000);
```

### Streaming e statistiche
```dart
// Conteggio record
final count = await db.query('users').count();

// Query in streaming (adatta per dati massivi)
db.streamQuery('users').listen((data) => print(data));
```



### Query e paginazione efficiente

Tostore offre supporto per la paginazione in doppia modalità:

#### 1. Modalità Offset
Adatta per set di dati piccoli (es. meno di 10.000 record) o quando è richiesto il salto di pagina specifico.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Salta i primi 40
    .limit(20); // Prendi 20
```
> [!TIP]
> Quando l'`offset` è molto grande, il database deve scansionare e scartare molti record, causando un calo delle prestazioni. Usa la **modalità Cursor** per la paginazione profonda.

#### 2. Modalità Cursor ad alte prestazioni
**Consigliata per dati massivi e scenari di scorrimento infinito**. Utilizza `nextCursor` per prestazioni O(1), assicurando una velocità di query costante.

> [!IMPORTANT]
> Se si ordina per un campo non indicizzato o per determinate query complesse, il motore può tornare alla scansione completa della tabella e restituire un cursore `null` (il che significa che la paginazione per quella specifica query non è ancora supportata).

```dart
// Pagina 1
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Recupera la pagina successiva usando il cursore
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Posizionati direttamente nel punto corretto
}

// Torna indietro efficientemente con prevCursor
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Caratteristica | Modalità Offset | Modalità Cursor |
| :--- | :--- | :--- |
| **Prestazioni** | Diminuiscono all'aumentare delle pagine | **Costanti (O(1))** |
| **Complessità** | Piccoli dati, salto di pagina | **Dati massivi, scroll infinito** |
| **Consistenza** | I cambiamenti possono causare salti | **Evita duplicati/omissioni dai cambiamenti** |



### Operatori di query

Tutti gli operatori (insensibili al maiuscolo/minuscolo) per `where(field, operator, value)`:

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

### Metodi di query semantici (consigliato)

Preferire i metodi semantici per evitare di digitare gli operatori manualmente.

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

## Architettura distribuita

```dart
// Configura nodi distribuiti
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

// Inserimento batch ad alte prestazioni
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Record inseriti in blocco in modo efficiente
]);

// Elaborazione in streaming di grandi set di dati - utilizzo memoria costante
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Elabora efficientemente anche dati su scala TB senza elevato utilizzo di memoria
  print(record);
}
```

## Esempi di chiavi primarie

Tostore fornisce vari algoritmi di chiavi primarie:

- **Sequenziale** (PrimaryKeyType.sequential): 238978991
- **Basata su timestamp** (PrimaryKeyType.timestampBased): 1306866018836946
- **Prefisso data** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **Codice breve** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// Esempio configurazione chiave primaria sequenziale
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // Nascondi volume di business
      ),
    ),
    fields: [/* Definizioni campi */]
  ),
]);
```


## Operazioni atomiche con espressioni

Il sistema di espressioni fornisce aggiornamenti atomici e sicuri dei campi. Tutti i calcoli sono eseguiti atomicamente a livello di database:

```dart
// Incremento semplice: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Calcolo complesso: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// Parentesi annidate: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Uso di funzioni: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Timestamp: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

## Transazioni

Le transazioni assicurano l'atomicità di più operazioni: o tutte hanno successo o tutte vengono annullate, garantendo la coerenza dei dati.

**Caratteristiche delle transazioni**:
- Esecuzione atomica di più operazioni.
- Recupero automatico di operazioni non completate dopo un crash.
- I dati sono salvati in modo sicuro al momento del commit.

```dart
// Transazione base
final txResult = await db.transaction(() async {
  // Inserisci Utente
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // Aggiornamento atomico tramite espressioni
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // Se una qualsiasi operazione fallisce, tutte le modifiche vengono annullate.
});

if (txResult.isSuccess) {
  print('Transazione eseguita con successo');
} else {
  print('Transazione annullata: ${txResult.error?.message}');
}

// Rollback automatico in caso di errore
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('Errore logica di business'); // Innesca rollback
}, rollbackOnError: true);
```

## Configurazione della sicurezza

**Meccanismi di sicurezza dei dati**:
- Doppi meccanismi di protezione garantiscono che i dati non vadano mai persi.
- Recupero automatico dai crash per operazioni incomplete.
- Persistenza sicura istantanea al successo dell'operazione.
- La crittografia ad alta resistenza protegge i dati sensibili.

> [!WARNING]
> **Gestione chiavi**: **`encodingKey`** può essere modificata liberamente; il motore migrerà i dati automaticamente alla modifica, senza rischio di perdita. **`encryptionKey`** non va modificata arbitrariamente: modificarla renderà i vecchi dati illeggibili (a meno di una migrazione). Non cablare chiavi sensibili nel codice; recuperale da un server sicuro.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Algoritmi supportati: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // Chiave di codifica (modificabile liberamente; i dati vengono migrati automaticamente)
      encodingKey: 'Tua-Chiave-Di-Codifica-Lunga-32-Byte...', 
      
      // Chiave di crittografia per dati critici (non modificare arbitrariamente; vecchi dati illeggibili senza migrazione)
      encryptionKey: 'Tua-Chiave-Di-Crittografia-Sicura...',
      
      // Binding del dispositivo (basato su percorso)
      // Se abilitato, le chiavi sono legate al percorso e alle caratteristiche del dispositivo.
      // Aumenta la sicurezza contro la copia dei file del database.
      deviceBinding: false, 
    ),
    // WAL (Write-Ahead Logging) abilitato di default
    enableJournal: true, 
    // Forza il flush su disco al commit (imposta a false per massime prestazioni)
    persistRecoveryOnCommit: true,
  ),
);
```

### Cifratura a livello valore (ToCrypto)

La cifratura completa del database sopra cifra tutte le tabelle e gli indici e può influire sulle prestazioni complessive. Per cifrare solo i campi sensibili, usare **ToCrypto**: è indipendente dal database (nessuna istanza db richiesta). Si codificano o decodificano i valori prima della scrittura o dopo la lettura; la chiave è gestita interamente dalla propria app. L’output è Base64, adatto a colonne JSON o TEXT.

- **key** (obbligatorio): `String` o `Uint8List`. Se non sono 32 byte, una chiave di 32 byte viene derivata tramite SHA-256.
- **type** (opzionale): Tipo di cifratura [ToCryptoType]: [ToCryptoType.chacha20Poly1305] o [ToCryptoType.aes256Gcm]. Predefinito [ToCryptoType.chacha20Poly1305]. Omettere per usare il predefinito.
- **aad** (opzionale): Dati autenticati aggiuntivi — `Uint8List`. Se passati in codifica, bisogna passare gli stessi byte in decodifica (es. nome tabella + campo per il binding del contesto). Omettere per uso semplice.

```dart
const key = 'my-secret-key';
// Codifica: testo in chiaro → Base64 cifrato (salvare in DB o JSON)
final cipher = ToCrypto.encode('sensitive data', key: key);
// Decodifica in lettura
final plain = ToCrypto.decode(cipher, key: key);

// Opzionale: legare il contesto con aad (stesso aad in codifica e decodifica)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```

## Prestazioni ed Esperienza

### Specifiche di prestazione

- **Velocità di avvio**: Avvio istantaneo e visualizzazione dati anche con oltre 10M di record su smartphone medi.
- **Query**: Indipendente dalla scala, recupero ultra-veloce costante a qualsiasi volume di dati.
- **Sicurezza dei dati**: Garanzie di transazione ACID + ripristino da crash per zero perdita di dati.

### Raccomandazioni

- 📱 **Progetto esempio**: Un esempio completo di app Flutter è fornito nella directory `example`.
- 🚀 **Produzione**: Usa la modalità Release per prestazioni di gran lunga superiori alla modalità Debug.
- ✅ **Test standard**: Tutte le funzionalità core hanno superato i test di integrazione standard.




Se Tostore ti aiuta, per favore dacci una ⭐️




## Roadmap

Tostore sta sviluppando attivamente funzionalità per migliorare ulteriormente l'infrastruttura dati nell'era dell'IA:

- **Vettori ad alta dimensione**: Aggiunta di recupero vettoriale e algoritmi di ricerca semantica.
- **Dati multi-modali**: Elaborazione end-to-end dai dati grezzi ai vettori di caratteristiche.
- **Strutture dati a grafo**: Supporto per l'archiviazione e la query efficiente di grafi di conoscenza.





> **Raccomandazione**: Gli sviluppatori mobili possono anche considerare il [Framework Toway](https://github.com/tocreator/toway), una soluzione full-stack che automatizza richieste dati, caricamento, archiviazione, cache e visualizzazione.




## Altre risorse

- 📖 **Documentazione**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Feedback**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Discussione**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


## Licenza

Questo progetto è distribuito sotto licenza MIT - vedi il file [LICENSE](LICENSE) per i dettagli.

---
