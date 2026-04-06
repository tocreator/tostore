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
  Français | 
  <a href="README.it.md">Italiano</a> | 
  <a href="README.tr.md">Türkçe</a>
</p>

## Navigation rapide
- **Mise en route** : [Pourquoi ToStore](#why-tostore) | [Fonctionnalités clés](#key-features) | [Guide d'installation](#installation) | [Mode KV](#quick-start-kv) | [Mode Tableau](#quick-start-table) | [Mode mémoire](#quick-start-memory)
- **Architecture et modèle** : [Définition du schéma](#schema-definition) | [Architecture distribuée](#distributed-architecture) | [Clés étrangères en cascade](#foreign-keys) | [Mobile/Ordinateur de bureau](#mobile-integration) | [Serveur/Agent](#server-integration) | [Algorithmes de clé primaire](#primary-key-examples)
- **Requêtes avancées** : [Requêtes avancées (JOIN)](#query-advanced) | [Agrégation & Statistiques](#aggregation-stats) | [Logique complexe (QueryCondition)](#query-condition) | [Requête réactive (regarder)](#reactive-query) | [Requête en streaming](#streaming-query)
- **Avancé et performances** : [Recherche de vecteurs](#vector-advanced) | [TTL au niveau de la table](#ttl-config) | [Pagination efficace](#query-pagination) | [Cache de requêtes](#query-cache) | [Expressions atomiques](#atomic-expressions) | [Transactions](#transactions)
- **Opérations et sécurité** : [Administration](#database-maintenance) | [Configuration de sécurité](#security-config) | [Gestion des erreurs](#error-handling) | [Performances et diagnostics](#performance) | [Plus de ressources](#more-resources)

<a id="why-tostore"></a>
## Pourquoi choisir ToStore ?

ToStore est un moteur de données moderne conçu pour l'ère AGI et les scénarios d'intelligence de pointe. Il prend en charge nativement les systèmes distribués, la fusion multimodale, les données relationnelles structurées, les vecteurs de grande dimension et le stockage de données non structurées. Construit sur une architecture de nœuds à auto-routage et un moteur inspiré des réseaux neuronaux, il offre aux nœuds une grande autonomie et une évolutivité horizontale élastique tout en dissociant logiquement les performances de l'échelle des données. Il comprend des transactions ACID, des requêtes relationnelles complexes (JOIN et clés étrangères en cascade), des TTL au niveau des tables et des agrégations, ainsi que plusieurs algorithmes de clé primaire distribués, des expressions atomiques, la reconnaissance des modifications de schéma, le cryptage, l'isolation des données multi-espaces, la planification de charge intelligente tenant compte des ressources et la récupération automatique après sinistre/accident.

Alors que l’informatique continue d’évoluer vers l’intelligence de pointe, les agents, capteurs et autres appareils ne sont plus de simples « affichages de contenu ». Ce sont des nœuds intelligents responsables de la production locale, de la sensibilisation à l’environnement, de la prise de décision en temps réel et des flux de données coordonnés. Les solutions de bases de données traditionnelles sont limitées par leur architecture sous-jacente et leurs extensions intégrées, ce qui rend de plus en plus difficile de satisfaire aux exigences de faible latence et de stabilité des applications intelligentes du cloud périphérique dans des contextes d'écritures à haute concurrence, d'ensembles de données massifs, de récupération vectorielle et de génération collaborative.

ToStore offre des capacités distribuées de pointe suffisamment puissantes pour des ensembles de données massifs, la génération d'IA locale complexe et le mouvement de données à grande échelle. Une collaboration intelligente et approfondie entre les nœuds périphériques et cloud fournit une base de données fiable pour la réalité mixte immersive, l'interaction multimodale, les vecteurs sémantiques, la modélisation spatiale et des scénarios similaires.

<a id="key-features"></a>
## Principales fonctionnalités

- 🌐 **Moteur de données multiplateforme unifié**
  - API unifiée dans les environnements mobiles, de bureau, Web et serveur
  - Prend en charge les données relationnelles structurées, les vecteurs de grande dimension et le stockage de données non structurées
  - Crée un pipeline de données depuis le stockage local jusqu'à la collaboration Edge-Cloud

- 🧠 **Architecture distribuée de style réseau neuronal**
  - Architecture de nœud à auto-routage qui dissocie l'adressage physique de l'échelle
  - Les nœuds hautement autonomes collaborent pour créer une topologie de données flexible
  - Prend en charge la coopération de nœuds et la mise à l'échelle horizontale élastique
  - Interconnexion approfondie entre les nœuds intelligents en périphérie et le cloud

- ⚡ **Exécution parallèle et planification des ressources**
  - Planification de charge intelligente tenant compte des ressources et haute disponibilité
  - Collaboration parallèle multi-nœuds et décomposition des tâches
  - Le découpage temporel maintient les animations de l'interface utilisateur fluides même sous une charge importante

- 🔍 **Requêtes structurées et récupération de vecteurs**
  - Prend en charge les prédicats complexes, les JOIN, les agrégations et le TTL au niveau de la table
  - Prend en charge les champs vectoriels, les index vectoriels et la récupération du voisin le plus proche
  - Les données structurées et vectorielles peuvent fonctionner ensemble dans le même moteur

- 🔑 **Clés primaires, index et évolution de schéma**
  - Algorithmes de clé primaire intégrés comprenant des stratégies séquentielles, d'horodatage, de préfixe de date et de code court
  - Prend en charge les index uniques, les index composites, les index vectoriels et les contraintes de clé étrangère
  - Détecte automatiquement les modifications de schéma et termine le travail de migration

- 🛡️ **Transactions, sécurité et récupération**
  - Fournit des transactions ACID, des mises à jour d'expressions atomiques et des clés étrangères en cascade
  - Prend en charge la récupération après incident, les validations durables et les garanties de cohérence
  - Prend en charge le cryptage ChaCha20-Poly1305 et AES-256-GCM

- 🔄 **Flux de travail multi-espaces et données**
  - Prend en charge les espaces isolés avec des données facultatives partagées à l'échelle mondiale
  - Prend en charge les écouteurs de requêtes en temps réel, la mise en cache intelligente à plusieurs niveaux et la pagination du curseur
  - Convient aux applications collaboratives multi-utilisateurs, locales et hors ligne

<a id="installation"></a>
## Installation

> [!IMPORTANT]
> **Mise à niveau depuis la v2.x ?** Veuillez lire le [Guide de mise à niveau vers la v3.x](../UPGRADE_GUIDE_v3.md) pour connaître les étapes de migration critiques et les modifications majeures.

Ajoutez `tostore` à votre `pubspec.yaml` :

```yaml
dependencies:
  tostore: any # Please use the latest version
```

<a id="quick-start"></a>
## Démarrage rapide

> [!TIP]
> **Comment choisir un mode de stockage ?**
> 1. [**Key-Value Mode (KV)**](#quick-start-kv) : Idéal pour l'accès à la configuration, la gestion des états dispersés ou le stockage de données JSON. C'est le moyen le plus rapide de démarrer.
> 2. [**Mode table structurée**](#quick-start-table) : Idéal pour les données métier de base qui nécessitent des requêtes complexes, une validation de contraintes ou une gouvernance des données à grande échelle. En intégrant la logique d’intégrité dans le moteur, vous pouvez réduire considérablement les coûts de développement et de maintenance de la couche applicative.
> 3. [**Mode mémoire**](#quick-start-memory) : idéal pour les calculs temporaires, les tests unitaires ou la **gestion globale ultra-rapide de l'état**. Avec les requêtes globales et les écouteurs `watch`, vous pouvez remodeler l'interaction des applications sans conserver une pile de variables globales.

<a id="quick-start-kv"></a>
### Stockage de valeurs-clés (KV)
Ce mode convient lorsque vous n'avez pas besoin de tableaux structurés prédéfinis. C'est simple, pratique et soutenu par un moteur de stockage hautes performances. **Son architecture d'indexation efficace maintient les performances des requêtes très stables et extrêmement réactives, même sur les appareils mobiles ordinaires à très grande échelle de données.** Les données dans différents espaces sont naturellement isolées, tandis que le partage mondial est également pris en charge.

```dart
// Initialize the database
final db = await ToStore.open();

// Set key-value pairs (supports String, int, bool, double, Map, List, Json, and more)
await db.setValue('user_profile', {
  'name': 'John',
  'age': 25,
});

// Switch space - isolate data for different users
await db.switchSpace(spaceName: 'user_123');

// Set a globally shared variable (isGlobal: true enables cross-space sharing, such as login state)
await db.setValue('current_user', 'John', isGlobal: true);

// Automatic expiration cleanup (TTL)
// Supports either a relative lifetime (ttl) or an absolute expiration time (expiresAt)
await db.setValue('temp_config', 'value', ttl: Duration(hours: 2));
await db.setValue('session_token', 'abc', expiresAt: DateTime(2026, 2, 31));

// Read data
final profile = await db.getValue('user_profile'); // Map<String, dynamic>

// Listen for real-time value changes (useful for refreshing local UI without extra state frameworks)
db.watchValue('current_user', isGlobal: true).listen((value) {
  print('Logged-in user changed to: $value');
});

// Listen to multiple keys at once
db.watchValues(['current_user', 'login_status']).listen((map) {
  print('Multiple config values were updated: $map');
});

// Remove data
await db.removeValue('current_user');
```

#### Exemple d'actualisation automatique de l'interface utilisateur Flutter
Dans Flutter, `StreamBuilder` plus `watchValue` vous offre un flux de rafraîchissement réactif très concis :

```dart
StreamBuilder(
  // When listening to a global variable, remember to set isGlobal: true
  stream: db.watchValue('current_user', isGlobal: true),
  builder: (context, snapshot) {
    // snapshot.data is the latest value of 'current_user' in KV storage
    final user = snapshot.data ?? 'Not logged in';
    return Text('Current user: $user');
  },
)
```

<a id="quick-start-table"></a>
### Mode tableau structuré
CRUD sur les tables structurées nécessite que le schéma soit créé à l'avance (voir [Définition du schéma](#schema-definition)). Approches d'intégration recommandées pour différents scénarios :
- **Mobile/Bureau** : pour les [scénarios de démarrage fréquents](#mobile-integration), il est recommandé de transmettre `schemas` lors de l'initialisation.
- **Serveur/Agent** : pour les [scénarios de longue durée](#server-integration), il est recommandé de créer des tables de manière dynamique via `createTables`.

```dart
// 1. Initialize the database
final db = await ToStore.open();

// 2. Insert data (prepare some base records)
final result = await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// Unified operation result model: DbResult
// It is recommended to always check isSuccess
if (result.isSuccess) {
  print('Insert succeeded, generated primary key ID: ${result.successKeys.first}');
} else {
  print('Insert failed: ${result.message}');
}

// Chained query (see [Query Operators](#query-operators); supports =, !=, >, <, LIKE, IN, and more)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// Update and delete
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// Real-time listening (see [Reactive Query](#reactive-query) for more details)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Users matching the condition have changed: $users');
});

// Pair with Flutter StreamBuilder for automatic local UI refresh
StreamBuilder(
  stream: db.query('users').where('age', '>', 18).watch(),
  builder: (context, snapshot) {
    final users = snapshot.data ?? [];
    return ListView.builder(
      itemCount: users.length,
      itemBuilder: (context, index) => Text(users[index]['username']),
    );
  },
);
```

<a id="quick-start-memory"></a>
### Mode mémoire

Pour des scénarios tels que la mise en cache, le calcul temporaire ou les charges de travail qui ne nécessitent pas de persistance sur le disque, vous pouvez initialiser une base de données en mémoire pure via `ToStore.memory()`. Dans ce mode, toutes les données, y compris les schémas, les index et les paires clé-valeur, résident entièrement en mémoire pour des performances de lecture/écriture maximales.

#### 💡 Fonctionne également comme gestion globale de l'état
Vous n'avez pas besoin d'une pile de variables globales ou d'un cadre de gestion d'état lourd. En combinant le mode mémoire avec `watchValue` ou `watch()`, vous pouvez obtenir une actualisation entièrement automatique de l'interface utilisateur sur les widgets et les pages. Il conserve les puissantes capacités de récupération d'une base de données tout en vous offrant une expérience réactive bien au-delà des variables ordinaires, ce qui le rend idéal pour l'état de connexion, la configuration en direct ou les compteurs de messages globaux.

> [!CAUTION]
> **Remarque** : Les données créées en mode mémoire pure sont complètement perdues après la fermeture ou le redémarrage de l'application. Ne l'utilisez pas pour les données commerciales de base.

```dart
// Initialize a pure in-memory database
final memDb = await ToStore.memory();

// Set a global state value (for example: unread message count)
await memDb.setValue('unread_count', 5, isGlobal: true);

// Listen from anywhere in the UI without passing parameters around
memDb.watchValue<int>('unread_count', isGlobal: true).listen((count) {
  print('UI automatically sensed the message count change: $count');
});

// All CRUD, KV access, and vector search run at in-memory speed
await memDb.insert('active_users', {'name': 'Marley', 'status': 'online'});
```


<a id="schema-definition"></a>
## Définition du schéma
**Définissez une seule fois et laissez le moteur gérer une gouvernance automatisée de bout en bout afin que votre application ne subisse plus de maintenance de validation lourde.**

Les exemples suivants de mobile, côté serveur et agent réutilisent tous `appSchemas` défini ici.


### Présentation du schéma de table

```dart
const userSchema = TableSchema(
  name: 'users', // Table name, required
  tableId: 'users', // Unique identifier of the table, optional
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // Primary key field name, defaults to id
    type: PrimaryKeyType.sequential, // Primary key auto-generation strategy
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, // Initial value for sequential IDs
      increment: 1, // Step size
      useRandomIncrement: false, // Whether to use random step sizes
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username', // Field name, required
      type: DataType.text, // Field data type, required
      nullable: false, // Whether null is allowed
      minLength: 3, // Minimum length
      maxLength: 32, // Maximum length
      unique: true, // Whether it must be unique
      fieldId: 'username', // Stable field identifier, optional, used to detect field renames
      comment: 'Login name', // Optional comment
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0, // Minimum numeric value
      maxValue: 150, // Maximum numeric value
      defaultValue: 0, // Static default value
      createIndex: true, // Shortcut for creating an index
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // Automatically fill with current time
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at', // Optional index name
      fields: ['status', 'created_at'], // Composite index fields
      unique: false, // Whether it is a unique index
      type: IndexType.btree, // Index type: btree/hash/bitmap/vector
    ),
  ],
  foreignKeys: const [], // Optional foreign-key constraints; see "Foreign Keys & Cascading"
  isGlobal: false, // Whether this is a global table; true means it can be shared across spaces
  ttlConfig: null, // Optional table-level TTL; see "Table-level TTL"
);

const appSchemas = [userSchema];
```

- **Mappages `DataType` courants** :
  | Tapez | Type de fléchette correspondant | Descriptif |
  | :--- | :--- | :--- |
| `integer` | `int` | Entier standard, adapté aux identifiants, compteurs et données similaires |
  | `bigInt` | `BigInt` / `String` | Grands entiers ; recommandé lorsque les nombres dépassent 18 chiffres pour éviter toute perte de précision |
  | `double` | `double` | Nombre à virgule flottante, adapté aux prix, coordonnées et données similaires |
  | `text` | `String` | Chaîne de texte avec contraintes de longueur facultatives |
  | `blob` | `Uint8List` | Données binaires brutes |
  | `boolean` | `bool` | Valeur booléenne |
  | `datetime` | `DateTime` / `String` | Date/heure ; stocké en interne sous ISO8601 |
  | `array` | `List` | Type de liste ou de tableau |
  | `json` | `Map<String, dynamic>` | Objet JSON, adapté aux données structurées dynamiques |
  | `vector` | `VectorData` / `List<num>` | Données vectorielles haute dimension pour la récupération sémantique de l'IA (embeddings) |

- **`PrimaryKeyType` stratégies d'auto-génération** :
  | Stratégie | Descriptif | Caractéristiques |
  | :--- | :--- | :--- |
| `none` | Pas de génération automatique | Vous devez fournir manuellement la clé primaire lors de l'insertion |
  | `sequential` | Incrément séquentiel | Bon pour les identifiants conviviaux, mais moins adapté aux performances distribuées |
  | `timestampBased` | Basé sur l'horodatage | Recommandé pour les environnements distribués |
  | `datePrefixed` | Préfixé par la date | Utile lorsque la lisibilité de la date est importante pour l'entreprise |
  | `shortCode` | Clé primaire de code court | Compact et adapté à un affichage externe |

> Toutes les clés primaires sont stockées sous `text` (`String`) par défaut.


### Contraintes et validation automatique

Vous pouvez écrire des règles de validation communes directement dans `FieldSchema`, évitant ainsi la duplication de logique dans le code de l'application :

- `nullable: false` : contrainte non nulle
- `minLength` / `maxLength` : contraintes de longueur de texte
- `minValue` / `maxValue` : contraintes de plage entière ou flottante
- `defaultValue` / `defaultValueType` : valeurs par défaut statiques et valeurs par défaut dynamiques
- `unique` : contrainte unique
- `createIndex` : créez des index pour le filtrage, le tri ou les relations haute fréquence
- `fieldId` / `tableId` : aide à la détection du renommage des champs et des tables lors de la migration

De plus, `unique: true` crée automatiquement un index unique à champ unique. `createIndex: true` et les clés étrangères créent automatiquement des index normaux à champ unique. Utilisez `indexes` lorsque vous avez besoin d'index composites, d'index nommés ou d'index vectoriels.


### Choisir une méthode d'intégration

- **Mobile/Ordinateur** : Idéal pour passer `appSchemas` directement dans `ToStore.open(...)`
- **Serveur/Agent** : Idéal lors de la création dynamique de schémas au moment de l'exécution via `createTables(appSchemas)`


<a id="mobile-integration"></a>
## Intégration pour les mobiles, les ordinateurs de bureau et d'autres scénarios de démarrage fréquents

📱 **Exemple** : [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// On Android/iOS, resolve the app's writable directory first, then pass dbPath explicitly
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

// Reuse the appSchemas defined above
final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// Multi-space architecture - isolate data for different users
await db.switchSpace(spaceName: 'user_123');
```

### Évolution du schéma

Pendant `ToStore.open()`, le moteur détecte automatiquement les modifications structurelles dans `schemas`, telles que l'ajout, la suppression, le renommage ou la modification de tables et de champs, ainsi que les modifications d'index, puis effectue le travail de migration nécessaire. Vous n'avez pas besoin de gérer manuellement les numéros de version de la base de données ni d'écrire des scripts de migration.


### Conserver l'état de connexion et de déconnexion (espace actif)

Le multi-espace est idéal pour **isoler les données utilisateur** : un espace par utilisateur, activé la connexion. Avec **Active Space** et les options de fermeture, vous pouvez conserver l'utilisateur actuel lors des redémarrages de l'application et prendre en charge un comportement de déconnexion propre.

- **Conserver l'état de connexion** : après avoir basculé un utilisateur vers son propre espace, marquez cet espace comme actif. Le prochain lancement peut entrer dans cet espace directement lors de l'ouverture de l'instance par défaut, sans étape « par défaut d'abord, puis changer ».
- **Déconnexion** : Lorsque l'utilisateur se déconnecte, fermez la base de données avec `keepActiveSpace: false`. Le prochain lancement n'entrera pas automatiquement dans l'espace de l'utilisateur précédent.

```dart
// After login: switch to the user's space and mark it active
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Optional: strictly stay in default when needed (for example, login screen only)
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// On logout: close and clear the active space so the next launch starts from default
await db.close(keepActiveSpace: false);
```


<a id="server-integration"></a>
## Intégration côté serveur/agent (scénarios de longue durée)

🖥️ **Exemple** : [server_quickstart.dart](../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Create table structures while the process is running
await db.createTables(appSchemas);

// Online schema updates
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // Rename table
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // Modify field attributes
  .renameField('old_name', 'new_name')     // Rename field
  .removeField('deprecated_field')         // Remove field
  .addField('created_at', type: DataType.datetime)  // Add field
  .removeIndex(fields: ['age'])            // Remove index
  .setPrimaryKeyConfig(                    // Change PK type; existing data must be empty or a warning will be issued
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );

// Monitor migration progress
final status = await db.queryMigrationTaskStatus(taskId);
print('Migration progress: ${status?.progressPercentage}%');


// Optional performance tuning for pure server workloads
// yieldDurationMs controls how often long-running work yields time slices.
// The default is tuned to 8ms to keep frontend UI animations smooth.
// In environments without UI, 50ms is recommended for higher throughput.
final dbServer = await ToStore.open(
  config: DataStoreConfig(yieldDurationMs: 50),
);
```


<a id="advanced-usage"></a>
## Utilisation avancée

ToStore fournit un riche ensemble de fonctionnalités avancées pour des scénarios commerciaux complexes :


<a id="vector-advanced"></a>
### Champs vectoriels, index vectoriels et recherche de vecteurs

```dart
await db.createTables([
  const TableSchema(
    name: 'embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,
    ),
    fields: [
      FieldSchema(
        name: 'document_title',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'embedding',
        type: DataType.vector, // Declare a vector field
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: 128, // Written and queried vectors must match this width
          precision: VectorPrecision.float32, // float32 usually balances precision and storage well
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'], // Field to index
        type: IndexType.vector, // Build a vector index
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh, // Built-in vector index type
          distanceMetric: VectorDistanceMetric.cosine, // Good for normalized embeddings
          maxDegree: 32, // More neighbors usually improve recall at higher memory cost
          efSearch: 64, // Higher recall but slower queries
          constructionEf: 128, // Higher-quality index but slower build time
        ),
      ),
    ],
  ),
]);

final queryVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.01)); // Must match dimensions

// Vector search
final results = await db.vectorSearch(
  'embeddings',
  fieldName: 'embedding',
  queryVector: queryVector,
  topK: 5, // Return the top 5 nearest records
  efSearch: 64, // Override the search expansion factor for this request
);

for (final r in results) {
  print('pk=${r.primaryKey}, score=${r.score}, distance=${r.distance}');
}
```

Remarques sur les paramètres :

- `dimensions` : doit correspondre à la largeur d'intégration réelle que vous écrivez
- `precision` : les choix courants incluent `float64`, `float32` et `int8` ; une plus grande précision coûte généralement plus de stockage
- `distanceMetric` : `cosine` est courant pour les plongements sémantiques, `l2` convient à la distance euclidienne et `innerProduct` convient à la recherche de produits scalaires.
- `maxDegree` : borne supérieure des voisins retenus par nœud dans le graphe NGH ; des valeurs plus élevées améliorent généralement le rappel au prix de plus de mémoire et de temps de construction
- `efSearch` : largeur d'expansion du temps de recherche ; l'augmenter améliore généralement le rappel mais augmente la latence
- `constructionEf` : largeur d'expansion au moment de la construction ; l'augmenter améliore généralement la qualité de l'index mais augmente le temps de construction
- `topK` : nombre de résultats à retourner

Notes de résultat :

- `score` : score de similarité normalisé, typiquement dans la plage `0 ~ 1` ; plus grand signifie plus semblable
- `distance` : valeur de distance ; pour `l2` et `cosine`, plus petit signifie généralement plus similaire

<a id="ttl-config"></a>
### TTL au niveau de la table (expiration automatique basée sur le temps)

Pour les journaux, la télémétrie, les événements et autres données qui devraient expirer avec le temps, vous pouvez définir la durée de vie au niveau de la table via `ttlConfig`. Le moteur nettoiera automatiquement les enregistrements expirés en arrière-plan :

```dart
const TableSchema(
  name: 'event_logs',
  fields: [
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      createIndex: true,
      defaultValueType: DefaultValueType.currentTimestamp,
    ),
  ],
  ttlConfig: TableTtlConfig(
    ttlMs: 7 * 24 * 60 * 60 * 1000, // Keep for 7 days
    // When sourceField is omitted, the engine creates the needed index automatically.
    // Optional custom sourceField requirements:
    // 1) type must be DataType.datetime
    // 2) nullable must be false
    // 3) defaultValueType must be DefaultValueType.currentTimestamp
    // sourceField: 'created_at',
  ),
);
```


### Stockage intelligent (Upsert)
ToStore décide de mettre à jour ou d'insérer en fonction de la clé primaire ou de la clé unique incluse dans `data`. `where` n'est pas pris en charge ici ; la cible du conflit est déterminée par les données elles-mêmes.

```dart
// By primary key
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// By unique key (the record must contain all fields from a unique index plus required fields)
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// Batch upsert (supports atomic mode or partial-success mode)
// allowPartialErrors: true means some rows may fail while others still succeed
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


<a id="query-advanced"></a>
### Requêtes avancées

ToStore fournit une API de requête déclarative chaînable avec une gestion flexible des champs et des relations multi-tables complexes.

#### 1. Sélection de champ (`select`)
La méthode `select` spécifie quels champs sont renvoyés. Si vous ne l'appelez pas, tous les champs sont renvoyés par défaut.
- **Alias** : prend en charge la syntaxe `field as alias` (insensible à la casse) pour renommer les clés dans le jeu de résultats
- **Champs qualifiés de table** : dans les jointures multi-tables, `table.field` évite les conflits de noms
- **Mélange d'agrégation** : les objets `Agg` peuvent être placés directement dans la liste `select`

```dart
final results = await db.query('orders')
    .select([
      'orders.id',
      'users.name as customer_name',
      'orders.amount',
      Agg.count('id', alias: 'total_items')
    ])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

#### 2. Rejoint (`join`)
Prend en charge les normes `join` (jointure interne), `leftJoin` et `rightJoin`.

#### 3. Jointures intelligentes basées sur des clés étrangères (recommandé)
Si `foreignKeys` est défini correctement dans `TableSchema`, vous n'avez pas besoin d'écrire manuellement les conditions de jointure. Le moteur peut résoudre les relations de référence et générer automatiquement le chemin JOIN optimal.

- **`joinReferencedTable(tableName)`** : rejoint automatiquement la table parent référencée par la table courante
- **`joinReferencingTable(tableName)`** : rejoint automatiquement les tables enfants qui font référence à la table actuelle

```dart
// Assume posts defines a foreign key to users
final posts = await db.query('posts')
    .joinReferencedTable('users') // Automatically resolves to ON posts.user_id = users.id
    .select(['posts.title', 'users.username'])
    .limit(20);
```

---

<a id="aggregation-stats"></a>
### Agrégation, regroupement et statistiques (Agg & GroupBy)

#### 1. Agrégation (`Agg` usine)
Les fonctions d'agrégation calculent des statistiques sur un ensemble de données. Avec le paramètre `alias`, vous pouvez personnaliser les noms des champs de résultat.

| Méthode | Objectif | Exemple |
| :--- | :--- | :--- |
| `Agg.count(field)` | Compter les enregistrements non nuls | `Agg.count('id', alias: 'total')` |
| `Agg.sum(field)` | Valeurs de somme | `Agg.sum('amount', alias: 'total_price')` |
| `Agg.avg(field)` | Valeur moyenne | `Agg.avg('score', alias: 'average_score')` |
| `Agg.max(field)` | Valeur maximale | `Agg.max('age')` |
| `Agg.min(field)` | Valeur minimale | `Agg.min('price')` |

> [!TIP]
> **Deux styles d'agrégation courants**
> 1. **Méthodes de raccourci (recommandées pour les métriques uniques)** : appelez directement sur la chaîne et récupérez immédiatement la valeur calculée.
> `num? totalAge = await db.query('users').sum('age');`
> 2. **Intégré dans `select` (pour plusieurs métriques ou regroupements)** : transmettez les objets `Agg` dans la liste `select`.
> `final stats = await db.query('orders').select(['status', Agg.sum('amount')]).groupBy(['status']);`

#### 2. Regroupement et filtrage (`groupBy` / `having`)
Utilisez `groupBy` pour catégoriser les enregistrements, puis `having` pour filtrer les résultats agrégés, similaire au comportement HAVING de SQL.

```dart
final stats = await db.query('orders')
    .select([
      'status',
      Agg.sum('amount', alias: 'sum_amount'),
      Agg.count('id', alias: 'order_count')
    ])
    .groupBy(['status'])
    // having accepts a QueryCondition used to filter aggregated results
    .having(QueryCondition().where(Agg.sum('amount'), '>', 5000))
    .limit(10);
```

#### 3. Méthodes de requête d'assistance
- **`exists()` (haute performance)** : vérifie si un enregistrement correspond. Contrairement à `count() > 0`, il court-circuite dès qu'une correspondance est trouvée, ce qui est excellent pour les très grands ensembles de données.
- **`count()`** : renvoie efficacement le nombre d'enregistrements correspondants.
- **`first()`** : une méthode pratique équivalente à `limit(1)` et renvoyant directement la première ligne sous la forme d'un `Map`.
- **`distinct([fields])`** : déduplique les résultats. Si `fields` est fourni, l'unicité est calculée en fonction de ces champs.

```dart
// Efficient existence check
if (await db.query('users').whereEqual('email', 'test@test.com').exists()) {
  print('Email is already registered');
}

// Get a deduplicated city list
final cities = await db.query('users').distinct(['city']);
```

<a id="query-condition"></a>
#### 4. Logique complexe avec `QueryCondition`
`QueryCondition` est l'outil principal de ToStore pour la logique imbriquée et la construction de requêtes entre parenthèses. Lorsque de simples appels `where` enchaînés ne suffisent pas pour des expressions comme `(A AND B) OR (C AND D)`, c'est l'outil à utiliser.

- **`condition(QueryCondition sub)`** : ouvre un groupe imbriqué `AND`
- **`orCondition(QueryCondition sub)`** : ouvre un groupe imbriqué `OR`
- **`or()`** : change le connecteur suivant en `OR` (la valeur par défaut est `AND`)

##### Exemple 1 : Conditions OU mixtes
SQL équivalent : `WHERE is_active = true AND (role = 'admin' OR fans >= 1000)`

```dart
final subGroup = QueryCondition()
    .whereEqual('role', 'admin')
    .or()
    .whereGreaterThanOrEqualTo('fans', 1000);

final results = await db.query('users')
    .whereEqual('is_active', true)
    .condition(subGroup);
```

##### Exemple 2 : Fragments de condition réutilisables
Vous pouvez définir des fragments de logique métier réutilisables une seule fois et les combiner dans différentes requêtes :

```dart
final hotUser = QueryCondition().whereGreaterThan('fans', 5000);
final recentLogin = QueryCondition().whereGreaterThan('last_login', '2024-01-01');

final targetUsers = await db.query('users')
    .condition(hotUser)
    .condition(recentLogin);
```


<a id="streaming-query"></a>
#### 5. Requête en streaming
Convient aux très grands ensembles de données lorsque vous ne souhaitez pas tout charger en mémoire en même temps. Les résultats peuvent être traités au fur et à mesure de leur lecture.

```dart
db.streamQuery('users').listen((data) {
  print('Processing one record: $data');
});
```

<a id="reactive-query"></a>
#### 6. Requête réactive
La méthode `watch()` vous permet de surveiller les résultats des requêtes en temps réel. Il renvoie un `Stream` et réexécute automatiquement la requête chaque fois que les données correspondantes changent dans la table cible.
- **Anti-rebond automatique** : l'anti-rebond intelligent intégré évite les rafales de requêtes redondantes
- **Synchronisation de l'interface utilisateur** : fonctionne naturellement avec Flutter `StreamBuilder` pour les listes de mise à jour en direct

```dart
// Simple listener
db.query('users').whereEqual('is_online', true).watch().listen((users) {
  print('Online user count changed: ${users.length}');
});

// Flutter StreamBuilder integration example
// Local UI refreshes automatically when data changes
StreamBuilder<List<Map<String, dynamic>>>(
  stream: db.query('messages').orderByDesc('id').limit(50).watch(),
  builder: (context, snapshot) {
    if (snapshot.hasData) {
      return ListView.builder(
        itemCount: snapshot.data!.length,
        itemBuilder: (context, index) => MessageTile(snapshot.data![index]),
      );
    }
    return CircularProgressIndicator();
  },
)
```

---

<a id="query-cache"></a>
### Mise en cache manuelle des résultats de requête (facultatif)

> [!IMPORTANT]
> **ToStore inclut déjà un cache LRU intelligent à plusieurs niveaux efficace en interne.**
> **La gestion manuelle du cache de routine n'est pas recommandée.** Considérez-la uniquement dans des cas particuliers :
> 1. Analyses complètes coûteuses sur des données non indexées qui changent rarement
> 2. Exigences persistantes de latence ultra-faible, même pour les requêtes non brûlantes

- `useQueryCache([Duration? expiry])` : active le cache et définit éventuellement une expiration
- `noQueryCache()` : désactiver explicitement le cache pour cette requête
- `clearQueryCache()` : invalider manuellement le cache pour ce modèle de requête

```dart
final results = await db.query('heavy_table')
    .where('non_indexed_field', '=', 'value')
    .useQueryCache(const Duration(minutes: 10)); // Manual acceleration for a heavy query only
```


<a id="query-pagination"></a>
### Requête et pagination efficace

> [!TIP]
> **Toujours spécifier `limit` pour de meilleures performances** : il est fortement recommandé de fournir explicitement `limit` dans chaque requête. En cas d'omission, le moteur affiche par défaut 1 000 lignes. Le moteur de requête principal est rapide, mais la sérialisation de très grands ensembles de résultats dans la couche application peut encore ajouter une surcharge inutile.

ToStore propose deux modes de pagination afin que vous puissiez choisir en fonction de vos besoins d'échelle et de performances :

#### 1. Pagination de base (mode décalage)
Convient aux ensembles de données relativement petits ou aux cas où vous avez besoin de sauts de page précis.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Skip the first 40 rows
    .limit(20); // Take 20 rows
```
> [!TIP]
> Lorsque `offset` devient très volumineux, la base de données doit analyser et supprimer de nombreuses lignes, de sorte que les performances chutent de manière linéaire. Pour une pagination approfondie, préférez le **Mode Curseur**.

#### 2. Pagination du curseur (mode curseur)
Idéal pour les ensembles de données volumineux et le défilement infini. En utilisant `nextCursor`, le moteur continue à partir de la position actuelle et évite le coût d'analyse supplémentaire lié aux décalages profonds.

> [!IMPORTANT]
> Pour certaines requêtes complexes ou tris sur des champs non indexés, le moteur peut revenir à une analyse complète et renvoyer un curseur `null`, ce qui signifie que la pagination n'est actuellement pas prise en charge pour cette requête spécifique.

```dart
// First page
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Use the returned cursor to fetch the next page
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Seek directly to the next position
}

// Likewise, prevCursor enables efficient backward paging
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Fonctionnalité | Mode décalage | Mode curseur |
| :--- | :--- | :--- |
| **Performances des requêtes** | Se dégrade à mesure que les pages s'approfondissent | Stable pour la pagination profonde |
| **Idéal pour** | Ensembles de données plus petits, sauts de page exacts | **Ensembles de données massifs, défilement infini** |
| **Cohérence sous modifications** | Les modifications de données peuvent entraîner l'omission de lignes | Évite les doublons et les omissions causés par les modifications de données |


<a id="foreign-keys"></a>
### Clés étrangères et cascade

Les clés étrangères garantissent l'intégrité référentielle et vous permettent de configurer des mises à jour et des suppressions en cascade. Les relations sont validées lors de l'écriture et de la mise à jour. Si les politiques en cascade sont activées, les données associées sont mises à jour automatiquement, réduisant ainsi le travail de cohérence dans le code de l'application.

```dart
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(name: 'id'),
    fields: [
      FieldSchema(name: 'username', type: DataType.text, nullable: false),
    ],
  ),
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
          fields: ['user_id'],              // Field in the current table
          referencedTable: 'users',         // Referenced table
          referencedFields: ['id'],         // Referenced field
          onDelete: ForeignKeyCascadeAction.cascade,  // Delete posts automatically when the user is deleted
          onUpdate: ForeignKeyCascadeAction.cascade,  // Cascade updates
        ),
    ],
  ),
]);
```


<a id="query-operators"></a>
### Opérateurs de requête

Toutes les conditions `where(field, operator, value)` prennent en charge les opérateurs suivants (insensibles à la casse) :

| Opérateur | Description | Exemple / Performance |
| :--- | :--- | :--- |
| `=` | Égal | `where('status', '=', 'val')` — **[Recommandé]** Recherche par index (Seek) |
| `!=`, `<>` | Pas égal | `where('role', '!=', 'val')` — **[Attention]** Analyse complète de la table |
| `>` , `>=`, `<`, `<=` | Comparaison | `where('age', '>', 18)` — **[Recommandé]** Analyse par index |
| `IN` | Dans la liste | `where('id', 'IN', [...])` — **[Recommandé]** Recherche par index (Seek) |
| `NOT IN` | Pas dans la liste | `where('status', 'NOT IN', [...])` — **[Attention]** Analyse complète de la table |
| `BETWEEN` | Plage | `where('age', 'BETWEEN', [18, 65])` — **[Recommandé]** Analyse par index |
| `LIKE` | Correspondance de modèle (`%` = n'importe quel caractère, `_` = un seul caractère) | `where('name', 'LIKE', 'John%')` — **[Attention]** Voir la note ci-dessous |
| `NOT LIKE` | Inadéquation des motifs | `where('email', 'NOT LIKE', '...')` — **[Attention]** Analyse complète de la table |
| `IS` | Est-ce que null | `where('deleted_at', 'IS', null)` — **[Recommandé]** Recherche par index (Seek) |
| `IS NOT` | N'est-ce pas null | `where('email', 'IS NOT', null)` — **[Attention]** Analyse complète de la table |

### Méthodes de requête sémantique (recommandées)

Recommandé pour éviter les chaînes d'opérateurs écrites à la main et pour obtenir une meilleure assistance IDE.

#### 1. Comparaison
Utilisé pour les comparaisons directes de valeurs numériques ou de chaînes.

```dart
db.query('users').whereEqual('username', 'John');           // Equal
db.query('users').whereNotEqual('role', 'guest');          // Not equal
db.query('users').whereGreaterThan('age', 18);             // Greater than
db.query('users').whereGreaterThanOrEqualTo('score', 60);  // Greater than or equal
db.query('users').whereLessThan('price', 100);             // Less than
db.query('users').whereLessThanOrEqualTo('quantity', 10);  // Less than or equal
db.query('users').whereTrue('is_active');                  // Is true
db.query('users').whereFalse('is_banned');                 // Is false
```

#### 2. Collection & Gamme
Utilisé pour tester si un champ se situe dans un ensemble ou une plage.

```dart
db.query('users').whereIn('id', ['id1', 'id2']);                 // In list
db.query('users').whereNotIn('status', ['banned', 'pending']);   // Not in list
db.query('users').whereBetween('age', 18, 65);                   // In range (inclusive)
```

#### 3. Vérification nulle
Utilisé pour tester si un champ a une valeur.

```dart
db.query('users').whereNull('deleted_at');    // Is null
db.query('users').whereNotNull('email');      // Is not null
db.query('users').whereEmpty('nickname');     // Is null or empty string
db.query('users').whereNotEmpty('bio');       // Is not null and not empty
```

#### 4. Correspondance de motifs
Prend en charge la recherche par caractère générique de style SQL (`%` correspond à n'importe quel nombre de caractères, `_` correspond à un seul caractère).

```dart
db.query('users').whereLike('name', 'John%');                        // SQL-style pattern match
db.query('users').whereContains('bio', 'flutter');                   // Contains match (LIKE '%value%')
db.query('users').whereStartsWith('name', 'Admin');                  // Prefix match (LIKE 'value%')
db.query('users').whereEndsWith('email', '.com');                    // Suffix match (LIKE '%value')
db.query('users').whereContainsAny('tags', ['dart', 'flutter']);     // Fuzzy match against any item in the list
```

```dart
// Equivalent to: .where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```

> [!CAUTION]
> **Guide de Performance des Requêtes (Index vs Analyse Complète)**
>
> Dans les scénarios de données à grande échelle (millions de lignes ou plus), veuillez suivre ces principes pour éviter les ralentissements du thread principal et les délais d'attente de requête :
>
> 1. **Optimisé par Index - [Recommandé]** :
>    *   **Méthodes sémantiques** : `whereEqual`, `whereGreaterThan`, `whereLessThan`, `whereIn`, `whereBetween`, `whereNull`, `whereTrue`, `whereFalse` et **`whereStartsWith`** (correspondance de préfixe).
>    *   **Opérateurs** : `=`, `>`, `<`, `>=`, `<=`, `IN`, `BETWEEN`, `IS null`, `LIKE 'prefix%'`.
>    *   *Explication : Ces opérations permettent un positionnement ultra-rapide via les index. Pour `whereStartsWith` / `LIKE 'abc%'`, l'index peut toujours effectuer une analyse de plage de préfixes.*
>
> 2. **Risques d'Analyse Complète - [Attention]** :
>    *   **Correspondance floue** : `whereContains` (`LIKE '%val%'`), `whereEndsWith` (`LIKE '%val'`), `whereContainsAny`.
>    *   **Requêtes de négation** : `whereNotEqual` (`!=`, `<>`), `whereNotIn` (`NOT IN`), `whereNotNull` (`IS NOT null`/`whereNotEmpty`).
>    *   **Inadéquation des motifs** : `NOT LIKE`.
>    *   *Explication : Les opérations ci-dessus nécessitent généralement de parcourir toute la zone de stockage de données, même si un index est créé. Bien que l'impact soit minimal sur les appareils mobiles ou les petits ensembles de données, dans les scénarios d'analyse de données distribuées ou de taille ultra-grande, elles doivent être utilisées avec prudence, combinées avec d'autres conditions d'index (par exemple, réduire les données par ID ou plage horaire) et la clause `limit`.*

<a id="distributed-architecture"></a>
## Architecture distribuée

```dart
// Configure distributed nodes
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,            // Enable distributed mode
      clusterId: 1,                       // Cluster ID
      centralServerUrl: 'https://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// Batch insert
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... efficient one-shot insertion of vector records
]);

// Stream and process large datasets
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Process each result incrementally to avoid loading everything at once
  print(record);
}
```

<a id="primary-key-examples"></a>
## Exemples de clés primaires

ToStore fournit plusieurs algorithmes de clé primaire distribués pour différents scénarios commerciaux :

- **Clé primaire séquentielle** (`PrimaryKeyType.sequential`) : `238978991`
- **Clé primaire basée sur l'horodatage** (`PrimaryKeyType.timestampBased`) : `1306866018836946`
- **Clé primaire avec préfixe de date** (`PrimaryKeyType.datePrefixed`) : `20250530182215887631`
- **Clé primaire de code court** (`PrimaryKeyType.shortCode`) : `9eXrF0qeXZ`

```dart
// Sequential primary key configuration example
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,      // Starting value
        increment: 50,            // Step size
        useRandomIncrement: true, // Random step size to hide business volume
      ),
    ),
    fields: [/* field definitions */]
  ),
]);
```


<a id="atomic-expressions"></a>
## Expressions atomiques

Le système d'expression fournit des mises à jour de champs atomiques de type sécurisé. Tous les calculs sont exécutés de manière atomique au niveau de la couche de base de données, évitant ainsi les conflits simultanés :

```dart
// Simple increment: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Complex calculation: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// Multi-layer parentheses: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) *
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Use functions: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Timestamp: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

**Expressions conditionnelles (par exemple, différencier mise à jour et insertion dans un upsert)** : utilisez `Expr.isUpdate()` / `Expr.isInsert()` avec `Expr.ifElse` ou `Expr.when` afin que l'expression soit évaluée uniquement lors de la mise à jour ou uniquement lors de l'insertion.

```dart
// Upsert: increment on update, set to 1 on insert
// The insert branch can use a plain literal; expressions are only evaluated on the update path
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    1,
  ),
});

// Use Expr.when (single branch, otherwise null)
await db.upsert('orders', {
  'id': orderId,
  'updatedAt': Expr.when(Expr.isUpdate(), Expr.now(), otherwise: Expr.now()),
});
```

<a id="transactions"></a>
## Transactions

Les transactions garantissent l'atomicité entre plusieurs opérations : soit tout réussit, soit tout est annulé, préservant ainsi la cohérence des données.

**Caractéristiques des transactions**
- plusieurs opérations, soit toutes réussissent, soit toutes reviennent en arrière
- le travail inachevé est automatiquement récupéré après un crash
- les opérations réussies sont conservées en toute sécurité

```dart
// Basic transaction - atomically commit multiple operations
final txResult = await db.transaction(() async {
  // Insert a user
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });

  // Atomic update using an expression
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');

  // If any operation fails, all changes are rolled back automatically
});

if (txResult.isSuccess) {
  print('Transaction committed successfully');
} else {
  print('Transaction rolled back: ${txResult.error?.message}');
}

// Automatic rollback on error
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('Business logic error'); // Trigger rollback
}, rollbackOnError: true);
```


<a id="database-maintenance"></a>
### Administration et maintenance

Les API suivantes couvrent l'administration, les diagnostics et la maintenance des bases de données pour le développement de type plugin, les panneaux d'administration et les scénarios opérationnels :

- **Gestion des tables**
  - `createTable(schema)` : créer une seule table manuellement ; utile pour le chargement de modules ou la création de tables d'exécution à la demande
  - `getTableSchema(tableName)` : récupérer les informations du schéma défini ; utile pour la validation automatisée ou la génération de modèles d'interface utilisateur
  - `getTableInfo(tableName)` : récupère les statistiques de la table d'exécution, y compris le nombre d'enregistrements, le nombre d'index, la taille du fichier de données, l'heure de création et si la table est globale
  - `clear(tableName)` : effacez toutes les données de la table tout en conservant en toute sécurité le schéma, les index et les contraintes de clés internes/externes
  - `dropTable(tableName)` : détruire complètement une table et son schéma ; non réversible
- **Gestion de l'espace**
  - `currentSpaceName` : obtenez l'espace actif actuel en temps réel
  - `listSpaces()` : liste tous les espaces alloués dans l'instance de base de données actuelle
  - `getSpaceInfo(useCache: true)` : auditer l'espace actuel ; utilisez `useCache: false` pour contourner le cache et lire l'état en temps réel
  - `deleteSpace(spaceName)` : supprime un espace spécifique et toutes ses données, sauf `default` et l'espace actif actuel
- **Découverte d'instance**
  - `config` : inspectez l'instantané final effectif `DataStoreConfig` pour l'instance
  - `instancePath` : localiser précisément le répertoire de stockage physique
  - `getVersion()` / `setVersion(version)` : contrôle de version défini par l'entreprise pour les décisions de migration au niveau de l'application (pas la version du moteur)
- **Entretien**
  - `flush(flushStorage: true)` : force les données en attente sur le disque ; si `flushStorage: true`, le système est également invité à vider les tampons de stockage de niveau inférieur
  - `deleteDatabase()` : supprime tous les fichiers physiques et métadonnées de l'instance actuelle ; utiliser avec précaution
- **Diagnostics**
  - `db.status.memory()` : inspectez les taux de réussite du cache, l'utilisation des pages d'index et l'allocation globale du tas
  - `db.status.space()` / `db.status.table(tableName)` : inspectez les statistiques en direct et les informations de santé pour les espaces et les tables
  - `db.status.config()` : inspecte l'instantané de configuration d'exécution actuel
  - `db.status.migration(taskId)` : suivez la progression de la migration asynchrone en temps réel

```dart

final spaces = await db.listSpaces();
final spaceInfo = await db.getSpaceInfo(useCache: false);
final tableSchema = await db.getTableSchema('users');
final tableInfo = await db.getTableInfo('users');

print('spaces: $spaces');
print(spaceInfo.toJson());
print(tableSchema?.toJson());
print(tableInfo?.toJson());

await db.flush();

final memoryInfo = await db.status.memory();
final configInfo = await db.status.config();
print(memoryInfo.toJson());
print(configInfo.toJson());
```


<a id="backup-restore"></a>
### Sauvegarde et restauration

Particulièrement utile pour l'importation/exportation locale par un seul utilisateur, la migration de données hors ligne volumineuses et la restauration du système après une panne :

- **Sauvegarde (`backup`)**
  - `compress` : s'il faut activer la compression ; recommandé et activé par défaut
  - `scope` : contrôle la plage de sauvegarde
    - `BackupScope.database` : sauvegarde l'**instance entière de la base de données**, y compris tous les espaces et tables globales
    - `BackupScope.currentSpace` : sauvegarde uniquement l'**espace actif actuel**, à l'exclusion des tables globales
    - `BackupScope.currentSpaceWithGlobal` : sauvegarde l'**espace actuel ainsi que ses tables globales associées**, idéal pour la migration à locataire unique ou à utilisateur unique
- **Restaurer (`restore`)**
  - `backupPath` : chemin physique vers le package de sauvegarde
  - `cleanupBeforeRestore` : s'il faut effacer silencieusement les données actuelles associées avant la restauration ; `true` est recommandé pour éviter les états logiques mixtes
  - `deleteAfterRestore` : supprime automatiquement le fichier source de sauvegarde après une restauration réussie

```dart
// Example: export the full data package for the current user
final backupPath = await db.backup(
  compress: true,
  scope: BackupScope.currentSpaceWithGlobal,
);

// Example: restore from a backup package and clean up the source file automatically
final restored = await db.restore(
  backupPath,
  cleanupBeforeRestore: true,
  deleteAfterRestore: true,
);
```

<a id="error-handling"></a>
### Codes d'état et gestion des erreurs


ToStore utilise un modèle de réponse unifié pour les opérations sur les données :

- `ResultType` : l'énumération d'état unifiée utilisée pour la logique de branchement
- `result.code` : un code numérique stable correspondant à `ResultType`
- `result.message` : un message lisible décrivant l'erreur en cours
- `successKeys` / `failedKeys` : listes de clés primaires réussies et échouées dans les opérations groupées


```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (!result.isSuccess) {
  switch (result.type) {
    case ResultType.notFound:
      print('Target resource does not exist: ${result.message}');
      break;
    case ResultType.notNullViolation:
    case ResultType.validationFailed:
      print('Data validation failed: ${result.message}');
      break;
    case ResultType.primaryKeyViolation:
    case ResultType.uniqueViolation:
      print('Unique constraint conflict: ${result.message}');
      break;
    case ResultType.foreignKeyViolation:
      print('Foreign key constraint failed: ${result.message}');
      break;
    case ResultType.resourceExhausted:
    case ResultType.timeout:
      print('System is busy. Please retry later: ${result.message}');
      break;
    case ResultType.ioError:
    case ResultType.dbError:
      print('Underlying storage error. Please record the logs: ${result.message}');
      break;
    default:
      print('Error type: ${result.type}, code: ${result.code}, message: ${result.message}');
  }
}
```

Exemples de codes d'état courants :
Le succès revient `0` ; les nombres négatifs indiquent des erreurs.
- `ResultType.success` (`0`) : opération réussie
- `ResultType.partialSuccess` (`1`) : opération groupée partiellement réussie
- `ResultType.unknown` (`-1`) : erreur inconnue
- `ResultType.uniqueViolation` (`-2`) : conflit d'index unique
- `ResultType.primaryKeyViolation` (`-3`) : conflit de clé primaire
- `ResultType.foreignKeyViolation` (`-4`) : la référence de clé étrangère ne satisfait pas aux contraintes
- `ResultType.notNullViolation` (`-5`) : un champ obligatoire est manquant ou un `null` non autorisé a été transmis
- `ResultType.validationFailed` (`-6`) : échec de la longueur, de la plage, du format ou de toute autre validation
- `ResultType.notFound` (`-11`) : la table, l'espace ou la ressource cible n'existe pas
- `ResultType.resourceExhausted` (`-15`) : ressources système insuffisantes ; réduire la charge ou réessayer
- `ResultType.dbError` (`-91`) : erreur de base de données
- `ResultType.ioError` (`-90`) : erreur du système de fichiers
- `ResultType.timeout` (`-92`) : délai d'attente

### Gestion des résultats des transactions
```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
  });
});

// txResult.isFailed: transaction failed; txResult.isSuccess: transaction succeeded
if (txResult.isFailed) {
  print('Transaction error type: ${txResult.error?.type}');
  print('Transaction error message: ${txResult.error?.message}');
}
```

Types d'erreurs de transaction :
- `TransactionErrorType.operationError` : une opération normale a échoué dans la transaction, telle qu'un échec de validation de champ, un état de ressource non valide ou une autre erreur de niveau métier.
- `TransactionErrorType.integrityViolation` : conflit d'intégrité ou de contrainte, tel que clé primaire, clé unique, clé étrangère ou échec non nul
- `TransactionErrorType.timeout` : délai d'attente
- `TransactionErrorType.io` : erreur d'E/S de stockage ou de système de fichiers sous-jacent
- `TransactionErrorType.conflict` : un conflit a fait échouer la transaction
- `TransactionErrorType.userAbort` : abandon initié par l'utilisateur (l'abandon manuel basé sur le lancement n'est actuellement pas pris en charge)
- `TransactionErrorType.unknown` : toute autre erreur


<a id="logging-diagnostics"></a>
### Rappel du journal et diagnostics de la base de données

ToStore peut acheminer les journaux de démarrage, de récupération, de migration automatique et de conflits de contraintes d'exécution vers la couche métier via `LogConfig.setConfig(...)`.

- `onLogHandler` reçoit tous les journaux qui passent les filtres `enableLog` et `logLevel` actuels.
- Appelez `LogConfig.setConfig(...)` avant l'initialisation afin que les journaux générés lors de l'initialisation et de la migration automatique soient également capturés.

```dart
  // Configure log parameters or callback
  LogConfig.setConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    publicLabel: 'my_app_db',
    onLogHandler: (message, type, label) {
      // In production, warn/error can be reported to your backend or logging platform
      if (!debugMode && (type == LogType.warn || type == LogType.error)) {
        developer.log(message, name: label);
      }
    },
  );

  final db = await ToStore.open();
