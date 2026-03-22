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


## Navigation Rapide

- [Pourquoi ToStore ?](#why-tostore) | [Points Clés](#key-features) | [Installation](#installation) | [Démarrage Rapide](#quick-start)
- [Définition du Schéma](#schema-definition) | [Intégration Mobile/Bureau](#mobile-integration) | [Intégration Serveur](#server-integration)
- [Vecteurs et Recherche ANN](#vector-advanced) | [TTL par Table](#ttl-config) | [Requête & Pagination](#query-pagination) | [Clés Étrangères](#foreign-keys) | [Opérateurs de Requête](#query-operators)
- [Architecture Distribuée](#distributed-architecture) | [Exemples de Clés Primaires](#primary-key-examples) | [Opérations Atomiques](#atomic-expressions) | [Transactions](#transactions) | [Gestion des Erreurs](#error-handling) | [Callback de logs et diagnostic de base de données](#logging-diagnostics)
- [Configuration de Sécurité](#security-config) | [Performance](#performance) | [Plus de Ressources](#more-resources)


<a id="why-tostore"></a>
## Pourquoi choisir ToStore ?

ToStore est un moteur de données moderne conçu pour l'ère de l'AGI et les scénarios d'intelligence en périphérie (edge intelligence). Il supporte nativement les systèmes distribués, la fusion multimodale, les données relationnelles structurées, les vecteurs à haute dimension et le stockage de données non structurées. Basé sur une architecture sous-jacente de type réseau neuronal, les nœuds possèdent une grande autonomie et une extensibilité horizontale élastique, construisant un réseau de topologie de données flexible pour une collaboration fluide entre la périphérie et le cloud sur plusieurs plateformes. Il offre des transactions ACID, des requêtes relationnelles complexes (JOIN, clés étrangères en cascade), le TTL au niveau de la table et des calculs d'agrégation. Il inclut plusieurs algorithmes de clés primaires distribuées, des expressions atomiques, l'identification des changements de schéma, la protection par chiffrement, l'isolement des données dans plusieurs espaces, l'équilibrage de charge intelligent sensible aux ressources et la récupération automatique après sinistre ou plantage.

Alors que le centre de gravité de l'informatique continue de se déplacer vers l'intelligence en périphérie, divers terminaux tels que les agents et les capteurs ne sont plus de simples "afficheurs de contenu", mais deviennent des nœuds intelligents responsables de la génération locale, de la perception de l'environnement, de la prise de décision en temps réel et de la collaboration des données. Les solutions de base de données traditionnelles, limitées par leur architecture sous-jacente et leurs extensions de type "plug-in", ont du mal à répondre aux exigences de faible latence et de stabilité des applications intelligentes en périphérie et dans le cloud lorsqu'elles sont confrontées à des écritures à haute fréquence, des données massives, la recherche vectorielle et la génération collaborative.

ToStore donne à la périphérie des capacités distribuées suffisantes pour supporter des données massives, la génération complexe d'IA locale et des flux de données à grande échelle. La collaboration intelligente profonde entre les nœuds de la périphérie et du cloud fournit une base de données fiable pour des scénarios tels que la fusion immersive AR/VR, l'interaction multimodale, les vecteurs sémantiques et la modélisation spatiale.


<a id="key-features"></a>
## Points Clés

- 🌐 **Moteur de Données Multiplateforme Unifié**
  - API unifiée pour Mobile, Bureau, Web et Serveur.
  - Supporte les données structurées relationnelles, les vecteurs à haute dimension et les données non structurées.
  - Idéal pour les cycles de vie des données, du stockage local à la collaboration périphérie-cloud.

- 🧠 **Architecture Distribuée de Type Réseau Neuronal**
  - Haute autonomie des nœuds ; la collaboration interconnectée construit des topologies de données flexibles.
  - Supporte la collaboration des nœuds et l'extensibilité horizontale élastique.
  - Interconnexion profonde entre les nœuds intelligents de périphérie et le cloud.

- ⚡ **Exécution Parallèle et Planification des Ressources**
  - Planification intelligente de la charge sensible aux ressources avec haute disponibilité.
  - Calcul collaboratif parallèle multi-nœuds et décomposition des tâches.

- 🔍 **Requête Structurée et Recherche Vectorielle**
  - Supporte les requêtes à conditions complexes, les JOINs, les calculs d'agrégation et le TTL par table.
  - Supporte les champs vectoriels, les index vectoriels et la recherche de voisins proches (ANN).
  - Les données structurées et vectorielles peuvent être utilisées en collaboration au sein du même moteur.

- 🔑 **Clés Primaires, Indexation et Évolution du Schéma**
  - Algorithmes intégrés de clé primaire : incrément séquentiel, horodatage, préfixe de date et code court.
  - Supporte les index uniques, les index composés, les index vectoriels et les contraintes de clés étrangères.
  - Identifie intelligemment les changements de schéma et automatise la migration des données.

- 🛡️ **Transactions, Sécurité et Récupération**
  - Offre des transactions ACID, des mises à jour d'expressions atomiques et des clés étrangères en cascade.
  - Supporte la récupération après sinistre, la persistance sur disque et les garanties de cohérence des données.
  - Supporte le chiffrement ChaCha20-Poly1305 et AES-256-GCM.

- 🔄 **Multi-espace et Flux de Travail de Données**
  - Supporte l'isolement des données via des Espaces avec partage global configurable.
  - Écouteurs de requêtes en temps réel, cache intelligent multiniveau et pagination par curseur.
  - Parfait pour les applications multi-utilisateurs, locales en priorité et de collaboration hors ligne.


<a id="installation"></a>
## Installation

> [!IMPORTANT]
> **Mise à niveau depuis v2.x ?** Lisez le [Guide de Mise à Niveau v3.x](../UPGRADE_GUIDE_v3.md) pour les étapes critiques de migration et les changements majeurs.

Ajoutez `tostore` comme dépendance dans votre `pubspec.yaml` :

```yaml
dependencies:
  tostore: any # Utilisez la version la plus récente
```

<a id="quick-start"></a>
## Démarrage Rapide

> [!IMPORTANT]
> **Définir le schéma de la table est la première étape** : Vous devez définir le schéma de la table avant d'effectuer des opérations CRUD (sauf si vous utilisez uniquement le stockage KV).
> - Voir [Définition du Schéma](#schema-definition) pour plus de détails sur les contraintes.
> - **Mobile/Bureau** : Passez `schemas` lors de l'initialisation ; voir [Intégration Mobile](#mobile-integration).
> - **Serveur** : Utilisez `createTables` au cours de l'exécution ; voir [Intégration Serveur](#server-integration).

```dart
// 1. Initialiser la base de données
final db = await ToStore.open();

// 2. Insérer des données
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Requêtes chaînées (voir [Opérateurs de Requête](#query-operators); supporte =, !=, >, <, LIKE, IN, etc.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. Mettre à jour et Supprimer
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Écoute en temps réel (l'UI se met à jour automatiquement lors des changements)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Utilisateurs correspondants mis à jour : $users');
});
```

### Stockage Clé-Valeur (KV)
Adapté aux scénarios qui ne nécessitent pas de tables structurées. Simple et pratique, il intègre un stockage KV haute performance pour la configuration, l'état et d'autres données dispersées. Les données dans différents Espaces sont isolées par défaut mais peuvent être configurées pour être partagées globalement.

```dart
final db = await ToStore.open();

// Définir des paires clé-valeur (supporte String, int, bool, double, Map, List, etc.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// Récupérer des données
final theme = await db.getValue('theme'); // 'dark'

// Supprimer des données
await db.removeValue('theme');

// Clé-valeur globale (partagée entre Espaces)
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```


<a id="schema-definition"></a>
## Définition du Schéma

### Aperçu de TableSchema

```dart
const userSchema = TableSchema(
  name: 'users', // Nom de la table, requis
  tableId: 'users', // ID unique, pour détection précise de renommage
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // Champ PK, par défaut 'id'
    type: PrimaryKeyType.sequential, 
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, 
      increment: 1, 
      useRandomIncrement: false, 
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username',
      type: DataType.text,
      nullable: false,
      minLength: 3,
      maxLength: 32,
      unique: true,
      fieldId: 'username', 
      comment: 'Nom de connexion', 
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0,
      maxValue: 150,
      defaultValue: 0,
      createIndex: true, // Créer un index pour la performance
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // Horodatage automatique
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at',
      fields: ['status', 'created_at'],
      unique: false,
      type: IndexType.btree,
    ),
  ],
  foreignKeys: const [], // Contraintes de clés étrangères (voir section)
  isGlobal: false, // Table globale (accessible dans tous les Espaces)
  ttlConfig: null, // TTL au niveau de la table (voir section)
);
```

`DataType` supporte `integer`, `bigInt`, `double`, `text`, `blob`, `boolean`, `datetime`, `array`, `json`, `vector`. 

### Contraintes et Auto-validation

Vous pouvez définir des règles de validation directement dans le schéma via `FieldSchema` :

- `nullable: false` : Contrainte non-nulle.
- `minLength` / `maxLength` : Longueur du texte.
- `minValue` / `maxValue` : Plage numérique.
- `defaultValue` : Valeurs par défaut.
- `unique` : Unicité (génère un index unique).
- `createIndex` : Crée un index pour les filtres fréquents.


<a id="mobile-integration"></a>
## Intégration Mobile/Bureau

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// Multi-espace - Isoler les données des utilisateurs
await db.switchSpace(spaceName: 'user_123');
```

### Persistance du Login et Déconnexion (Espace Actif)

Utilisez l'**Espace Actif** pour maintenir l'utilisateur actuel après le redémarrage.

- **Persistance** : Marquez l'espace comme actif lors du changement (`keepActive: true`).
- **Déconnexion** : Fermez la base de données avec `keepActiveSpace: false`.

```dart
// Après login : Sauvegarder l'espace utilisateur comme actif
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Déconnexion : Fermer et effacer l'espace actif pour le prochain démarrage
await db.close(keepActiveSpace: false);
```


<a id="server-integration"></a>
## Intégration Serveur

```dart
final db = await ToStore.open();

// Créer ou valider la structure au démarrage
await db.createTables(appSchemas);

// Mise à jour de schéma en ligne
final taskId = await db.updateSchema('users')
  .renameTable('users_new')
  .modifyField('username', minLength: 5, unique: true)
  .renameField('old', 'new')
  .removeField('deprecated')
  .addField('created_at', type: DataType.datetime)
  .removeIndex(fields: ['age']);
    
// Suivre la progression de la migration
final status = await db.queryMigrationTaskStatus(taskId);
print('Progression : ${status?.progressPercentage}%');


// Gestion Manuelle du Cache de Requête
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Invalider le cache spécifique
await db.query('users').where('is_active', '=', true).clearQueryCache();
```


<a id="advanced-usage"></a>
## Usage Avancé


<a id="vector-advanced"></a>
### Vecteurs et Recherche ANN

```dart
await db.createTables([
  const TableSchema(
    name: 'embeddings',
    fields: [
      FieldSchema(name: 'document_title', type: DataType.text, nullable: false),
      FieldSchema(
        name: 'embedding',
        type: DataType.vector,
        vectorConfig: VectorFieldConfig(dimensions: 128, precision: VectorPrecision.float32),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'],
        type: IndexType.vector,
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,
          distanceMetric: VectorDistanceMetric.cosine,
        ),
      ),
    ],
  ),
]);

final queryVector = VectorData.fromList(List.generate(128, (i) => i * 0.01));

// Recherche vectorielle
final results = await db.vectorSearch(
  'embeddings', 
  fieldName: 'embedding', 
  queryVector: queryVector, 
  topK: 5,
);
```


<a id="ttl-config"></a>
### TTL par Table (Expiration Automatique)

Pour les logs ou événements : les données expirées sont automatiquement nettoyées en arrière-plan.

```dart
const TableSchema(
  name: 'event_logs',
  fields: [/* ... */],
  ttlConfig: TableTtlConfig(ttlMs: 7 * 24 * 60 * 60 * 1000), // Garder 7 jours
);
```


### Écriture Intelligente (Upsert)
Met à jour si la PK ou clé unique existe, sinon insère.

```dart
await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});
```


### JOIN & Agrégation
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .limit(20);

// Agrégation
final count = await db.query('users').count();
final sum = await db.query('orders').sum('total');
```


<a id="query-pagination"></a>
### Requête et Pagination Efficace

- **Mode Offset** : Pour les petits datasets ou sauts de page.
- **Mode Cursor** : Recommandé pour les données massives et scroll infini (O(1)).

```dart
final page1 = await db.query('users').orderByDesc('id').limit(20);

if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor);
}
```


<a id="foreign-keys"></a>
### Clés Étrangères et Cascade

```dart
foreignKeys: [
    ForeignKeySchema(
      name: 'fk_posts_user',
      fields: ['user_id'],
      referencedTable: 'users',
      referencedFields: ['id'],
      onDelete: ForeignKeyCascadeAction.cascade, // Supprime les posts si l'user est supprimé
    ),
],
```


<a id="query-operators"></a>
### Opérateurs de Requête

Supporté : `=`, `!=`, `>`, `>=`, `<`, `<=`, `IN`, `NOT IN`, `BETWEEN`, `LIKE`, `IS NULL`, `IS NOT NULL`.

```dart
db.query('users').whereEqual('name', 'John').whereGreaterThan('age', 18).limit(20);
```


<a id="atomic-expressions"></a>
## Opérations Atomiques

Calculs au niveau DB pour éviter les conflits de concurrence :

```dart
// balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', id);

// Dans un Upsert : Incrémente si update, sinon définit à 1
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(Expr.isUpdate(), Expr.field('count') + 1, 1),
});
```


<a id="transactions"></a>
## Transactions

Garantissent l'atomicité : soit tout réussit, soit tout est annulé.

```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {...});
  await db.update('users', {...});
});
```


<a id="logging-diagnostics"></a>
### Callback de logs et diagnostic de base de données

ToStore peut utiliser `LogConfig.setConfig(...)` pour renvoyer à la couche applicative les logs de démarrage, de récupération, de migration automatique et de conflit de contraintes à l'exécution.

- `onLogHandler` reçoit tous les logs filtrés par les valeurs courantes de `enableLog` et `logLevel`.
- Appelez `LogConfig.setConfig(...)` avant l'initialisation afin de capturer aussi les logs d'initialisation et de migration automatique.

```dart
  // Configurer les paramètres de log ou le callback
  LogConfig.setConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    publicLabel: 'my_app_db',
    onLogHandler: (message, type, label) {
      // En production, warn/error peuvent être remontés au backend ou à la plateforme de logs
      if (!debugMode && (type == LogType.warn || type == LogType.error)) {
        developer.log(message, name: label);
      }
    },
  );

  final db = await ToStore.open();
```


<a id="security-config"></a>
## Sécurité

> [!WARNING]
> **Gestion des clés** : `encodingKey` peut être changée (auto-migration). `encryptionKey` est critique ; son changement sans migration rend les anciennes données illisibles.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      encryptionType: EncryptionType.chacha20Poly1305, 
      encodingKey: '...', 
      encryptionKey: '...',
    ),
  ),
);
```

### Chiffrement de champ (ToCrypto)
Pour chiffrer sélectivement des champs sensibles sans affecter la performance globale.


<a id="performance"></a>
## Performance

- 📱 **Exemple** : Projet complet dans le dossier `example`.
- 🚀 **Release Mode** : Bien plus performant que le mode Debug.
- ✅ **Testé** : Fonctions de base couvertes par des suites de tests.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="Démo de performance ToStore" width="320" />
</p>

- **Démo Performance** : Fluide avec plus de 100M+ d'entrées. ([Vidéo](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4))

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="Récupération après sinistre ToStore" width="320" />
</p>

- **Récupération** : Récupération automatique après coupure de courant. ([Vidéo](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4))


Si ToStore vous aide, donnez-nous une ⭐️ ! C'est le meilleur soutien.

---

> **Recommandation** : Utilisez le [ToApp Framework](https://github.com/tocreator/toapp) pour le front-end. Une solution full-stack pour les requêtes, le cache et le state management.
