# ToStore ResultStatus Spécification de Diagnostic Automatique & Résolution d'État

Pour permettre aux opérations automatisées (Ops), aux agents IA, aux scripts de test automatisés et aux applications clientes d'identifier avec précision les différents résultats d'exécution et états d'exception de la base de données, ToStore introduit un système structuré de `ResultStatus` dans sa dernière version.

Ce document de spécification décrit en détail les principes de conception des codes d'état, les spécifications des clés d'identifiants sémantiques et les structures de champs dédiées des différents types d'états pour aider les utilisateurs de bases de données et les développeurs à implémenter de manière autonome la résolution d'état.

---

## 1. Principes Fondamentaux de Conception

### 1.1 Spécification Numérique du Code d'État (code)

Tous les codes d'état numériques (`code`) sont définis sur une longueur fixe de 5 chiffres (sauf pour l'état de succès) :

- **État de Succès (Code de succès spécial)**: Spécifiquement fixé à `0`.
- **Autres États (Codes d'erreur & de diagnostic)**: Unifiés à 5 chiffres.
- **Code de Classe**: Les deux premiers chiffres du code d'état, utilisés pour identifier rapidement la catégorie principale.
- **Code Feuille**: Les trois derniers chiffres du code d'état, représentant le scénario d'erreur spécifique.

> [!TIP]
> Lors du développement d'Ops automatisées, d'agents IA ou de scripts de test externes, les développeurs peuvent router vers les gestionnaires d'exceptions correspondants en utilisant les deux premiers chiffres (Code de classe) ou la plage, puis effectuer un traitement plus précis basé sur le Code feuille.

> [!IMPORTANT]
> **Meilleure Pratique pour la Vérification en Mémoire**:
> Lors de la lecture des résultats d'opération de base de données en mémoire (par exemple, dans le code client ou Dart/Flutter), **la méthode la plus recommandée et la plus efficace consiste à utiliser directement les propriétés en lecture seule (getters) intégrées** de `ResultStatus` ou `ResultType` (telles que `isBusinessError`, `isCriticalError`, etc., voir la [Section 3.2](#32-getters-daide-en-m%C3%A9moire)), évitant ainsi l'analyse manuelle des plages numériques ou la correspondance de préfixes de chaînes de caractères.

### 1.2 Spécification de l'Identifiant Sémantique d'État (codeKey)

Chaque état correspond à un identifiant textuel unique `codeKey` :

- **Format de Nom**: `[Préfixe_Catégorie_Principale]_[Identifiant_Détail_Multi-niveaux]`.
- **Règle de Nom**: Composé de lettres majuscules anglaises et de tirets bas `_`, sans espace ni caractère spécial.
- **Préfixe de Catégorie Principale**: Indique à quelle catégorie métier de base appartient l'état. Si plusieurs niveaux de catégories existent, le préfixe le plus générique est placé à l'avant pour faciliter la recherche de préfixes et le filtrage par plage.

---

## 2. Table de Référence Rapide des Codes de Classe

Voici la définition de correspondance de tous les Codes de classe dans ToStore :

| Plage de Code | Code de Classe (2 premiers chiffres) | Préfixe Sémantique | Catégorie | Stratégie d'Exception |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `00` | `SUCCESS` | **Opération réussie** | Ne lève pas d'exception, retourne normalement. |
| `10000 - 19999` | `10 - 19` | `BIZ_` | **Erreur Métier** (Erreurs de saisie de l'utilisateur final, par exemple violations de contraintes) | Ne lève pas d'exception, toujours retournée via `DbResult` ou `QueryResult`. |
| `20000 - 49999` | `20 - 49` | `DEV_` | **Erreur Développeur** (Paramètres d'API invalides, configuration de schéma de table invalide, etc.) | **Lève directement une `DbException` dans les environnements de débogage** pour avertir les développeurs ; **retourne normalement comme résultat dans les environnements de production**. *(Remarque : l'incompatibilité de version du moteur et les échecs majeurs d'exécution de lots de migration sont des erreurs critiques, qui lèvent des exceptions même en production)* |
| `50000 - 79999` | `50 - 79` | `SYS_` | **Erreur Système** (Espace disque plein, exceptions IO, expiration de l'obtention de verrou, etc.) | Lève une exception lorsque l'exécution normale est bloquée ; les autres (par exemple, conflit de transaction) sont retournées comme résultats. |
| `99000 - 99999` | `99` | `ENG_` | **Erreur Moteur** (Erreur logique du moteur, corruption de fichier de données, erreur interne inconnue) | En général, ne lève pas d'exceptions ; lève des exceptions pour les cas graves. |

---

## 3. Structure des Champs Communs ResultStatus et Aides en Mémoire

### 3.1 Champs Communs (Structure JSON Sérialisée)

Tous les types de `ResultStatus`, lorsqu'ils sont sérialisés en JSON, contiennent les 4 champs communs de base suivants. Les utilisateurs peuvent lire ces champs directement pour des vérifications préliminaires.

| Champ | Type | Description |
| :--- | :--- | :--- |
| `index` | `int` | Index de séquence dans les opérations par lots. Pour les opérations uniques, il est fixé à `0`. |
| `code` | `int` | Code d'état numérique (`0` pour le succès, nombre à 5 chiffres pour une exception). |
| `codeKey` | `String` | Clé d'identifiant sémantique d'état, par exemple, `BIZ_CONSTRAINT_UNIQUE`. |
| `message` | `String` | Description détaillée de l'état lisible par l'homme. |

### 3.2 Getters d'Aide en Mémoire

En Dart/Flutter, `ResultStatus` et `ResultType` encapsulent des propriétés en lecture seule (Getters) hautement efficaces en `O(1)` pour vérifier la catégorie et la gravité en mémoire sans vérification manuelle de plage ni correspondance de chaînes de caractères :

| Propriété | Type | Description |
| :--- | :--- | :--- |
| `isBusinessError` | `bool` | Indique s'il s'agit d'une **Erreur Métier** (par exemple, conflit de contrainte, échec de transtypage ; plage `10000 - 19999`). |
| `isConstraintError` | `bool` | Indique si cela correspond à **ConstraintStatus** (même plage numérique que `isBusinessError` : `10000 - 19999`). |
| `isDeveloperError` | `bool` | Indique s'il s'agit d'une **Erreur Développeur** (par exemple, schéma invalide, non-correspondance de paramètres, table non trouvée ; plage `20000 - 49999`). |
| `isSystemError` | `bool` | Indique s'il s'agit d'une **Erreur Système** (par exemple, expiration de verrou, disque plein, verrou de fichier ; plage `50000 - 79999`). |
| `isEngineError` | `bool` | Indique s'il s'agit d'une **Erreur Moteur** (plage `99000 - 99999`). |
| `isCriticalError` | `bool` | Indique s'il s'agit d'une **Erreur Critique / Événement de niveau catastrophe** (nécessite une intervention manuelle ou des opérations, par exemple disque plein, mémoire insuffisante, corruption grave de fichier de données, échec de migration incompatible, etc.). |

---

## 4. Structures de Résolution Détaillées et Champs Dédiés

Selon la plage de `code` / `codeKey` et la sous-classe spécifique de `ResultStatus`, la structure JSON sérialisée transportera différents **champs de diagnostic dédiés**. Vous trouverez ci-dessous les spécifications des champs et le mappage d'application pour les 5 sous-classes d'état.

### 4.1 SuccessStatus (Opération réussie)

- **Plage de Catégorie**: `code == 0`, `codeKey == "SUCCESS"`
- **Scénario Applicable**: Enregistrements insérés, modifiés ou supprimés avec succès.
- **Définition de Champ Dédié**:

  | Champ | Type | Détails |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Optionnel**. Retourné uniquement lors des écritures sur une seule ligne (par exemple, `insert`) ou des mises à jour (par exemple, `update`), représentant la clé primaire de l'enregistrement physiquement généré ou modifié. |

- **Exemple JSON**:
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

### 4.2 ConstraintStatus (Intégrité des données & conflits de contraintes)

- **Plage de Catégorie**: `code` dans `[10000, 19999]` (tous les codes feuille Erreur Métier : validation, contraintes d'intégrité et enregistrement introuvable). Correspond à `ResultType.isConstraintError`.
- **Définition de Champ Dédié**:

  | Champ | Type | Détails |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Requis**. Nom de la table où le conflit d'intégrité de contrainte ou l'erreur de non-trouvé s'est produit. |
  | `constraintName` | `String?` | **Optionnel**. Le nom de la contrainte spécifique qui a causé l'erreur (par exemple, `fk_users_profile` pour une clé étrangère, le nom de l'index pour un conflit d'unicité, ou `null` pour les erreurs not-null ou de transtypage). |
  | `fields` | `List<String>` | **Requis**. Liste des champs provoquant le conflit. |
  | `conflictingKeys` | `List<dynamic>` | **Requis**. Liste des valeurs d'entrée à l'origine du conflit, mappées 1:1 avec `fields`. Si un champ est null, l'élément correspondant dans la liste est `null`. |
  | `primaryKey` | `String?` | **Optionnel**. Clé primaire de l'enregistrement associé. S'il ne s'agit pas d'une écriture sur une seule ligne, ou si elle a été bloquée à l'étape de mémoire, elle sera `null`. |
  | `referencedTable` | `String?` | **Optionnel**. Nom de la table parente dans les conflits de clés étrangères. |

- **Directives pour les Codes Feuilles**:

  | Code & ResultType | Scénario | Directives de Champs |
  | :--- | :--- | :--- |
  | `10000`<br>`bizValidationFailed` | Échec de validation du format ou de la plage de données | <ul><li>`tableName`: Table affectée</li><li>`constraintName`: `null`</li><li>`fields`: Champs violant la validation, par exemple `["email"]`</li><li>`conflictingKeys`: Valeurs invalides causant l'échec, par exemple `["invalid-email"]`</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |
  | `10001`<br>`bizNotNullViolation` | Violation de la contrainte not null | <ul><li>`tableName`: Table affectée</li><li>`constraintName`: `null`</li><li>`fields`: Champs violant la restriction not-null, par exemple `["email"]`</li><li>`conflictingKeys`: Toujours `[null]`</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |
  | `10002`<br>`bizTypeCastFailed` | Échec de conversion ou de transtypage de type de données | <ul><li>`tableName`: Table affectée</li><li>`constraintName`: `null`</li><li>`fields`: Champs dont le transtypage a échoué, par exemple `["age"]`</li><li>`conflictingKeys`: Valeurs invalides causant l'échec, par exemple `["not_a_number"]`</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |
  | `11001`<br>`bizPrimaryKeyViolation` | Conflit de clé primaire (existe déjà) | <ul><li>`tableName`: Table affectée</li><li>`constraintName`: `"PRIMARY"` ou nom de la contrainte</li><li>`fields`: Champs de clé primaire, par exemple `["id"]`</li><li>`conflictingKeys`: Valeurs en double, par exemple `["usr_101"]`</li><li>`primaryKey`: Valeur en conflit, par exemple `"usr_101"`</li></ul> |
  | `11002`<br>`bizUniqueViolation` | Violation de contrainte d'unicité | <ul><li>`tableName`: Table affectée</li><li>`constraintName`: Nom de l'index unique, par exemple `"uk_email"`</li><li>`fields`: Champs composant l'unicité, par exemple `["email"]`</li><li>`conflictingKeys`: Valeurs causant le conflit, par exemple `["test@a.com"]`</li><li>`primaryKey`: Clé primaire de l'enregistrement en conflit (le cas échéant)</li></ul> |
  | `11003`<br>`bizForeignKeyViolation` | Violation de contrainte de clé étrangère (Générique) | <ul><li>`tableName`: Table enfant</li><li>`constraintName`: Nom de la contrainte de clé étrangère</li><li>`fields`: Colonnes de clé étrangère</li><li>`conflictingKeys`: Valeurs d'entrée causant le conflit</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li><li>`referencedTable`: Table parente</li></ul> |
  | `11004`<br>`bizCheckViolation` | Violation de contrainte check | <ul><li>`tableName`: Table affectée</li><li>`constraintName`: Nom de la contrainte check</li><li>`fields`: Champs vérifiés</li><li>`conflictingKeys`: Valeurs violant la contrainte check</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |
  | `11005`<br>`bizForeignKeyParentNotExist` | La clé parente référencée n'existe pas | <ul><li>`tableName`: Table enfant</li><li>`constraintName`: Nom de la contrainte de clé étrangère</li><li>`fields`: Colonnes de clé étrangère, par exemple `["userId"]`</li><li>`conflictingKeys`: Valeur de référence inexistante, par exemple `["non_parent"]`</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li><li>`referencedTable`: Table parente</li></ul> |
  | `11006`<br>`bizForeignKeyChildRestrict` | Suppression/mise à jour restreinte par les enregistrements enfants | <ul><li>`tableName`: Table parente</li><li>`constraintName`: Nom de la contrainte de clé étrangère</li><li>`fields`: Colonnes référencées de la table parente</li><li>`conflictingKeys`: Valeurs de clé parente référencées par la table enfant</li><li>`primaryKey`: Valeurs de clé parente</li><li>`referencedTable`: Table enfant</li></ul> |
  | `11007`<br>`bizForeignKeyCompositeMismatch` | Valeurs de clé étrangère composite incomplètes | <ul><li>`tableName`: Table enfant</li><li>`constraintName`: Nom de la contrainte de clé étrangère</li><li>`fields`: Colonnes de clé étrangère composite</li><li>`conflictingKeys`: Valeurs d'entrée (contient des valeurs nulles partielles)</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li><li>`referencedTable`: Table parente</li></ul> |
  | `11008`<br>`bizForeignKeyTypeMismatch` | Non-correspondance de type de clé étrangère | <ul><li>`tableName`: Table enfant</li><li>`constraintName`: Nom de la contrainte de clé étrangère</li><li>`fields`: Colonnes de clé étrangère</li><li>`conflictingKeys`: Valeurs dont le transtypage a échoué</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li><li>`referencedTable`: Table parente</li></ul> |
  | `11009`<br>`bizValueExceedsMaxLength` | La longueur de la valeur dépasse la contrainte maximale | <ul><li>`tableName`: Table affectée</li><li>`constraintName`: `null`</li><li>`fields`: Champs violant la limite, par exemple `["name"]`</li><li>`conflictingKeys`: Valeurs transgressives, par exemple `["a" * 1000]`</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |
  | `11010`<br>`bizValueLessThanMinLength` | La longueur de la valeur est inférieure à la contrainte minimale | <ul><li>`tableName`: Table affectée</li><li>`constraintName`: `null`</li><li>`fields`: Champs violant la limite, par exemple `["code"]`</li><li>`conflictingKeys`: Valeurs plus courtes que le minimum, par exemple `["ab"]`</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |
  | `11011`<br>`bizValueLessThanMinValue` | La valeur numérique est inférieure à la contrainte minimale | <ul><li>`tableName`: Table affectée</li><li>`constraintName`: `null`</li><li>`fields`: Champs violant la limite, par exemple `["age"]`</li><li>`conflictingKeys`: Valeurs inférieures au minimum, par exemple `[-5]`</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |
  | `11012`<br>`bizValueExceedsMaxValue` | La valeur numérique dépasse la contrainte maximale | <ul><li>`tableName`: Table affectée</li><li>`constraintName`: `null`</li><li>`fields`: Champs violant la limite, par exemple `["score"]`</li><li>`conflictingKeys`: Valeurs dépassant le maximum, par exemple `[105]`</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |
  | `12001`<br>`bizRecordNotFound` | La ressource n'existe pas / Enregistrement non trouvé | <ul><li>`tableName`: Table affectée</li><li>`constraintName`: `null`</li><li>`fields`: Champs cibles de recherche, par exemple `["id"]`</li><li>`conflictingKeys`: Clés cibles non trouvées, par exemple `["non_exist_id"]`</li><li>`primaryKey`: Valeur de la clé manquante, par exemple `"non_exist_id"`</li></ul> |

- **Exemple JSON** (L'enregistrement parent de la clé étrangère n'existe pas) :
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

### 4.3 SchemaValidationStatus (Validation de schéma de table & migration incompatible)

- **Plage de Catégorie**: `code` dans `[30000, 39999]` — `30000–30013` validation statique de schéma, `31001–31006` gardes de migration.
- **Définition de Champ Dédié**:

  | Champ | Type | Détails |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Requis**. Nom de la table en cours de validation ou de migration physique. |
  | `field` | `String?` | **Optionnel**. Le nom du champ spécifique déclenchant l'erreur de schéma ou de migration. |
  | `wrongValue` | `dynamic` | **Optionnel**. Valeur de configuration invalide ou configuration de différence de migration causant le conflit. |

- **Directives pour les Codes Feuilles**:

  | Code & ResultType | Scénario | Directives de Champs |
  | :--- | :--- | :--- |
  | `30000`<br>`devInvalidSchema` | Définition de schéma de table invalide | <ul><li>`tableName`: Nom de la table</li><li>`field`: `null`</li><li>`wrongValue`: Map de configuration invalide, ou `null`</li></ul> |
  | `30001`<br>`devInvalidSchemaTableName` | Échec de validation du nom de la table (caractères illégaux ou trop long) | <ul><li>`tableName`: Nom transgressif</li><li>`field`: `null`</li><li>`wrongValue`: Chaîne transgressive</li></ul> |
  | `30002`<br>`devInvalidSchemaFieldName` | Échec de validation du nom du champ (caractères illégaux) | <ul><li>`tableName`: Nom de la table</li><li>`field`: Nom du champ transgressif</li><li>`wrongValue`: Chaîne transgressive</li></ul> |
  | `30003`<br>`devInvalidSchemaDuplicateFieldName` | Nom de champ dupliqué dans le schéma de la table | <ul><li>`tableName`: Nom de la table</li><li>`field`: Nom de champ dupliqué</li><li>`wrongValue`: `null`</li></ul> |
  | `30004`<br>`devInvalidSchemaPrimaryKey` | Échec de validation de la clé primaire (manquante ou format invalide) | <ul><li>`tableName`: Nom de la table</li><li>`field`: `"primaryKey"` ou nom du champ de la clé primaire</li><li>`wrongValue`: Détails de configuration de la clé primaire</li></ul> |
  | `30005`<br>`devInvalidSchemaIndexLimit` | Le nombre d'index de table dépasse la limite système de 16 | <ul><li>`tableName`: Nom de la table</li><li>`field`: `null`</li><li>`wrongValue`: Liste des configurations d'index</li></ul> |
  | `30006`<br>`devInvalidSchemaIndexField` | L'index fait référence à un champ inexistant | <ul><li>`tableName`: Nom de la table</li><li>`field`: Nom de l'index</li><li>`wrongValue`: Nom du champ causant la non-correspondance</li></ul> |
  | `30007`<br>`devInvalidSchemaIndexType` | Type d'index incompatible avec le type de données ou la configuration du champ | <ul><li>`tableName`: Nom de table</li><li>`field`: Nom d'index/champ</li><li>`wrongValue`: Infos de conflit, ex. `{ "indexType": "btree", "fieldType": "vector" }`</li></ul> |
  | `30008`<br>`devInvalidSchemaForeignKey` | Définition de clé étrangère invalide (par exemple, colonnes non correspondantes) | <ul><li>`tableName`: Nom de la table</li><li>`field`: Nom de la clé étrangère</li><li>`wrongValue`: Détails de configuration de la clé étrangère</li></ul> |
  | `30009`<br>`devInvalidSchemaSpaceMismatch` | Non-correspondance de limite globale/spécifique à l'espace | <ul><li>`tableName`: Nom de la table</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30010`<br>`devInvalidSchemaTtlConfig` | Échec de la validation de la configuration TTL | <ul><li>`tableName`: Nom de la table</li><li>`field`: Champ d'horodatage TTL</li><li>`wrongValue`: Map de configuration TTL invalide, par exemple, `{ "enabled": true, "fieldName": "expire_at" }`</li></ul> |
  | `30011`<br>`devSchemaTableExists` | La table existe déjà | <ul><li>`tableName`: Nom de la table</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30012`<br>`devSchemaFieldExists` | Mise à niveau de schéma : ajout d'un champ qui existe déjà | <ul><li>`tableName`: Nom de la table</li><li>`field`: Nom du champ en conflit</li><li>`wrongValue`: `null`</li></ul> |
  | `30013`<br>`devSchemaIndexExists` | Mise à niveau de schéma : ajout d'un index qui existe déjà | <ul><li>`tableName`: Nom de la table</li><li>`field`: Nom de l'index</li><li>`wrongValue`: `null`</li></ul> |
  | `31001`<br>`devMigrationNotAllowedWithData` | La migration nécessite une modification des données et n'a pas été explicitement autorisée | <ul><li>`tableName`: Nom de la table</li><li>`field`: `null`</li><li>`wrongValue`: Map des différences de mise à niveau de migration</li></ul> |
  | `31002`<br>`devMigrationUnsafeTypeConversion` | Migration physique : conversion de type non supportée pour le champ | <ul><li>`tableName`: Nom de la table</li><li>`field`: Nom du champ</li><li>`wrongValue`: Map des types en conflit, par exemple `{ "from": "text", "to": "integer" }`</li></ul> |
  | `31003`<br>`devMigrationCannotAddNonNullField` | Impossible d'ajouter un champ non-nullable sans valeur par défaut à une table non vide | <ul><li>`tableName`: Nom de la table</li><li>`field`: Nom du champ transgressif</li><li>`wrongValue`: Paramètres de migration, par exemple `{ "nullable": false, "defaultValue": null }`</li></ul> |
  | `31004`<br>`devMigrationNullableToNonNullNotAllowed` | Migration physique : changement de champ de nullable à non-nullable | <ul><li>`tableName`: Nom de la table</li><li>`field`: Nom du champ</li><li>`wrongValue`: Paramètres de migration, identique à 31003</li></ul> |
  | `31005`<br>`devMigrationUniqueTighteningNotAllowed` | Migration physique : resserrement de la contrainte de champ vers UNIQUE | <ul><li>`tableName`: Nom de la table</li><li>`field`: Nom du champ</li><li>`wrongValue`: Définition de l'index causant la contrainte unique</li></ul> |
  | `31006`<br>`devMigrationPromoteLargeOpNotAllowed` | Opérations à grande échelle bloquées pendant promoteFieldToPrimaryKey | <ul><li>`tableName`: Nom de table</li><li>`field`: `null`</li><li>`wrongValue`: Phase promote / id de tâche (le cas échéant)</li></ul> |

- **Exemple JSON** (Ajout d'un champ non-nullable sans valeur par défaut à une table non vide) :
  ```json
  {
    "index": 0,
    "code": 31003,
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

### 4.4 InvalidArgumentStatus (Arguments d'API & validation de pagination par curseur)

- **Plage de Catégorie**: `code` dans `[20000, 20999]` **hors** `20005` / `20006`, **plus** `22004` (`devFieldNotFound`). Les codes `20005` / `20006` et autres `2200x` introuvables utilisent GeneralStatus (§4.6).
- **Définition de Champ Dédié**:

  | Champ | Type | Détails |
  | :--- | :--- | :--- |
  | `parameterName` | `String` | **Requis**. Nom de l'argument déclenchant l'échec de validation (par exemple `"cursor"`, `"orderBy"`, ou une clé de colonne spécifique). |
  | `passedValue` | `dynamic` | **Optionnel**. Valeur d'entrée non conforme passée par l'appelant. Les objets complexes sont convertis en chaînes de caractères. |
  | `primaryKey` | `String?` | **Optionnel**. Clé primaire de l'enregistrement associé. |

- **Directives pour les Codes Feuilles**:

  | Code & ResultType | Scénario | Directives de Champs |
  | :--- | :--- | :--- |
  | `20001`<br>`devInvalidArgumentFormat` | Erreur de format d'argument | <ul><li>`parameterName`: Nom de l'argument invalide</li><li>`passedValue`: Valeur passée, par exemple `"twenty"`</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |
  | `20002`<br>`devInvalidArgumentType` | Non-correspondance de type d'argument | <ul><li>`parameterName`: Nom du paramètre</li><li>`passedValue`: Valeur passée, par exemple `{"foo": "bar"}` (lorsqu'une String est attendue)</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |
  | `20003`<br>`devInvalidArgumentMissing` | L'argument requis est manquant | <ul><li>`parameterName`: Nom du paramètre manquant, par exemple `"dbPath"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |
  | `20004`<br>`devInvalidPrimaryKeyFormat` | Format de clé primaire invalide | <ul><li>`parameterName`: `"primaryKey"` ou champ de clé primaire</li><li>`passedValue`: Valeur de clé primaire invalide, par exemple, `"invalid_id_value"`</li><li>`primaryKey`: Valeur de clé primaire invalide</li></ul> |
  | `20007`<br>`devVectorDimensionMismatch` | Non-correspondance des dimensions vectorielles | <ul><li>`parameterName`: `"other"`</li><li>`passedValue`: Taille de dimension transgressive</li><li>`primaryKey`: `null`</li></ul> |
  | `20008`<br>`devIndexFieldMissing` | Champ d'index requis manquant dans l'enregistrement pour le curseur | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Champ d'index manquant</li><li>`primaryKey`: `null`</li></ul> |
  | `20101`<br>`devInvalidCursorPagination` | La pagination par curseur et l'offset sont mutuellement exclusifs | <ul><li>`parameterName`: `"cursor"` / `"offset"`</li><li>`passedValue`: Paramètres de pagination en conflit</li><li>`primaryKey`: `null`</li></ul> |
  | `20102`<br>`devInvalidCursorTable` | Le curseur ne correspond pas à la table cible | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Jeton de curseur</li><li>`primaryKey`: `null`</li></ul> |
  | `20103`<br>`devInvalidCursorSignature` | Signature de curseur non correspondante (altérée) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Jeton de curseur</li><li>`primaryKey`: `null`</li></ul> |
  | `20104`<br>`devInvalidCursorOrderBy` | Configuration orderBy du curseur invalide ou non correspondante | <ul><li>`parameterName`: `"orderBy"`</li><li>`passedValue`: Liste orderBy, par exemple `["-age", "id"]`</li><li>`primaryKey`: `null`</li></ul> |
  | `20105`<br>`devInvalidCursorMode` | Non-correspondance du mode de jeton de curseur | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Mode jeton, par exemple, `"sortKey"`</li><li>`primaryKey`: `null`</li></ul> |
  | `20106`<br>`devInvalidCursorPayload` | Charge utile de curseur invalide (indécodable) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: `null`</li></ul> |
  | `20201`<br>`devInvalidQuerySelectField` | Le champ de sélection de requête doit être String ou QueryAggregation | <ul><li>`parameterName`: `"select"`</li><li>`passedValue`: Définition de champ select invalide</li><li>`primaryKey`: `null`</li></ul> |
  | `20202`<br>`devInvalidQueryForeignKeyJoin` | Pas de relation de clé étrangère pour l'auto-join | <ul><li>`parameterName`: `"join"` / `"tableName"`</li><li>`passedValue`: Table cible manquant de relation</li><li>`primaryKey`: `null`</li></ul> |
  | `20203`<br>`devInvalidQueryFieldAlias` | Format d'alias de champ de requête invalide | <ul><li>`parameterName`: `"alias"`</li><li>`passedValue`: Chaîne d'alias invalide</li><li>`primaryKey`: `null`</li></ul> |
  | `20204`<br>`devInvalidExpression` | Configuration d'expression invalide ou exception d'exécution | <ul><li>`parameterName`: Aspect de l'erreur (par exemple `"arguments"`, `"functionName"`, `"node"`)</li><li>`passedValue`: Valeur ou nombre invalide</li><li>`primaryKey`: `null`</li></ul> |
  | `22004`<br>`devFieldNotFound` | Champ non trouvé | <ul><li>`parameterName`: Nom de champ inconnu, par exemple `"extra"`</li><li>`passedValue`: Valeur d'entrée passée pour le champ</li><li>`primaryKey`: Clé primaire de l'enregistrement (le cas échéant)</li></ul> |

- **Exemple JSON** (Les champs orderBy du curseur ne correspondent pas à l'orderBy de la requête actuelle) :
  ```json
  {
    "index": 0,
    "code": 20104,
    "codeKey": "DEV_INVALID_CURSOR_ORDERBY",
    "message": "Cursor orderBy fields do not match current query orderBy.",
    "parameterName": "orderBy",
    "passedValue": ["age DESC", "id ASC"],
    "primaryKey": null
  }
  ```

---

### 4.5 TransactionOperationStatus (Conflit & annulation de transaction)

- **Plage de Catégorie**: uniquement `50001` (`sysTransactionAborted`) et `50002` (`sysTransactionConflict`). Les autres codes `500xx` (ex. `50003` / `50004`) utilisent GeneralStatus (§4.6).
- **Définition de Champ Dédié**:

  | Champ | Type | Détails |
  | :--- | :--- | :--- |
  | `txId` | `String` | **Requis**. Identifiant unique de flux de transaction globale. Utilisé pour suivre le cycle de vie de la transaction. |

- **Directives pour les Codes Feuilles**:

  | Code & ResultType | Scénario | Directives de Champs |
  | :--- | :--- | :--- |
  | `50001`<br>`sysTransactionAborted` | Transaction annulée (rollback explicite ou échec en cascade) | <ul><li>`txId`: ID de transaction active</li></ul> |
  | `50002`<br>`sysTransactionConflict` | Conflit de transaction (mises à jour simultanées de la même clé dans SSI/WAL) | <ul><li>`txId`: ID de la transaction en conflit</li></ul> |

- **Exemple JSON** (Conflit Écriture-Écriture concurrent SSI) :
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

### 4.6 GeneralStatus (Exceptions génériques & système)

- **Plage de Catégorie**: Repli pour les codes hors §§4.1–4.5 — dont `20005` / `20006`, `22001`–`22003`, `230xx` / `240xx`, le reste de `50xxx`–`53xxx` et `99001`.
- **Définition de Champ Dédié**:

  | Champ | Type | Détails |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Optionnel**. Clé primaire de l'enregistrement associé. |
  | `target` | `String?` | **Optionnel**. Ressource physique cible, par exemple des chemins de fichiers physiques, des verrous ou des URL. |
  | `operation` | `String?` | **Optionnel**. Nom de l'appel système actif, par exemple `'readAsString'`, `'delete'`, `'acquire'`. |

- **Directives pour les Codes Feuilles**:

  | Code & ResultType | Scénario / Niveau | Directives de Champs |
  | :--- | :--- | :--- |
  | `20005`<br>`devIndexOutOfBounds` | L'index ou la plage est hors limites (Erreur Développeur) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `20006`<br>`devUnsupportedOperation` | L'opération n'est pas supportée dans le contexte actuel (Erreur Développeur) | <ul><li>`primaryKey`: `null`</li><li>`target`: Table/ressource cible (le cas échéant)</li><li>`operation`: Nom de la méthode (le cas échéant)</li></ul> |
  | `22001`<br>`devTableNotFound` | Table non trouvée (Erreur Développeur) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22002`<br>`devIndexNotFound` | Index non trouvé (Erreur Développeur) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22003`<br>`devSpaceNotFound` | Espace non trouvé (Erreur Développeur) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23001`<br>`devLargeScaleOperationRequired` | Large-scale data operation requires `allowLargeScaleOperation()` (Developer Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23002`<br>`devLargeScaleOperationNotAllowedInTransaction` | Large-scale data operation is not allowed inside a transaction (Developer Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `24001`<br>`devEngineIncompatible` | **Critique**: Version du moteur incompatible | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50003`<br>`sysTransactionLimitExceeded` | Les données mises en tampon par la transaction dépassent la limite sûre sous pression mémoire (Erreur Système) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50004`<br>`sysMigrationBatchExecutionFailed` | Échec de l'exécution du lot de migration (Erreur Système) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51001`<br>`sysTimeoutLockAcquisition` | Expiration de l'acquisition du verrou (Erreur Système) | <ul><li>`primaryKey`: Clé cible (le cas échéant)</li><li>`target`: ID de la ressource de verrou</li><li>`operation`: `"acquire"`</li></ul> |
  | `51002`<br>`sysTimeout` | Expiration de l'opération (Erreur Système) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51003`<br>`sysDbClosed` | La base de données est fermée, l'opération a été annulée en toute sécurité (Erreur Système) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52001`<br>`sysResourceExhaustedMemory` | Ressources mémoire épuisées (Erreur Système) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52002`<br>`sysResourceExhausted` | Ressources système épuisées, par exemple disque plein (Erreur Système) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `53001`<br>`sysIoNotFound` | Le fichier ou le chemin physique n'existe pas (Erreur Système) | <ul><li>`primaryKey`: `null`</li><li>`target`: Chemin du fichier ou du dossier</li><li>`operation`: Opération I/O</li></ul> |
  | `53002`<br>`sysIoPermissionDenied` | Autorisation refusée pour l'accès au fichier (Erreur Système) | <ul><li>`primaryKey`: `null`</li><li>`target`: Chemin du fichier</li><li>`operation`: Opération I/O</li></ul> |
  | `53003`<br>`sysIoDiskFull` | Disque plein ou quota de stockage dépassé (Erreur Système) | <ul><li>`primaryKey`: `null`</li><li>`target`: Chemin du fichier</li><li>`operation`: Opération I/O</li></ul> |
  | `53004`<br>`sysIoFileLocked` | Le fichier est verrouillé ou utilisé par un autre processus (Erreur Système) | <ul><li>`primaryKey`: `null`</li><li>`target`: Chemin du fichier</li><li>`operation`: Opération I/O</li></ul> |
  | `53005`<br>`sysIoDeviceFault` | Panne du périphérique ou du support de stockage (Erreur Système) | <ul><li>`primaryKey`: `null`</li><li>`target`: Chemin du fichier</li><li>`operation`: Opération I/O</li></ul> |
  | `53006`<br>`sysIoWebStorageUnavailable` | IndexedDB Web ou stockage non disponible (Erreur Système) | <ul><li>`primaryKey`: `null`</li><li>`target`: Ressource IndexedDB</li><li>`operation`: Opération I/O</li></ul> |
  | `53007`<br>`sysBackupCorrupted` | Le package de sauvegarde est corrompu ou les métadonnées sont manquantes (Erreur Système) | <ul><li>`primaryKey`: `null`</li><li>`target`: Chemin de sauvegarde</li><li>`operation`: Lecture/écriture de sauvegarde</li></ul> |
  | `53008`<br>`sysIoDataCorrupted` | Le fichier de données de la base de données est corrompu ou le checksum a échoué (Erreur Système) | <ul><li>`primaryKey`: `null`</li><li>`target`: Chemin du fichier de données</li><li>`operation`: Opération I/O</li></ul> |
  | `53009`<br>`sysInvalidDataFormat` | Échec du formatage ou de l'analyse du flux de données (Erreur Système) | <ul><li>`primaryKey`: `null`</li><li>`target`: Clé du flux de données</li><li>`operation`: `"decode"` / `"deserialize"`</li></ul> |
  | `53099`<br>`sysIoGeneric` | Erreur I/O système générique (Erreur Système) | <ul><li>`primaryKey`: `null`</li><li>`target`: Chemin du fichier</li><li>`operation`: Opération I/O</li></ul> |
  | `99001`<br>`engError` | Erreur moteur (Erreur Moteur) | <ul><li>`primaryKey`: `null`</li></ul> |

- **Exemple JSON** (Erreur de table non trouvée) :
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

## 5. Recommandations de Résolution d'État et de Gestion des Exceptions (Exemples Dart/Flutter)

Dans ToStore, toutes les opérations d'écriture de base (Insert, Update, Delete) retournent un `DbResult`. Les requêtes retournent un `QueryResult`, et les opérations de transaction retournent un `TransactionResult`. Les erreurs de configuration structurelle lèvent une `DbException`.

Vous trouverez ci-dessous des exemples de code illustrant comment les applications clientes doivent consommer, analyser et gérer proprement les états de la base de données :

### 5.1 Gestion des Réponses d'Écriture (`DbResult`)

```dart
import 'package:tostore/tostore.dart';

void handleDatabaseWriteResult(DbResult result) {
  // 1. Vérifier instantanément si l'écriture s'est terminée entièrement sans erreur
  if (!result.hasErrors) {
    print("Toutes les opérations d'écriture ont réussi. Affectés: ${result.successCount}");

    // Pour les écritures d'une seule ligne, récupérer directement la clé sans itérer les statuts
    if (result.firstPrimaryKey != null) {
      print("Clé primaire du premier enregistrement réussi: ${result.firstPrimaryKey}");
    }
  } else {
    print("🛑 Erreur détectée. Réussis: ${result.successCount}, Échoués: ${result.failedCount}");
    print("Première erreur: ${result.firstType.codeKey} (${result.firstType.code})");

    // 2. Itérer les statuts (l'index s'aligne 1:1 avec le tableau de batch d'entrée)
    for (final status in result.statuses) {
      final int idx = status.index;

      // 3. Pattern matching sur les sous-classes pour router la logique de gestion
      if (status is SuccessStatus) {
        print("Index [$idx] Réussi. Clé primaire: ${status.primaryKey}");
      } 
      else if (status is ConstraintStatus) {
        // Gérer la violation de contrainte (clé primaire, unicité, check, clé étrangère, etc.)
        print("Index [$idx] Violation de contrainte! Table: ${status.tableName}, Colonnes: ${status.fields}");
        print("Valeurs en conflit: ${status.conflictingKeys}, PK: ${status.primaryKey}");
        print("Message d'erreur: ${status.message}");
      } 
      else if (status is InvalidArgumentStatus) {
        // Gérer les erreurs de paramètres
        print("Index [$idx] Paramètre invalide! Paramètre: ${status.parameterName}, Valeur passée: ${status.passedValue}");
      } 
      else if (status is GeneralStatus) {
        // Gérer l'expiration de verrou, disque plein, problèmes d'E/S système, etc.
        print("Index [$idx] Exception générique! Code: ${status.code} (${status.codeKey})");
        print("Message: ${status.message}");
      }
    }
  }
}
```

### 5.2 Capture de Schéma de Table et Exception d'Opération (`DbException`)

Pour la création de table (`createTable`) ou les modifications de schéma (`updateSchema`), ou dans les cas où les définitions de schéma échouent aux vérifications au niveau du code, ToStore lève une `DbException` en production :

```dart
try {
  // Ouverture de la base de données avec mises à jour de schéma
  await ToStore.open(schemas: [..]);
} on DbException catch (e) {
  print("❌ Exception fatale de la base de données! Erreur agrégée: \n${e.message}");
  
  // Itérer à travers les statuts individuels dans l'exception
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // Problèmes du validateur de schéma
      print("Échec de la validation du schéma! Table: ${status.tableName}");
      if (status.field != null) {
        print("Champ transgressif: ${status.field}, Configuration invalide: ${status.wrongValue}");
      }
    } else {
      print("Diagnostics: [${status.codeKey}] (Code ${status.code}): ${status.message}");
    }
  }
}
```

### 5.3 Gestion des Opérations de Requête (`QueryResult`) & Contrôles de Transaction (`TransactionResult`)

- **Pour les Requêtes**:
  ```dart
  final queryResult = await db.query('users').where('age', '>', 18);
  if (queryResult.hasErrors) {
    // Gérer les exceptions de requête (par exemple curseur invalide, table manquante)
    print("La requête a échoué! Code: ${queryResult.type.code}, Message: ${queryResult.message}");
  } else {
    // Requête exécutée avec succès
    final List<Map<String, dynamic>> users = queryResult.data;
    print("Récupéré ${users.length} enregistrements. A plus de données: ${queryResult.hasMore}");
  }
  ```
- **Pour les Transactions**:
  ```dart
  final txnResult = await db.transaction(() async {
    await db.insert('users', newUser);
  });

  if (txnResult.hasErrors) {
    print("Transaction annulée! TxId: ${txnResult.txId}");
    // Récupérer les détails des échecs individuels des sous-opérations
    for (final status in txnResult.statuses) {
      if (status.type != ResultType.success) {
        print("Cause de l'échec: [${status.codeKey}] ${status.message}");
      }
    }
  }
  ```

---

## 6. Référence Complète des Codes d'État Feuilles et des Identifiants Sémantiques

Reportez-vous au tableau ci-dessous pour le routage et l'analyse exacts des états :

| Code d'État (Code) | Identifiant (CodeKey) | Enum en Mémoire (ResultType) | Catégorie | Description |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `ResultType.success` | Succès | Opération exécutée avec succès |
| **10000** | `BIZ_VALIDATION_FAILED` | `ResultType.bizValidationFailed` | Erreur Métier | Échec de validation du format ou de la plage de données |
| **10001** | `BIZ_NOT_NULL_VIOLATION` | `ResultType.bizNotNullViolation` | Erreur Métier | Violation de la contrainte not null |
| **10002** | `BIZ_VALIDATION_TYPE_CAST` | `ResultType.bizTypeCastFailed` | Erreur Métier | Échec de conversion ou de transtypage de type de données |
| **11001** | `BIZ_CONSTRAINT_PRIMARY_KEY` | `ResultType.bizPrimaryKeyViolation` | Erreur Métier | Conflit de clé primaire (existe déjà) |
| **11002** | `BIZ_CONSTRAINT_UNIQUE` | `ResultType.bizUniqueViolation` | Erreur Métier | Violation de contrainte d'unicité |
| **11003** | `BIZ_CONSTRAINT_FOREIGN_KEY` | `ResultType.bizForeignKeyViolation` | Erreur Métier | Violation de contrainte de clé étrangère (Générique) |
| **11004** | `BIZ_CONSTRAINT_CHECK` | `ResultType.bizCheckViolation` | Erreur Métier | Violation de contrainte check |
| **11005** | `BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST` | `ResultType.bizForeignKeyParentNotExist` | Erreur Métier | La clé parente référencée n'existe pas |
| **11006** | `BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT` | `ResultType.bizForeignKeyChildRestrict` | Erreur Métier | Suppression/mise à jour restreinte par les enregistrements enfants |
| **11007** | `BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH` | `ResultType.bizForeignKeyCompositeMismatch` | Erreur Métier | Valeurs de clé étrangère composite incomplètes |
| **11008** | `BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH` | `ResultType.bizForeignKeyTypeMismatch` | Erreur Métier | Non-correspondance de type de clé étrangère |
| **11009** | `BIZ_CONSTRAINT_MAX_LENGTH` | `ResultType.bizValueExceedsMaxLength` | Erreur Métier | La longueur de la valeur dépasse la contrainte maximale |
| **11010** | `BIZ_CONSTRAINT_MIN_LENGTH` | `ResultType.bizValueLessThanMinLength` | Erreur Métier | La longueur de la valeur est inférieure à la contrainte minimale |
| **11011** | `BIZ_CONSTRAINT_MIN_VALUE` | `ResultType.bizValueLessThanMinValue` | Erreur Métier | La valeur numérique est inférieure à la contrainte minimale |
| **11012** | `BIZ_CONSTRAINT_MAX_VALUE` | `ResultType.bizValueExceedsMaxValue` | Erreur Métier | La valeur numérique dépasse la contrainte maximale |
| **12001** | `BIZ_NOT_FOUND_RECORD` | `ResultType.bizRecordNotFound` | Erreur Métier | Ressource inexistante / Enregistrement non trouvé |
| **20001** | `DEV_INVALID_ARGUMENT_FORMAT` | `ResultType.devInvalidArgumentFormat` | Erreur Développeur | Erreur de format d'argument |
| **20002** | `DEV_INVALID_ARGUMENT_TYPE` | `ResultType.devInvalidArgumentType` | Erreur Développeur | Non-correspondance de type d'argument |
| **20003** | `DEV_INVALID_ARGUMENT_MISSING` | `ResultType.devInvalidArgumentMissing` | Erreur Développeur | L'argument requis est manquant |
| **20004** | `DEV_INVALID_PRIMARY_KEY_FORMAT` | `ResultType.devInvalidPrimaryKeyFormat` | Erreur Développeur | Format de clé primaire invalide |
| **20005** | `DEV_INDEX_OUT_OF_BOUNDS` | `ResultType.devIndexOutOfBounds` | Erreur Développeur | L'index ou la plage est hors limites |
| **20006** | `DEV_UNSUPPORTED_OPERATION` | `ResultType.devUnsupportedOperation` | Erreur Développeur | L'opération n'est pas supportée dans le contexte actuel |
| **20007** | `DEV_VECTOR_DIMENSION_MISMATCH` | `ResultType.devVectorDimensionMismatch` | Erreur Développeur | Non-correspondance des dimensions vectorielles |
| **20008** | `DEV_INDEX_FIELD_MISSING` | `ResultType.devIndexFieldMissing` | Erreur Développeur | Champ d'index requis manquant dans l'enregistrement pour le curseur |
| **20101** | `DEV_INVALID_CURSOR_PAGINATION` | `ResultType.devInvalidCursorPagination` | Erreur Développeur | La pagination par curseur et l'offset sont mutuellement exclusifs |
| **20102** | `DEV_INVALID_CURSOR_TABLE` | `ResultType.devInvalidCursorTable` | Erreur Développeur | Le curseur ne correspond pas à la table cible |
| **20103** | `DEV_INVALID_CURSOR_SIGNATURE` | `ResultType.devInvalidCursorSignature` | Erreur Développeur | Signature de curseur non correspondante (altérée) |
| **20104** | `DEV_INVALID_CURSOR_ORDERBY` | `ResultType.devInvalidCursorOrderBy` | Erreur Développeur | Configuration orderBy du curseur invalide ou non correspondante |
| **20105** | `DEV_INVALID_CURSOR_MODE` | `ResultType.devInvalidCursorMode` | Erreur Développeur | Non-correspondance du mode de jeton de curseur |
| **20106** | `DEV_INVALID_CURSOR_PAYLOAD` | `ResultType.devInvalidCursorPayload` | Erreur Développeur | Charge utile de curseur invalide (indécodable) |
| **20201** | `DEV_INVALID_QUERY_SELECT_FIELD` | `ResultType.devInvalidQuerySelectField` | Erreur Développeur | Le champ de sélection de requête doit être String ou QueryAggregation |
| **20202** | `DEV_INVALID_QUERY_FOREIGN_KEY_JOIN` | `ResultType.devInvalidQueryForeignKeyJoin` | Erreur Développeur | Pas de relation de clé étrangère pour l'auto-join |
| **20203** | `DEV_INVALID_QUERY_FIELD_ALIAS` | `ResultType.devInvalidQueryFieldAlias` | Erreur Développeur | Format d'alias de champ de requête invalide |
| **20204** | `DEV_INVALID_EXPRESSION` | `ResultType.devInvalidExpression` | Erreur Développeur | Configuration d'expression invalide ou exception d'exécution |
| **22001** | `DEV_NOT_FOUND_TABLE` | `ResultType.devTableNotFound` | Erreur Développeur | Table non trouvée |
| **22002** | `DEV_NOT_FOUND_INDEX` | `ResultType.devIndexNotFound` | Erreur Développeur | Index non trouvé |
| **22003** | `DEV_NOT_FOUND_SPACE` | `ResultType.devSpaceNotFound` | Erreur Développeur | Espace non trouvé |
| **22004** | `DEV_NOT_FOUND_FIELD` | `ResultType.devFieldNotFound` | Erreur Développeur | Champ non trouvé |
| **23001** | `DEV_LARGE_SCALE_OPERATION_REQUIRED` | `ResultType.devLargeScaleOperationRequired` | Erreur Développeur | Large-scale data operation requires `allowLargeScaleOperation()` to prevent OOM |
| **23002** | `DEV_LARGE_SCALE_OPERATION_NOT_ALLOWED_IN_TRANSACTION` | `ResultType.devLargeScaleOperationNotAllowedInTransaction` | Developer Error | Large-scale data operation is not allowed inside a transaction |
| **24001** | `DEV_ENGINE_INCOMPATIBLE` | `ResultType.devEngineIncompatible` | Erreur Développeur | **Critique**: Version du moteur incompatible |
| **30000** | `DEV_INVALID_SCHEMA` | `ResultType.devInvalidSchema` | Erreur Développeur | Définition de schéma de table invalide |
| **30001** | `DEV_INVALID_SCHEMA_TABLE_NAME` | `ResultType.devInvalidSchemaTableName` | Erreur Développeur | Échec de validation du nom de la table |
| **30002** | `DEV_INVALID_SCHEMA_FIELD_NAME` | `ResultType.devInvalidSchemaFieldName` | Erreur Développeur | Échec de validation du nom du champ |
| **30003** | `DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME` | `ResultType.devInvalidSchemaDuplicateFieldName` | Erreur Développeur | Nom de champ dupliqué dans le schéma de la table |
| **30004** | `DEV_INVALID_SCHEMA_PRIMARY_KEY` | `ResultType.devInvalidSchemaPrimaryKey` | Erreur Développeur | Échec de validation de la clé primaire |
| **30005** | `DEV_INVALID_SCHEMA_INDEX_LIMIT` | `ResultType.devInvalidSchemaIndexLimit` | Erreur Développeur | Échec de validation du nombre d'index |
| **30006** | `DEV_INVALID_SCHEMA_INDEX_FIELD` | `ResultType.devInvalidSchemaIndexField` | Erreur Développeur | L'index fait référence à un champ inexistant |
| **30007** | `DEV_INVALID_SCHEMA_INDEX_TYPE` | `ResultType.devInvalidSchemaIndexType` | Erreur Développeur | Type d'index incompatible avec le type de données ou la configuration du champ |
| **30008** | `DEV_INVALID_SCHEMA_FOREIGN_KEY` | `ResultType.devInvalidSchemaForeignKey` | Erreur Développeur | Définition de clé étrangère invalide |
| **30009** | `DEV_INVALID_SCHEMA_SPACE_MISMATCH` | `ResultType.devInvalidSchemaSpaceMismatch` | Erreur Développeur | Non-correspondance de limite globale/spécifique à l'espace |
| **30010** | `DEV_INVALID_SCHEMA_TTL_CONFIG` | `ResultType.devInvalidSchemaTtlConfig` | Erreur Développeur | Échec de la validation de la configuration TTL |
| **30011** | `DEV_SCHEMA_TABLE_EXISTS` | `ResultType.devSchemaTableExists` | Erreur Développeur | La table existe déjà |
| **30012** | `DEV_SCHEMA_FIELD_EXISTS` | `ResultType.devSchemaFieldExists` | Erreur Développeur | Le champ existe déjà |
| **30013** | `DEV_SCHEMA_INDEX_EXISTS` | `ResultType.devSchemaIndexExists` | Erreur Développeur | L'index existe déjà |
| **31001** | `DEV_MIGRATION_NOT_ALLOWED_WITH_DATA` | `ResultType.devMigrationNotAllowedWithData` | Erreur Développeur | La migration nécessite une modification des données et n'a pas été explicitement autorisée |
| **31002** | `DEV_MIGRATION_UNSAFE_TYPE_CONVERSION` | `ResultType.devMigrationUnsafeTypeConversion` | Erreur Développeur | Type de changement non pris en charge pour le champ |
| **31003** | `DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD` | `ResultType.devMigrationCannotAddNonNullField` | Erreur Développeur | Impossible d'ajouter un champ non-nullable sans valeur par défaut |
| **31004** | `DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED` | `ResultType.devMigrationNullableToNonNullNotAllowed` | Erreur Développeur | Le changement de champ de nullable à non-nullable n'est pas autorisé |
| **31005** | `DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED` | `ResultType.devMigrationUniqueTighteningNotAllowed` | Erreur Développeur | Resserrement vers UNIQUE non autorisé |
| **31006** | `DEV_MIGRATION_PROMOTE_LARGE_OP_NOT_ALLOWED` | `ResultType.devMigrationPromoteLargeOpNotAllowed` | Erreur Développeur | Opérations à grande échelle bloquées pendant promoteFieldToPrimaryKey |
| **50001** | `SYS_TRANSACTION_ABORTED` | `ResultType.sysTransactionAborted` | Erreur Système | Transaction annulée |
| **50002** | `SYS_TRANSACTION_CONFLICT` | `ResultType.sysTransactionConflict` | Erreur Système | Conflit de transaction |
| **50003** | `SYS_TRANSACTION_LIMIT_EXCEEDED` | `ResultType.sysTransactionLimitExceeded` | Erreur Système | La transaction dépasse la limite mémoire sûre sous pression mémoire |
| **50004** | `SYS_MIGRATION_BATCH_EXECUTION_FAILED` | `ResultType.sysMigrationBatchExecutionFailed` | Erreur Système | **Critique**: Échec de l'exécution du lot de migration |
| **51001** | `SYS_TIMEOUT_LOCK_ACQUISITION` | `ResultType.sysTimeoutLockAcquisition` | Erreur Système | Expiration de l'acquisition du verrou |
| **51002** | `SYS_TIMEOUT` | `ResultType.sysTimeout` | Erreur Système | Expiration de l'opération |
| **51003** | `SYS_DB_CLOSED` | `ResultType.sysDbClosed` | Erreur Système | La base de données est fermée, l'opération a été annulée en toute sécurité |
| **52001** | `SYS_RESOURCE_EXHAUSTED_MEMORY` | `ResultType.sysResourceExhaustedMemory` | Erreur Système | **Critique**: Ressources mémoire épuisées |
| **52002** | `SYS_RESOURCE_EXHAUSTED` | `ResultType.sysResourceExhausted` | Erreur Système | **Critique**: Ressources système épuisées |
| **53001** | `SYS_IO_NOT_FOUND` | `ResultType.sysIoNotFound` | Erreur Système | Le fichier ou le chemin physique n'existe pas |
| **53002** | `SYS_IO_PERMISSION_DENIED` | `ResultType.sysIoPermissionDenied` | Erreur Système | Autorisation refusée pour l'accès au fichier |
| **53003** | `SYS_IO_DISK_FULL` | `ResultType.sysIoDiskFull` | Erreur Système | **Critique**: Disque plein ou quota de stockage dépassé |
| **53004** | `SYS_IO_FILE_LOCKED` | `ResultType.sysIoFileLocked` | Erreur Système | Le fichier est verrouillé ou utilisé par un autre processus |
| **53005** | `SYS_IO_DEVICE_FAULT` | `ResultType.sysIoDeviceFault` | Erreur Système | **Critique**: Panne du périphérique ou du support de stockage |
| **53006** | `SYS_IO_WEB_STORAGE_UNAVAILABLE` | `ResultType.sysIoWebStorageUnavailable` | Erreur Système | IndexedDB Web ou stockage non disponible |
| **53007** | `SYS_BACKUP_CORRUPTED` | `ResultType.sysBackupCorrupted` | Erreur Système | Le package de sauvegarde est corrompu ou les métadonnées sont manquantes |
| **53008** | `SYS_IO_DATA_CORRUPTED` | `ResultType.sysIoDataCorrupted` | Erreur Système | **Critique**: Le fichier de données de la base de données est corrompu ou le checksum a échoué |
| **53009** | `SYS_INVALID_DATA_FORMAT` | `ResultType.sysInvalidDataFormat` | Erreur Système | Échec du formatage ou de l'analyse du flux de données |
| **53099** | `SYS_IO_GENERIC` | `ResultType.sysIoGeneric` | Erreur Système | Erreur I/O système générique |
| **99001** | `ENG_ERROR` | `ResultType.engError` | Erreur Moteur | Erreur moteur |
