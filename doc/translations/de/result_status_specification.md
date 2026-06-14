# ToStore ResultStatus Automatisierte Diagnose & Statusauflösung Spezifikation

Um automatisierten Betriebsabläufen (Ops), AI-Agenten, automatisierten Testskripten und Client-Anwendungen eine präzise Identifizierung verschiedener Datenbankausführungsergebnisse und Ausnahmezustände zu ermöglichen, führt ToStore in seiner neuesten Version ein strukturiertes `ResultStatus`-System ein.

Dieses Spezifikationsdokument beschreibt im Detail die Entwurfsprinzipien von Statuscodes, die Spezifikationen semantischer Bezeichner-Keys und die dedizierten Feldstrukturen verschiedener Statustypen, um Datenbankbenutzern und Entwicklern bei der unabhängigen Implementierung der Statusauflösung zu helfen.

---

## 1. Kern-Entwurfsprinzipien

### 1.1 Numerische Statuscode-Spezifikation (code)

Alle numerischen Statuscodes (`code`) sind mit einer festen Länge von 5 Ziffern definiert (außer für den Erfolgsstatus):

- **Erfolgsstatus (Spezieller Erfolgscode)**: Speziell auf `0` fixiert.
- **Andere Zustände (Fehler- & Diagnosecodes)**: Einheitlich auf 5 Ziffern festgelegt.
- **Klassencode**: Die ersten beiden Ziffern des Statuscodes, die zur schnellen Identifizierung der Hauptkategorie dienen.
- **Blattcode**: Die letzten drei Ziffern des Statuscodes, die das spezifische Fehlerszenario darstellen.

> [!TIP]
> Bei der Entwicklung von automatisierten Ops, AI-Agenten oder externen Testskripten können Entwickler mithilfe der ersten beiden Ziffern (Klassencode) oder des Bereichs zu entsprechenden Ausnahmebehandlern routen und dann eine feingranulare Behandlung basierend auf dem Blattcode durchführen.

