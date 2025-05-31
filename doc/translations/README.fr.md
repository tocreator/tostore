# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | Français | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

Tostore est un moteur de base de données à architecture distribuée multiplateforme profondément intégré à votre projet. Son modèle de traitement des données inspiré des réseaux neuronaux implémente une gestion des données comparable au fonctionnement du cerveau. Les mécanismes de parallélisme multi-partitions et la topologie d'interconnexion des nœuds créent un réseau de données intelligent, tandis que le traitement parallèle avec Isolate exploite pleinement les capacités multicœurs. Avec divers algorithmes de clés primaires distribuées et une extension de nœuds illimitée, il peut servir de couche de données pour les infrastructures de calcul distribué et d'entraînement de données à grande échelle, permettant un flux de données fluide des appareils périphériques aux serveurs cloud. Des fonctionnalités comme la détection précise des changements de schéma, la migration intelligente, le chiffrement ChaCha20Poly1305 et l'architecture multi-espaces supportent parfaitement divers scénarios d'applications, des applications mobiles aux systèmes côté serveur.

## Pourquoi choisir Tostore ?

### 1. Traitement parallèle des partitions vs. stockage en fichier unique
| Tostore | Bases de données traditionnelles |
|:---------|:-----------|
| ✅ Mécanisme de partitionnement intelligent, données réparties sur plusieurs fichiers de taille appropriée | ❌ Stockage dans un fichier de données unique, dégradation linéaire des performances avec la croissance des données |
| ✅ Lecture uniquement des fichiers de partition pertinents, performances de requête découplées du volume total de données | ❌ Nécessité de charger l'intégralité du fichier de données, même pour interroger un seul enregistrement |
| ✅ Maintien des temps de réponse en millisecondes même avec des volumes de données au niveau du To | ❌ Augmentation significative de la latence de lecture/écriture sur les appareils mobiles lorsque les données dépassent 5 Mo |
| ✅ Consommation de ressources proportionnelle à la quantité de données interrogées, pas au volume total de données | ❌ Appareils à ressources limitées sujets à la pression de mémoire et aux erreurs OOM |
| ✅ La technologie Isolate permet un véritable traitement parallèle multicœur | ❌ Un fichier unique ne peut pas être traité en parallèle, gaspillage des ressources CPU |

### 2. Parallélisme Dart vs. langages de script traditionnels
| Tostore | Bases de données basées sur des scripts traditionnels |
|:---------|:-----------|
| ✅ Les Isolates s'exécutent en parallèle véritable sans contraintes de verrou global | ❌ Les langages comme Python sont limités par le GIL, inefficaces pour les tâches intensives en CPU |
| ✅ La compilation AOT génère un code machine efficace, performances proches du natif | ❌ Perte de performance dans le traitement des données due à l'exécution interprétée |
| ✅ Modèle de tas mémoire indépendant, évite les contentions de verrou et de mémoire | ❌ Le modèle de mémoire partagée nécessite des mécanismes de verrouillage complexes en haute concurrence |
| ✅ La sécurité des types offre des optimisations de performance et une vérification des erreurs à la compilation | ❌ Le typage dynamique découvre les erreurs à l'exécution avec moins d'opportunités d'optimisation |
| ✅ Intégration profonde avec l'écosystème Flutter | ❌ Nécessite des couches ORM supplémentaires et des adaptateurs UI, augmentant la complexité |

### 3. Intégration embarquée vs. stockages de données indépendants
| Tostore | Bases de données traditionnelles |
|:---------|:-----------|
| ✅ Utilise le langage Dart, s'intègre parfaitement aux projets Flutter/Dart | ❌ Nécessite d'apprendre SQL ou des langages de requête spécifiques, augmentant la courbe d'apprentissage |
| ✅ Le même code supporte le frontend et le backend, pas besoin de changer de pile technologique | ❌ Frontend et backend nécessitent généralement différentes bases de données et méthodes d'accès |
| ✅ Style d'API chaîné correspondant aux styles de programmation modernes, excellente expérience de développement | ❌ Concaténation de chaînes SQL vulnérable aux attaques et aux erreurs, manque de sécurité de type |
| ✅ Support pour la programmation réactive, se marie naturellement avec les frameworks UI | ❌ Nécessite des couches d'adaptation supplémentaires pour connecter l'UI et la couche de données |
| ✅ Pas besoin de configuration complexe de mappage ORM, utilisation directe des objets Dart | ❌ Complexité du mappage objet-relationnel, coûts élevés de développement et de maintenance |

