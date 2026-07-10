# ToStore ResultStatus Specifica di Diagnostica Automatica & Risoluzione dello Stato

Per consentire alle operazioni automatizzate (Ops), agli agenti di intelligenza artificiale (IA), agli script di test automatizzati e alle applicazioni client di identificare accuratamente i vari risultati di esecuzione del database e gli stati di eccezione, ToStore introduce un sistema strutturato di `ResultStatus` nella sua ultima versione.

Questo documento di specifica descrive in dettaglio i principi di progettazione dei codici di stato, le specifiche delle chiavi degli identificatori semantici e le strutture dei campi dedicati dei vari tipi di stato per aiutare gli utenti del database e gli sviluppatori a implementare in modo indipendente la risoluzione dello stato.

---

## 1. Principi di Progettazione Fondamentali

### 1.1 Specifica Numerica del Codice di Stato (code)

Tutti i codici di stato numerici (`code`) sono definiti utilizzando una lunghezza fissa di 5 cifre (ad eccezione dello stato di successo):

- **Stato di Successo (Codice di successo speciale)**: Specificamente fissato a `0`.
- **Altri Stati (Codici di errore e diagnostici)**: Uniformati a 5 cifre.
- **Codice di Classe**: Le prime due cifre del codice di stato, utilizzate per identificare rapidamente la categoria principale.
- **Codice Foglia**: Le ultime tre cifre del codice di stato, che rappresentano lo scenario di errore specifico.

> [!TIP]
> Durante lo sviluppo di Ops automatizzate, agenti di IA o script di test esterni, gli sviluppatori possono instradare ai relativi gestori di eccezioni utilizzando le prime due cifre (Codice di classe) o l'intervallo, per poi eseguire una gestione dettagliata in base al Codice foglia.

