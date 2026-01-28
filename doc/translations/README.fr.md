# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | Français | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)


## Pourquoi choisir Tostore ?

Tostore est le seul moteur de stockage haute performance pour les bases de données vectorielles distribuées dans l'écosystème Dart/Flutter. Utilisant une architecture de type réseau neuronal, il présente une interconnectivité intelligente et une collaboration entre les nœuds, prenant en charge une mise à l'échelle horizontale infinie. Il construit un réseau de topologie de données flexible et fournit une identification précise des changements de schéma, une protection par cryptage et une isolation des données multi-espaces. Tostore exploite pleinement les CPU multi-cœurs pour un traitement parallèle extrême et prend nativement en charge la collaboration multiplateforme, des appareils périphériques (edge) mobiles au cloud. Avec divers algorithmes de clés primaires distribuées, il fournit une base de données puissante pour des scénarios tels que la réalité virtuelle immersive, l'interaction multimodale, l'informatique spatiale, l'IA générative et la modélisation de l'espace vectoriel sémantique.

Alors que l'IA générative et l'informatique spatiale déplacent le centre de gravité vers la périphérie (edge), les terminaux évoluent de simples afficheurs de contenu vers des noyaux de génération locale, de perception environnementale et de prise de décision en temps réel. Les bases de données intégrées traditionnelles à fichier unique sont limitées par leur conception architecturale, luttant souvent pour répondre aux exigences de réponse immédiate des applications intelligentes face à des écritures à haute concurrence, une recherche vectorielle massive et une génération collaborative cloud-edge. Tostore est né pour les appareils périphériques, leur conférant des capacités de stockage distribué suffisantes pour supporter une IA locale complexe et un flux de données à grande échelle, réalisant ainsi une véritable collaboration approfondie entre le cloud et le edge.

**Résistant aux coupures de courant et aux plantages** : Même en cas de coupure de courant inattendue ou de plantage de l'application, les données peuvent être automatiquement récupérées, réalisant une perte zéro réelle. Lorsqu'une opération sur les données répond, les données ont déjà été sauvegardées en toute sécurité, éliminant tout risque de perte de données.

**Dépassement des limites de performance** : Les tests de performance montrent que même avec 10 millions d'enregistrements, un smartphone classique peut démarrer immédiatement et afficher les résultats de recherche instantanément. Quelle que soit la taille du volume de données, vous bénéficiez d'une expérience fluide qui dépasse de loin celle des bases de données traditionnelles.




...... Du bout des doigts aux applications cloud, Tostore vous aide à libérer la puissance de calcul des données et à préparer l'avenir ......




## Caractéristiques de Tostore

- 🌐 **Support fluide de toutes les plateformes**
  - Exécutez le même code sur toutes les plateformes, des applications mobiles aux serveurs cloud.
  - S'adapte intelligemment aux différents backends de stockage des plateformes (IndexedDB, système de fichiers, etc.).
  - Interface API unifiée pour une synchronisation de données multiplateforme sans souci.
  - Flux de données fluide des appareils périphériques aux serveurs cloud.
  - Calcul vectoriel local sur les appareils périphériques, réduisant la latence du réseau et la dépendance au cloud.

- 🧠 **Architecture distribuée de type réseau neuronal**
  - Structure de topologie de nœuds interconnectés pour une organisation efficace du flux de données.
  - Mécanisme de partitionnement de données haute performance pour un véritable traitement distribué.
  - Équilibrage dynamique intelligent de la charge de travail pour maximiser l'utilisation des ressources.
  - Mise à l'échelle horizontale infinie des nœuds pour construire facilement des réseaux de données complexes.

- ⚡ **Capacité de traitement parallèle ultime**
  - Lecture/écriture parallèle réelle utilisant les Isolates, fonctionnant à plein régime sur les CPU multi-cœurs.
  - La planification intelligente des ressources équilibre automatiquement la charge pour maximiser les performances multi-cœurs.
  - Le réseau informatique multi-nœuds collaboratif double l'efficacité du traitement des tâches.
  - Le cadre de planification sensible aux ressources optimise automatiquement les plans d'exécution pour éviter les conflits de ressources.
  - L'interface de requête en flux (streaming) gère facilement des ensembles de données massifs.