### 4. Détection précise des changements de schéma vs. gestion manuelle des migrations
| Tostore | Bases de données traditionnelles |
|:---------|:-----------|
| ✅ Détecte automatiquement les changements de schéma, pas besoin de gestion des numéros de version | ❌ Dépendance au contrôle manuel des versions et au code de migration explicite |
| ✅ Détection au niveau milliseconde des changements de tables/champs et migration automatique des données | ❌ Besoin de maintenir la logique de migration pour les mises à niveau entre versions |
| ✅ Identification précise des renommages de tables/champs, préservation de toutes les données historiques | ❌ Le renommage des tables/champs peut entraîner une perte de données |
| ✅ Opérations de migration atomiques garantissant la cohérence des données | ❌ Les interruptions de migration peuvent causer des incohérences de données |
| ✅ Mises à jour de schéma entièrement automatisées sans intervention manuelle | ❌ Logique de mise à niveau complexe et coûts de maintenance élevés avec l'augmentation des versions |






## Points forts techniques

- 🌐 **Support multiplateforme transparent**:
  - Expérience cohérente sur les plateformes Web, Linux, Windows, Mobile, Mac
  - Interface API unifiée, synchronisation des données multiplateforme sans tracas
  - Adaptation automatique à divers backends de stockage multiplateformes (IndexedDB, systèmes de fichiers, etc.)
  - Flux de données fluide de l'informatique de périphérie au cloud

- 🧠 **Architecture distribuée inspirée des réseaux neuronaux**:
  - Topologie de nœuds interconnectés similaire aux réseaux neuronaux
  - Mécanisme efficace de partitionnement des données pour le traitement distribué
  - Équilibrage dynamique intelligent de la charge de travail
  - Support pour l'extension illimitée des nœuds, construction facile de réseaux de données complexes

- ⚡ **Capacités de traitement parallèle ultimes**:
  - Lecture/écriture véritablement parallèle avec Isolates, utilisation complète du multicœur CPU
  - Réseau de calcul multi-nœuds coopérant pour une efficacité multipliée des tâches multiples
  - Framework de traitement distribué conscient des ressources, optimisation automatique des performances
  - Interface de requête en streaming optimisée pour traiter des ensembles de données massifs

- 🔑 **Divers algorithmes de clés primaires distribuées**:
  - Algorithme d'incrément séquentiel - longueur de pas aléatoire librement ajustable
  - Algorithme basé sur l'horodatage - idéal pour les scénarios d'exécution parallèle haute performance
  - Algorithme de préfixe de date - adapté aux données avec indication de plage temporelle
  - Algorithme de code court - identifiants uniques concis

- 🔄 **Migration de schéma intelligente**:
  - Identification précise des comportements de renommage de tables/champs
  - Mise à jour et migration automatiques des données lors des changements de schéma
  - Mises à niveau sans temps d'arrêt, sans impact sur les opérations commerciales
  - Stratégies de migration sécurisées prévenant la perte de données

- 🛡️ **Sécurité de niveau entreprise**:
  - Algorithme de chiffrement ChaCha20Poly1305 pour protéger les données sensibles
  - Chiffrement de bout en bout, garantissant la sécurité des données stockées et transmises
  - Contrôle d'accès aux données à granularité fine

- 🚀 **Cache intelligent et performance de recherche**:
  - Mécanisme de cache intelligent multiniveau pour une récupération efficace des données
  - Cache de démarrage améliorant dramatiquement la vitesse de lancement des applications
  - Moteur de stockage profondément intégré avec le cache, pas besoin de code de synchronisation supplémentaire
  - Mise à l'échelle adaptative, maintien des performances stables même avec la croissance des données

