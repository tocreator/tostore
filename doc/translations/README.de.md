# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | Deutsch | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

ToStore ist eine hochleistungsfähige Speicher-Engine, die speziell für mobile Anwendungen entwickelt wurde. Vollständig in Dart implementiert, erreicht sie außergewöhnliche Leistung durch B+ Tree-Indexierung und intelligente Caching-Strategien. Ihre Multi-Space-Architektur löst die Herausforderungen der Benutzerdatenisolierung und des globalen Datenaustausches, während Enterprise-Grade-Funktionen wie Transaktionsschutz, automatische Reparatur, inkrementelles Backup und Null-Kosten im Leerlauf zuverlässige Datenspeicherung für mobile Anwendungen gewährleisten.

## Warum ToStore?

- 🚀 **Maximale Leistung**: 
  - B+ Tree-Indexierung mit intelligenter Abfrageoptimierung
  - Intelligente Caching-Strategie mit Millisekunden-Antwortzeit
  - Nicht-blockierendes gleichzeitiges Lesen/Schreiben mit stabiler Leistung
- 🎯 **Einfach zu verwenden**: 
  - Flüssiges verkettbares API-Design
  - Unterstützung für SQL/Map-Style Abfragen
  - Intelligente Typinferenz mit vollständigen Code-Hinweisen
  - Keine Konfiguration, sofort einsatzbereit
- 🔄 **Innovative Architektur**: 
  - Multi-Space-Datenisolierung, perfekt für Multi-User-Szenarien
  - Globale Datenaustausch löst Synchronisierungsherausforderungen
  - Unterstützung für verschachtelte Transaktionen
  - Bedarfsgerechtes Space-Loading minimiert Ressourcenverbrauch
  - Automatische Datenspeicherung, intelligentes Update/Insert
- 🛡️ **Enterprise-Grade Zuverlässigkeit**: 
  - ACID-Transaktionsschutz gewährleistet Datenkonsistenz
  - Inkrementeller Backup-Mechanismus mit schneller Wiederherstellung
  - Datenintegritätsprüfung mit automatischer Fehlerkorrektur

## Schnellstart

Grundlegende Verwendung:

```dart
// Datenbank initialisieren
final db = ToStore(
  version: 1,
  onCreate: (db) async {
    // Tabelle erstellen
    await db.createTable(
      'users',
      TableSchema(
        primaryKey: 'id',
        fields: [
          FieldSchema(name: 'id', type: DataType.integer, nullable: false),
          FieldSchema(name: 'name', type: DataType.text, nullable: false),
          FieldSchema(name: 'age', type: DataType.integer),
          FieldSchema(name: 'tags', type: DataType.array),
        ],
        indexes: [
          IndexSchema(fields: ['name'], unique: true),
        ],
      ),
    );
  },
);
await db.initialize(); // Optional, stellt sicher, dass die Datenbank vor Operationen vollständig initialisiert ist

// Daten einfügen
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// Daten aktualisieren
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Daten löschen
await db.delete('users').where('id', '!=', 1);

// Verkettete Abfrage mit komplexen Bedingungen
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Datensätze zählen
final count = await db.query('users').count();

// SQL-Style Abfrage
final users = await db.queryBySql(
  'users',
  where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)',
  limit: 10
);

// Map-Style Abfrage
final users = await db.queryByMap(
  'users',
  where: {
    'age': {'>=': 30},
    'name': {'like': '%John%'},
  },
  orderBy: ['age'],
  limit: 10,
);

// Batch-Einfügung
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## Multi-Space-Architektur

Die Multi-Space-Architektur von ToStore macht die Verwaltung von Multi-User-Daten einfach:

```dart
// Zum Benutzer-Space wechseln
await db.switchBaseSpace(spaceName: 'user_123');

// Benutzerdaten abfragen
final followers = await db.query('followers');

// Schlüssel-Wert-Daten setzen oder aktualisieren, isGlobal: true bedeutet globale Daten
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Globale Schlüssel-Wert-Daten abrufen
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## Upsert Daten

```dart
// Daten automatisch speichern,Batch upsert unterstützen
await db.upsert('users', {'name': 'John'})
  .where('email', '=', 'john@example.com');

// Automatisches Einfügen oder Aktualisieren basierend auf Primärschlüssel
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});
```


## Leistung

In Hochlast-Szenarien einschließlich Batch-Schreibvorgängen, zufälligen Lese-/Schreibvorgängen und bedingten Abfragen zeigt ToStore außergewöhnliche Leistung und übertrifft andere führende Datenbanken für Dart/Flutter bei weitem.

## Weitere Funktionen

- 💫 Elegante verkettbare API
- 🎯 Intelligente Typinferenz
- 📝 Vollständige Code-Hinweise
- 🔐 Automatisches inkrementelles Backup
- 🛡️ Datenintegritätsprüfung
- 🔄 Automatische Wiederherstellung nach Abstürzen
- 📦 Intelligente Datenkomprimierung
- 📊 Automatische Index-Optimierung
- 💾 Mehrstufige Caching-Strategie

Unser Ziel ist es nicht, einfach nur eine weitere Datenbank zu erstellen. ToStore wurde aus dem Toway-Framework extrahiert, um eine alternative Lösung anzubieten. Wenn Sie mobile Anwendungen entwickeln, empfehlen wir die Verwendung des Toway-Frameworks, das ein komplettes Flutter-Entwicklungsökosystem bietet. Mit Toway müssen Sie sich nicht direkt mit der zugrunde liegenden Datenbank befassen - Datenanfragen, Laden, Speichern, Caching und Anzeige werden automatisch vom Framework verarbeitet.
Weitere Informationen zum Toway-Framework finden Sie im [Toway-Repository](https://github.com/tocreator/toway)

## Dokumentation

Besuchen Sie unser [Wiki](https://github.com/tocreator/tostore) für detaillierte Dokumentation.

## Support & Feedback

- Issues einreichen: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- An Diskussionen teilnehmen: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Beitragen: [Contribution Guide](CONTRIBUTING.md)

## Lizenz

Dieses Projekt ist unter der MIT-Lizenz lizenziert - siehe die [LICENSE](LICENSE)-Datei für Details.

---

<p align="center">Wenn Sie ToStore nützlich finden, geben Sie uns bitte einen ⭐️</p> 