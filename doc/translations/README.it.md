# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | Italiano | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

ToStore è un motore di archiviazione ad alte prestazioni progettato specificamente per applicazioni mobili. Implementato in Dart puro, raggiunge prestazioni eccezionali attraverso l'indicizzazione B+ tree e strategie di cache intelligenti. La sua architettura multi-spazio risolve le sfide di isolamento dei dati utente e condivisione dei dati globali, mentre funzionalità di livello enterprise come protezione delle transazioni, riparazione automatica, backup incrementale e costo zero in inattività forniscono un'archiviazione dati affidabile per le applicazioni mobili.

## Perché ToStore?

- 🚀 **Prestazioni Massime**: 
  - Indicizzazione B+ tree con ottimizzazione intelligente delle query
  - Strategia di cache intelligente con risposta in millisecondi
  - Lettura/scrittura concorrente non bloccante con prestazioni stabili
- 🔄 **Evoluzione Intelligente degli Schema**: 
  - Aggiornamento automatico della struttura delle tabelle tramite schemi
  - Nessuna migrazione manuale versione per versione
  - API concatenabile per modifiche complesse
  - Aggiornamenti senza tempi di inattività
- 🎯 **Facile da Usare**: 
  - Design API concatenabile fluido
  - Supporto per query stile SQL/Map
  - Inferenza di tipo intelligente con suggerimenti di codice completi
  - Pronto all'uso senza configurazione complessa
- 🔄 **Architettura Innovativa**: 
  - Isolamento dati multi-spazio, perfetto per scenari multi-utente
  - Condivisione dati globali risolve le sfide di sincronizzazione
  - Supporto per transazioni annidate
  - Caricamento spazio su richiesta minimizza l'uso delle risorse
  - Operazioni automatiche sui dati (upsert)
- 🛡️ **Affidabilità Enterprise**: 
  - Protezione transazioni ACID garantisce la consistenza dei dati
  - Meccanismo di backup incrementale con recupero rapido
  - Verifica integrità dati con riparazione automatica

## Avvio Rapido

Utilizzo base:

```dart
// Inizializzare il database
final db = ToStore(
  version: 2, // ogni volta che il numero di versione viene incrementato, la struttura della tabella in schemas verrà automaticamente creata o aggiornata
  schemas: [
    // Definisci semplicemente il tuo schema più recente, ToStore gestisce l'aggiornamento automaticamente
    const TableSchema(
      name: 'users',
      primaryKey: 'id',
      fields: [
        FieldSchema(name: 'id', type: DataType.integer, nullable: false),
        FieldSchema(name: 'name', type: DataType.text, nullable: false),
        FieldSchema(name: 'age', type: DataType.integer),
      ],
      indexes: [
        IndexSchema(fields: ['name'], unique: true),
      ],
    ),
  ],
  // aggiornamenti e migrazioni complessi possono essere eseguiti usando db.updateSchema
  // se il numero di tabelle è piccolo, si consiglia di regolare direttamente la struttura in schemas per l'aggiornamento automatico
  onUpgrade: (db, oldVersion, newVersion) async {
    if (oldVersion == 1) {
      await db.updateSchema('users')
          .addField("fans", type: DataType.array, comment: "follower")
          .addIndex("follow", fields: ["follow", "name"])
          .dropField("last_login")
          .modifyField('email', unique: true)
          .renameField("last_login", "last_login_time");
    }
  },
);
await db.initialize(); // Opzionale, assicura che il database sia completamente inizializzato prima delle operazioni

// Inserire dati
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// Aggiornare dati
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Eliminare dati
await db.delete('users').where('id', '!=', 1);

// Query concatenata con condizioni complesse
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Contare record
final count = await db.query('users').count();

// Query stile SQL
final users = await db.queryBySql(
  'users',
  where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)',
  limit: 10
);

// Query stile Map
final users = await db.queryByMap(
  'users',
  where: {
    'age': {'>=': 30},
    'name': {'like': '%John%'},
  },
  orderBy: ['age'],
  limit: 10,
);

// Inserimento batch
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## Architettura Multi-spazio

L'architettura multi-spazio di ToStore rende semplice la gestione dei dati multi-utente:

```dart
// Passare allo spazio utente
await db.switchBaseSpace(spaceName: 'user_123');

// Query dati utente
final followers = await db.query('followers');

// Impostare o aggiornare dati chiave-valore, isGlobal: true significa dati globali
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Ottenere dati chiave-valore globali
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

# Upsert data

```dart
// Memorizza automaticamente i dati, supporto batch upsert
await db.upsert('users', {'name': 'John'})
  .where('email', '=', 'john@example.com');

// Inserimento automatico o aggiornamento basato sulla chiave primaria
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});
```


## Prestazioni

In scenari ad alta concorrenza inclusi scritture batch, letture/scritture casuali e query condizionali, ToStore dimostra prestazioni eccezionali, superando ampiamente altri database principali disponibili per Dart/Flutter.

## Più Funzionalità

- 💫 API concatenabile elegante
- 🎯 Inferenza di tipo intelligente
- 📝 Suggerimenti di codice completi
- 🔐 Backup incrementale automatico
- 🛡️ Validazione integrità dati
- 🔄 Recupero automatico da crash
- 📦 Compressione dati intelligente
- 📊 Ottimizzazione automatica degli indici
- 💾 Strategia di caching multilivello

Il nostro obiettivo non è semplicemente creare un altro database. ToStore è estratto dal framework Toway per fornire una soluzione alternativa. Se stai sviluppando applicazioni mobili, raccomandiamo di utilizzare il framework Toway, che offre un ecosistema completo di sviluppo Flutter. Con Toway, non dovrai gestire direttamente il database sottostante - le richieste dati, il caricamento, l'archiviazione, il caching e la visualizzazione sono tutti gestiti automaticamente dal framework.
Per maggiori informazioni sul framework Toway, visita il [Repository Toway](https://github.com/tocreator/toway)

## Documentazione

Visita la nostra [Wiki](https://github.com/tocreator/tostore) per documentazione dettagliata.

## Supporto & Feedback

- Invia Issues: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Unisciti alle Discussioni: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Contribuisci: [Guida alla Contribuzione](CONTRIBUTING.md)

## Licenza

Questo progetto è sotto licenza MIT - vedi il file [LICENSE](LICENSE) per i dettagli.

---

<p align="center">Se trovi ToStore utile, dacci una ⭐️</p> 