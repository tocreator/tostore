# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | Italiano | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

Tostore è un motore di database con architettura distribuita multipiattaforma profondamente integrato nel tuo progetto. Il suo modello di elaborazione dati ispirato alle reti neurali implementa una gestione dei dati paragonabile al funzionamento del cervello. I meccanismi di parallelismo multi-partizione e la topologia di interconnessione dei nodi creano una rete di dati intelligente, mentre l'elaborazione parallela con Isolate sfrutta pienamente le capacità multi-core. Con vari algoritmi di chiavi primarie distribuite e un'estensione di nodi illimitata, può fungere da livello dati per infrastrutture di calcolo distribuito e addestramento dati su larga scala, consentendo un flusso di dati fluido dai dispositivi periferici ai server cloud. Funzionalità come il rilevamento preciso dei cambiamenti di schema, la migrazione intelligente, la crittografia ChaCha20Poly1305 e l'architettura multi-spazio supportano perfettamente vari scenari applicativi, dalle applicazioni mobili ai sistemi lato server.

## Perché scegliere Tostore?

### 1. Elaborazione parallela delle partizioni vs. archiviazione a file singolo
| Tostore | Database tradizionali |
|:---------|:-----------|
| ✅ Meccanismo di partizionamento intelligente, dati distribuiti su più file di dimensioni appropriate | ❌ Archiviazione in un singolo file di dati, degrado lineare delle prestazioni con la crescita dei dati |
| ✅ Lettura solo dei file di partizione pertinenti, prestazioni di query indipendenti dal volume totale dei dati | ❌ Necessità di caricare l'intero file di dati, anche per interrogare un singolo record |
| ✅ Mantenimento dei tempi di risposta in millisecondi anche con volumi di dati a livello di TB | ❌ Aumento significativo della latenza di lettura/scrittura sui dispositivi mobili quando i dati superano i 5 MB |
| ✅ Consumo di risorse proporzionale alla quantità di dati interrogati, non al volume totale dei dati | ❌ Dispositivi con risorse limitate soggetti a pressione di memoria ed errori OOM |
| ✅ La tecnologia Isolate consente una vera elaborazione parallela multi-core | ❌ Un file singolo non può essere elaborato in parallelo, spreco di risorse CPU |

### 2. Parallelismo Dart vs. linguaggi di script tradizionali
| Tostore | Database basati su script tradizionali |
|:---------|:-----------|
| ✅ Gli Isolate vengono eseguiti in vero parallelo senza vincoli di lock globale | ❌ Linguaggi come Python sono limitati dal GIL, inefficienti per task CPU-intensive |
| ✅ La compilazione AOT genera codice macchina efficiente, prestazioni vicine al nativo | ❌ Perdita di prestazioni nell'elaborazione dei dati dovuta all'esecuzione interpretata |
| ✅ Modello di heap di memoria indipendente, evita contese di lock e memoria | ❌ Il modello di memoria condivisa richiede meccanismi di locking complessi in alta concorrenza |
| ✅ La sicurezza dei tipi offre ottimizzazioni delle prestazioni e verifica degli errori in fase di compilazione | ❌ Il typing dinamico scopre gli errori a runtime con meno opportunità di ottimizzazione |
| ✅ Integrazione profonda con l'ecosistema Flutter | ❌ Richiede livelli ORM aggiuntivi e adattatori UI, aumentando la complessità |

### 3. Integrazione embedded vs. storage dati indipendenti
| Tostore | Database tradizionali |
|:---------|:-----------|
| ✅ Utilizza il linguaggio Dart, si integra perfettamente con progetti Flutter/Dart | ❌ Richiede di imparare SQL o linguaggi di query specifici, aumentando la curva di apprendimento |
| ✅ Lo stesso codice supporta frontend e backend, nessun bisogno di cambiare stack tecnologico | ❌ Frontend e backend generalmente richiedono database e metodi di accesso diversi |
| ✅ Stile di API a catena corrispondente agli stili di programmazione moderni, eccellente esperienza di sviluppo | ❌ Concatenazione di stringhe SQL vulnerabile ad attacchi ed errori, mancanza di sicurezza dei tipi |
| ✅ Supporto per la programmazione reattiva, si sposa naturalmente con i framework UI | ❌ Richiede strati di adattamento aggiuntivi per collegare UI e livello dati |
| ✅ Nessun bisogno di configurazione complessa di mappatura ORM, uso diretto degli oggetti Dart | ❌ Complessità del mapping oggetto-relazionale, costi elevati di sviluppo e manutenzione |