```


<a id="security-config"></a>
## Configuration de la sécurité

> [!WARNING]
> **Gestion des clés** : **`encodingKey`** peut être modifié librement et le moteur migrera automatiquement les données, afin que les données restent récupérables. **`encryptionKey`** ne doit pas être modifié par hasard. Une fois modifiées, les anciennes données ne peuvent pas être déchiffrées, sauf si vous les migrez explicitement. Ne codez jamais en dur les clés sensibles ; il est recommandé de les récupérer auprès d'un service sécurisé.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Supported encryption algorithms: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305,

      // Encoding key (can be changed; data will be migrated automatically)
      encodingKey: 'Your-32-Byte-Long-Encoding-Key...',

      // Encryption key for critical data (do not change casually unless you are migrating data)
      encryptionKey: 'Your-Secure-Encryption-Key...',

      // Device binding (path-based binding)
      // When enabled, the key is deeply bound to the database path and device characteristics.
      // Data cannot be decrypted when moved to a different physical path.
      // Advantage: better protection if database files are copied directly.
      // Drawback: if the install path or device characteristics change, data may become unrecoverable.
      deviceBinding: false,
    ),
    // Enable crash recovery logging (Write-Ahead Logging), enabled by default
    enableJournal: true,
    // Whether transactions force data to disk on commit; set false to reduce sync overhead
    persistRecoveryOnCommit: true,
  ),
);
```