- 🔑 **Divers algorithmes de clés primaires distribuées**
  - Algorithme d'incrémentation séquentielle - Ajustez librement les tailles de pas aléatoires pour cacher l'échelle de l'activité.
  - Algorithme basé sur l'horodatage (Timestamp) - Le meilleur choix pour les scénarios à haute concurrence.
  - Algorithme de préfixe de date - Support parfait pour l'affichage de données sur une période donnée.
  - Algorithme de code court - Génère des identifiants uniques courts et faciles à lire.

- 🔄 **Migration intelligente de schéma et intégrité des données**
  - Identifie avec précision les champs de table renommés sans aucune perte de données.
  - Détection automatique des changements de schéma et migration de données en quelques millisecondes.
  - Mises à jour sans interruption, invisibles pour l'entreprise.
  - Stratégies de migration sécurisées pour les changements de structure complexes.
  - Validation automatique des contraintes de clés étrangères avec support d'opérations en cascade assurant l'intégrité référentielle.

- 🛡️ **Sécurité et durabilité de niveau entreprise**
  - Mécanisme de double protection : l'enregistrement en temps réel des changements de données garantit que rien n'est jamais perdu.
  - Récupération automatique après plantage : reprend automatiquement les opérations inachevées après une coupure de courant ou un plantage.
  - Garantie de cohérence des données : les opérations réussissent entièrement ou sont totalement annulées (rollback).
  - Mises à jour calculées atomiques : le système d'expressions supporte des calculs complexes, exécutés de manière atomique pour éviter les conflits de concurrence.
  - Persistance sécurisée instantanée : les données sont sauvegardées en toute sécurité dès que l'opération réussit.
  - L'algorithme de cryptage haute résistance ChaCha20Poly1305 protège les données sensibles.
  - Cryptage de bout en bout pour une sécurité pendant tout le stockage et la transmission.

- 🚀 **Cache intelligent et performance de recherche**
  - Mécanisme de cache intelligent à plusieurs niveaux pour une recherche de données ultra-rapide.
  - Stratégies de cache profondément intégrées au moteur de stockage.
  - La mise à l'échelle adaptative maintient des performances stables à mesure que le volume de données augmente.
  - Notifications de changement de données en temps réel avec mise à jour automatique des résultats de recherche.

- 🔄 **Flux de travail de données intelligent**
  - L'architecture multi-espaces assure l'isolation des données tout en permettant un partage global.
  - Distribution intelligente de la charge de travail entre les nœuds de calcul.
  - Fournit une base solide pour l'entraînement et l'analyse de données à grande échelle.


## Installation

> [!IMPORTANT]
> **Mise à niveau depuis v2.x ?** Veuillez lire le [Guide de mise à niveau v3.0](../UPGRADE_GUIDE_v3.md) pour les étapes de migration critiques et les changements importants.

Ajoutez `tostore` comme dépendance dans votre `pubspec.yaml` :

```yaml
dependencies:
  tostore: any # Veuillez utiliser la version la plus récente
```

## Démarrage rapide