### 4. Rilevamento preciso dei cambiamenti di schema vs. gestione manuale delle migrazioni
| Tostore | Database tradizionali |
|:---------|:-----------|
| ✅ Rileva automaticamente i cambiamenti di schema, nessun bisogno di gestione dei numeri di versione | ❌ Dipendenza dal controllo manuale delle versioni e dal codice di migrazione esplicito |
| ✅ Rilevamento a livello di millisecondi dei cambiamenti di tabelle/campi e migrazione automatica dei dati | ❌ Necessità di mantenere la logica di migrazione per gli aggiornamenti tra versioni |
| ✅ Identificazione precisa delle rinominazioni di tabelle/campi, conservazione di tutti i dati storici | ❌ La rinominazione di tabelle/campi può comportare una perdita di dati |
| ✅ Operazioni di migrazione atomiche che garantiscono la coerenza dei dati | ❌ Le interruzioni della migrazione possono causare incoerenze dei dati |
| ✅ Aggiornamenti dello schema completamente automatizzati senza intervento manuale | ❌ Logica di aggiornamento complessa e costi di manutenzione elevati con l'aumento delle versioni |







## Punti di forza tecnici

- 🌐 **Supporto multipiattaforma trasparente**:
  - Esperienza coerente su piattaforme Web, Linux, Windows, Mobile, Mac
  - Interfaccia API unificata, sincronizzazione dati multipiattaforma senza problemi
  - Adattamento automatico a vari backend di archiviazione multipiattaforma (IndexedDB, filesystem, ecc.)
  - Flusso di dati fluido dall'edge computing al cloud

- 🧠 **Architettura distribuita ispirata alle reti neurali**:
  - Topologia di nodi interconnessi simile alle reti neurali
  - Meccanismo efficiente di partizionamento dei dati per l'elaborazione distribuita
  - Bilanciamento del carico dinamico intelligente
  - Supporto per l'estensione illimitata dei nodi, costruzione facile di reti di dati complesse

- ⚡ **Capacità di elaborazione parallela ultime**:
  - Lettura/scrittura veramente parallela con Isolate, utilizzo completo della CPU multi-core
  - Rete di calcolo multi-nodo cooperante per un'efficienza moltiplicata dei task multipli
  - Framework di elaborazione distribuita consapevole delle risorse, ottimizzazione automatica delle prestazioni
  - Interfaccia di query in streaming ottimizzata per elaborare set di dati massicci

- 🔑 **Diversi algoritmi di chiavi primarie distribuite**:
  - Algoritmo di incremento sequenziale - lunghezza del passo casuale liberamente regolabile
  - Algoritmo basato su timestamp - ideale per scenari di esecuzione parallela ad alte prestazioni
  - Algoritmo a prefisso di data - adatto per dati con indicazione di intervallo temporale
  - Algoritmo a codice breve - identificatori unici concisi

- 🔄 **Migrazione dello schema intelligente**:
  - Identificazione precisa dei comportamenti di rinominazione di tabelle/campi
  - Aggiornamento e migrazione automatica dei dati durante i cambiamenti di schema
  - Aggiornamenti senza tempi di inattività, senza impatto sulle operazioni aziendali
  - Strategie di migrazione sicure che prevengono la perdita di dati

- 🛡️ **Sicurezza a livello enterprise**:
  - Algoritmo di crittografia ChaCha20Poly1305 per proteggere i dati sensibili
  - Crittografia end-to-end, garantendo la sicurezza dei dati archiviati e trasmessi
  - Controllo dell'accesso ai dati a grana fine

- 🚀 **Cache intelligente e prestazioni di ricerca**:
  - Meccanismo di cache intelligente multilivello per un recupero efficiente dei dati
  - Cache di avvio che migliora drasticamente la velocità di lancio delle applicazioni
  - Motore di archiviazione profondamente integrato con la cache, nessun bisogno di codice di sincronizzazione aggiuntivo
  - Scaling adattivo, mantenimento di prestazioni stabili anche con la crescita dei dati

