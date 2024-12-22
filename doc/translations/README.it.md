# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | Italiano | [Türkçe](README.tr.md)

ToStore è un motore di archiviazione ad alte prestazioni progettato specificamente per applicazioni mobili. Implementato interamente in Dart, raggiunge prestazioni eccezionali attraverso l'indicizzazione B+ tree e strategie di caching intelligenti. La sua architettura multi-spazio risolve le sfide dell'isolamento dei dati utente e della condivisione dei dati globali, mentre le funzionalità di livello enterprise come la protezione delle transazioni, la riparazione automatica, il backup incrementale e il costo zero in idle garantiscono un'archiviazione dati affidabile per le applicazioni mobili.

## Perché ToStore?

- 🚀 **Prestazioni Massime**: 
  - Indicizzazione B+ tree con ottimizzazione intelligente delle query
  - Strategia di caching intelligente con risposta in millisecondi
  - Lettura/scrittura concorrente non bloccante con prestazioni stabili
- 🎯 **Facile da Usare**: 
  - Design API fluido e concatenabile
  - Supporto per query stile SQL/Map
  - Inferenza di tipo intelligente con suggerimenti di codice completi
  - Zero configurazione, pronto all'uso
- 🔄 **Architettura Innovativa**: 
  - Isolamento dati multi-spazio, perfetto per scenari multi-utente
  - La condivisione dei dati globali risolve le sfide di sincronizzazione
  - Supporto per transazioni annidate
  - Caricamento dello spazio su richiesta minimizza l'uso delle risorse
- 🛡️ **Affidabilità Enterprise**: 
  - Protezione transazioni ACID garantisce la consistenza dei dati
  - Meccanismo di backup incrementale con recupero rapido
  - Validazione dell'integrità dei dati con riparazione automatica degli errori

## Avvio Rapido

Utilizzo base:

```dart
// Inizializzare il database
final db = ToStore(
  version: 1,
  onCreate: (db) async {
    // Creare tabella
    await db.createTable(
      'users',
      TableSchema(
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
    );
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