> [!IMPORTANT]
> **La définition du schéma de table est la première étape** : Avant d'effectuer des opérations CRUD, vous devez définir le schéma de la table. La méthode de définition spécifique dépend de votre scénario :
> - **Mobile/Bureau** : Recommandé [Définition statique](#intégration-pour-les-scénarios-de-démarrage-fréquent).
> - **Côté serveur** : Recommandé [Création dynamique](#intégration-côté-serveur).

```dart
// 1. Initialiser la base de données
final db = await ToStore.open();

// 2. Insérer des données
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Requêtes chaînées (Supporte =, !=, >, <, LIKE, IN, etc.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. Mettre à jour et Supprimer
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Écoute en temps réel (l'UI se met à jour automatiquement)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Utilisateurs correspondants mis à jour : $users');
});
```

### Stockage Clé-Valeur (KV)
Adapté aux scénarios ne nécessitant pas de définir des tables structurées. C'est simple, pratique et inclut un store KV haute performance intégré pour les configurations, les états et autres données éparses. Les données dans des espaces (Spaces) différents sont naturellement isolées mais peuvent être partagées globalement.

```dart
// 1. Définir des paires clé-valeur (Supporte String, int, bool, double, Map, List, etc.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 2. Récupérer des données
final theme = await db.getValue('theme'); // 'dark'

// 3. Supprimer des données
await db.removeValue('theme');

// 4. Clé-valeur globale (partagée entre les Spaces)
// Par défaut, les données KV sont spécifiques à l'espace. Utilisez isGlobal: true pour le partage.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



## Intégration pour les scénarios de démarrage fréquent

```dart
// Définition de schéma adaptée aux scénarios de démarrage fréquent (applications mobiles/bureau).
// Identifie précisément les changements de schéma et migre automatiquement les données.
final db = await ToStore.open(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // Table globale accessible par tous les espaces
            fields: [],
    ),
    const TableSchema(
      name: 'users', // Nom de la table
      tableId: "users",  // Identifiant unique pour une détection à 100% des renommages
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // Nom de la clé primaire
      ),
      fields: [        // Définition des champs (hors clé primaire)
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true,
          fieldId: 'username',  // Identifiant unique du champ
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime
        ),
      ],
      indexes: [ // Définition des index
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
    // Exemple de contrainte de clé étrangère
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
          fields: ['user_id'],              // Champs de la table actuelle
          referencedTable: 'users',         // Table référencée
          referencedFields: ['id'],         // Champs référencés
          onDelete: ForeignKeyCascadeAction.cascade,  // Suppression en cascade
          onUpdate: ForeignKeyCascadeAction.cascade,  // Mise à jour en cascade
        ),
      ],
    ),
  ],
);

// Architecture multi-espaces - isolation parfaite des données des différents utilisateurs
await db.switchSpace(spaceName: 'user_123');
```

## Intégration côté serveur

```dart
// Création massive de schémas au runtime
await db.createTables([
  // Table de stockage des vecteurs de caractéristiques spatiales 3D
  const TableSchema(
    name: 'spatial_embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,   // PK basée sur l'horodatage pour haute concurrence
    ),
    fields: [
      FieldSchema(
        name: 'video_name',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'spatial_features',
        type: DataType.vector,                // Type de stockage vectoriel
        vectorConfig: VectorFieldConfig(
          dimensions: 1024,                   // Vecteur haute dimension
          precision: VectorPrecision.float32, 
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['video_name'],
        unique: true,
      ),
      IndexSchema(
        type: IndexType.vector,              // Index vectoriel
        fields: ['spatial_features'],
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.hnsw,   // Algorithme HNSW pour recherche ANN efficace
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,
            'efConstruction': 200,
          },
        ),
      ),
    ],
  ),
  // Autres tables...
]);