> [!IMPORTANT]
> **Best Practice für die In-Memory-Prüfung**:
> Beim Lesen von Datenbankoperationsergebnissen im Arbeitsspeicher (z. B. im Client- oder Dart/Flutter-Code) **ist die am meisten empfohlene und effizienteste Methode die direkte Verwendung der integrierten schreibgeschützten Eigenschaften (Getter)** von `ResultStatus` oder `ResultType` (wie `isBusinessError`, `isCriticalError` usw., siehe [Abschnitt 3.2](#32-in-memory-hilfs-getter)), wodurch das manuelle Parsen von numerischen Bereichen oder String-Präfix-Abgleichen vermieden wird.

### 1.2 Semantische Statusbezeichner-Spezifikation (codeKey)

Jeder Status entspricht einem eindeutigen String-Bezeichner `codeKey`:

- **Namensformat**: `[Hauptkategorie_Präfix]_[Mehrstufiger_Detailbezeichner]`.
- **Namensregel**: Besteht aus englischen Großbuchstaben und Unterstrichen `_`, enthält keine Leerzeichen oder Sonderzeichen.
- **Hauptkategorie_Präfix**: Gibt an, zu welcher Kerngeschäftskategorie der Zustand gehört. Wenn mehrere Kategorieebenen vorhanden sind, wird das allgemeinste Präfix ganz nach vorne gestellt, um die Präfixsuche und Bereichsfilterung zu erleichtern.

---

## 2. Schnellreferenztabelle der Klassencodes

Nachfolgend ist die Zuordnungsdefinition aller Klassencodes in ToStore aufgeführt:

| Codebereich | Klassencode (Erste 2 Ziffern) | Semantisches Präfix | Kategorie | Ausnahme-Strategie |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `00` | `SUCCESS` | **Operation erfolgreich** | Löst keine Ausnahme aus, kehrt normal zurück. |
| `10000 - 19999` | `10 - 19` | `BIZ_` | **Geschäftsfehler** (Endbenutzer-Eingabefehler, z. B. Constraint-Verletzungen) | Löst keine Ausnahme aus, wird immer über `DbResult` oder `QueryResult` zurückgegeben. |
| `20000 - 49999` | `20 - 49` | `DEV_` | **Entwicklerfehler** (Ungültige API-Parameter, ungültige Tabellenschemakonfiguration usw.) | **Löst in Debug-Umgebungen direkt eine `DbException` aus**, um Entwickler zu warnen; **kehrt in Produktionsumgebungen normal als Ergebnis zurück**. *(Hinweis: Inkompatibilität der Engine-Version und schwerwiegende Fehler bei der Ausführung von Migrations-Batches sind kritische Fehler, die auch in der Produktion Ausnahmen auslösen)* |
| `50000 - 79999` | `50 - 79` | `SYS_` | **Systemfehler** (Festplatte voll, IO-Ausnahmen, Timeout beim Sperrenerwerb usw.) | Löst eine Ausnahme aus, wenn die normale Ausführung blockiert ist; andere (z. B. Transaktionskonflikte) werden als Ergebnis zurückgegeben. |
| `99000 - 99999` | `99` | `ENG_` | **Engine-Fehler** (Engine-Logikfehler, Beschädigung der Datendatei, unbekannter interner Fehler) | Löst im Allgemeinen keine Ausnahmen aus; wirft Ausnahmen bei schweren Fällen. |

---

## 3. Gemeinsame Felder von ResultStatus und In-Memory-Hilfen

### 3.1 Gemeinsame Felder (Serialisierte JSON-Struktur)

Alle Arten von `ResultStatus` enthalten bei der Serialisierung in JSON die folgenden 4 grundlegenden gemeinsamen Felder. Benutzer können diese Felder für vorläufige Prüfungen direkt auslesen.

| Feld | Typ | Beschreibung |
| :--- | :--- | :--- |
| `index` | `int` | Sequenzindex bei Batch-Operationen. Bei Einzeloperationen ist dieser fest auf `0` eingestellt. |
| `code` | `int` | Numerischer Statuscode (`0` für Erfolg, 5-stellige Nummer für Ausnahmen). |
| `codeKey` | `String` | Semantischer Statusbezeichner-Key, z. B. `CONSTRAINT_VIOLATION_UNIQUE`. |
| `message` | `String` | Für Menschen lesbare Beschreibung der Statusdetails. |

### 3.2 In-Memory-Hilfs-Getter

In Dart/Flutter kapseln `ResultStatus` und `ResultType` hocheffiziente `O(1)` schreibgeschützte Eigenschaften (Getter) zur Überprüfung von Kategorie und Schweregrad im Arbeitsspeicher ohne manuelle Bereichsprüfungen oder String-Abgleiche:

| Eigenschaft | Typ | Beschreibung |
| :--- | :--- | :--- |
| `isBusinessError` | `bool` | Gibt an, ob es sich um einen **Geschäftsfehler** handelt (z. B. Constraint-Konflikt, Cast-Fehler; Bereich `10000 - 19999`). |
| `isDeveloperError` | `bool` | Gibt an, ob es sich um einen **Entwicklerfehler** handelt (z. B. ungültiges Schema, Parameter-Mismatch, Tabelle nicht gefunden; Bereich `20000 - 49999`). |
| `isSystemError` | `bool` | Gibt an, ob es sich um einen **Systemfehler** handelt (z. B. Timeout beim Sperrenerwerb, Festplatte voll, Dateisperre; Bereich `50000 - 79999`). |
| `isEngineError` | `bool` | Gibt an, ob es sich um einen **Engine-Fehler** handelt (Bereich `99000 - 99999`). |
| `isCriticalError` | `bool` | Gibt an, ob es sich um einen **kritischen Fehler / ein katastrophales Ereignis** handelt (erfordert manuelles oder betriebliches Eingreifen, z. B. Festplatte voll, unzureichender Arbeitsspeicher, schwerwiegende Beschädigung der Datendatei, inkompatibler Migrationsfehler usw.). |

---

## 4. Detaillierte Auflösungsstrukturen und dedizierte Felder

Abhängig vom Bereich von `code` / `codeKey` und der spezifischen Unterklasse von `ResultStatus` enthält die serialisierte JSON-Struktur unterschiedliche **dedizierte Diagnosefelder**. Nachfolgend finden Sie die Feldspezifikationen und das Anwendungs-Mapping für die 5 Status-Unterklassen.

### 4.1 SuccessStatus (Operation erfolgreich)

- **Kategoriebereich**: `code == 0`, `codeKey == "SUCCESS"`
- **Anwendbares Szenario**: Datensätze erfolgreich eingefügt, geändert oder gelöbt.
- **Dedizierte Felddefinition**:

  | Feld | Typ | Details |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Optional**. Wird nur bei Schreibvorgängen in eine einzelne Zeile (z. B. `insert`) oder Updates (z. B. `update`) zurückgegeben und stellt den physisch erzeugten oder geänderten Datensatz-Primärschlüssel dar. |

- **JSON-Beispiel**:
  ```json
  {
    "index": 0,
    "code": 0,
    "codeKey": "SUCCESS",
    "message": "Operation successful",
    "primaryKey": "usr_9a8f4c2b"
  }
  ```

---

### 4.2 ConstraintStatus (Datenintegrität & Constraint-Konflikte)

- **Kategoriebereich**: `code` innerhalb von `[10000, 19999]` (hauptsächlich Validierungs- und Integritäts-Constraint-Konflikte).
- **Dedizierte Felddefinition**:

  | Feld | Typ | Details |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Erforderlich**. Name der Tabelle, in der der Integritäts-Constraint-Konflikt oder der Nicht-Gefunden-Fehler aufgetreten ist. |
  | `constraintName` | `String?` | **Optional**. Der Name des spezifischen Constraints, das den Fehler verursacht hat (z. B. `fk_users_profile` für Fremdschlüssel, Indexname bei Unique-Konflikten oder `null` bei Not-Null- oder Cast-Fehlern). |
  | `fields` | `List<String>` | **Erforderlich**. Liste der Felder, die den Konflikt verursachen. |
  | `conflictingKeys` | `List<dynamic>` | **Erforderlich**. Liste der Eingabewerte, die den Konflikt verursachen, 1:1 den `fields` zugeordnet. Wenn ein Feld null ist, ist das entsprechende Element in der Liste `null`. |
  | `primaryKey` | `String?` | **Optional**. Zugeordneter Datensatz-Primärschlüssel. Wenn es sich nicht um einen Schreibvorgang für eine einzelne Zeile handelt oder der Vorgang in der Speicherphase blockiert wurde, ist dies `null`. |
  | `referencedTable` | `String?` | **Optional**. Name der übergeordneten Tabelle bei Fremdschlüsselkonflikten. |

- **Blattcode-Richtlinien**:

  | Code & ResultType | Szenario | Feldrichtlinien |
  | :--- | :--- | :--- |
  | `10000`<br>`bizValidationFailed` | Datenformat- oder Bereichsvalidierung fehlgeschlagen | <ul><li>`tableName`: Betroffene Tabelle</li><li>`constraintName`: `null`</li><li>`fields`: Felder, die gegen die Validierung verstoßen, z. B. `["email"]`</li><li>`conflictingKeys`: Ungültige Werte, die den Fehler verursachen, z. B. `["invalid-email"]`</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |
  | `10001`<br>`bizNotNullViolation` | Verletzung des Not-Null-Constraints | <ul><li>`tableName`: Betroffene Tabelle</li><li>`constraintName`: `null`</li><li>`fields`: Felder, die gegen die Not-Null-Beschränkung verstoßen, z. B. `["email"]`</li><li>`conflictingKeys`: Immer `[null]`</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |
  | `10002`<br>`bizTypeCastFailed` | Datentypkonvertierung oder Cast fehlgeschlagen | <ul><li>`tableName`: Betroffene Tabelle</li><li>`constraintName`: `null`</li><li>`fields`: Felder, bei denen der Cast fehlgeschlagen ist, z. B. `["age"]`</li><li>`conflictingKeys`: Ungültige Werte, die den Fehler verursachen, z. B. `["not_a_number"]`</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |
  | `11001`<br>`bizPrimaryKeyViolation` | Primärschlüsselkonflikt (existiert bereits) | <ul><li>`tableName`: Betroffene Tabelle</li><li>`constraintName`: `"PRIMARY"` oder Name des Constraints</li><li>`fields`: Primärschlüsselfelder, z. B. `["id"]`</li><li>`conflictingKeys`: Doppelte Werte, z. B. `["usr_101"]`</li><li>`primaryKey`: Konfliktverursachender Wert, z. B. `"usr_101"`</li></ul> |
  | `11002`<br>`bizUniqueViolation` | Verletzung des Unique-Constraints | <ul><li>`tableName`: Betroffene Tabelle</li><li>`constraintName`: Name des Unique-Index, z. B. `"uk_email"`</li><li>`fields`: Felder, die die Eindeutigkeit bilden, z. B. `["email"]`</li><li>`conflictingKeys`: Werte, die den Konflikt verursachen, z. B. `["test@a.com"]`</li><li>`primaryKey`: Primärschlüssel des konfliktverursachenden Datensatzes (falls vorhanden)</li></ul> |
  | `11003`<br>`bizForeignKeyViolation` | Fremdschlüssel-Constraint-Verletzung (Generisch) | <ul><li>`tableName`: Untergeordnete Tabelle (Child Table)</li><li>`constraintName`: Name des Fremdschlüssel-Constraints</li><li>`fields`: Fremdschlüsselspalten</li><li>`conflictingKeys`: Eingabewerte, die den Konflikt verursachen</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li><li>`referencedTable`: Übergeordnete Tabelle (Parent Table)</li></ul> |
  | `11004`<br>`bizCheckViolation` | Verletzung des Check-Constraints | <ul><li>`tableName`: Betroffene Tabelle</li><li>`constraintName`: Name des Check-Constraints</li><li>`fields`: Geprüfte Felder</li><li>`conflictingKeys`: Werte, die gegen den Check verstoßen</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |
  | `11005`<br>`bizForeignKeyParentNotExist` | Referenzierter übergeordneter Schlüssel existiert nicht | <ul><li>`tableName`: Untergeordnete Tabelle (Child Table)</li><li>`constraintName`: Name des Fremdschlüssel-Constraints</li><li>`fields`: Fremdschlüsselspalten, z. B. `["userId"]`</li><li>`conflictingKeys`: Nicht existierender Referenzwert, z. B. `["non_parent"]`</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li><li>`referencedTable`: Übergeordnete Tabelle (Parent Table)</li></ul> |
  | `11006`<br>`bizForeignKeyChildRestrict` | Löschen/Aktualisieren durch untergeordnete Datensätze eingeschränkt | <ul><li>`tableName`: Übergeordnete Tabelle (Parent Table)</li><li>`constraintName`: Name des Fremdschlüssel-Constraints</li><li>`fields`: Spalten, auf die in der übergeordneten Tabelle verwiesen wird</li><li>`conflictingKeys`: Übergeordnete Schlüsselwerte, auf die von der untergeordneten Tabelle verwiesen wird</li><li>`primaryKey`: Übergeordnete Schlüsselwerte</li><li>`referencedTable`: Untergeordnete Tabelle (Child Table)</li></ul> |
  | `11007`<br>`bizForeignKeyCompositeMismatch` | Unvollständige zusammengesetzte Fremdschlüsselwerte | <ul><li>`tableName`: Untergeordnete Tabelle (Child Table)</li><li>`constraintName`: Name des Fremdschlüssel-Constraints</li><li>`fields`: Zusammengesetzte Fremdschlüsselspalten</li><li>`conflictingKeys`: Eingabewerte (enthält teilweise Nullwerte)</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li><li>`referencedTable`: Übergeordnete Tabelle (Parent Table)</li></ul> |
  | `11008`<br>`bizForeignKeyTypeMismatch` | Datentyp des Fremdschlüssels stimmt nicht überein | <ul><li>`tableName`: Untergeordnete Tabelle (Child Table)</li><li>`constraintName`: Name des Fremdschlüssel-Constraints</li><li>`fields`: Fremdschlüsselspalten</li><li>`conflictingKeys`: Werte, bei denen der Cast fehlgeschlagen ist</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li><li>`referencedTable`: Übergeordnete Tabelle (Parent Table)</li></ul> |
  | `11009`<br>`bizValueExceedsMaxLength` | Wertlänge überschreitet das Maximum-Constraint | <ul><li>`tableName`: Betroffene Tabelle</li><li>`constraintName`: `null`</li><li>`fields`: Felder, die gegen das Limit verstoßen, z. B. `["name"]`</li><li>`conflictingKeys`: Überschreitende Werte, z. B. `["a" * 1000]`</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |
  | `11010`<br>`bizValueLessThanMinLength` | Wertlänge ist kürzer als das Minimum-Constraint | <ul><li>`tableName`: Betroffene Tabelle</li><li>`constraintName`: `null`</li><li>`fields`: Felder, die gegen das Limit verstoßen, z. B. `["code"]`</li><li>`conflictingKeys`: Werte, die kürzer als das Minimum sind, z. B. `["ab"]`</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |
  | `11011`<br>`bizValueLessThanMinValue` | Numerischer Wert ist kleiner als das Minimum-Constraint | <ul><li>`tableName`: Betroffene Tabelle</li><li>`constraintName`: `null`</li><li>`fields`: Felder, die gegen das Limit verstoßen, z. B. `["age"]`</li><li>`conflictingKeys`: Werte unter dem Minimum, z. B. `[-5]`</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |
  | `11012`<br>`bizValueExceedsMaxValue` | Numerischer Wert überschreitet das Maximum-Constraint | <ul><li>`tableName`: Betroffene Tabelle</li><li>`constraintName`: `null`</li><li>`fields`: Felder, die gegen das Limit verstoßen, z. B. `["score"]`</li><li>`conflictingKeys`: Werte über dem Maximum, z. B. `[105]`</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |
  | `12002`<br>`bizRecordNotFound` | Ressource existiert nicht / Datensatz nicht gefunden | <ul><li>`tableName`: Betroffene Tabelle</li><li>`constraintName`: `null`</li><li>`fields`: Suchzielfelder, z. B. `["id"]`</li><li>`conflictingKeys`: Nicht gefundene Zielschlüssel, z. B. `["non_exist_id"]`</li><li>`primaryKey`: Wert des fehlenden Schlüssels, z. B. `"non_exist_id"`</li></ul> |

- **JSON-Beispiel** (Referenzierter übergeordneter Datensatz existiert nicht):
  ```json
  {
    "index": 0,
    "code": 11005,
    "codeKey": "BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST",
    "message": "Foreign key constraint violation on table \"profiles\" (Constraint: \"fk_profiles_userId\"): Referenced record does not exist in table \"users\" for fields (userId) referencing (id). Conflicting values: [usr_999]",
    "tableName": "profiles",
    "constraintName": "fk_profiles_userId",
    "fields": ["userId"],
    "conflictingKeys": ["usr_999"],
    "primaryKey": "prof_112233",
    "referencedTable": "users"
  }
  ```

---

### 4.3 SchemaValidationStatus (Tabellenschema-Validierung & inkompatible Migration)

- **Kategoriebereich**: `code` innerhalb von `[30000, 39999]` (Schema-Konfigurationsfehler und physische Migrationsdiskrepanzen).
- **Dedizierte Felddefinition**:

  | Feld | Typ | Details |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Erforderlich**. Name der Tabelle, die validiert oder physisch migriert wird. |
  | `field` | `String?` | **Optional**. Der spezifische Feldname, der den Schema- oder Migrationsfehler ausgelöst hat. |
  | `wrongValue` | `dynamic` | **Optional**. Ungültiger Konfigurationswert oder Migrations-Diff-Konfiguration, die den Konflikt verursacht hat. |

- **Blattcode-Richtlinien**:

  | Code & ResultType | Szenario | Feldrichtlinien |
  | :--- | :--- | :--- |
  | `30000`<br>`devInvalidSchema` | Ungültige Tabellenschemadefinition | <ul><li>`tableName`: Tabellenname</li><li>`field`: `null`</li><li>`wrongValue`: Ungültige Konfigurations-Map oder `null`</li></ul> |
  | `30001`<br>`devInvalidSchemaTableName` | Tabellenname-Validierung fehlgeschlagen (ungültige Zeichen oder zu lang) | <ul><li>`tableName`: Fehlerhafter Name</li><li>`field`: `null`</li><li>`wrongValue`: Fehlerhafter String</li></ul> |
  | `30002`<br>`devInvalidSchemaFieldName` | Feldname-Validierung fehlgeschlagen (ungültige Zeichen) | <ul><li>`tableName`: Tabellenname</li><li>`field`: Fehlerhafter Feldname</li><li>`wrongValue`: Fehlerhafter String</li></ul> |
  | `30003`<br>`devInvalidSchemaPrimaryKey` | Primärschlüsselvalidierung fehlgeschlagen (fehlt oder ungültiges Format) | <ul><li>`tableName`: Tabellenname</li><li>`field`: `"primaryKey"` oder Name des Primärschlüsselfelds</li><li>`wrongValue`: Primärschlüssel-Konfigurationsdetails</li></ul> |
  | `30004`<br>`devInvalidSchemaIndexLimit` | Tabellenindexanzahl überschreitet das Systemlimit von 16 | <ul><li>`tableName`: Tabellenname</li><li>`field`: `null`</li><li>`wrongValue`: Liste der Indexkonfigurationen</li></ul> |
  | `30005`<br>`devSchemaTableExists` | Tabelle existiert bereits | <ul><li>`tableName`: Tabellenname</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30006`<br>`devSchemaFieldExists` | Schema-Upgrade: Hinzufügen eines bereits vorhandenen Feldes | <ul><li>`tableName`: Tabellenname</li><li>`field`: Konfliktverursachender Feldname</li><li>`wrongValue`: `null`</li></ul> |
  | `30007`<br>`devSchemaIndexExists` | Schema-Upgrade: Hinzufügen eines bereits vorhandenen Index | <ul><li>`tableName`: Tabellenname</li><li>`field`: Indexname</li><li>`wrongValue`: `null`</li></ul> |
  | `30008`<br>`devInvalidSchemaForeignKey` | Fremdschlüsseldefinition ungültig (z. B. Spaltenkonflikt) | <ul><li>`tableName`: Tabellenname</li><li>`field`: Name des Fremdschlüssels</li><li>`wrongValue`: Fremdschlüssel-Konfigurationsdetails</li></ul> |
  | `30009`<br>`devInvalidSchemaSpaceMismatch` | Globaler/Space-spezifischer Grenzwertkonflikt | <ul><li>`tableName`: Tabellenname</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30010`<br>`devMigrationNotAllowedWithData` | Migration erfordert Datenänderung und wurde nicht explizit erlaubt | <ul><li>`tableName`: Tabellenname</li><li>`field`: `null`</li><li>`wrongValue`: Migration-Upgrade-Diffs-Map</li></ul> |
  | `30011`<br>`devMigrationUnsafeTypeConversion` | Physische Migration: Nicht unterstützte Typkonvertierung für Feld | <ul><li>`tableName`: Tabellenname</li><li>`field`: Feldname</li><li>`wrongValue`: Konfliktverursachende Typen-Map, z. B. `{ "from": "text", "to": "integer" }`</li></ul> |
  | `30013`<br>`devMigrationCannotAddNonNullField` | Nicht-Null-Feld ohne Standardwert kann nicht zu einer nicht-leeren Tabelle hinzugefügt werden | <ul><li>`tableName`: Tabellenname</li><li>`field`: Fehlerhafter Feldname</li><li>`wrongValue`: Migrationsparameter, z. B. `{ "nullable": false, "defaultValue": null }`</li></ul> |
  | `30014`<br>`devMigrationNullableToNonNullNotAllowed` | Physische Migration: Änderung eines Feldes von Nullable zu Nicht-Null | <ul><li>`tableName`: Tabellenname</li><li>`field`: Feldname</li><li>`wrongValue`: Migrationsparameter, analog zu 30013</li></ul> |
  | `30015`<br>`devMigrationUniqueTighteningNotAllowed` | Physische Migration: Verschärfung der Feldbeschränkung auf UNIQUE | <ul><li>`tableName`: Tabellenname</li><li>`field`: Feldname</li><li>`wrongValue`: Indexdefinition, die die Unique-Beschränkung verursacht</li></ul> |
  | `30016`<br>`devInvalidSchemaTtlConfig` | TTL-Konfigurationsvalidierung fehlgeschlagen | <ul><li>`tableName`: Tabellenname</li><li>`field`: TTL-Zeitstempelfeld</li><li>`wrongValue`: Ungültige TTL-Konfigurations-Map, z. B. `{ "enabled": true, "fieldName": "expire_at" }`</li></ul> |
  | `30017`<br>`devInvalidSchemaDuplicateFieldName` | Doppelter Feldname im Tabellenschema | <ul><li>`tableName`: Tabellenname</li><li>`field`: Doppelter Feldname</li><li>`wrongValue`: `null`</li></ul> |
  | `30018`<br>`devInvalidSchemaIndexField` | Index verweist auf ein nicht existierendes Feld | <ul><li>`tableName`: Tabellenname</li><li>`field`: Indexname</li><li>`wrongValue`: Feldname, der die Diskrepanz verursacht</li></ul> |

- **JSON-Beispiel** (Hinzufügen eines Nicht-Null-Feldes ohne Standardwert zu einer nicht-leeren Tabelle):
  ```json
  {
    "index": 0,
    "code": 30013,
    "codeKey": "DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD",
    "message": "Cannot add non-nullable field \"phone\" without a default value to non-empty table \"users\". This operation is physically impossible and would fail during data write.",
    "tableName": "users",
    "field": "phone",
    "wrongValue": {
      "nullable": false,
      "defaultValue": null
    }
  }
  ```

---

### 4.4 InvalidArgumentStatus (API-Argumente & Cursor-Paginierungsvalidierung)

- **Kategoriebereich**: `code` innerhalb von `[20000, 20999]` (Validierungsfehler bei API-Parametern, Abfragestrukturen oder Paginierungs-Token).
- **Dedizierte Felddefinition**:

  | Feld | Typ | Details |
  | :--- | :--- | :--- |
  | `parameterName` | `String` | **Erforderlich**. Name des Arguments, das den Validierungsfehler verursacht hat (z. B. `"cursor"`, `"orderBy"` oder spezifischer Spaltenschlüssel). |
  | `passedValue` | `dynamic` | **Optional**. Vom Aufrufer übergebener, nicht konformer Eingabewert. Komplexe Objekte werden in Strings konvertiert. |
  | `primaryKey` | `String?` | **Optional**. Zugeordneter Datensatz-Primärschlüssel. |

- **Blattcode-Richtlinien**:

  | Code & ResultType | Szenario | Feldrichtlinien |
  | :--- | :--- | :--- |
  | `20001`<br>`devInvalidArgumentFormat` | Formatfehler des Arguments | <ul><li>`parameterName`: Ungültiger Argumentname</li><li>`passedValue`: Übergebener Wert, z. B. `"twenty"`</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |
  | `20002`<br>`devInvalidArgumentType` | Typkonflikt des Arguments | <ul><li>`parameterName`: Parametername</li><li>`passedValue`: Übergebener Wert, z. B. `{"foo": "bar"}` (wenn String erwartet)</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |
  | `20003`<br>`devInvalidArgumentMissing` | Erforderliches Argument fehlt | <ul><li>`parameterName`: Name des fehlenden Parameters, z. B. `"dbPath"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |
  | `20005`<br>`devInvalidPrimaryKeyFormat` | Ungültiges Primärschlüsselformat | <ul><li>`parameterName`: `"primaryKey"` oder Primärschlüsselfeld</li><li>`passedValue`: Ungültiger Primärschlüsselwert, z. B. `"invalid_id_value"`</li><li>`primaryKey`: Ungültiger Primärschlüsselwert</li></ul> |
  | `20010`<br>`devVectorDimensionMismatch` | Vektordimensionen stimmen nicht überein | <ul><li>`parameterName`: `"other"`</li><li>`passedValue`: Fehlerhafte Dimensionsgröße</li><li>`primaryKey`: `null`</li></ul> |
  | `20011`<br>`devIndexFieldMissing` | Erforderliches Indexfeld fehlt im Datensatz für Cursor | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Fehlendes Indexfeld</li><li>`primaryKey`: `null`</li></ul> |
  | `20201`<br>`devInvalidCursorPagination` | Cursor-Paginierung und Offset schließen sich gegenseitig aus | <ul><li>`parameterName`: `"cursor"` / `"offset"`</li><li>`passedValue`: Konfliktverursachende Paginierungsparameter</li><li>`primaryKey`: `null`</li></ul> |
  | `20202`<br>`devInvalidCursorTable` | Cursor stimmt nicht mit Zieltabelle überein | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Cursor-Token</li><li>`primaryKey`: `null`</li></ul> |
  | `20203`<br>`devInvalidCursorSignature` | Ungültige Cursor-Signatur (manipuliert) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Cursor-Token</li><li>`primaryKey`: `null`</li></ul> |
  | `20204`<br>`devInvalidCursorOrderBy` | Cursor-orderBy-Konfiguration ungültig oder nicht übereinstimmend | <ul><li>`parameterName`: `"orderBy"`</li><li>`passedValue`: OrderBy-Liste, z. B. `["-age", "id"]`</li><li>`primaryKey`: `null`</li></ul> |
  | `20205`<br>`devInvalidCursorMode` | Modus des Cursor-Tokens stimmt nicht überein | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Token-Modus, z. B. `"sortKey"`</li><li>`primaryKey`: `null`</li></ul> |
  | `20206`<br>`devInvalidCursorPayload` | Ungültige Cursor-Nutzlast (nicht decodierbar) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: `null`</li></ul> |
  | `20301`<br>`devInvalidQuerySelectField` | Abfrage-Select-Feld muss ein String oder eine QueryAggregation sein | <ul><li>`parameterName`: `"select"`</li><li>`passedValue`: Ungültige Select-Feld-Definition</li><li>`primaryKey`: `null`</li></ul> |
  | `20302`<br>`devInvalidQueryForeignKeyJoin` | Keine Fremdschlüsselbeziehung für automatischen Join vorhanden | <ul><li>`parameterName`: `"join"` / `"tableName"`</li><li>`passedValue`: Zieltabelle ohne Beziehung</li><li>`primaryKey`: `null`</li></ul> |
  | `20303`<br>`devInvalidQueryFieldAlias` | Format des Abfrage-Feld-Alias ungültig | <ul><li>`parameterName`: `"alias"`</li><li>`passedValue`: Ungültiger Alias-String</li><li>`primaryKey`: `null`</li></ul> |
  | `20304`<br>`devInvalidExpression` | Ungültige Ausdruckskonfiguration oder Ausführungsausnahme | <ul><li>`parameterName`: Fehleraspekt (z. B. `"arguments"`, `"functionName"`, `"node"`)</li><li>`passedValue`: Ungültiger Wert oder Anzahl</li><li>`primaryKey`: `null`</li></ul> |
  | `22005`<br>`devFieldNotFound` | Feld nicht gefunden | <ul><li>`parameterName`: Unbekannter Feldname, z. B. `"extra"`</li><li>`passedValue`: Übergebener Wert für das Feld</li><li>`primaryKey`: Datensatz-Primärschlüssel (falls vorhanden)</li></ul> |

- **JSON-Beispiel** (Cursor-Sortierfelder stimmen nicht mit Abfrage-Sortierfeldern überein):
  ```json
  {
    "index": 0,
    "code": 20204,
    "codeKey": "DEV_INVALID_CURSOR_ORDERBY",
    "message": "Cursor orderBy fields do not match current query orderBy.",
    "parameterName": "orderBy",
    "passedValue": ["age DESC", "id ASC"],
    "primaryKey": null
  }
  ```

---

### 4.5 TransactionOperationStatus (Transaktionskonflikt & -abbruch)

- **Kategoriebereich**: `code` innerhalb von `[50000, 50999]` (Transaktions-Rollback, expliziter Abbruch oder Serialisierbarkeitskonflikte).
- **Dedizierte Felddefinition**:

  | Feld | Typ | Details |
  | :--- | :--- | :--- |
  | `txId` | `String` | **Erforderlich**. Global eindeutiger Transaktions-Stream-Identifikations-ID. Dient zur Verfolgung des Transaktionslebenszyklus. |

- **Blattcode-Richtlinien**:

  | Code & ResultType | Szenario | Feldrichtlinien |
  | :--- | :--- | :--- |
  | `50001`<br>`sysTransactionAborted` | Transaktion abgebrochen (expliziter Rollback oder Kaskadenfehler) | <ul><li>`txId`: Aktive Transaktions-ID</li></ul> |
  | `50002`<br>`sysTransactionConflict` | Transaktionskonflikt (gleichzeitige Updates auf denselben Schlüssel in SSI/WAL) | <ul><li>`txId`: Konfliktverursachende Transaktions-ID</li></ul> |

- **JSON-Beispiel** (SSI-Schreib-Schreib-Konflikt bei gleichzeitigen Schreibvorgängen):
  ```json
  {
    "index": 0,
    "code": 50002,
    "codeKey": "SYS_TRANSACTION_CONFLICT",
    "message": "Transaction conflict, concurrent updates detected on entity version mismatch (record: usr_123456)",
    "txId": "tx_88ff3b2a99c1"
  }
  ```

---

### 4.6 GeneralStatus (Generische & systemnahe Ausnahmen)

- **Kategoriebereich**: Fallback für alle anderen Statuscodes (Low-Level-IO, Hardwarefehler, System-Timeouts usw.).
- **Dedizierte Felddefinition**:

  | Feld | Typ | Details |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Optional**. Zugeordneter Datensatz-Primärschlüssel. |
  | `target` | `String?` | **Optional**. Physische Zielressource, z. B. physische Dateipfade, Sperren oder URLs. |
  | `operation` | `String?` | **Optional**. Name des aktiven Systemaufrufs, z. B. `'readAsString'`, `'delete'`, `'acquire'`. |

- **Blattcode-Richtlinien**:

  | Code & ResultType | Szenario / Ebene | Feldrichtlinien |
  | :--- | :--- | :--- |
  | `20007`<br>`devIndexOutOfBounds` | Index oder Bereich liegt außerhalb der Grenzen (Entwicklerfehler) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `20008`<br>`devUnsupportedOperation` | Operation wird im aktuellen Kontext nicht unterstützt (Entwicklerfehler) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ziel-Tabelle/Ressource (falls vorhanden)</li><li>`operation`: Methodenname (falls vorhanden)</li></ul> |
  | `22001`<br>`devTableNotFound` | Tabelle nicht gefunden (Entwicklerfehler) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22003`<br>`devIndexNotFound` | Index nicht gefunden (Entwicklerfehler) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22004`<br>`devSpaceNotFound` | Space nicht gefunden (Entwicklerfehler) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23001`<br>`devLargeScaleOperationBypassRequired` | Überspringen von Details erforderlich, um OOM zu verhindern (Entwicklerfehler) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `24001`<br>`devEngineIncompatible` | **Kritisch**: Engine-Version inkompatibel | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50003`<br>`sysMigrationBatchExecutionFailed` | Chargenmigration-Ausführung fehlgeschlagen (Systemfehler) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51001`<br>`sysTimeoutLockAcquisition` | Timeout beim Sperrenerwerb (Systemfehler) | <ul><li>`primaryKey`: Zielschlüssel (falls vorhanden)</li><li>`target`: ID der gesperrten Ressource</li><li>`operation`: `"acquire"`</li></ul> |
  | `51002`<br>`sysTimeout` | Operation-Timeout (Systemfehler) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51003`<br>`sysCancellation` | Operation wurde abgebrochen (Systemfehler) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52001`<br>`sysResourceExhaustedMemory` | Arbeitsspeicher erschöpft (Systemfehler) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52002`<br>`sysResourceExhausted` | Systemressourcen erschöpft, z. B. Festplatte voll (Systemfehler) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `53001`<br>`sysIoNotFound` | Physische Datei oder Pfad existiert nicht (Systemfehler) | <ul><li>`primaryKey`: `null`</li><li>`target`: Datei- oder Ordnerpfad</li><li>`operation`: I/O-Operation</li></ul> |
  | `53002`<br>`sysIoPermissionDenied` | Dateizugriff verweigert (Systemfehler) | <ul><li>`primaryKey`: `null`</li><li>`target`: Dateipfad</li><li>`operation`: I/O-Operation</li></ul> |
  | `53003`<br>`sysIoDiskFull` | Speicherplatz voll oder Speicherplatzkontingent überschritten (Systemfehler) | <ul><li>`primaryKey`: `null`</li><li>`target`: Dateipfad</li><li>`operation`: I/O-Operation</li></ul> |
  | `53004`<br>`sysIoFileLocked` | Datei ist gesperrt oder wird von einem anderen Prozess verwendet (Systemfehler) | <ul><li>`primaryKey`: `null`</li><li>`target`: Dateipfad</li><li>`operation`: I/O-Operation</li></ul> |
  | `53005`<br>`sysIoDeviceFault` | Speichergeräte- oder Medienfehler (Systemfehler) | <ul><li>`primaryKey`: `null`</li><li>`target`: Dateipfad</li><li>`operation`: I/O-Operation</li></ul> |
  | `53006`<br>`sysIoWebStorageUnavailable` | Web-IndexedDB oder -Speicher ist nicht verfügbar (Systemfehler) | <ul><li>`primaryKey`: `null`</li><li>`target`: IndexedDB-Ressource</li><li>`operation`: I/O-Operation</li></ul> |
  | `53007`<br>`sysBackupCorrupted` | Backup-Paket ist beschädigt oder Metadaten fehlen (Systemfehler) | <ul><li>`primaryKey`: `null`</li><li>`target`: Backup-Pfad</li><li>`operation`: Lesen/Schreiben des Backups</li></ul> |
  | `53008`<br>`sysIoDataCorrupted` | Datenbankdatendatei beschädigt oder Checksumme fehlgeschlagen (Systemfehler) | <ul><li>`primaryKey`: `null`</li><li>`target`: Datendateipfad</li><li>`operation`: I/O-Operation</li></ul> |
  | `53009`<br>`sysInvalidDataFormat` | Formatierung oder Parsing des Datenstroms fehlgeschlagen (Systemfehler) | <ul><li>`primaryKey`: `null`</li><li>`target`: Datenstromschlüssel</li><li>`operation`: `"decode"` / `"deserialize"`</li></ul> |
  | `53099`<br>`sysIoGeneric` | Generischer System-IO-Fehler (Systemfehler) | <ul><li>`primaryKey`: `null`</li><li>`target`: Dateipfad</li><li>`operation`: I/O-Operation</li></ul> |
  | `99001`<br>`engError` | Engine-Fehler (Engine-Fehler) | <ul><li>`primaryKey`: `null`</li></ul> |

- **JSON-Beispiel** (Tabelle-nicht-gefunden-Fehler):
  ```json
  {
    "index": 0,
    "code": 22001,
    "codeKey": "DEV_NOT_FOUND_TABLE",
    "message": "Table \"orders\" not found in database metadata schema.",
    "primaryKey": null
  }
  ```

---

## 5. Empfehlungen zur Statusauflösung und Ausnahmebehandlung für Datenbankbenutzer (Dart/Flutter-Beispiele)

In ToStore geben alle wichtigen Schreibvorgänge (Insert, Update, Delete) ein `DbResult` zurück. Abfragen geben ein `QueryResult` zurück und Transaktionsoperationen geben ein `TransactionResult` zurück. Fehler bei der strukturellen Konfiguration lösen eine `DbException` aus.

Nachfolgend finden Sie Codebeispiele, die veranschaulichen, wie Client-Anwendungen Datenbankstatus abrufen, analysieren und ordnungsgemäß behandeln sollten:

### 5.1 Behandlung von Antworten auf Schreibvorgänge (`DbResult`)

```dart
import 'package:tostore/tostore.dart';

void handleDatabaseWriteResult(DbResult result) {
  // 1. Sofort prüfen, ob der Schreibvorgang komplett fehlerfrei abgeschlossen wurde
  if (!result.hasErrors) {
    print("Alle Schreibvorgänge erfolgreich. Betroffen: ${result.successCount}");

    // Bei Schreibvorgängen in eine einzelne Zeile den Schlüssel direkt abrufen
    if (result.firstPrimaryKey != null) {
      print("Primärschlüssel des ersten erfolgreichen Datensatzes: ${result.firstPrimaryKey}");
    }
  } else {
    print("🛑 Fehler erkannt. Erfolgreich: ${result.successCount}, Fehlgeschlagen: ${result.failedCount}");
    print("Erster Fehler: ${result.firstType.codeKey} (${result.firstType.code})");

    // 2. Statusdaten iterieren (Index entspricht 1:1 dem Eingabe-Batch-Array)
    for (final status in result.statuses) {
      final int idx = status.index;

      // 3. Pattern Matching auf Unterklassen zur Steuerung der Behandlungslogik
      if (status is SuccessStatus) {
        print("Index [$idx] Erfolgreich. Primärschlüssel: ${status.primaryKey}");
      } 
      else if (status is ConstraintStatus) {
        // Behandlung von Constraint-Verletzungen (Primärschlüssel, Unique, Check, Fremdschlüssel usw.)
        print("Index [$idx] Constraint-Verletzung! Tabelle: ${status.tableName}, Spalten: ${status.fields}");
        print("Konfliktverursachende Werte: ${status.conflictingKeys}, PK: ${status.primaryKey}");
        print("Fehlermeldung: ${status.message}");
      } 
      else if (status is InvalidArgumentStatus) {
        // Behandlung von Parameterfehlern
        print("Index [$idx] Ungültiger Parameter! Parameter: ${status.parameterName}, Übergebener Wert: ${status.passedValue}");
      } 
      else if (status is GeneralStatus) {
        // Behandlung von Sperr-Timeouts, Festplatte voll, System-I/O-Problemen usw.
        print("Index [$idx] Generische Ausnahme! Code: ${status.code} (${status.codeKey})");
        print("Meldung: ${status.message}");
      }
    }
  }
}
```

### 5.2 Abfangen von Tabellenschema- und Vorgangsausnahmen (`DbException`)

Für die Tabellenerstellung (`createTable`) oder Schemaänderungen (`updateSchema`), oder in Fällen, in denen Schemadefinitionen die Prüfungen auf Code-Ebene nicht bestehen, löst ToStore in der Produktion eine `DbException` aus:

```dart
try {
  // Datenbank mit Schema-Updates öffnen
  await ToStore.open(schemas: [..]);
} on DbException catch (e) {
  print("❌ Kritische Datenbankausnahme! Aggregierter Fehler: \n${e.message}");
  
  // Die einzelnen Status in der Ausnahme iterieren
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // Probleme mit der Schema-Validierung
      print("Schemavalidierung fehlgeschlagen! Tabelle: ${status.tableName}");
      if (status.field != null) {
        print("Fehlerhaftes Feld: ${status.field}, Ungültige Konfiguration: ${status.wrongValue}");
      }
    } else {
      print("Diagnose: [${status.codeKey}] (Code ${status.code}): ${status.message}");
    }
  }
}
```

### 5.3 Behandlung von Abfrageoperationen (`QueryResult`) & Transaktionssteuerung (`TransactionResult`)

- **Für Abfragen**:
  ```dart
  final queryResult = await db.query('users').where('age', '>', 18);
  if (queryResult.hasErrors) {
    // Abfrageausnahmen behandeln (z. B. ungültiger Cursor, fehlende Tabelle)
    print("Abfrage fehlgeschlagen! Code: ${queryResult.type.code}, Meldung: ${queryResult.message}");
  } else {
    // Abfrage erfolgreich ausgeführt
    final List<Map<String, dynamic>> users = queryResult.data;
    print("${users.length} Datensätze abgerufen. Hat weitere: ${queryResult.hasMore}");
  }
  ```
- **Für Transaktionen**:
  ```dart
  final txnResult = await db.transaction(() async {
    await db.insert('users', newUser);
  });

  if (txnResult.hasErrors) {
    print("Transaktion zurückgesetzt! TxId: ${txnResult.txId}");
    // Detaillierte Fehler einzelner Unteroperationen abrufen
    for (final status in txnResult.statuses) {
      if (status.type != ResultType.success) {
        print("Fehlerursache: [${status.codeKey}] ${status.message}");
      }
    }
  }
  ```

---

## 6. Vollständige Referenz der Blattstatuscodes und semantischen Bezeichner

Die genaue Zuordnung der Status-Routings und -Parsings entnehmen Sie bitte der folgenden Tabelle:

| Statuscode (Code) | Bezeichner (CodeKey) | Speicher-Enum (ResultType) | Kategorie | Beschreibung |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `ResultType.success` | Erfolg | Operation erfolgreich ausgeführt |
| **10000** | `BIZ_VALIDATION_FAILED` | `ResultType.bizValidationFailed` | Geschäftsfehler | Datenformat- oder Bereichsvalidierung fehlgeschlagen |
| **10001** | `BIZ_NOT_NULL_VIOLATION` | `ResultType.bizNotNullViolation` | Geschäftsfehler | Verletzung des Not-Null-Constraints |
| **10002** | `BIZ_VALIDATION_TYPE_CAST` | `ResultType.bizTypeCastFailed` | Geschäftsfehler | Datentypkonvertierung oder Cast fehlgeschlagen |
| **11001** | `BIZ_CONSTRAINT_PRIMARY_KEY` | `ResultType.bizPrimaryKeyViolation` | Geschäftsfehler | Primärschlüsselkonflikt (existiert bereits) |
| **11002** | `BIZ_CONSTRAINT_UNIQUE` | `ResultType.bizUniqueViolation` | Geschäftsfehler | Verletzung des Unique-Constraints |
| **11003** | `BIZ_CONSTRAINT_FOREIGN_KEY` | `ResultType.bizForeignKeyViolation` | Geschäftsfehler | Fremdschlüssel-Constraint-Verletzung (Generisch) |
| **11004** | `BIZ_CONSTRAINT_CHECK` | `ResultType.bizCheckViolation` | Geschäftsfehler | Verletzung des Check-Constraints |
| **11005** | `BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST` | `ResultType.bizForeignKeyParentNotExist` | Geschäftsfehler | Referenzierter übergeordneter Schlüssel existiert nicht |
| **11006** | `BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT` | `ResultType.bizForeignKeyChildRestrict` | Geschäftsfehler | Löschen/Aktualisieren durch untergeordnete Datensätze eingeschränkt |
| **11007** | `BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH` | `ResultType.bizForeignKeyCompositeMismatch` | Geschäftsfehler | Unvollständige zusammengesetzte Fremdschlüsselwerte |
| **11008** | `BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH` | `ResultType.bizForeignKeyTypeMismatch` | Geschäftsfehler | Datentyp des Fremdschlüssels stimmt nicht überein |
| **11009** | `BIZ_CONSTRAINT_MAX_LENGTH` | `ResultType.bizValueExceedsMaxLength` | Geschäftsfehler | Wertlänge überschreitet das Maximum-Constraint |
| **11010** | `BIZ_CONSTRAINT_MIN_LENGTH` | `ResultType.bizValueLessThanMinLength` | Geschäftsfehler | Wertlänge ist kürzer als das Minimum-Constraint |
| **11011** | `BIZ_CONSTRAINT_MIN_VALUE` | `ResultType.bizValueLessThanMinValue` | Geschäftsfehler | Numerischer Wert ist kleiner als das Minimum-Constraint |
| **11012** | `BIZ_CONSTRAINT_MAX_VALUE` | `ResultType.bizValueExceedsMaxValue` | Geschäftsfehler | Numerischer Wert überschreitet das Maximum-Constraint |
| **12002** | `BIZ_NOT_FOUND_RECORD` | `ResultType.bizRecordNotFound` | Geschäftsfehler | Ressource existiert nicht / Datensatz nicht gefunden |
| **20001** | `DEV_INVALID_ARGUMENT_FORMAT` | `ResultType.devInvalidArgumentFormat` | Entwicklerfehler | Formatfehler des Arguments |
| **20002** | `DEV_INVALID_ARGUMENT_TYPE` | `ResultType.devInvalidArgumentType` | Entwicklerfehler | Typkonflikt des Arguments |
| **20003** | `DEV_INVALID_ARGUMENT_MISSING` | `ResultType.devInvalidArgumentMissing` | Entwicklerfehler | Erforderliches Argument fehlt |
| **20005** | `DEV_INVALID_PRIMARY_KEY_FORMAT` | `ResultType.devInvalidPrimaryKeyFormat` | Entwicklerfehler | Ungültiges Primärschlüsselformat |
| **20007** | `DEV_INDEX_OUT_OF_BOUNDS` | `ResultType.devIndexOutOfBounds` | Entwicklerfehler | Index oder Bereich liegt außerhalb der Grenzen |
| **20008** | `DEV_UNSUPPORTED_OPERATION` | `ResultType.devUnsupportedOperation` | Entwicklerfehler | Operation wird im aktuellen Kontext nicht unterstützt |
| **20010** | `DEV_VECTOR_DIMENSION_MISMATCH` | `ResultType.devVectorDimensionMismatch` | Entwicklerfehler | Vektordimensionen stimmen nicht überein |
| **20011** | `DEV_INDEX_FIELD_MISSING` | `ResultType.devIndexFieldMissing` | Entwicklerfehler | Erforderliches Indexfeld fehlt im Datensatz für Cursor |
| **20201** | `DEV_INVALID_CURSOR_PAGINATION` | `ResultType.devInvalidCursorPagination` | Entwicklerfehler | Cursor-Paginierung und Offset schließen sich gegenseitig aus |
| **20202** | `DEV_INVALID_CURSOR_TABLE` | `ResultType.devInvalidCursorTable` | Entwicklerfehler | Cursor stimmt nicht mit Zieltabelle überein |
| **20203** | `DEV_INVALID_CURSOR_SIGNATURE` | `ResultType.devInvalidCursorSignature` | Entwicklerfehler | Ungültige Cursor-Signatur (manipuliert) |
| **20204** | `DEV_INVALID_CURSOR_ORDERBY` | `ResultType.devInvalidCursorOrderBy` | Entwicklerfehler | Cursor-orderBy-Konfiguration ungültig oder nicht übereinstimmend |
| **20205** | `DEV_INVALID_CURSOR_MODE` | `ResultType.devInvalidCursorMode` | Entwicklerfehler | Modus des Cursor-Tokens stimmt nicht überein |
| **20206** | `DEV_INVALID_CURSOR_PAYLOAD` | `ResultType.devInvalidCursorPayload` | Entwicklerfehler | Ungültige Cursor-Nutzlast (nicht decodierbar) |
| **20301** | `DEV_INVALID_QUERY_SELECT_FIELD` | `ResultType.devInvalidQuerySelectField` | Entwicklerfehler | Abfrage-Select-Feld muss ein String oder eine QueryAggregation sein |
| **20302** | `DEV_INVALID_QUERY_FOREIGN_KEY_JOIN` | `ResultType.devInvalidQueryForeignKeyJoin` | Entwicklerfehler | Keine Fremdschlüsselbeziehung für automatischen Join vorhanden |
| **20303** | `DEV_INVALID_QUERY_FIELD_ALIAS` | `ResultType.devInvalidQueryFieldAlias` | Entwicklerfehler | Format des Abfrage-Feld-Alias ungültig |
| **20304** | `DEV_INVALID_EXPRESSION` | `ResultType.devInvalidExpression` | Entwicklerfehler | Ungültige Ausdruckskonfiguration oder Ausführungsausnahme |
| **22001** | `DEV_NOT_FOUND_TABLE` | `ResultType.devTableNotFound` | Entwicklerfehler | Tabelle nicht gefunden |
| **22003** | `DEV_NOT_FOUND_INDEX` | `ResultType.devIndexNotFound` | Entwicklerfehler | Index nicht gefunden |
| **22004** | `DEV_NOT_FOUND_SPACE` | `ResultType.devSpaceNotFound` | Entwicklerfehler | Space nicht gefunden |
| **22005** | `DEV_NOT_FOUND_FIELD` | `ResultType.devFieldNotFound` | Entwicklerfehler | Feld nicht gefunden |
| **23001** | `DEV_LARGE_SCALE_OPERATION_REQUIRED_BYPASS` | `ResultType.devLargeScaleOperationBypassRequired` | Entwicklerfehler | Große Operation erfordert das Überspringen von Ergebnisdetails zur OOM-Vermeidung |
| **24001** | `DEV_ENGINE_INCOMPATIBLE` | `ResultType.devEngineIncompatible` | Entwicklerfehler | **Kritisch**: Engine-Version inkompatibel |
| **30000** | `DEV_INVALID_SCHEMA` | `ResultType.devInvalidSchema` | Entwicklerfehler | Ungültige Tabellenschemadefinition |
| **30001** | `DEV_INVALID_SCHEMA_TABLE_NAME` | `ResultType.devInvalidSchemaTableName` | Entwicklerfehler | Tabellenname-Validierung fehlgeschlagen |
| **30002** | `DEV_INVALID_SCHEMA_FIELD_NAME` | `ResultType.devInvalidSchemaFieldName` | Entwicklerfehler | Feldname-Validierung fehlgeschlagen |
| **30003** | `DEV_INVALID_SCHEMA_PRIMARY_KEY` | `ResultType.devInvalidSchemaPrimaryKey` | Entwicklerfehler | Primärschlüsselvalidierung fehlgeschlagen |
| **30004** | `DEV_INVALID_SCHEMA_INDEX_LIMIT` | `ResultType.devInvalidSchemaIndexLimit` | Entwicklerfehler | Indexanzahl-Validierung fehlgeschlagen |
| **30005** | `DEV_SCHEMA_TABLE_EXISTS` | `ResultType.devSchemaTableExists` | Entwicklerfehler | Tabelle existiert bereits |
| **30006** | `DEV_SCHEMA_FIELD_EXISTS` | `ResultType.devSchemaFieldExists` | Entwicklerfehler | Feld existiert bereits |
| **30007** | `DEV_SCHEMA_INDEX_EXISTS` | `ResultType.devSchemaIndexExists` | Entwicklerfehler | Index existiert bereits |
| **30008** | `DEV_INVALID_SCHEMA_FOREIGN_KEY` | `ResultType.devInvalidSchemaForeignKey` | Entwicklerfehler | Fremdschlüsseldefinition ungültig |
| **30009** | `DEV_INVALID_SCHEMA_SPACE_MISMATCH` | `ResultType.devInvalidSchemaSpaceMismatch` | Entwicklerfehler | Globaler/Space-spezifischer Grenzwertkonflikt |
| **30010** | `DEV_MIGRATION_NOT_ALLOWED_WITH_DATA` | `ResultType.devMigrationNotAllowedWithData` | Entwicklerfehler | Migration erfordert Datenänderung und wurde nicht explizit erlaubt |
| **30011** | `DEV_MIGRATION_UNSAFE_TYPE_CONVERSION` | `ResultType.devMigrationUnsafeTypeConversion` | Entwicklerfehler | Nicht unterstützte Datentypänderung für Feld |
| **30013** | `DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD` | `ResultType.devMigrationCannotAddNonNullField` | Entwicklerfehler | Hinzufügen eines Nicht-Null-Feldes ohne Standardwert ist nicht erlaubt |
| **30014** | `DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED` | `ResultType.devMigrationNullableToNonNullNotAllowed` | Entwicklerfehler | Änderung des Feldes von Nullable zu Nicht-Null ist nicht erlaubt |
| **30015** | `DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED` | `ResultType.devMigrationUniqueTighteningNotAllowed` | Entwicklerfehler | Verschärfung von non-unique auf UNIQUE ist nicht erlaubt |
| **30016** | `DEV_INVALID_SCHEMA_TTL_CONFIG` | `ResultType.devInvalidSchemaTtlConfig` | Entwicklerfehler | TTL-Konfigurationsvalidierung fehlgeschlagen |
| **30017** | `DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME` | `ResultType.devInvalidSchemaDuplicateFieldName` | Entwicklerfehler | Doppelter Feldname im Tabellenschema |
| **30018** | `DEV_INVALID_SCHEMA_INDEX_FIELD` | `ResultType.devInvalidSchemaIndexField` | Entwicklerfehler | Index verweist auf ein nicht existierendes Feld |
| **50001** | `SYS_TRANSACTION_ABORTED` | `ResultType.sysTransactionAborted` | Systemfehler | Transaktion abgebrochen |
| **50002** | `SYS_TRANSACTION_CONFLICT` | `ResultType.sysTransactionConflict` | Systemfehler | Transaktionskonflikt |
| **50003** | `SYS_MIGRATION_BATCH_EXECUTION_FAILED` | `ResultType.sysMigrationBatchExecutionFailed` | Systemfehler | **Kritisch**: Chargenmigration-Ausführung fehlgeschlagen |
| **51001** | `SYS_TIMEOUT_LOCK_ACQUISITION` | `ResultType.sysTimeoutLockAcquisition` | Systemfehler | Timeout beim Sperrenerwerb |
| **51002** | `SYS_TIMEOUT` | `ResultType.sysTimeout` | Systemfehler | Operation-Timeout |
| **51003** | `SYS_CANCELLATION` | `ResultType.sysCancellation` | Systemfehler | Operation wurde abgebrochen |
| **52001** | `SYS_RESOURCE_EXHAUSTED_MEMORY` | `ResultType.sysResourceExhaustedMemory` | Systemfehler | **Kritisch**: Arbeitsspeicher erschöpft |
| **52002** | `SYS_RESOURCE_EXHAUSTED` | `ResultType.sysResourceExhausted` | Systemfehler | **Kritisch**: Systemressourcen erschöpft |
| **53001** | `SYS_IO_NOT_FOUND` | `ResultType.sysIoNotFound` | Systemfehler | Physische Datei oder Pfad existiert nicht |
| **53002** | `SYS_IO_PERMISSION_DENIED` | `ResultType.sysIoPermissionDenied` | Systemfehler | Dateizugriff verweigert |
| **53003** | `SYS_IO_DISK_FULL` | `ResultType.sysIoDiskFull` | Systemfehler | **Kritisch**: Speicherplatz voll oder Speicherplatzkontingent überschritten |
| **53004** | `SYS_IO_FILE_LOCKED` | `ResultType.sysIoFileLocked` | Systemfehler | Datei ist gesperrt oder wird von einem anderen Prozess verwendet |
| **53005** | `SYS_IO_DEVICE_FAULT` | `ResultType.sysIoDeviceFault` | Systemfehler | **Kritisch**: Speichergeräte- oder Medienfehler |
| **53006** | `SYS_IO_WEB_STORAGE_UNAVAILABLE` | `ResultType.sysIoWebStorageUnavailable` | Systemfehler | Web-IndexedDB oder -Speicher ist nicht verfügbar |
| **53007** | `SYS_BACKUP_CORRUPTED` | `ResultType.sysBackupCorrupted` | Systemfehler | Backup-Paket ist beschädigt oder Metadaten fehlen |
| **53008** | `SYS_IO_DATA_CORRUPTED` | `ResultType.sysIoDataCorrupted` | Systemfehler | **Kritisch**: Datenbankdatendatei beschädigt oder Checksumme fehlgeschlagen |
| **53009** | `SYS_INVALID_DATA_FORMAT` | `ResultType.sysInvalidDataFormat` | Systemfehler | Formatierung oder Parsing des Datenstroms fehlgeschlagen |
| **53099** | `SYS_IO_GENERIC` | `ResultType.sysIoGeneric` | Systemfehler | Generischer System-IO-Fehler |
| **99001** | `ENG_ERROR` | `ResultType.engError` | Engine-Fehler | Engine-Fehler |
