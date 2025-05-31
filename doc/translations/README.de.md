# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | Deutsch | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

Tostore ist eine plattformübergreifende Datenbank-Engine mit verteilter Architektur, die tief in Ihr Projekt integriert ist. Das von neuronalen Netzwerken inspirierte Datenverarbeitungsmodell implementiert eine gehirnähnliche Datenverarbeitung. Mehrfachpartitions-Parallelisierungsmechanismen und die Topologie miteinander verbundener Knoten schaffen ein intelligentes Datennetzwerk, während die parallele Verarbeitung mit Isolates die Fähigkeiten von Mehrkernprozessoren voll ausnutzt. Mit verschiedenen Algorithmen für verteilte Primärschlüssel und unbegrenzter Knotenerweiterung kann es als Datenschicht für verteilte Recheninfrastrukturen und großangelegtes Datentraining dienen und ermöglicht einen nahtlosen Datenfluss von Edge-Geräten bis zu Cloud-Servern. Funktionen wie die präzise Erkennung von Schemaänderungen, intelligente Migration, ChaCha20Poly1305-Verschlüsselung und eine Multi-Space-Architektur unterstützen perfekt verschiedene Anwendungsszenarien, von mobilen Apps bis hin zu serverseitigen Systemen.

## Warum Tostore wählen?

### 1. Partitionsparallelität vs. Einzeldateispeicherung
| Tostore | Traditionelle Datenbanken |
|:---------|:-----------|
| ✅ Intelligenter Partitionierungsmechanismus, Daten verteilt auf mehrere Dateien angemessener Größe | ❌ Speicherung in einer einzigen Datendatei, lineare Leistungsverschlechterung mit wachsenden Daten |
| ✅ Liest nur relevante Partitionsdateien, Abfrageleistung ist entkoppelt vom Gesamtdatenvolumen | ❌ Muss die gesamte Datendatei laden, selbst für die Abfrage eines einzelnen Datensatzes |
| ✅ Behält Antwortzeiten im Millisekundenbereich auch bei TB-Datenmengen bei | ❌ Signifikante Erhöhung der Lese-/Schreiblatenz auf mobilen Geräten, wenn Daten 5MB überschreiten |
| ✅ Ressourcenverbrauch proportional zur Menge der abgefragten Daten, nicht zum Gesamtdatenvolumen | ❌ Ressourcenbeschränkte Geräte anfällig für Speicherdruck und OOM-Fehler |
| ✅ Isolate-Technologie ermöglicht echte Mehrkern-Parallelverarbeitung | ❌ Eine einzelne Datei kann nicht parallel verarbeitet werden, Verschwendung von CPU-Ressourcen |

### 2. Dart-Parallelität vs. traditionelle Skriptsprachen
| Tostore | Traditionelle skriptbasierte Datenbanken |
|:---------|:-----------|
| ✅ Isolates führen echte Parallelausführung ohne globale Sperrbeschränkungen aus | ❌ Sprachen wie Python werden durch GIL eingeschränkt, ineffizient für CPU-intensive Aufgaben |
| ✅ AOT-Kompilierung erzeugt effizienten Maschinencode, nahezu native Leistung | ❌ Leistungsverlust bei der Datenverarbeitung durch interpretierte Ausführung |
| ✅ Unabhängiges Speicher-Heap-Modell, vermeidet Lock- und Speicherkonflikte | ❌ Shared-Memory-Modell erfordert komplexe Sperrmechanismen bei hoher Nebenläufigkeit |
| ✅ Typsicherheit bietet Leistungsoptimierungen und Fehlerprüfung zur Kompilierungszeit | ❌ Dynamische Typisierung entdeckt Fehler zur Laufzeit mit weniger Optimierungsmöglichkeiten |
| ✅ Tiefe Integration mit dem Flutter-Ökosystem | ❌ Erfordert zusätzliche ORM-Schichten und UI-Adapter, erhöht die Komplexität |

### 3. Eingebettete Integration vs. unabhängige Datenspeicher
| Tostore | Traditionelle Datenbanken |
|:---------|:-----------|
| ✅ Verwendet Dart-Sprache, nahtlose Integration mit Flutter/Dart-Projekten | ❌ Erfordert das Erlernen von SQL oder spezifischen Abfragesprachen, erhöht die Lernkurve |
| ✅ Derselbe Code unterstützt Frontend und Backend, kein Technologie-Stack-Wechsel nötig | ❌ Frontend und Backend benötigen typischerweise unterschiedliche Datenbanken und Zugriffsmethoden |
| ✅ Verkettete API-Stile passen zu modernen Programmierstilen, hervorragende Entwicklererfahrung | ❌ SQL-String-Verkettung ist anfällig für Angriffe und Fehler, mangelnde Typsicherheit |
| ✅ Unterstützung für reaktive Programmierung, natürliche Verbindung mit UI-Frameworks | ❌ Erfordert zusätzliche Adaptionsschichten zur Verbindung von UI und Datenschicht |
| ✅ Keine komplexe ORM-Mapping-Konfiguration erforderlich, direkte Verwendung von Dart-Objekten | ❌ Komplexität des objekt-relationalen Mappings, hohe Entwicklungs- und Wartungskosten |