- 🔄 **Flux de travail innovants**:
  - Isolation des données multi-espaces, support parfait pour les scénarios multi-locataires et multi-utilisateurs
  - Attribution intelligente de la charge de travail entre les nœuds de calcul
  - Fournit une base de données robuste pour l'entraînement et l'analyse de données à grande échelle
  - Stockage automatique des données, mises à jour et insertions intelligentes

- 💼 **L'expérience du développeur est prioritaire**:
  - Documentation bilingue détaillée et commentaires de code (chinois et anglais)
  - Informations de débogage riches et métriques de performance
  - Capacités intégrées de validation des données et de récupération de corruption
  - Configuration zéro prêt à l'emploi, démarrage rapide

## Démarrage rapide

Utilisation de base:

```dart
// Initialisation de la base de données
final db = ToStore();
await db.initialize(); // Optionnel, assure que l'initialisation de la base de données est terminée avant les opérations

// Insertion de données
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// Mise à jour de données
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Suppression de données
await db.delete('users').where('id', '!=', 1);

// Support pour les requêtes chaînées complexes
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Stockage automatique des données, mise à jour si existe, insertion sinon
await db.upsert('users', {'name': 'John','email': 'john@example.com'})
  .where('email', '=', 'john@example.com');
// Ou
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});

// Comptage efficace des enregistrements
final count = await db.query('users').count();

// Traitement de données massives en utilisant des requêtes en streaming
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // Traite chaque enregistrement selon les besoins, évitant la pression mémoire
    print('Traitement de l\'utilisateur: ${userData['username']}');
  });

// Définir des paires clé-valeur globales
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Obtenir des données de paires clé-valeur globales
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## Exemple d'application mobile

```dart
// Définition de structure de table adaptée aux scénarios de démarrage fréquent comme les applications mobiles, détection précise des changements de structure de table, mise à niveau et migration de données automatiques
final db = ToStore(
  schemas: [
    const TableSchema(
      name: 'users', // Nom de la table
      tableId: "users",  // Identifiant unique de table, optionnel, utilisé pour une identification à 100% des exigences de renommage, même sans peut atteindre un taux de précision supérieur à 98%
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id', // Clé primaire
      ),
      fields: [ // Définition des champs, n'inclut pas la clé primaire
        FieldSchema(name: 'username', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'email', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [ // Définition des index
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// Passer à l'espace utilisateur - isolation des données
await db.switchSpace(spaceName: 'user_123');
```

## Exemple de serveur backend

```dart
await db.createTables([
      const TableSchema(
        name: 'users', // Nom de la table
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id', // Clé primaire
          type: PrimaryKeyType.timestampBased,  // Type de clé primaire
        ),
        fields: [
          // Définition des champs, n'inclut pas la clé primaire
          FieldSchema(
              name: 'username',
              type: DataType.text,
              nullable: false,
              unique: true),
          FieldSchema(name: 'vector_data', type: DataType.blob),  // Stockage de données vectorielles
          // Autres champs ...
        ],
        indexes: [
          // Définition des index
          IndexSchema(fields: ['username']),
          IndexSchema(fields: ['email']),
        ],
      ),
      // Autres tables ...
]);


// Mise à jour de la structure de table
final taskId = await db.updateSchema('users')
    .renameTable('newTableName')  // Renommer la table
    .modifyField('username',minLength: 5,maxLength: 20,unique: true)  // Modifier les propriétés du champ
    .renameField('oldName', 'newName')  // Renommer le champ
    .removeField('fieldName')  // Supprimer le champ
    .addField('name', type: DataType.text)  // Ajouter un champ
    .removeIndex(fields: ['age'])  // Supprimer un index
    .setPrimaryKeyConfig(  // Définir la configuration de la clé primaire
      const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
    );
    
// Interroger l'état de la tâche de migration
final status = await db.queryMigrationTaskStatus(taskId);  
print('Progression de la migration: ${status?.progressPercentage}%');
```


## Architecture distribuée

```dart
// Configuration des nœuds distribués
final db = ToStore(
    config: DataStoreConfig(
        distributedNodeConfig: const DistributedNodeConfig(
            clusterId: 1,  // Configuration de l'appartenance au cluster
            centralServerUrl: 'http://127.0.0.1:8080',
            accessToken: 'b7628a4f9b4d269b98649129'))
);

// Insertion par lot de données vectorielles
await db.batchInsert('vector', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Des milliers d'enregistrements
]);

// Traitement en streaming de grands ensembles de données pour analyse
await for (final record in db.streamQuery('vector')
    .where('vector_name', '=', 'face_2366')
    .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
    .stream) {
  // L'interface de streaming prend en charge l'extraction et la transformation de caractéristiques à grande échelle
  print(record);
}
```

## Exemples de clés primaires
Différents algorithmes de clés primaires, tous supportant la génération distribuée, il n'est pas recommandé de générer soi-même des clés primaires pour éviter l'impact des clés primaires non ordonnées sur les capacités de recherche.
Clé primaire séquentielle PrimaryKeyType.sequential : 238978991
Clé primaire basée sur l'horodatage PrimaryKeyType.timestampBased : 1306866018836946
Clé primaire à préfixe de date PrimaryKeyType.datePrefixed : 20250530182215887631
Clé primaire à code court PrimaryKeyType.shortCode : 9eXrF0qeXZ

```dart
// Clé primaire séquentielle PrimaryKeyType.sequential
// Lorsque le système distribué est activé, le serveur central alloue des plages que les nœuds génèrent eux-mêmes, compactes et faciles à mémoriser, adaptées aux ID utilisateurs et aux numéros attrayants
await db.createTables([
      const TableSchema(
        name: 'users',
        primaryKeyConfig: PrimaryKeyConfig(
          type: PrimaryKeyType.sequential,  // Type de clé primaire séquentielle
          sequentialConfig:  SequentialIdConfig(
              initialValue: 10000, // Valeur initiale d'auto-incrément
              increment: 50,  // Pas d'incrément
              useRandomIncrement: true,  // Utilisation d'un pas aléatoire pour éviter de révéler le volume d'affaires
            ),
        ),
        // Définition des champs et index ...
        fields: []
      ),
      // Autres tables ...
 ]);
```


## Configuration de sécurité

```dart
// Renommage de tables et champs - reconnaissance automatique et conservation des données
final db = ToStore(
      config: DataStoreConfig(
        enableEncoding: true, // Activer l'encodage sécurisé pour les données de table
        encodingKey: 'YouEncodingKey', // Clé d'encodage, peut être ajustée arbitrairement
        encryptionKey: 'YouEncryptionKey', // Clé de chiffrement, remarque : modifier cette clé empêchera le décodage des anciennes données
      ),
    );
```

## Tests de performance

Tostore 2.0 implémente une évolutivité linéaire des performances, les changements fondamentaux dans le traitement parallèle, les mécanismes de partitionnement et l'architecture distribuée ont considérablement amélioré les capacités de recherche de données, offrant des temps de réponse en millisecondes même avec une croissance massive des données. Pour le traitement de grands ensembles de données, l'interface de requête en streaming peut traiter des volumes massifs de données sans épuiser les ressources mémoire.



## Plans futurs
Tostore développe le support pour les vecteurs de haute dimension afin de s'adapter au traitement de données multimodales et à la recherche sémantique.


Notre objectif n'est pas de créer une base de données; Tostore est simplement un composant extrait du framework Toway pour votre considération. Si vous développez des applications mobiles, nous recommandons d'utiliser le framework Toway avec son écosystème intégré, qui couvre la solution complète pour le développement d'applications Flutter. Avec Toway, vous n'aurez pas besoin de toucher à la base de données sous-jacente, toutes les opérations de requête, chargement, stockage, mise en cache et affichage des données seront automatiquement effectuées par le framework.
Pour plus d'informations sur le framework Toway, veuillez visiter le [dépôt Toway](https://github.com/tocreator/toway).

## Documentation

Visitez notre [Wiki](https://github.com/tocreator/tostore) pour une documentation détaillée.

## Support et feedback

- Soumettre des problèmes: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Rejoindre la discussion: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Contribuer au code: [Guide de contribution](CONTRIBUTING.md)

## Licence

Ce projet est sous licence MIT - voir le fichier [LICENSE](LICENSE) pour plus de détails.

---

<p align="center">Si vous trouvez Tostore utile, n'hésitez pas à nous donner une ⭐️</p>