### Chiffrement au niveau de la valeur (ToCrypto)

Le chiffrement complet de la base de données sécurise toutes les données des tables et des index, mais peut affecter les performances globales. Si vous n'avez besoin de protéger que quelques valeurs sensibles, utilisez plutôt **ToCrypto**. Il est découplé de la base de données, ne nécessite aucune instance `db` et permet à votre application d'encoder/décoder les valeurs avant l'écriture ou après la lecture. La sortie est Base64, qui s'intègre naturellement dans les colonnes JSON ou TEXT.

- **`key`** (obligatoire) : `String` ou `Uint8List`. S'il ne s'agit pas de 32 octets, SHA-256 est utilisé pour dériver une clé de 32 octets.
- **`type`** (facultatif) : type de cryptage de `ToCryptoType`, tel que `ToCryptoType.chacha20Poly1305` ou `ToCryptoType.aes256Gcm`. La valeur par défaut est `ToCryptoType.chacha20Poly1305`.
- **`aad`** (facultatif) : données supplémentaires authentifiées de type `Uint8List`. S’ils sont fournis lors du codage, les mêmes octets doivent également être fournis lors du décodage.

```dart
const key = 'my-secret-key';
// Encode: plaintext -> Base64 ciphertext (can be stored in DB or JSON)
final cipher = ToCrypto.encode('sensitive data', key: key);
// Decode when reading
final plain = ToCrypto.decode(cipher, key: key);

// Optional: bind contextual data with aad (must match during decode)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```