// Mises à jour de schéma en ligne - Transparent pour l'entreprise
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // Renommer la table
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // Modifier les propriétés d'un champ
  .renameField('old_name', 'new_name')     // Renommer un champ
  .removeField('deprecated_field')         // Supprimer un champ
  .addField('created_at', type: DataType.datetime)  // Ajouter un champ
  .removeIndex(fields: ['age'])            // Supprimer un index
  .setPrimaryKeyConfig(                    // Modifier la config PK
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// Suivre la progression de la migration
final status = await db.queryMigrationTaskStatus(taskId);
print('Progression de la migration : ${status?.progressPercentage}%');


// Gestion manuelle du cache de requêtes (Serveur)
// Pour les requêtes sur les clés primaires ou les champs indexés (requêtes d'égalité, IN), les performances sont déjà extrêmes et la gestion manuelle du cache est généralement inutile.

// Stocker manuellement le résultat d'une requête pendant 5 minutes.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Invalider un cache spécifique quand les données changent.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// Désactiver explicitement le cache pour les requêtes nécessitant des données en temps réel.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```



## Utilisation avancée

Tostore offre un riche ensemble de fonctionnalités avancées :

### Requêtes imbriquées et filtrage personnalisé
Supporte l'imbrication infinie de conditions et des fonctions personnalisées flexibles.

```dart
// Imbrication de conditions : (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// Fonction de condition personnalisée
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('recommendation') ?? false);
```

### Upsert intelligent
Met à jour si l'enregistrement existe, sinon l'insère.

```dart
await db.upsert('users', {
  'email': 'john@example.com',
  'name': 'John New'
}).where('email', '=', 'john@example.com');
```


### Joins et sélection de champs
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### Streaming et statistiques
```dart
// Compter les enregistrements
final count = await db.query('users').count();

// Requête en streaming (adapté aux données massives)
db.streamQuery('users').listen((data) => print(data));
```



### Requêtes et pagination efficace

> [!TIP]
> **Spécifiez explicitement `limit` pour de meilleures performances** : Il est fortement recommandé de toujours spécifier un `limit` lors des requêtes. S'il est omis, le moteur limite par défaut à 1000 enregistrements. Bien que le cœur de la requête soit extrêmement rapide, la sérialisation d'un grand nombre d'enregistrements dans des applications sensibles à l'interface utilisateur peut entraîner une latence inutile.

Tostore offre deux modes de pagination :

#### 1. Mode Offset
Adapté aux jeux de données réduits ou lorsqu'un saut de page précis est requis.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Sauter les 40 premiers
    .limit(20); // Prendre 20
```
> [!TIP]
> Quand l'`offset` est très grand, la base de données doit scanner et ignorer de nombreux enregistrements, ce qui dégrade les performances. Utilisez le **Mode Cursor** pour une pagination profonde.

#### 2. Mode Cursor haute performance
**Recommandé pour les données massives et le scroll infini**. Utilise `nextCursor` pour des performances en O(1), assurant une vitesse de requête constante.

> [!IMPORTANT]
> En cas de tri sur un champ non indexé ou pour certaines requêtes complexes, le moteur peut revenir à un scan complet et renvoyer un curseur `null` (ce qui signifie que la pagination pour cette requête spécifique n'est pas encore supportée).

```dart
// Page 1
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Récupérer la page suivante via le curseur
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Atteint directement la position
}

// Revenir en arrière efficacement avec prevCursor
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Caractéristique | Mode Offset | Mode Cursor |
| :--- | :--- | :--- |
| **Performance** | Diminue quand les pages augmentent | **Constante (O(1))** |
| **Complexité** | Petites données, saut de page | **Données massives, scroll infini** |
| **Cohérence** | Les changements de données peuvent causer des doublons | **Évite les doublons/oublis dus aux changements** |





## Architecture distribuée

```dart
// Configurer les nœuds distribués
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,
      clusterId: 1,
      centralServerUrl: 'http://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// Insertion massive haute performance (Batch Insert)
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Enregistrements insérés par lot efficacement
]);

// Traiter des jeux de données massifs en streaming - consommation mémoire constante
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Traite efficacement même des données à l'échelle du To sans consommation mémoire excessive
  print(record);
}
```

## Exemples de types de clés primaires

Tostore propose plusieurs algorithmes de clés primaires :

- **Séquentielle** (PrimaryKeyType.sequential) : 238978991
- **Basée sur l'horodatage** (PrimaryKeyType.timestampBased) : 1306866018836946
- **Préfixe de date** (PrimaryKeyType.datePrefixed) : 20250530182215887631
- **Code court** (PrimaryKeyType.shortCode) : 9eXrF0qeXZ

```dart
// Exemple de configuration de clé primaire séquentielle
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // Masque le volume d'activité
      ),
    ),
    fields: [/* Définition des champs */]
  ),
]);
```


## Opérations atomiques avec expressions

Le système d'expressions permet des mises à jour de champs atomiques et sûres. Tous les calculs sont exécutés de manière atomique au niveau de la base de données :