### 4. Präzise Schemaänderungserkennung vs. manuelle Migrationsverwaltung
| Tostore | Traditionelle Datenbanken |
|:---------|:-----------|
| ✅ Erkennt Schemaänderungen automatisch, keine Versionsnummernverwaltung erforderlich | ❌ Abhängigkeit von manueller Versionskontrolle und explizitem Migrationscode |
| ✅ Millisekunden-Erkennung von Tabellen-/Feldänderungen und automatische Datenmigration | ❌ Muss Migrationslogik für Upgrades zwischen Versionen pflegen |
| ✅ Erkennt Tabellen-/Feldumbenennungen präzise, behält alle historischen Daten bei | ❌ Tabellen-/Feldumbenennungen können zu Datenverlust führen |
| ✅ Atomare Migrationsoperationen gewährleisten Datenkonsistenz | ❌ Migrationsunterbrechungen können zu Dateninkonsistenzen führen |
| ✅ Vollautomatisierte Schemaaktualisierungen ohne manuelle Eingriffe | ❌ Komplexe Upgrade-Logik und hohe Wartungskosten mit zunehmender Versionszahl |







## Technische Highlights

- 🌐 **Nahtlose plattformübergreifende Unterstützung**:
  - Konsistente Erfahrung über Web, Linux, Windows, Mobile, Mac Plattformen
  - Einheitliche API-Schnittstelle, problemlose plattformübergreifende Datensynchronisation
  - Automatische Anpassung an verschiedene plattformübergreifende Speicher-Backends (IndexedDB, Dateisysteme usw.)
  - Nahtloser Datenfluss von Edge-Computing bis zur Cloud

- 🧠 **Neuronale Netzwerk-inspirierte verteilte Architektur**:
  - Neuronale netzwerkähnliche Topologie miteinander verbundener Knoten
  - Effizienter Datenpartitionierungsmechanismus für verteilte Verarbeitung
  - Intelligente dynamische Workload-Balancierung
  - Unterstützung für unbegrenzte Knotenerweiterung, einfacher Aufbau komplexer Datennetzwerke

- ⚡ **Ultimative Parallelverarbeitungsfähigkeiten**:
  - Echt paralleles Lesen/Schreiben mit Isolates, volle CPU-Mehrkernnutzung
  - Mehrknoten-Rechennetzwerk arbeitet kooperativ, Multitasking-Effizienz multipliziert
  - Ressourcenbewusstes verteiltes Verarbeitungs-Framework, automatische Leistungsoptimierung
  - Streaming-Abfrageschnittstelle optimiert für die Verarbeitung großer Datensätze

- 🔑 **Vielfältige verteilte Primärschlüsselalgorithmen**:
  - Sequentieller Inkrementalgorithmus - frei einstellbare zufällige Schrittlänge
  - Zeitstempelbasierter Algorithmus - ideal für Hochleistungs-Parallelausführungsszenarien
  - Datenpräfix-Algorithmus - geeignet für Daten mit Zeitbereichsindikation
  - Kurzcode-Algorithmus - prägnante eindeutige Kennungen

- 🔄 **Intelligente Schemamigration**:
  - Präzise Identifikation von Tabellen-/Feldumbenennungsverhalten
  - Automatische Aktualisierung und Datenmigration bei Schemaänderungen
  - Zero-Downtime-Upgrades, keine Auswirkungen auf Geschäftsoperationen
  - Sichere Migrationsstrategien, die Datenverlust verhindern

- 🛡️ **Unternehmenssicherheit**:
  - ChaCha20Poly1305-Verschlüsselungsalgorithmus zum Schutz sensibler Daten
  - Ende-zu-Ende-Verschlüsselung, Sicherheit gespeicherter und übertragener Daten gewährleistet
  - Feingranulare Datenzugriffskontrolle

- 🚀 **Intelligentes Caching und Suchleistung**:
  - Mehrstufiger intelligenter Caching-Mechanismus für effiziente Datenabfrage
  - Startup-Caching verbessert App-Startgeschwindigkeit dramatisch
  - Speicher-Engine tief mit Cache integriert, kein zusätzlicher Synchronisierungscode erforderlich
  - Adaptive Skalierung, stabile Leistung auch bei wachsenden Daten