<a id="advanced-config"></a>
## Configuration avancée expliquée (DataStoreConfig)

> [!TIP]
> **Intelligence zéro configuration**
> ToStore détecte automatiquement la plate-forme, les caractéristiques de performances, la mémoire disponible et le comportement des E/S pour optimiser des paramètres tels que la concurrence, la taille des partitions et le budget du cache. **Dans 99 % des scénarios commerciaux courants, vous n'avez pas besoin d'affiner `DataStoreConfig` manuellement.** Les valeurs par défaut offrent déjà d'excellentes performances pour la plateforme actuelle.


| Paramètre | Par défaut | Objectif et recommandation |
| :--- | :--- | :--- |
| **`yieldDurationMs`** | **8 ms** | **Recommandation principale.** La tranche de temps utilisée lorsque les tâches longues aboutissent. `8ms` s'aligne bien avec le rendu 120 ips/60 ips et permet de maintenir l'interface utilisateur fluide lors de requêtes ou de migrations volumineuses. |
| **`maxQueryOffset`** | **10 000** | **Protection des requêtes.** Lorsque `offset` dépasse ce seuil, une erreur est générée. Cela empêche les E/S pathologiques d’une pagination à décalage profond. |
| **`defaultQueryLimit`** | **1000** | **Garde-corps de ressources.** Appliqué lorsqu'une requête ne spécifie pas `limit`, empêchant le chargement accidentel d'ensembles de résultats massifs et les problèmes potentiels de MOO. |
| **`cacheMemoryBudgetMB`** | (auto) | **Gestion fine de la mémoire.** Budget total de mémoire cache. Le moteur l'utilise pour piloter automatiquement la récupération LRU. |
| **`enableJournal`** | **vrai** | **Auto-réparation en cas de crash.** Lorsqu'il est activé, le moteur peut récupérer automatiquement après un crash ou une panne de courant. |
| **`persistRecoveryOnCommit`** | **vrai** | **Forte garantie de durabilité.** Lorsqu'elles sont vraies, les transactions validées sont synchronisées avec le stockage physique. Lorsqu'il est faux, le vidage est effectué de manière asynchrone en arrière-plan pour une meilleure vitesse, avec un faible risque de perte d'une infime quantité de données en cas de crash extrême. |
| **`ttlCleanupIntervalMs`** | **300 000** | **Interrogation TTL globale.** L'intervalle d'arrière-plan pour l'analyse des données expirées lorsque le moteur n'est pas inactif. Des valeurs inférieures suppriment les données expirées plus tôt, mais coûtent plus cher. |
| **`maxConcurrency`** | (auto) | **Contrôle de la concurrence de calcul.** Définit le nombre maximal de travailleurs parallèles pour les tâches intensives telles que le calcul vectoriel et le chiffrement/déchiffrement. Il est généralement préférable de le garder automatique. |

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    yieldDurationMs: 8, // Excellent for frontend UI smoothness; for servers, 50ms is often better
    defaultQueryLimit: 50, // Force a maximum result-set size
    enableJournal: true, // Ensure crash self-healing
  ),
);
```

---

<a id="performance"></a>
## Performances et expérience

### Repères

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore Basic Performance Demo" width="320" />
</p>

- **Démo des performances de base** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4" target="_blank" rel="noopener">basic-demo.mp4</a>) : l'aperçu GIF peut ne pas tout afficher. Veuillez ouvrir la vidéo pour la démonstration complète. Même sur les appareils mobiles ordinaires, le démarrage, la pagination et la récupération restent stables et fluides même lorsque l'ensemble de données dépasse 100 millions d'enregistrements.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore Disaster Recovery Stress Test" width="320" />
</p>

- **Test de stress de reprise après sinistre** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4" target="_blank" rel="noopener">disaster-recovery.mp4</a>) : lors des écritures à haute fréquence, le processus est intentionnellement interrompu encore et encore pour simuler des crashs et des pannes de courant. ToStore est capable de récupérer rapidement.


### Conseils d'expérience

- 📱 **Exemple de projet** : le répertoire `example` comprend une application Flutter complète
- 🚀 **Builds de production** : packager et tester en mode release ; les performances de la version sont bien au-delà du mode débogage
- ✅ **Tests standard** : les capacités de base sont couvertes par des tests standardisés


Si ToStore vous aide, envoyez-nous un ⭐️
C'est l'une des meilleures façons de soutenir le projet. Merci beaucoup.


> **Recommandation** : pour le développement d'applications frontales, envisagez le [framework ToApp](https://github.com/tocreator/toapp), qui fournit une solution complète qui automatise et unifie les demandes de données, le chargement, le stockage, la mise en cache et la présentation.


<a id="more-resources"></a>
## Plus de ressources

- 📖 **Documentation** : [Wiki](https://github.com/tocreator/tostore)
- 📢 **Rapport de problèmes** : [Problèmes GitHub](https://github.com/tocreator/tostore/issues)
- 💬 **Discussion technique** : [Discussions GitHub](https://github.com/tocreator/tostore/discussions)