```dart
// Incrément simple : balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Calcul complexe : total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// Parenthèses imbriquées : finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Utilisation de fonctions : price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Horodatage : updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

## Transactions

Les transactions garantissent l'atomicité de plusieurs opérations : soit tout réussit, soit tout est annulé, garantissant la cohérence des données.

**Caractéristiques des transactions** :
- Exécution atomique de plusieurs opérations.
- Récupération automatique des opérations inachevées après un plantage.
- Sauvegarde sécurisée des données lors de la validation (commit).

```dart
// Transaction basique
final txResult = await db.transaction(() async {
  // Insérer un utilisateur
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // Mise à jour atomique via expressions
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // En cas d'échec, tous les changements sont annulés automatiquement.
});

if (txResult.isSuccess) {
  print('Transaction validée avec succès');
} else {
  print('Transaction annulée : ${txResult.error?.message}');
}

// Annulation automatique sur erreur
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('Erreur métier'); // Déclenche l'annulation
}, rollbackOnError: true);
```

## Configuration de la sécurité

**Mécanismes de sécurité des données** :
- La double protection garantit que les données ne sont jamais perdues.
- Récupération automatique après plantage.
- Persistance sécurisée dès que l'opération réussit.
- Cryptage haute résistance pour les données sensibles.

> [!WARNING]
> **Gestion des clés** : Changer la `encryptionKey` rendra les anciennes données illisibles (sauf migration). Ne codez pas les clés en dur ; récupérez-les depuis un serveur sécurisé.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Algorithmes supportés : none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // Clé d'encodage (obligatoire à l'initialisation)
      encodingKey: 'Votre-Clé-D-Encodage-De-32-Octets...', 
      
      // Clé de cryptage pour les données critiques
      encryptionKey: 'Votre-Clé-De-Cryptage-Sécurisée...',
      
      // Liaison à l'appareil (basé sur le chemin)
      // Si activé, les clés sont liées au chemin et aux caractéristiques de l'appareil.
      // Renforce la sécurité contre le vol de fichiers de base de données.
      deviceBinding: false, 
    ),
    // WAL (Write-Ahead Logging) activé par défaut
    enableJournal: true, 
    // Force l'écriture disque au commit (mettre à false pour plus de performance)
    persistRecoveryOnCommit: true,
  ),
);
```


## Performance et Expérience

### Spécifications de performance

- **Vitesse de démarrage** : Démarrage et affichage instantanés même avec plus de 10 millions d'enregistrements sur un smartphone moyen.
- **Requêtes** : Indépendant de l'échelle, recherche ultra-rapide constante à tout volume de données.
- **Sécurité des données** : Garanties de transaction ACID + récupération après crash pour zéro perte de données.

### Recommandations

- 📱 **Projet d'exemple** : Un exemple complet d'application Flutter est disponible dans le répertoire `example`.
- 🚀 **Production** : Utilisez le mode Release pour des performances bien supérieures au mode Debug.
- ✅ **Tests standards** : Toutes les fonctionnalités clés ont passé les tests d'intégration.




Si Tostore vous aide, n'hésitez pas à nous donner une ⭐️




## Roadmap

Tostore développe activement de nouvelles fonctionnalités pour renforcer l'infrastructure de données à l'ère de l'IA :

- **Vecteurs haute dimension** : Ajout de la recherche vectorielle et d'algorithmes de recherche sémantique.
- **Données multi-modales** : Traitement de bout en bout, des données brutes aux vecteurs de caractéristiques.
- **Structures de données en graphe** : Support pour le stockage et la requête efficace de graphes de connaissances.





> **Recommandation** : Les développeurs mobiles peuvent aussi considérer le [Framework Toway](https://github.com/tocreator/toway), une solution full-stack qui automatise les requêtes, le chargement, le stockage, le cache et l'affichage des données.




## Plus de ressources

- 📖 **Documentation** : [Wiki](https://github.com/tocreator/tostore)
- 📢 **Feedback** : [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Discussion** : [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


## Licence

Ce projet est sous licence MIT - voir le fichier [LICENSE](LICENSE) pour plus de détails.

---