- 🔄 **Flussi di lavoro innovativi**:
  - Isolamento dei dati multi-spazio, supporto perfetto per scenari multi-tenant e multi-utente
  - Assegnazione intelligente del carico di lavoro tra i nodi di calcolo
  - Fornisce un database robusto per l'addestramento e l'analisi dei dati su larga scala
  - Archiviazione automatica dei dati, aggiornamenti e inserimenti intelligenti

- 💼 **L'esperienza dello sviluppatore è prioritaria**:
  - Documentazione bilingue dettagliata e commenti al codice (cinese e inglese)
  - Informazioni di debug ricche e metriche di prestazione
  - Capacità integrate di convalida dei dati e recupero dalla corruzione
  - Configurazione zero pronta all'uso, avvio rapido

## Avvio rapido

Utilizzo di base:

```dart
// Inizializzazione del database
final db = ToStore();
await db.initialize(); // Opzionale, assicura che l'inizializzazione del database sia completata prima delle operazioni

// Inserimento di dati
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// Aggiornamento di dati
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Eliminazione di dati
await db.delete('users').where('id', '!=', 1);

// Supporto per query a catena complesse
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Archiviazione automatica dei dati, aggiornamento se esiste, inserimento altrimenti
await db.upsert('users', {'name': 'John','email': 'john@example.com'})
  .where('email', '=', 'john@example.com');
// Oppure
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});

// Conteggio efficiente dei record
final count = await db.query('users').count();

// Elaborazione di dati massivi utilizzando query in streaming
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // Elabora ogni record secondo necessità, evitando la pressione di memoria
    print('Elaborazione utente: ${userData['username']}');
  });

// Impostare coppie chiave-valore globali
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Ottenere dati da coppie chiave-valore globali
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## Esempio di applicazione mobile

```dart
// Definizione della struttura della tabella adatta a scenari di avvio frequente come le applicazioni mobili, rilevamento preciso dei cambiamenti della struttura della tabella, aggiornamento e migrazione automatica dei dati
final db = ToStore(
  schemas: [
    const TableSchema(
      name: 'users', // Nome della tabella
      tableId: "users",  // Identificatore unico della tabella, opzionale, utilizzato per un'identificazione al 100% dei requisiti di rinominazione, anche senza può raggiungere un tasso di precisione superiore al 98%
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id', // Chiave primaria
      ),
      fields: [ // Definizione dei campi, non include la chiave primaria
        FieldSchema(name: 'username', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'email', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [ // Definizione degli indici
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// Passare allo spazio utente - isolamento dei dati
await db.switchSpace(spaceName: 'user_123');
```

## Esempio di server backend

```dart
await db.createTables([
      const TableSchema(
        name: 'users', // Nome della tabella
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id', // Chiave primaria
          type: PrimaryKeyType.timestampBased,  // Tipo di chiave primaria
        ),
        fields: [
          // Definizione dei campi, non include la chiave primaria
          FieldSchema(
              name: 'username',
              type: DataType.text,
              nullable: false,
              unique: true),
          FieldSchema(name: 'vector_data', type: DataType.blob),  // Archiviazione dei dati vettoriali
          // Altri campi...
        ],
        indexes: [
          // Definizione degli indici
          IndexSchema(fields: ['username']),
          IndexSchema(fields: ['email']),
        ],
      ),
      // Altre tabelle...
]);


// Aggiornamento della struttura della tabella
final taskId = await db.updateSchema('users')
    .renameTable('newTableName')  // Rinominare la tabella
    .modifyField('username',minLength: 5,maxLength: 20,unique: true)  // Modificare le proprietà del campo
    .renameField('oldName', 'newName')  // Rinominare il campo
    .removeField('fieldName')  // Rimuovere il campo
    .addField('name', type: DataType.text)  // Aggiungere un campo
    .removeIndex(fields: ['age'])  // Rimuovere un indice
    .setPrimaryKeyConfig(  // Impostare la configurazione della chiave primaria
      const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
    );
    
// Interrogare lo stato dell'attività di migrazione
final status = await db.queryMigrationTaskStatus(taskId);  
print('Progresso della migrazione: ${status?.progressPercentage}%');
```


## Architettura distribuita

```dart
// Configurazione dei nodi distribuiti
final db = ToStore(
    config: DataStoreConfig(
        distributedNodeConfig: const DistributedNodeConfig(
            clusterId: 1,  // Configurazione dell'appartenenza al cluster
            centralServerUrl: 'http://127.0.0.1:8080',
            accessToken: 'b7628a4f9b4d269b98649129'))
);

// Inserimento in batch di dati vettoriali
await db.batchInsert('vector', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Migliaia di record
]);

// Elaborazione in streaming di grandi set di dati per analisi
await for (final record in db.streamQuery('vector')
    .where('vector_name', '=', 'face_2366')
    .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
    .stream) {
  // L'interfaccia di streaming supporta l'estrazione e la trasformazione di feature su larga scala
  print(record);
}
```

## Esempi di chiavi primarie
Diversi algoritmi di chiavi primarie, tutti supportano la generazione distribuita, non è consigliabile generare da soli le chiavi primarie per evitare l'impatto delle chiavi primarie non ordinate sulle capacità di ricerca.
Chiave primaria sequenziale PrimaryKeyType.sequential: 238978991
Chiave primaria basata su timestamp PrimaryKeyType.timestampBased: 1306866018836946
Chiave primaria con prefisso di data PrimaryKeyType.datePrefixed: 20250530182215887631
Chiave primaria a codice breve PrimaryKeyType.shortCode: 9eXrF0qeXZ

```dart
// Chiave primaria sequenziale PrimaryKeyType.sequential
// Quando il sistema distribuito è abilitato, il server centrale alloca intervalli che i nodi generano autonomamente, compatti e facili da memorizzare, adatti per ID utente e numeri attraenti
await db.createTables([
      const TableSchema(
        name: 'users',
        primaryKeyConfig: PrimaryKeyConfig(
          type: PrimaryKeyType.sequential,  // Tipo di chiave primaria sequenziale
          sequentialConfig:  SequentialIdConfig(
              initialValue: 10000, // Valore iniziale di auto-incremento
              increment: 50,  // Passo di incremento
              useRandomIncrement: true,  // Uso di un passo casuale per evitare di rivelare il volume di affari
            ),
        ),
        // Definizione di campi e indici...
        fields: []
      ),
      // Altre tabelle...
 ]);
```


## Configurazione di sicurezza

```dart
// Rinominazione di tabelle e campi - riconoscimento automatico e conservazione dei dati
final db = ToStore(
      config: DataStoreConfig(
        enableEncoding: true, // Abilitare la codifica sicura per i dati della tabella
        encodingKey: 'YouEncodingKey', // Chiave di codifica, può essere regolata arbitrariamente
        encryptionKey: 'YouEncryptionKey', // Chiave di crittografia, nota: modificare questa chiave impedirà la decodifica dei vecchi dati
      ),
    );
```

## Test di prestazioni

Tostore 2.0 implementa una scalabilità lineare delle prestazioni, i cambiamenti fondamentali nell'elaborazione parallela, nei meccanismi di partizionamento e nell'architettura distribuita hanno migliorato significativamente le capacità di ricerca dei dati, offrendo tempi di risposta in millisecondi anche con una crescita massiccia dei dati. Per l'elaborazione di grandi set di dati, l'interfaccia di query in streaming può elaborare volumi massicci di dati senza esaurire le risorse di memoria.



## Piani futuri
Tostore sta sviluppando il supporto per vettori ad alta dimensione per adattarsi all'elaborazione di dati multimodali e alla ricerca semantica.


Il nostro obiettivo non è creare un database; Tostore è semplicemente un componente estratto dal framework Toway per la vostra considerazione. Se stai sviluppando applicazioni mobili, ti consigliamo di utilizzare il framework Toway con il suo ecosistema integrato, che copre la soluzione completa per lo sviluppo di applicazioni Flutter. Con Toway, non avrai bisogno di toccare il database sottostante, tutte le operazioni di query, caricamento, archiviazione, caching e visualizzazione dei dati saranno automaticamente gestite dal framework.
Per ulteriori informazioni sul framework Toway, visita il [repository Toway](https://github.com/tocreator/toway).

## Documentazione

Visita il nostro [Wiki](https://github.com/tocreator/tostore) per una documentazione dettagliata.

## Supporto e feedback

- Segnala problemi: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Partecipa alla discussione: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Contribuisci al codice: [Guida al contributo](CONTRIBUTING.md)

## Licenza

Questo progetto è sotto licenza MIT - vedi il file [LICENSE](LICENSE) per maggiori dettagli.

---

<p align="center">Se trovi Tostore utile, non esitare a darci una ⭐️</p>