> [!IMPORTANT]
> **Migliore Pratica per il Controllo in Memoria**:
> Quando si leggono i risultati delle operazioni del database in memoria (ad esempio, nel codice client o Dart/Flutter), **il metodo più consigliato ed efficiente è utilizzare direttamente le proprietà in sola lettura (getter) integrate** di `ResultStatus` o `ResultType` (come `isBusinessError`, `isCriticalError`, ecc., vedere la [Sezione 3.2](#32-getter-di-utilità-in-memoria)), evitando l'analisi manuale degli intervalli numerici o il confronto dei prefissi delle stringhe.

### 1.2 Specifica dell'Identificativo Semantico dello Stato (codeKey)

Ciascun stato corrisponde a un identificativo stringa univoco `codeKey`:

- **Formato del Nome**: `[Prefisso_Categoria_Principale]_[Identificatore_Dettaglio_Multilivello]`.
- **Regola del Nome**: Composto da lettere maiuscole inglesi e trattini bassi `_`, senza spazi o caratteri speciali.
- **Prefisso Categoria Principale**: Indica a quale categoria di business principale appartiene lo stato. Se esistono più livelli di categoria, il prefijo più generico viene posizionato all'inizio per facilitare la ricerca dei prefissi e il filtraggio degli intervalli.

---

## 2. Tabella di Riferimento Rapido dei Codici di Classe

Di seguito è riportata la definizione di mappatura di tutti i Codici di classe in ToStore:

| Intervallo di Codice | Codice di Classe (Prime 2 cifre) | Prefisso Semantico | Categoria | Strategia di Eccezione |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `00` | `SUCCESS` | **Operazione riuscita** | Non genera eccezioni, ritorna normalmente. |
| `10000 - 19999` | `10 - 19` | `BIZ_` | **Errore Aziendale** (Errori di input dell'utente finale, ad esempio violazione dei vincoli) | Non genera eccezioni, risponde sempre tramite `DbResult` o `QueryResult`. |
| `20000 - 49999` | `20 - 49` | `DEV_` | **Errore dello Sviluppatore** (Parametri API non validi, configurazione dello schema della tabella non valida, ecc.) | **Genera direttamente una `DbException` in ambienti di debug** per avvisare gli sviluppatori; **ritorna normalmente come risultato negli ambienti di produzione**. *(Nota: l'incompatibilità della versione del motore e gli errori di esecuzione dei batch di migrazione principali sono errori critici, che generano eccezioni anche in produzione)* |
| `50000 - 79999` | `50 - 79` | `SYS_` | **Errore di Sistema** (Disco pieno, eccezioni di I/O, timeout di acquisizione del blocco, ecc.) | Genera un'eccezione quando la normale esecuzione è bloccata; altri (ad esempio, conflitto di transazioni) vengono restituiti come risultati. |
| `99000 - 99999` | `99` | `ENG_` | **Errore del Motore** (Errore logico del motore, corruzione del file di dati, errore interno sconosciuto) | In genere non genera eccezioni; genera eccezioni per casi gravi. |

---

## 3. Struttura dei Campi Comuni di ResultStatus e Aiuti in Memoria

### 3.1 Campi Comuni (Struttura JSON Serializzata)

Tutti i tipi di `ResultStatus`, quando serializzati in JSON, contengono i seguenti 4 campi comuni di base. Gli utenti possono leggere questi campi direttamente per controlli preliminari.

| Campo | Tipo | Descrizione |
| :--- | :--- | :--- |
| `index` | `int` | Indice di sequenza nelle operazioni batch. Per le operazioni singole, questo valore è fisso a `0`. |
| `code` | `int` | Codice di stato numerico (`0` per successo, numero a 5 cifre per eccezioni). |
| `codeKey` | `String` | Chiave dell'identificatore semantico dello stato, ad esempio `CONSTRAINT_VIOLATION_UNIQUE`. |
| `message` | `String` | Descrizione dettagliata dello stato leggibile dall'uomo. |

### 3.2 Getter di Utilità in Memoria

In Dart/Flutter, `ResultStatus` e `ResultType` incapsulano proprietà in sola lettura (Getter) altamente efficienti in `O(1)` per verificare la categoria e la gravità in memoria senza controlli manuali dell'intervallo o confronto di stringhe:

| Proprietà | Tipo | Descrizione |
| :--- | :--- | :--- |
| `isBusinessError` | `bool` | Indica se si tratta di un **Errore Aziendale** (ad esempio, conflitto di vincoli, errore di cast; intervallo `10000 - 19999`). |
| `isDeveloperError` | `bool` | Indica se si tratta di un **Errore dello Sviluppatore** (ad esempio, schema non valido, discrepanza dei parametri, tabella non trovata; intervallo `20000 - 49999`). |
| `isSystemError` | `bool` | Indica se si tratta di un **Errore di Sistema** (ad esempio, timeout del blocco, disco pieno, blocco dei file; intervallo `50000 - 79999`). |
| `isEngineError` | `bool` | Indica se si tratta di un **Errore del Motore** (intervallo `99000 - 99999`). |
| `isCriticalError` | `bool` | Indica se si tratta di un **Errore Critico / Evento a livello di disastro** (richiede un intervento manuale o operativo, ad esempio disco pieno, memoria insufficiente, grave corruzione del file di dati, errore di migrazione incompatibile, ecc.). |

---

## 4. Strutture di Risoluzione Dettagliate e Campi Dedicati

A seconda dell'intervallo di `code` / `codeKey` e della sottoclasse specifica di `ResultStatus`, la struttura JSON serializzata trasporterà diversi **campi diagnostici dedicati**. Di seguito sono riportate le specifiche dei campi e la mappatura delle applicazioni per le 5 sottoclassi di stato.

### 4.1 SuccessStatus (Operazione riuscita)

- **Intervallo di Categoria**: `code == 0`, `codeKey == "SUCCESS"`
- **Scenario Applicabile**: Record inseriti, modificati o eliminati con successo.
- **Definizione del Campo Dedicato**:

  | Campo | Tipo | Dettagli |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Opzionale**. Restituito solo nelle scritture su riga singola (ad esempio, `insert`) o aggiornamenti (ad esempio, `update`) rappresentando la chiave primaria del record fisicamente generato o modificato. |

- **Esempio JSON**:
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

### 4.2 ConstraintStatus (Integrità dei dati & conflitti di vincoli)

- **Intervallo di Categoria**: `code` all'interno di `[10000, 19999]` (principalmente conflitti di validazione e vincoli di integrità).
- **Definizione del Campo Dedicato**:

  | Campo | Tipo | Dettagli |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Richiesto**. Nome della tabella in cui si è verificato il conflitto del vincolo di integrità o l'errore di non trovato. |
  | `constraintName` | `String?` | **Opzionale**. Il nome del vincolo specifico che ha causato l'errore (ad esempio, `fk_users_profile` per chiave esterna, nome dell'indice per conflitto di univocità o `null` per errori not-null o di cast). |
  | `fields` | `List<String>` | **Richiesto**. Elenco dei campi che causano il conflitto. |
  | `conflictingKeys` | `List<dynamic>` | **Richiesto**. Elenco dei valori di input che causano il conflitto, mappati 1:1 con `fields`. Se un campo è nullo, l'elemento corrispondente nell'elenco è `null`. |
  | `primaryKey` | `String?` | **Opzionale**. Chiave primaria del record associato. Se non si tratta di una scrittura su riga singola, o se è stata bloccata nella fase di memoria, sarà `null`. |
  | `referencedTable` | `String?` | **Opzionale**. Nome della tabella principale nei conflitti di chiave esterna. |

- **Linee Guida per i Codici Foglia**:

  | Codice & ResultType | Scenario | Linee Guida per i Campi |
  | :--- | :--- | :--- |
  | `10000`<br>`bizValidationFailed` | Convalida del formato dei dati o dell'intervallo non riuscita | <ul><li>`tableName`: Tabella interessata</li><li>`constraintName`: `null`</li><li>`fields`: Campi che violano la convalida, ad esempio `["email"]`</li><li>`conflictingKeys`: Valori non validi che causano l'errore, ad esempio `["invalid-email"]`</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |
  | `10001`<br>`bizNotNullViolation` | Violazione del vincolo not null | <ul><li>`tableName`: Tabella interessata</li><li>`constraintName`: `null`</li><li>`fields`: Campi che violano la restrizione not-null, ad esempio `["email"]`</li><li>`conflictingKeys`: Sempre `[null]`</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |
  | `10002`<br>`bizTypeCastFailed` | Conversione del tipo di dati o cast non riuscito | <ul><li>`tableName`: Tabella interessata</li><li>`constraintName`: `null`</li><li>`fields`: Campi per cui il cast non è riuscito, ad esempio `["age"]`</li><li>`conflictingKeys`: Valori non validi che causano l'errore, ad esempio `["not_a_number"]`</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |
  | `11001`<br>`bizPrimaryKeyViolation` | Conflitto di chiave primaria (esiste già) | <ul><li>`tableName`: Tabella interessata</li><li>`constraintName`: `"PRIMARY"` o il nome del vincolo</li><li>`fields`: Campi di chiave primaria, ad esempio `["id"]`</li><li>`conflictingKeys`: Valori duplicati, ad esempio `["usr_101"]`</li><li>`primaryKey`: Valore in conflitto, ad esempio `"usr_101"`</li></ul> |
  | `11002`<br>`bizUniqueViolation` | Violazione del vincolo di univocità | <ul><li>`tableName`: Tabella interessata</li><li>`constraintName`: Nome dell'indice unico, ad esempio `"uk_email"`</li><li>`fields`: Campi che compongono l'univocità, ad esempio `["email"]`</li><li>`conflictingKeys`: Valori che causano il conflitto, ad esempio `["test@a.com"]`</li><li>`primaryKey`: Chiave primaria del record in conflitto (se presente)</li></ul> |
  | `11003`<br>`bizForeignKeyViolation` | Violazione del vincolo di chiave esterna (Generico) | <ul><li>`tableName`: Tabella figlio (secondaria)</li><li>`constraintName`: Nome del vincolo di chiave esterna</li><li>`fields`: Colonne di chiave esterna</li><li>`conflictingKeys`: Valori di input che causano il conflitto</li><li>`primaryKey`: Chiave primaria del record (se presente)</li><li>`referencedTable`: Tabella padre (principale)</li></ul> |
  | `11004`<br>`bizCheckViolation` | Violazione del vincolo check | <ul><li>`tableName`: Tabella interessata</li><li>`constraintName`: Nome del vincolo check</li><li>`fields`: Campi controllati</li><li>`conflictingKeys`: Valori che violano il check</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |
  | `11005`<br>`bizForeignKeyParentNotExist` | La chiave padre referenziata non esiste | <ul><li>`tableName`: Tabella figlio (secondaria)</li><li>`constraintName`: Nome del vincolo di chiave esterna</li><li>`fields`: Colonne di chiave esterna, ad esempio `["userId"]`</li><li>`conflictingKeys`: Valore di riferimento non esistente, ad esempio `["non_parent"]`</li><li>`primaryKey`: Chiave primaria del record (se presente)</li><li>`referencedTable`: Tabella padre (principale)</li></ul> |
  | `11006`<br>`bizForeignKeyChildRestrict` | Eliminazione/aggiornamento limitato dai record figlio | <ul><li>`tableName`: Tabella padre (principale)</li><li>`constraintName`: Nome del vincolo di chiave esterna</li><li>`fields`: Colonne referenziate della tabella padre</li><li>`conflictingKeys`: Valori di chiave padre referenziati dalla tabella figlio</li><li>`primaryKey`: Valori della chiave padre</li><li>`referencedTable`: Tabella figlio (secondaria)</li></ul> |
  | `11007`<br>`bizForeignKeyCompositeMismatch` | Valori di chiave esterna composta incompleti | <ul><li>`tableName`: Tabella figlio (secondaria)</li><li>`constraintName`: Nome del vincolo di chiave esterna</li><li>`fields`: Colonne di chiave esterna composta</li><li>`conflictingKeys`: Valori di input (contiene valori nulli parziali)</li><li>`primaryKey`: Chiave primaria del record (se presente)</li><li>`referencedTable`: Tabella padre (principale)</li></ul> |
  | `11008`<br>`bizForeignKeyTypeMismatch` | Discrepanza di tipo di chiave esterna | <ul><li>`tableName`: Tabella figlio (secondaria)</li><li>`constraintName`: Nome del vincolo di chiave esterna</li><li>`fields`: Colonne di chiave esterna</li><li>`conflictingKeys`: Valori per cui il cast non è riuscito</li><li>`primaryKey`: Chiave primaria del record (se presente)</li><li>`referencedTable`: Tabella padre (principale)</li></ul> |
  | `11009`<br>`bizValueExceedsMaxLength` | La lunghezza del valore supera il vincolo massimo | <ul><li>`tableName`: Tabella interessata</li><li>`constraintName`: `null`</li><li>`fields`: Campi che violano il limite, ad esempio `["name"]`</li><li>`conflictingKeys`: Valori che superano il limite, ad esempio `["a" * 1000]`</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |
  | `11010`<br>`bizValueLessThanMinLength` | La lunghezza del valore è inferiore al vincolo minimo | <ul><li>`tableName`: Tabella interessata</li><li>`constraintName`: `null`</li><li>`fields`: Campi che violano il limite, ad esempio `["code"]`</li><li>`conflictingKeys`: Valori più corti del minimo, ad esempio `["ab"]`</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |
  | `11011`<br>`bizValueLessThanMinValue` | Il valore numerico è inferiore al vincolo minimo | <ul><li>`tableName`: Tabella interessata</li><li>`constraintName`: `null`</li><li>`fields`: Campi che violano il limite, ad esempio `["age"]`</li><li>`conflictingKeys`: Valori inferiori al minimo, ad esempio `[-5]`</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |
  | `11012`<br>`bizValueExceedsMaxValue` | Il valore numerico supera il vincolo massimo | <ul><li>`tableName`: Tabella interessata</li><li>`constraintName`: `null`</li><li>`fields`: Campi che violano il limite, ad esempio `["score"]`</li><li>`conflictingKeys`: Valori che superano il massimo, ad esempio `[105]`</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |
  | `12002`<br>`bizRecordNotFound` | La risorsa non esiste / Record non trovato | <ul><li>`tableName`: Tabella interessata</li><li>`constraintName`: `null`</li><li>`fields`: Campi di ricerca target, ad esempio `["id"]`</li><li>`conflictingKeys`: Chiavi target non trovate, ad esempio `["non_exist_id"]`</li><li>`primaryKey`: Valore della chiave mancante, ad esempio `"non_exist_id"`</li></ul> |

- **Esempio JSON** (Il record padre della chiave esterna non esiste):
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

### 4.3 SchemaValidationStatus (Validazione dello schema della tabella & migrazione incompatibile)

- **Intervallo di Categoria**: `code` all'interno di `[30000, 39999]` (errori di verifica della configurazione dello schema e incoerenze di migrazione fisica).
- **Definizione del Campo Dedicato**:

  | Campo | Tipo | Dettagli |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Richiesto**. Nome della tabella che si sta validando o migrando fisicamente. |
  | `field` | `String?` | **Opzionale**. Il nome del campo specifico che ha causato l'errore di schema o migrazione. |
  | `wrongValue` | `dynamic` | **Opzionale**. Valore di configurazione non valido o configurazione di differenza di migrazione che causa il conflitto. |

- **Linee Guida per i Codici Foglia**:

  | Codice & ResultType | Scenario | Linee Guida per i Campi |
  | :--- | :--- | :--- |
  | `30000`<br>`devInvalidSchema` | Definizione dello schema della tabella non valida | <ul><li>`tableName`: Nome della tabella</li><li>`field`: `null`</li><li>`wrongValue`: Map di configurazione non valida, o `null`</li></ul> |
  | `30001`<br>`devInvalidSchemaTableName` | Convalida del nome della tabella non riuscita (caratteri non validi o troppo lungo) | <ul><li>`tableName`: Nome non valido</li><li>`field`: `null`</li><li>`wrongValue`: Stringa non valida</li></ul> |
  | `30002`<br>`devInvalidSchemaFieldName` | Convalida del nome del campo non riuscita (caratteri non validi) | <ul><li>`tableName`: Nome della tabella</li><li>`field`: Nome del campo non valido</li><li>`wrongValue`: Stringa non valida</li></ul> |
  | `30003`<br>`devInvalidSchemaPrimaryKey` | Convalida della chiave primaria non riuscita (mancante o formato non valido) | <ul><li>`tableName`: Nome della tabella</li><li>`field`: `"primaryKey"` o nome del campo della chiave primaria</li><li>`wrongValue`: Dettagli di configurazione della chiave primaria</li></ul> |
  | `30004`<br>`devInvalidSchemaIndexLimit` | Il numero degli indici della tabella supera il limite del sistema di 16 | <ul><li>`tableName`: Nome della tabella</li><li>`field`: `null`</li><li>`wrongValue`: Elenco delle configurazioni degli indici</li></ul> |
  | `30005`<br>`devSchemaTableExists` | La tabella esiste già | <ul><li>`tableName`: Nome della tabella</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30006`<br>`devSchemaFieldExists` | Aggiornamento dello schema: aggiunta di un campo esistente | <ul><li>`tableName`: Nome della tabella</li><li>`field`: Nome del campo in conflitto</li><li>`wrongValue`: `null`</li></ul> |
  | `30007`<br>`devSchemaIndexExists` | Aggiornamento dello schema: aggiunta di un indice esistente | <ul><li>`tableName`: Nome della tabella</li><li>`field`: Nome dell'indice</li><li>`wrongValue`: `null`</li></ul> |
  | `30008`<br>`devInvalidSchemaForeignKey` | Definizione di chiave esterna non valida (ad esempio, discrepanza di colonne) | <ul><li>`tableName`: Nome della tabella</li><li>`field`: Nome della chiave esterna</li><li>`wrongValue`: Dettagli di configurazione della chiave esterna</li></ul> |
  | `30009`<br>`devInvalidSchemaSpaceMismatch` | Discrepanza di limite globale/specifico dello spazio | <ul><li>`tableName`: Nome della tabella</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30010`<br>`devMigrationNotAllowedWithData` | La migrazione richiede la modifica dei dati e non è stata esplicitamente consentita | <ul><li>`tableName`: Nome della tabella</li><li>`field`: `null`</li><li>`wrongValue`: Map delle differenze di aggiornamento della migrazione</li></ul> |
  | `30011`<br>`devMigrationUnsafeTypeConversion` | Migrazione fisica: conversione del tipo non supportata per il campo | <ul><li>`tableName`: Nome della tabella</li><li>`field`: Nome del campo</li><li>`wrongValue`: Map dei tipi in conflitto, ad esempio `{ "from": "text", "to": "integer" }`</li></ul> |
  | `30013`<br>`devMigrationCannotAddNonNullField` | Impossibile aggiungere un campo non-nullable senza un valore predefinito a una tabella non vuota | <ul><li>`tableName`: Nome della tabella</li><li>`field`: Nome del campo non valido</li><li>`wrongValue`: Parametri di migrazione, ad esempio `{ "nullable": false, "defaultValue": null }`</li></ul> |
  | `30014`<br>`devMigrationNullableToNonNullNotAllowed` | Migrazione fisica: modifica del campo da nullable a non-nullable | <ul><li>`tableName`: Nome della tabella</li><li>`field`: Nome del campo</li><li>`wrongValue`: Parametri di migrazione, identico a 30013</li></ul> |
  | `30015`<br>`devMigrationUniqueTighteningNotAllowed` | Migrazione fisica: restrizione del vincolo del campo a UNIQUE | <ul><li>`tableName`: Nome della tabella</li><li>`field`: Nome del campo</li><li>`wrongValue`: Definizione dell'indice che causa il vincolo unico</li></ul> |
  | `30016`<br>`devInvalidSchemaTtlConfig` | Convalida della configurazione TTL non riuscita | <ul><li>`tableName`: Nome della tabella</li><li>`field`: Campo data/ora TTL</li><li>`wrongValue`: Map di configurazione TTL non valida, ad esempio, `{ "enabled": true, "fieldName": "expire_at" }`</li></ul> |
  | `30017`<br>`devInvalidSchemaDuplicateFieldName` | Nome di campo duplicato nello schema della tabella | <ul><li>`tableName`: Nome della tabella</li><li>`field`: Nome di campo duplicato</li><li>`wrongValue`: `null`</li></ul> |
  | `30018`<br>`devInvalidSchemaIndexField` | L'indice fa riferimento a un campo inesistente | <ul><li>`tableName`: Nome della tabella</li><li>`field`: Nome dell'indice</li><li>`wrongValue`: Nome del campo che causa la discrepanza</li></ul> |

- **Esempio JSON** (Aggiunta di un campo non-nullable senza valore predefinito a una tabella non vuota):
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

### 4.4 InvalidArgumentStatus (Argomenti dell'API & validazione della paginazione tramite cursore)

- **Intervallo di Categoria**: `code` all'interno di `[20000, 20999]` (errori di validazione dei parametri dell'API, delle strutture di query o dei token di paginazione).
- **Definizione del Campo Dedicato**:

  | Campo | Tipo | Dettagli |
  | :--- | :--- | :--- |
  | `parameterName` | `String` | **Richiesto**. Nome dell'argomento che ha causato l'errore di validazione (ad esempio `"cursor"`, `"orderBy"`, o una chiave di colonna specifica). |
  | `passedValue` | `dynamic` | **Opzionale**. Valore di input non conforme passato dal chiamante. Gli oggetti complessi vengono convertiti in stringhe. |
  | `primaryKey` | `String?` | **Opzionale**. Chiave primaria del record associato. |

- **Linee Guida per i Codici Foglia**:

  | Codice & ResultType | Scenario | Linee Guida per i Campi |
  | :--- | :--- | :--- |
  | `20001`<br>`devInvalidArgumentFormat` | Erreur di formato dell'argomento | <ul><li>`parameterName`: Nome dell'argomento non valido</li><li>`passedValue`: Valore passato, ad esempio `"twenty"`</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |
  | `20002`<br>`devInvalidArgumentType` | Discrepanza di tipo dell'argomento | <ul><li>`parameterName`: Nome del parametro</li><li>`passedValue`: Valore passato, ad esempio `{"foo": "bar"}` (quando si attende String)</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |
  | `20003`<br>`devInvalidArgumentMissing` | L'argomento richiesto è mancante | <ul><li>`parameterName`: Nome del parametro mancante, ad esempio `"dbPath"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |
  | `20005`<br>`devInvalidPrimaryKeyFormat` | Formato della chiave primaria non valido | <ul><li>`parameterName`: `"primaryKey"` o campo della chiave primaria</li><li>`passedValue`: Valore di chiave primaria non valido, ad esempio, `"invalid_id_value"`</li><li>`primaryKey`: Valore di chiave primaria non valido</li></ul> |
  | `20010`<br>`devVectorDimensionMismatch` | Discrepanza delle dimensioni del vettore | <ul><li>`parameterName`: `"other"`</li><li>`passedValue`: Dimensione non valida della dimensione</li><li>`primaryKey`: `null`</li></ul> |
  | `20011`<br>`devIndexFieldMissing` | Campo dell'indice richiesto mancante nel record per il cursore | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Campo dell'indice mancante</li><li>`primaryKey`: `null`</li></ul> |
  | `20201`<br>`devInvalidCursorPagination` | La paginazione tramite cursore e l'offset si escludono a vicenda | <ul><li>`parameterName`: `"cursor"` / `"offset"`</li><li>`passedValue`: Parametri di paginazione in conflitto</li><li>`primaryKey`: `null`</li></ul> |
  | `20202`<br>`devInvalidCursorTable` | Il cursore non corrisponde alla tabella target | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Token del cursore</li><li>`primaryKey`: `null`</li></ul> |
  | `20203`<br>`devInvalidCursorSignature` | Discrepanza nella firma del cursore (manomesso) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Token del cursore</li><li>`primaryKey`: `null`</li></ul> |
  | `20204`<br>`devInvalidCursorOrderBy` | Configurazione orderBy del cursore non valida o non corrispondente | <ul><li>`parameterName`: `"orderBy"`</li><li>`passedValue`: Elenco orderBy, ad esempio `["-age", "id"]`</li><li>`primaryKey`: `null`</li></ul> |
  | `20205`<br>`devInvalidCursorMode` | Discrepanza nel modo del token del cursore | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Modo del token, ad esempio, `"sortKey"`</li><li>`primaryKey`: `null`</li></ul> |
  | `20206`<br>`devInvalidCursorPayload` | Payload del cursore non valido (non decodificabile) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: `null`</li></ul> |
  | `20301`<br>`devInvalidQuerySelectField` | Il campo di selezione della query deve essere String o QueryAggregation | <ul><li>`parameterName`: `"select"`</li><li>`passedValue`: Definizione del campo select non valida</li><li>`primaryKey`: `null`</li></ul> |
  | `20302`<br>`devInvalidQueryForeignKeyJoin` | Nessuna relazione di chiave esterna per l'auto-join | <ul><li>`parameterName`: `"join"` / `"tableName"`</li><li>`passedValue`: Tabella target priva di relazione</li><li>`primaryKey`: `null`</li></ul> |
  | `20303`<br>`devInvalidQueryFieldAlias` | Formato dell'alias del campo della query non valido | <ul><li>`parameterName`: `"alias"`</li><li>`passedValue`: Stringa di alias non valida</li><li>`primaryKey`: `null`</li></ul> |
  | `20304`<br>`devInvalidExpression` | Configurazione dell'espressione non valida o eccezione di esecuzione | <ul><li>`parameterName`: Aspetto dell'errore (ad esempio `"arguments"`, `"functionName"`, `"node"`)</li><li>`passedValue`: Valore o conteggio non valido</li><li>`primaryKey`: `null`</li></ul> |
  | `22005`<br>`devFieldNotFound` | Campo non trovato | <ul><li>`parameterName`: Nome del campo sconosciuto, ad esempio `"extra"`</li><li>`passedValue`: Valore di input passato per il campo</li><li>`primaryKey`: Chiave primaria del record (se presente)</li></ul> |

- **Esempio JSON** (I campi orderBy del cursore non corrispondono alla query attuale orderBy):
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

### 4.5 TransactionOperationStatus (Conflitto e interruzione di transazione)

- **Intervallo di Categoria**: `code` all'interno di `[50000, 50999]` (rollback di transazione, interruzione esplicita o conflitti di serializzabilità).
- **Definizione del Campo Dedicato**:

  | Campo | Tipo | Dettagli |
  | :--- | :--- | :--- |
  | `txId` | `String` | **Richiesto**. Identificatore di flusso di transazione univoco a livello globale. Utilizzato per tracciare il ciclo di vita della transazione. |

- **Linee Guida per i Codici Foglia**:

  | Codice & ResultType | Scenario | Linee Guida per i Campi |
  | :--- | :--- | :--- |
  | `50001`<br>`sysTransactionAborted` | Transazione interrotta (rollback esplicito o errore in cascata) | <ul><li>`txId`: ID della transazione attiva</li></ul> |
  | `50002`<br>`sysTransactionConflict` | Conflitto di transazione (aggiornamenti simultanei sulla stessa chiave in SSI/WAL) | <ul><li>`txId`: ID della transazione in conflitto</li></ul> |

- **Esempio JSON** (Conflitto di scrittura-scrittura simultaneo SSI):
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

### 4.6 GeneralStatus (Eccezioni generiche e a livello di sistema)

- **Intervallo di Categoria**: Fallback per qualsiasi altro codice di stato (I/O a basso livello, errori hardware, timeout di sistema, ecc.).
- **Definizione del Campo Dedicato**:

  | Campo | Tipo | Dettagli |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Opzionale**. Chiave primaria del record associato. |
  | `target` | `String?` | **Opzionale**. Risorsa fisica target, ad esempio percorsi di file fisici, blocchi o URL. |
  | `operation` | `String?` | **Opzionale**. Nome della chiamata di sistema attiva, ad esempio `'readAsString'`, `'delete'`, `'acquire'`. |

- **Linee Guida per i Codici Foglia**:

  | Codice & ResultType | Scenario / Livello | Linee Guida per i Campi |
  | :--- | :--- | :--- |
  | `20007`<br>`devIndexOutOfBounds` | L'indice o l'intervallo è fuori dai limiti (Errore dello sviluppatore) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `20008`<br>`devUnsupportedOperation` | L'operazione non è supportata nel contesto corrente (Errore dello sviluppatore) | <ul><li>`primaryKey`: `null`</li><li>`target`: Tabella/risorsa target (se presente)</li><li>`operation`: Nome del metodo (se presente)</li></ul> |
  | `22001`<br>`devTableNotFound` | Tabella non trovata (Errore dello sviluppatore) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22003`<br>`devIndexNotFound` | Indice non trovato (Errore dello sviluppatore) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22004`<br>`devSpaceNotFound` | Spazio non trovato (Errore dello sviluppatore) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23001`<br>`devLargeScaleOperationBypassRequired` | Salto dei dettagli richiesto per evitare OOM (Errore dello sviluppatore) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `24001`<br>`devEngineIncompatible` | **Critico**: Versione del motore incompatibile | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50003`<br>`sysTransactionLimitExceeded` | I dati memorizzati nel buffer della transazione superano il limite sicuro sotto pressione di memoria (Errore di sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50004`<br>`sysMigrationBatchExecutionFailed` | Errore di esecuzione del batch di migrazione (Errore di sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51001`<br>`sysTimeoutLockAcquisition` | Timeout di acquisizione del blocco (Errore di sistema) | <ul><li>`primaryKey`: Chiave target (se presente)</li><li>`target`: ID della risorsa di blocco</li><li>`operation`: `"acquire"`</li></ul> |
  | `51002`<br>`sysTimeout` | Timeout dell'operazione (Errore di sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51003`<br>`sysDbClosed` | Il database è chiuso, l'operazione è stata annullata in modo sicuro (Errore di sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52001`<br>`sysResourceExhaustedMemory` | Risorse di memoria esaurite (Errore di sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52002`<br>`sysResourceExhausted` | Risorse di sistema esaurite, ad esempio disco pieno (Errore di sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `53001`<br>`sysIoNotFound` | Il file o il percorso fisico non esiste (Errore di sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Percorso del file o della cartella</li><li>`operation`: Operazione di I/O</li></ul> |
  | `53002`<br>`sysIoPermissionDenied` | Autorizzazione negata per l'accesso al file (Errore di sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Percorso del file</li><li>`operation`: Operazione di I/O</li></ul> |
  | `53003`<br>`sysIoDiskFull` | Disco pieno o quota di archiviazione superata (Errore di sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Percorso del file</li><li>`operation`: Operazione di I/O</li></ul> |
  | `53004`<br>`sysIoFileLocked` | Il file è bloccato o in uso da un altro processo (Errore di sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Percorso del file</li><li>`operation`: Operazione di I/O</li></ul> |
  | `53005`<br>`sysIoDeviceFault` | Errore del dispositivo o del supporto di archiviazione (Errore di sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Percorso del file</li><li>`operation`: Operazione di I/O</li></ul> |
  | `53006`<br>`sysIoWebStorageUnavailable` | IndexedDB Web o archiviazione non disponibile (Errore di sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Risorsa IndexedDB</li><li>`operation`: Operazione di I/O</li></ul> |
  | `53007`<br>`sysBackupCorrupted` | Il pacchetto di backup è danneggiato o mancano i metadati (Errore di sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Percorso di backup</li><li>`operation`: Lettura/scrittura del backup</li></ul> |
  | `53008`<br>`sysIoDataCorrupted` | Il file di dati del database è danneggiato o la checksum è fallita (Errore di sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Percorso del file di dati</li><li>`operation`: Operazione di I/O</li></ul> |
  | `53009`<br>`sysInvalidDataFormat` | Formattazione o analisi del flusso di dati fallita (Errore di sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Chiave del flusso di dati</li><li>`operation`: `"decode"` / `"deserialize"`</li></ul> |
  | `53099`<br>`sysIoGeneric` | Errore generico di I/O di sistema (Errore di sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Percorso del file</li><li>`operation`: Operazione di I/O</li></ul> |
  | `99001`<br>`engError` | Errore del motore (Errore del motore) | <ul><li>`primaryKey`: `null`</li></ul> |

- **Esempio JSON** (Errore di tabella non trovata):
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

## 5. Raccomandazioni per la Risoluzione dello Stato & la Gestione delle Eccezioni per gli Utenti (Esempi in Dart/Flutter)

In ToStore, tutte le operazioni di scrittura principali (Insert, Update, Delete) restituiscono un `DbResult`. Le query restituiscono un `QueryResult` e le operazioni di transazione restituiscono un `TransactionResult`. Gli errori di configurazione strutturale generano una `DbException`.

Di seguito sono riportati esempi di codice che illustrano come le applicazioni client dovrebbero consumare, analizzare e gestire in modo pulito gli stati del database:

### 5.1 Gestione delle Risposte di Scrittura (`DbResult`)

```dart
import 'package:tostore/tostore.dart';

void handleDatabaseWriteResult(DbResult result) {
  // 1. Verificare istantaneamente se la scrittura è stata completata interamente senza errori
  if (!result.hasErrors) {
    print("Tutte le operazioni di scrittura sono cambiate con successo. Interessati: ${result.successCount}");

    // Per le scritture su riga singola, recuperare direttamente la chiave senza iterare gli stati
    if (result.firstPrimaryKey != null) {
      print("Chiave primaria del primo record riuscito: ${result.firstPrimaryKey}");
    }
  } else {
    print("🛑 Errore rilevato. Riusciti: ${result.successCount}, Falliti: ${result.failedCount}");
    print("Primo errore: ${result.firstType.codeKey} (${result.firstType.code})");

    // 2. Iterare gli stati (l'indice si allinea 1:1 con l'array batch di input)
    for (final status in result.statuses) {
      final int idx = status.index;

      // 3. Pattern matching sulle sottoclassi per instradare la logica di gestione
      if (status is SuccessStatus) {
        print("Index [$idx] Riuscito. Chiave primaria: ${status.primaryKey}");
      } 
      else if (status is ConstraintStatus) {
        // Gestire la violazione dei vincoli (chiave primaria, univocità, check, chiave esterna, ecc.)
        print("Index [$idx] Violazione del vincolo! Tabella: ${status.tableName}, Colonne: ${status.fields}");
        print("Valori in conflitto: ${status.conflictingKeys}, PK: ${status.primaryKey}");
        print("Messaggio di errore: ${status.message}");
      } 
      else if (status is InvalidArgumentStatus) {
        // Gestire gli errori dei parametri
        print("Index [$idx] Parametro non valido! Parametro: ${status.parameterName}, Valore passato: ${status.passedValue}");
      } 
      else if (status is GeneralStatus) {
        // Gestire timeout del blocco, disco pieno, problemi di I/O di sistema, ecc.
        print("Index [$idx] Eccezione generica! Codice: ${status.code} (${status.codeKey})");
        print("Messaggio: ${status.message}");
      }
    }
  }
}
```

### 5.2 Intercettazione dello Schema della Tabella e dell'Eccezione di Operazione (`DbException`)

Per la creazione di tabelte (`createTable`) o modifiche dello schema (`updateSchema`), o in casi in cui le definizioni di schema falliscono i controlli a livello di codice, ToStore genera una `DbException` in produzione:

```dart
try {
  // Apertura del database con aggiornamenti dello schema
  await ToStore.open(schemas: [..]);
} on DbException catch (e) {
  print("❌ Eccezione fatale del database! Errore aggregato: \n${e.message}");
  
  // Iterare attraverso i singoli stati nell'eccezione
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // Problemi del validatore di schema
      print("Validazione dello schema fallita! Tabella: ${status.tableName}");
      if (status.field != null) {
        print("Campo non valido: ${status.field}, Configurazione non valida: ${status.wrongValue}");
      }
    } else {
      print("Diagnostica: [${status.codeKey}] (Code ${status.code}): ${status.message}");
    }
  }
}
```

### 5.3 Gestione delle Operazioni di Query (`QueryResult`) & Controlli di Transazione (`TransactionResult`)

- **Per le Query**:
  ```dart
  final queryResult = await db.query('users').where('age', '>', 18);
  if (queryResult.hasErrors) {
    // Gestire le eccezioni della query (ad esempio cursore non valido, tabella mancante)
    print("Query fallita! Codice: ${queryResult.type.code}, Messaggio: ${queryResult.message}");
  } else {
    // Query eseguita con successo
    final List<Map<String, dynamic>> users = queryResult.data;
    print("Recuperati ${users.length} record. Ha altri dati: ${queryResult.hasMore}");
  }
  ```
- **Per le Transazioni**:
  ```dart
  final txnResult = await db.transaction(() async {
    await db.insert('users', newUser);
  });

  if (txnResult.hasErrors) {
    print("Transazione annullata! TxId: ${txnResult.txId}");
    // Recuperare i dettagli dei fallimenti delle singole sub-operazioni
    for (final status in txnResult.statuses) {
      if (status.type != ResultType.success) {
        print("Causa del fallimento: [${status.codeKey}] ${status.message}");
      }
    }
  }
  ```

---

## 6. Riferimento Completo dei Codici di Stato Foglia e degli Identificatori Semantici

Fare riferimento alla tabella seguente per l'instradamento e l'analisi dello stato esatti:

| Codice di Stato (Code) | Identificatore (CodeKey) | Enum in Memoria (ResultType) | Categoria | Descrizione |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `ResultType.success` | Successo | Operazione eseguita con successo |
| **10000** | `BIZ_VALIDATION_FAILED` | `ResultType.bizValidationFailed` | Errore Aziendale | Convalida del formato dei dati o dell'intervallo non riuscita |
| **10001** | `BIZ_NOT_NULL_VIOLATION` | `ResultType.bizNotNullViolation` | Errore Aziendale | Violazione del vincolo not null |
| **10002** | `BIZ_VALIDATION_TYPE_CAST` | `ResultType.bizTypeCastFailed` | Errore Aziendale | Conversione del tipo di dati o cast non riuscito |
| **11001** | `BIZ_CONSTRAINT_PRIMARY_KEY` | `ResultType.bizPrimaryKeyViolation` | Errore Aziendale | Conflitto di chiave primaria (esiste già) |
| **11002** | `BIZ_CONSTRAINT_UNIQUE` | `ResultType.bizUniqueViolation` | Errore Aziendale | Violazione del vincolo di univocità |
| **11003** | `BIZ_CONSTRAINT_FOREIGN_KEY` | `ResultType.bizForeignKeyViolation` | Errore Aziendale | Violazione del vincolo di chiave esterna (Generico) |
| **11004** | `BIZ_CONSTRAINT_CHECK` | `ResultType.bizCheckViolation` | Errore Aziendale | Violazione del vincolo check |
| **11005** | `BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST` | `ResultType.bizForeignKeyParentNotExist` | Errore Aziendale | La chiave padre referenziata non esiste |
| **11006** | `BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT` | `ResultType.bizForeignKeyChildRestrict` | Errore Aziendale | Eliminazione/aggiornamento limitato dai record figlio |
| **11007** | `BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH` | `ResultType.bizForeignKeyCompositeMismatch` | Erreur Aziendale | Valori di chiave esterna composta incompleti |
| **11008** | `BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH` | `ResultType.bizForeignKeyTypeMismatch` | Erreure Aziendale | Discrepanza di tipo di chiave esterna |
| **11009** | `BIZ_CONSTRAINT_MAX_LENGTH` | `ResultType.bizValueExceedsMaxLength` | Errore Aziendale | La lunghezza del valor supera il vincolo massimo |
| **11010** | `BIZ_CONSTRAINT_MIN_LENGTH` | `ResultType.bizValueLessThanMinLength` | Errore Aziendale | La lunghezza del valore è inferiore al vincolo minimo |
| **11011** | `BIZ_CONSTRAINT_MIN_VALUE` | `ResultType.bizValueLessThanMinValue` | Errore Aziendale | Il valore numerico è inferiore al vincolo minimo |
| **11012** | `BIZ_CONSTRAINT_MAX_VALUE` | `ResultType.bizValueExceedsMaxValue` | Errore Aziendale | Il valore numerico supera il vincolo massimo |
| **12002** | `BIZ_NOT_FOUND_RECORD` | `ResultType.bizRecordNotFound` | Errore Aziendale | La risorsa non esiste / Record non trovato |
| **20001** | `DEV_INVALID_ARGUMENT_FORMAT` | `ResultType.devInvalidArgumentFormat` | Errore dello Sviluppatore | Erreur di formato dell'argomento |
| **20002** | `DEV_INVALID_ARGUMENT_TYPE` | `ResultType.devInvalidArgumentType` | Errore dello Sviluppatore | Discrepanza di tipo dell'argomento |
| **20003** | `DEV_INVALID_ARGUMENT_MISSING` | `ResultType.devInvalidArgumentMissing` | Errore dello Sviluppatore | L'argomento richiesto è mancante |
| **20005** | `DEV_INVALID_PRIMARY_KEY_FORMAT` | `ResultType.devInvalidPrimaryKeyFormat` | Errore dello Sviluppatore | Formato della chiave primaria non valido |
| **20007** | `DEV_INDEX_OUT_OF_BOUNDS` | `ResultType.devIndexOutOfBounds` | Errore dello Sviluppatore | L'indice o l'intervallo è fuori dai limiti |
| **20008** | `DEV_UNSUPPORTED_OPERATION` | `ResultType.devUnsupportedOperation` | Errore dello Sviluppatore | L'operazione non è supportata nel contesto corrente |
| **20010** | `DEV_VECTOR_DIMENSION_MISMATCH` | `ResultType.devVectorDimensionMismatch` | Errore dello Sviluppatore | Discrepanza delle dimensioni del vettore |
| **20011** | `DEV_INDEX_FIELD_MISSING` | `ResultType.devIndexFieldMissing` | Errore dello Sviluppatore | Campo dell'indice richiesto mancante nel record per il cursore |
| **20201** | `DEV_INVALID_CURSOR_PAGINATION` | `ResultType.devInvalidCursorPagination` | Errore dello Sviluppatore | La paginazione tramite cursore e l'offset si escludono a vicenda |
| **20202** | `DEV_INVALID_CURSOR_TABLE` | `ResultType.devInvalidCursorTable` | Errore dello Sviluppatore | Il cursore non corrisponde alla tabella target |
| **20203** | `DEV_INVALID_CURSOR_SIGNATURE` | `ResultType.devInvalidCursorSignature` | Errore dello Sviluppatore | Discrepanza nella firma del cursore (manomesso) |
| **20204** | `DEV_INVALID_CURSOR_ORDERBY` | `ResultType.devInvalidCursorOrderBy` | Errore dello Sviluppatore | Configurazione orderBy del cursore non valida o non corrispondente |
| **20205** | `DEV_INVALID_CURSOR_MODE` | `ResultType.devInvalidCursorMode` | Errore dello Sviluppatore | Discrepanza nel modo del token del cursore |
| **20206** | `DEV_INVALID_CURSOR_PAYLOAD` | `ResultType.devInvalidCursorPayload` | Errore dello Sviluppatore | Payload del cursore non valido (non decodificabile) |
| **20301** | `DEV_INVALID_QUERY_SELECT_FIELD` | `ResultType.devInvalidQuerySelectField` | Errore dello Sviluppatore | Il campo di selezione della query deve essere String o QueryAggregation |
| **20302** | `DEV_INVALID_QUERY_FOREIGN_KEY_JOIN` | `ResultType.devInvalidQueryForeignKeyJoin` | Errore dello Sviluppatore | Nessuna relazione di chiave esterna per l'auto-join |
| **20303** | `DEV_INVALID_QUERY_FIELD_ALIAS` | `ResultType.devInvalidQueryFieldAlias` | Errore dello Sviluppatore | Formato dell'alias del campo della query non valido |
| **20304** | `DEV_INVALID_EXPRESSION` | `ResultType.devInvalidExpression` | Errore dello Sviluppatore | Configurazione dell'espressione non valida o eccezione di esecuzione |
| **22001** | `DEV_NOT_FOUND_TABLE` | `ResultType.devTableNotFound` | Errore dello Sviluppatore | Tabella non trovata |
| **22003** | `DEV_NOT_FOUND_INDEX` | `ResultType.devIndexNotFound` | Errore dello Sviluppatore | Indice non trovato |
| **22004** | `DEV_NOT_FOUND_SPACE` | `ResultType.devSpaceNotFound` | Errore dello Sviluppatore | Spazio non trovato |
| **22005** | `DEV_NOT_FOUND_FIELD` | `ResultType.devFieldNotFound` | Errore dello Sviluppatore | Campo non trovato |
| **23001** | `DEV_LARGE_SCALE_OPERATION_REQUIRED_BYPASS` | `ResultType.devLargeScaleOperationBypassRequired` | Errore dello Sviluppatore | L'operazione su larga scala richiede di omettere i dettagli per prevenire OOM |
| **24001** | `DEV_ENGINE_INCOMPATIBLE` | `ResultType.devEngineIncompatible` | Errore dello Sviluppatore | **Critico**: Versione del motore incompatibile |
| **30000** | `DEV_INVALID_SCHEMA` | `ResultType.devInvalidSchema` | Errore dello Sviluppatore | Definizione dello schema della tabella non valida |
| **30001** | `DEV_INVALID_SCHEMA_TABLE_NAME` | `ResultType.devInvalidSchemaTableName` | Errore dello Sviluppatore | Convalida del nome della tabella non riuscita |
| **30002** | `DEV_INVALID_SCHEMA_FIELD_NAME` | `ResultType.devInvalidSchemaFieldName` | Errore dello Sviluppatore | Convalida del nome del campo non riuscita |
| **30003** | `DEV_INVALID_SCHEMA_PRIMARY_KEY` | `ResultType.devInvalidSchemaPrimaryKey` | Errore dello Sviluppatore | Convalida della chiave primaria non riuscita |
| **30004** | `DEV_INVALID_SCHEMA_INDEX_LIMIT` | `ResultType.devInvalidSchemaIndexLimit` | Errore dello Sviluppatore | Convalida del numero degli indici non riuscita |
| **30005** | `DEV_SCHEMA_TABLE_EXISTS` | `ResultType.devSchemaTableExists` | Errore dello Sviluppatore | La tabella esiste già |
| **30006** | `DEV_SCHEMA_FIELD_EXISTS` | `ResultType.devSchemaFieldExists` | Errore dello Sviluppatore | Il campo esiste già |
| **30007** | `DEV_SCHEMA_INDEX_EXISTS` | `ResultType.devSchemaIndexExists` | Errore dello Sviluppatore | L'indice esiste già |
| **30008** | `DEV_INVALID_SCHEMA_FOREIGN_KEY` | `ResultType.devInvalidSchemaForeignKey` | Errore dello Sviluppatore | Definizione di chiave esterna non valida |
| **30009** | `DEV_INVALID_SCHEMA_SPACE_MISMATCH` | `ResultType.devInvalidSchemaSpaceMismatch` | Errore dello Sviluppatore | Discrepanza di limite globale/specifico dello spazio |
| **30010** | `DEV_MIGRATION_NOT_ALLOWED_WITH_DATA` | `ResultType.devMigrationNotAllowedWithData` | Errore dello Sviluppatore | La migrazione richiede la modifica dei dati e non è stata esplicitamente consentita |
| **30011** | `DEV_MIGRATION_UNSAFE_TYPE_CONVERSION` | `ResultType.devMigrationUnsafeTypeConversion` | Errore dello Sviluppatore | Tipo di modifica non supportato per il campo |
| **30013** | `DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD` | `ResultType.devMigrationCannotAddNonNullField` | Errore dello Sviluppatore | Aggiunta di un campo non-nullable senza un valore predefinito non consentita |
| **30014** | `DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED` | `ResultType.devMigrationNullableToNonNullNotAllowed` | Errore dello Sviluppatore | Modifica del campo da nullable a non-nullable non consentita |
| **30015** | `DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED` | `ResultType.devMigrationUniqueTighteningNotAllowed` | Errore dello Sviluppatore | Restrizione a UNIQUE non consentita |
| **30016** | `DEV_INVALID_SCHEMA_TTL_CONFIG` | `ResultType.devInvalidSchemaTtlConfig` | Errore dello Sviluppatore | Convalida della configurazione TTL non riuscita |
| **30017** | `DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME` | `ResultType.devInvalidSchemaDuplicateFieldName` | Errore dello Sviluppatore | Nome di campo duplicato nello schema della tabella |
| **30018** | `DEV_INVALID_SCHEMA_INDEX_FIELD` | `ResultType.devInvalidSchemaIndexField` | Errore dello Sviluppatore | L'indice fa riferimento a un campo inesistente |
| **50001** | `SYS_TRANSACTION_ABORTED` | `ResultType.sysTransactionAborted` | Errore di Sistema | Transazione interrotta |
| **50002** | `SYS_TRANSACTION_CONFLICT` | `ResultType.sysTransactionConflict` | Errore di Sistema | Conflitto di transazione |
| **50003** | `SYS_TRANSACTION_LIMIT_EXCEEDED` | `ResultType.sysTransactionLimitExceeded` | Errore di Sistema | La transazione supera il limite di memoria sicuro sotto pressione di memoria |
| **50004** | `SYS_MIGRATION_BATCH_EXECUTION_FAILED` | `ResultType.sysMigrationBatchExecutionFailed` | Errore di Sistema | **Critico**: Errore di esecuzione del batch di migrazione |
| **51001** | `SYS_TIMEOUT_LOCK_ACQUISITION` | `ResultType.sysTimeoutLockAcquisition` | Errore di Sistema | Timeout di acquisizione del blocco |
| **51002** | `SYS_TIMEOUT` | `ResultType.sysTimeout` | Errore di Sistema | Timeout dell'operazione |
| **51003** | `SYS_DB_CLOSED` | `ResultType.sysDbClosed` | Errore di Sistema | Il database è chiuso, l'operazione è stata annullata in modo sicuro |
| **52001** | `SYS_RESOURCE_EXHAUSTED_MEMORY` | `ResultType.sysResourceExhaustedMemory` | Errore di Sistema | **Critico**: Risorse di memoria esaurite |
| **52002** | `SYS_RESOURCE_EXHAUSTED` | `ResultType.sysResourceExhausted` | Errore di Sistema | **Critico**: Risorse di sistema esaurite |
| **53001** | `SYS_IO_NOT_FOUND` | `ResultType.sysIoNotFound` | Errore di Sistema | Il file o il percorso fisico non esiste |
| **53002** | `SYS_IO_PERMISSION_DENIED` | `ResultType.sysIoPermissionDenied` | Errore di Sistema | Autorizzazione negata per l'accesso al file |
| **53003** | `SYS_IO_DISK_FULL` | `ResultType.sysIoDiskFull` | Errore di Sistema | **Critico**: Disco pieno o quota di archiviazione superata |
| **53004** | `SYS_IO_FILE_LOCKED` | `ResultType.sysIoFileLocked` | Errore di Sistema | Il file è bloccato o in uso da un altro processo |
| **53005** | `SYS_IO_DEVICE_FAULT` | `ResultType.sysIoDeviceFault` | Errore di Sistema | **Critico**: Errore del dispositivo o del supporto di archiviazione |
| **53006** | `SYS_IO_WEB_STORAGE_UNAVAILABLE` | `ResultType.sysIoWebStorageUnavailable` | Errore di Sistema | IndexedDB Web o archiviazione non disponibile |
| **53007** | `SYS_BACKUP_CORRUPTED` | `ResultType.sysBackupCorrupted` | Errore di Sistema | Il pacchetto di backup è danneggiato o mancano i metadati |
| **53008** | `SYS_IO_DATA_CORRUPTED` | `ResultType.sysIoDataCorrupted` | Errore di Sistema | **Critico**: Il file di dati del database è danneggiato o la checksum è fallita |
| **53009** | `SYS_INVALID_DATA_FORMAT` | `ResultType.sysInvalidDataFormat` | Errore di Sistema | Formattazione o analisi del flusso di dati fallita |
| **53099** | `SYS_IO_GENERIC` | `ResultType.sysIoGeneric` | Errore di Sistema | Errore generico di I/O di sistema |
| **99001** | `ENG_ERROR` | `ResultType.engError` | Errore del motore | Errore del motore |