- 🔄 **Innovative Workflows**:
  - Multi-Space-Datenisolierung, perfekte Unterstützung für Multi-Tenant-, Multi-User-Szenarien
  - Intelligente Workload-Zuweisung zwischen Rechenknoten
  - Robuste Datengrundlage für großangelegtes Datentraining und -analyse
  - Automatische Datenspeicherung, intelligente Updates und Einfügungen

- 💼 **Entwicklererfahrung hat Priorität**:
  - Detaillierte zweisprachige Dokumentation und Codekommentare (Chinesisch und Englisch)
  - Umfangreiche Debug-Informationen und Leistungsmetriken
  - Integrierte Datenvalidierung und Korruptionswiederherstellungsfunktionen
  - Zero-Konfiguration Out-of-the-Box, schneller Einstieg

## Schnellstart

Grundlegende Verwendung:

```dart
// Datenbank initialisieren
final db = ToStore();
await db.initialize(); // Optional, stellt sicher, dass die Datenbankinitialisierung abgeschlossen ist, bevor Operationen ausgeführt werden

// Daten einfügen
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// Daten aktualisieren
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Daten löschen
await db.delete('users').where('id', '!=', 1);

// Unterstützung für komplexe verkettete Abfragen
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Automatische Datenspeicherung, aktualisiert wenn vorhanden, fügt ein wenn nicht
await db.upsert('users', {'name': 'John','email': 'john@example.com'})
  .where('email', '=', 'john@example.com');
// Oder
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});

// Effiziente Datensatzzählung
final count = await db.query('users').count();

// Verarbeitung großer Datenmengen mit Streaming-Abfragen
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // Verarbeite jeden Datensatz nach Bedarf, vermeidet Speicherdruck
    print('Verarbeite Benutzer: ${userData['username']}');
  });

// Globale Schlüssel-Wert-Paare setzen
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Globale Schlüssel-Wert-Paar-Daten abrufen
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## Mobile App-Beispiel

```dart
// Tabellendefinition für häufig startende Szenarien wie mobile Apps, präzise Erkennung von Tabellenstrukturänderungen, automatisches Upgrade und Datenmigration
final db = ToStore(
  schemas: [
    const TableSchema(
      name: 'users', // Tabellenname
      tableId: "users",  // Eindeutige Tabellenkennung, optional, für 100% Erkennungsrate bei Umbenennungen, auch ohne kann >98% Genauigkeit erreicht werden
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id', // Primärschlüssel
      ),
      fields: [ // Felddefinitionen, ohne Primärschlüssel
        FieldSchema(name: 'username', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'email', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [ // Indexdefinitionen
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// Umschalten auf Benutzerraum - Datenisolierung
await db.switchSpace(spaceName: 'user_123');
```

## Backend-Server-Beispiel

```dart
await db.createTables([
      const TableSchema(
        name: 'users', // Tabellenname
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id', // Primärschlüssel
          type: PrimaryKeyType.timestampBased,  // Primärschlüsseltyp
        ),
        fields: [
          // Felddefinitionen, ohne Primärschlüssel
          FieldSchema(
              name: 'username',
              type: DataType.text,
              nullable: false,
              unique: true),
          FieldSchema(name: 'vector_data', type: DataType.blob),  // Vektordaten speichern
          // Weitere Felder ...
        ],
        indexes: [
          // Indexdefinitionen
          IndexSchema(fields: ['username']),
          IndexSchema(fields: ['email']),
        ],
      ),
      // Weitere Tabellen ...
]);


// Tabellenstruktur aktualisieren
final taskId = await db.updateSchema('users')
    .renameTable('newTableName')  // Tabellenname ändern
    .modifyField('username',minLength: 5,maxLength: 20,unique: true)  // Feldeigenschaften ändern
    .renameField('oldName', 'newName')  // Feldname ändern
    .removeField('fieldName')  // Feld entfernen
    .addField('name', type: DataType.text)  // Feld hinzufügen
    .removeIndex(fields: ['age'])  // Index entfernen
    .setPrimaryKeyConfig(  // Primärschlüsselkonfiguration setzen
      const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
    );
    
// Migrationsstatus abfragen
final status = await db.queryMigrationTaskStatus(taskId);  
print('Migrationsfortschritt: ${status?.progressPercentage}%');
```


## Verteilte Architektur

```dart
// Verteilte Knoten konfigurieren
final db = ToStore(
    config: DataStoreConfig(
        distributedNodeConfig: const DistributedNodeConfig(
            clusterId: 1,  // Clusterzugehörigkeit konfigurieren
            centralServerUrl: 'http://127.0.0.1:8080',
            accessToken: 'b7628a4f9b4d269b98649129'))
);

// Stapelweises Einfügen von Vektordaten
await db.batchInsert('vector', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Tausende von Datensätzen
]);

// Streaming-Verarbeitung großer Datensätze für Analysen
await for (final record in db.streamQuery('vector')
    .where('vector_name', '=', 'face_2366')
    .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
    .stream) {
  // Streaming-Schnittstelle unterstützt großangelegte Merkmalextraktion und -transformation
  print(record);
}
```

## Primärschlüsselbeispiele
Verschiedene Primärschlüsselalgorithmen, alle unterstützen verteilte Generierung, eigene Primärschlüsselgenerierung wird nicht empfohlen, um negative Auswirkungen ungeordneter Primärschlüssel auf die Suchfähigkeit zu vermeiden.
Sequentieller Primärschlüssel PrimaryKeyType.sequential: 238978991
Zeitstempelbasierter Primärschlüssel PrimaryKeyType.timestampBased: 1306866018836946
Datenpräfix-Primärschlüssel PrimaryKeyType.datePrefixed: 20250530182215887631
Kurzcode-Primärschlüssel PrimaryKeyType.shortCode: 9eXrF0qeXZ

```dart
// Sequentieller Primärschlüssel PrimaryKeyType.sequential
// Bei aktivierter verteilter Nutzung weist der zentrale Server Bereiche zu, die Knoten selbständig generieren, kompakt und leicht zu merken, geeignet für Benutzer-IDs und schöne Nummern
await db.createTables([
      const TableSchema(
        name: 'users',
        primaryKeyConfig: PrimaryKeyConfig(
          type: PrimaryKeyType.sequential,  // Sequentieller Primärschlüsseltyp
          sequentialConfig:  SequentialIdConfig(
              initialValue: 10000, // Startwert für Autoinkrement
              increment: 50,  // Inkrementschritt
              useRandomIncrement: true,  // Zufällige Schrittlänge verwenden, um Geschäftsvolumen zu verbergen
            ),
        ),
        // Feld- und Indexdefinitionen ...
        fields: []
      ),
      // Weitere Tabellen ...
 ]);
```


## Sicherheitskonfiguration

```dart
// Tabellen und Felder umbenennen - automatische Erkennung und Datenbeibehaltung
final db = ToStore(
      config: DataStoreConfig(
        enableEncoding: true, // Sichere Codierung für Tabellendaten aktivieren
        encodingKey: 'YouEncodingKey', // Codierungsschlüssel, kann beliebig angepasst werden
        encryptionKey: 'YouEncryptionKey', // Verschlüsselungsschlüssel, Hinweis: Änderung verhindert Decodierung alter Daten
      ),
    );
```

## Leistungstests

Tostore 2.0 implementiert lineare Skalierbarkeit, grundlegende Änderungen in Parallelverarbeitung, Partitionierungsmechanismen und verteilter Architektur haben die Datenabfragefähigkeiten erheblich verbessert und ermöglichen millisekunden-schnelle Antwortzeiten selbst bei massivem Datenwachstum. Für die Verarbeitung großer Datensätze kann die Streaming-Abfrageschnittstelle massive Datenmengen verarbeiten, ohne Speicherressourcen zu erschöpfen.



## Zukunftspläne
Tostore entwickelt Unterstützung für hochdimensionale Vektoren, um multimodale Datenverarbeitung und semantische Suche zu ermöglichen.


Unser Ziel ist nicht, eine Datenbank zu erstellen; Tostore ist lediglich eine Komponente, die aus dem Toway-Framework für Ihre Betrachtung extrahiert wurde. Wenn Sie mobile Anwendungen entwickeln, empfehlen wir die Verwendung des Toway-Frameworks mit seinem integrierten Ökosystem, das eine Full-Stack-Lösung für Flutter-Anwendungsentwicklung bietet. Mit Toway müssen Sie nicht direkt mit der Datenbank interagieren, alle Operationen für Abfrage, Laden, Speichern, Caching und Anzeigen von Daten werden automatisch vom Framework übernommen.
Weitere Informationen zum Toway-Framework finden Sie im [Toway-Repository](https://github.com/tocreator/toway).

## Dokumentation

Besuchen Sie unser [Wiki](https://github.com/tocreator/tostore) für detaillierte Dokumentation.

## Support und Feedback

- Issues einreichen: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- An Diskussionen teilnehmen: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Code beitragen: [Contributing Guide](CONTRIBUTING.md)

## Lizenz

Dieses Projekt ist unter der MIT-Lizenz lizenziert - siehe [LICENSE](LICENSE) Datei für Details.

---

<p align="center">Wenn Sie Tostore hilfreich finden, geben Sie uns bitte einen ⭐️</p>
