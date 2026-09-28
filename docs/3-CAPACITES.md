# Ce que l'outil mesure, et ce qu'on a le droit d'en conclure

Pour chaque extraction : sa source, son grain, sa volumetrie mesuree, et surtout les
**conclusions autorisees et interdites**.

Ce document n'est pas une precaution de style. Il existe parce qu'une donnee absente ou
un indicateur approximatif produisent tres facilement une conclusion plus forte que ce que
la source permet - et qu'une telle conclusion, presentee a un ingenieur qui connait son
parc, decredibilise tout le reste.

Les volumetries sont **mesurees** sur un catalogue reel. Les noms de colonnes sont
**releves** sur un catalogue en `SCHEMA_VERSION 6`.

---

## 1. Les trois natures

| Nature | Sens | Comportement du runner |
|---|---|---|
| **Automatique** | contexte sans lequel les autres fichiers ne s'interprètent pas | toujours produit, non décochable |
| **Fondamentale** | le cœur de l'audit, disponible au niveau Basic donc partout | proposé coché |
| **Conditionnelle** | dépend d'un niveau de logging supérieur | proposé décoché, grisé si le logging observé ne le permet pas |

Une extraction conditionnelle dont la source est vide **ne produit pas un fichier vide** : elle
est déclarée indisponible dans `Extractions.csv` avec son motif. Un fichier d'en-têtes
ressemblerait à une extraction réussie sans résultat, ce qui est un tout autre constat.

---

## 2. Où vit le niveau de preuve

**Pas dans les CSV bruts.** Une colonne de confiance au grain brut serait trompeuse : la
confiance appartient à une **conclusion calculée**, pas à une exécution, une tâche ou un
message. La même ligne brute peut alimenter une mesure exacte et une inférence faible.

Le niveau de preuve se place à deux endroits, et à un troisième quand il est localement
signifiant :

| Où | Quoi | Quand |
|---|---|---|
| Manifeste d'extraction | `Measured`, `Derived` ou `Proxy` par champ calculé | dès la première version |
| Tables d'analyse | `EvidenceLevel` et `ConclusionCode`, sur liste fermée | **obligatoire dès qu'une conclusion est automatisée**, pas avant |
| Colonne dédiée | par exemple `DeploymentTimeEvidence`, voir 4.4 | quand une même colonne peut venir de sources de fiabilité différentes |

Pour la première version, la matrice écrite suffit aux extractions brutes. Le mécanisme
devient obligatoire quand les premières tables analytiques ou pages Power BI automatisent une
conclusion. Ne pas anticiper davantage.

---

## 3. Règles transverses

### 3.1 Ce qui ne sort jamais

| Interdit | Où ça se trouve | Motif |
|---|---|---|
| Comptes de domaine | `executed_as_name`, `caller_name`, `stopped_by_name`, `created_by_name`, `deployed_by_name`, tous les `*_sid` | des personnes identifiables. La catégorie suffit |
| Valeurs de paramètres métier | `execution_parameter_values` en `object_type` 20 et 30, `object_parameters.default_value` | **mesuré** : `CM.Ventes.ConnectionString` sort en clair, `sensitive = 0`, avec serveur et base |
| Texte des messages | `event_messages.message` | transporte chemins réseau, chaînes de connexion et ordres SQL |
| Valeur de retour d'exécutable | `executable_statistics.execution_value` | `sql_variant` **défini par l'utilisateur** : un nombre ne prouve pas un nombre de lignes, une chaîne peut contenir n'importe quoi |
| **Descriptions libres** | `folders`, `projects`, `packages`, `object_parameters`, `object_versions` | même raisonnement que le texte des messages, appliqué après relecture : un texte libre peut porter un nom de client, un chemin, un ticket. Elles n'alimentent aucun signal |
| Valeur brute de `CALLER_INFO` hors liste blanche | `execution_parameter_values` | paramètre système, mais **texte posé par l'appelant**. `SQLAGENT` sort, une chaîne libre non reconnue non |

**Seule exception, liste blanche** : les valeurs de paramètres en `object_type = 50`, les
paramètres système, pivotées en colonnes de l'exécution.

### 3.2 Ce qui est conservé sans discussion

Le **triplet dossier / projet / package** sur toute ligne identifiant un package, et
`executable_guid` au grain de la tâche. Ce sont les clés du contrat d'enrichissement optionnel
du rapprochement possible avec un audit statique des sources. Gratuites maintenant, impossibles à reconstituer après coup.

### 3.3 Normalisations obligatoires

| Règle | Motif |
|---|---|
| Retirer l'indice `[n]` du chemin d'exécution pour obtenir le chemin **logique**, et conserver les deux | **mesuré** : 310 lignes sur 409, soit 76 %, portent un indice d'itération |
| Fermer les exécutions en cours à l'**`ExtractionTimestampUtc`** du fichier de contexte, jamais à une heure recalculée par requête | une exécution en cours disparaît sinon du calcul de concurrence, et fait disparaître avec elle le chevauchement des autres. Deux requêtes fermant à deux instants différents ne sont plus comparables |
| Tout horodatage sort en **ISO 8601 UTC à précision native**, `CONVERT(varchar(40), …, 127)` | **mesuré** : le format court écrasait la fraction de seconde. Deux exécutables démarrant à `.7655161` et `.8125161` sortaient tous deux à `08:07:10`. Sur des durées en millisecondes et du recouvrement d'intervalles, c'est disqualifiant |
| La fenêtre est **semi-ouverte** : `>= @DebutFenetre` et `< @FinFenetre` | avec `<=`, deux fenêtres adjacentes extraient deux fois le run posé exactement sur la borne |
| Les clés d'un modèle hiérarchique sont **textuelles et globales**, `Type:Id` | `folder_id`, `project_id` et `package_id` viennent de trois espaces d'identifiants indépendants et peuvent collisionner. Les identifiants numériques restent pour le diagnostic, jamais comme clé |
| Booléens `True` / `False`, absence en chaîne vide, colonne inconnue présente et vide | conventions du SSIS Toolkit |

### 3.4 Bornage du volume : refus, jamais troncature

Le runner impose une **fenêtre temporelle commune** à toutes les tables de faits dynamiques :
exécutions, exécutables, messages, et enrichissements conditionnels. Le pré-vol estime le
nombre de lignes de chaque grain avant d'extraire.

Si une limite configurable est dépassée, l'extraction s'arrête sur l'état explicite
**`VolumeExceedsLimit`** et propose de réduire la fenêtre.

**Elle ne prend jamais les premières lignes, les dernières, ni un Top N packages.** Un
échantillon ainsi biaisé serait indistinguable d'une vraie distribution, ce qui est
strictement pire qu'une extraction refusée. Elle ne retire pas non plus un type de message
pour faire rentrer un fichier.

**La limite est par extraction, pas globale, et obligatoire dès la première version.** Une
limite unique ne peut pas représenter des coûts aussi différents : mesuré, une exécution vaut
1 ligne d'exécution, 11 d'exécutables et **486 de phases de composants**. Le plan porte donc
pour chaque extraction une `LimiteLignesParDefaut`, sa stratégie d'estimation, et la
possibilité d'une surcharge explicite. `0` ou `null` ne valent que si l'absence de limite est
assumée **et affichée**.

Les valeurs initiales peuvent être prudentes et s'ajuster après un premier catalogue client.
Ce qui est figé ici, c'est le contrat : estimation avant extraction, refus explicite, aucune
troncature, et écriture en flux continu.

### 3.5 Colonnes dépendantes de la version du catalogue

Deux colonnes posent ce problème, et elles se traitent différemment.

**`CUSTOMIZED_LOGGING_LEVEL`** est une valeur de paramètre, lue par pivot sur son nom. Un
catalogue qui ne la porte pas rend simplement une colonne vide : aucune condition à écrire, et
c'est ce qui est fait.

**`worker_agent_id`** est une vraie colonne de `catalog.executions`, absente avant 2017. La
sélectionner ferait échouer la requête entière sur un catalogue plus ancien, et la conditionner
exigerait du SQL dynamique — donc de construire le texte envoyé, ce qu'interdit la règle du
fichier exécuté sans transformation. **Elle n'est donc pas extraite.** Le Scale Out n'entre pas
dans le périmètre, et le prix à payer serait la portabilité de toute l'extraction.

---

## 4. La matrice

### 4.1 Exécutions — *fondamentale*

| | |
|---|---|
| **Source** | `catalog.executions`, plus les paramètres système pivotés |
| **Grain** | une ligne par exécution |
| **Volumétrie** | 1 par exécution |
| **Logging** | Basic |
| **Famille** | 1, 3, 4, 5, 6, 8, 9 |

**Colonnes.** Identité : `execution_id`, triplet, `project_lsn`, environnement. Contexte :
`server_name`, `machine_name`, `use32bitruntime`, `cpu_count`, mémoire physique et pagination,
`executed_count`. Temps : `created_time`,
`start_time`, `end_time`, décalage UTC, durée, délai d'initialisation. Issue : `status`, et un
booléen *arrêt demandé* dérivé de `stopped_by_sid` sans jamais sortir le nom.

**Paramètres système pivotés**, mesurés présents : `LOGGING_LEVEL`, `CALLER_INFO`,
`SYNCHRONIZED`, `DUMP_ON_ERROR`, `DUMP_ON_EVENT`, `DUMP_EVENT_CODE`. Plus
`CUSTOMIZED_LOGGING_LEVEL` **si présent**, voir 3.5. Le pivot les ramène à des colonnes : le
coût est nul.

**Origine déclarée**, trois catégories et jamais deux :

| `CALLER_INFO` | Catégorie |
|---|---|
| `SQLAGENT` | `AgentSql` |
| valeur non vide différente | `AutreDeclaree` |
| vide | `Indeterminee` |

**Conclusions autorisées.** Durée d'une exécution. Temps cumulé par package. Stabilité et
dérive à `project_lsn` constant. Nombre d'exécutions simultanées par recouvrement
d'intervalles. Délai observé entre initialisation et démarrage effectif.

**Conclusions interdites.**

- *« Lancement manuel »* déduit d'un `CALLER_INFO` vide. La valeur **identifie l'Agent, pas
  son contraire** : un orchestrateur tiers, un appel T-SQL ou un script laissent la même
  valeur vide. Le générateur d'historique de ce projet en est la démonstration.
- *« SSISDB a bridé l'exécution. »* Le délai entre initialisation et démarrage est un
  **symptôme**, pas sa cause. Formulation admise : *une hausse concomitante à une forte
  concurrence justifie une investigation sur la mise en file ou la capacité.*
- *« La machine était saturée. »* La mémoire est une **photo au démarrage**. Admis : *les
  exécutions lentes coïncident régulièrement avec une mémoire disponible plus faible au
  lancement.*
- *« Ce déploiement a causé la dégradation. »* Coïncidence, jamais causalité, et `project_lsn`
  versionne le projet, pas le package.
- *« Le parallélisme est inexploité. »* Le recouvrement mesure un **nombre d'exécutions
  simultanées**, pas l'occupation d'une machine — et ce nombre **s'inclut lui-même** : 1
  signifie aucun pair concurrent.

---

### 4.2 Exécutables — *fondamentale*

| | |
|---|---|
| **Source** | `catalog.executable_statistics` jointe à `catalog.executables` |
| **Grain** | une ligne par exécutable par exécution, **itérations comprises** |
| **Volumétrie** | **11,1 par exécution** en moyenne, 13,0 sur le package le plus imbriqué (mesuré) |
| **Logging** | Basic |
| **Famille** | 7 |

**Colonnes.** `execution_id`, `executable_id`, `executable_guid`, `executable_name`,
`package_name`, `package_path`, `execution_path` brut, **chemin logique normalisé**, indice
d'itération extrait, `start_time`, `end_time`, `execution_duration` en millisecondes,
`execution_result`.

`execution_value` reste **exclue**. Deux métadonnées la remplacent, vérifiées implémentables :
`ExecutionValuePresent`, et `ExecutionValueBaseType` obtenu par
`SQL_VARIANT_PROPERTY(..., 'BaseType')`. N'extraire que les valeurs numériques créerait une
fausse promesse sémantique — la valeur est définie par l'utilisateur et un nombre ne prouve
aucun nombre de lignes. Si une mission connaît la convention d'un package, la valeur relèvera
d'un enrichissement local documenté, hors du socle.

**Conclusions autorisées.** Répartition du temps entre tâches. Dispersion entre itérations
d'une même boucle. Localisation d'une tâche dominante.

**Conclusions interdites.**

- **Sommer les durées d'un package.** Un conteneur inclut ses enfants : mesuré, `\Package` à
  187 ms contient `\Package\Data Flow Task` à 140 ms.
- **Agréger sur le chemin brut.** 76 % des lignes portent un indice d'itération.
- *« Il n'y a rien à optimiser. »* Admis : *aucun levier dominant identifié.*
- **Conclure sur le temps total d'une exécution depuis ces seules lignes.** Le corps du package
  ne couvre pas tout le temps écoulé ; le reste est validation, préparation et libération et
  n'apparaît pas ici. Mesuré à 92 % sur un package trivial, à 1,9 % sur l'ensemble du corpus :
  c'est un signal **par package**, jamais une propriété générale.

---

### 4.3 Messages, métadonnées — *fondamentale*

| | |
|---|---|
| **Source** | `catalog.event_messages`, filtrée |
| **Grain** | une ligne par message retenu |
| **Volumétrie** | 136,0 par exécution brut, **0,8 après filtrage** (mesuré) |
| **Logging** | Basic |
| **Famille** | 6 |

**Filtre, versionné dans la requête et non exposé en paramètre client** — le changer changerait
le sens du CSV et empêcherait toute comparaison entre missions :

| `message_type` | Sens |
|---:|---|
| 100 | annulation de requête |
| 110 | avertissement |
| 120 | erreur |
| 130 | échec de tâche |

Seuls 110 et 120 ont été observés localement ; 100 et 130 sont documentés et retenus sans
attendre de les voir. **Le ratio de 0,8 est donc un plancher**, mesuré sur un corpus presque
sain : un parc qui plante beaucoup le fera monter, et c'est le pré-vol qui le mesure. Si le
volume dépasse la limite, le runner refuse selon 3.4 ; il ne retire aucun type pour faire
rentrer le fichier.

**Colonnes.** `event_message_id`, `operation_id` qui vaut l'`execution_id`, `message_time`,
`message_type`, `message_source_type`, `package_name`, `event_name`, `message_source_name`,
`subcomponent_name`, `package_path`, `execution_path`, `message_code`. **`message` est
exclue.**

**Conclusion autorisée, et elle vaut cher.** Des messages d'erreur journalisés **malgré un
statut final réussi** : mesuré, deux runs sur trente-sept. Le croisement statut × compteur
d'erreurs révèle ce qu'aucune lecture du statut ne donne, au niveau Basic donc partout.

**Conclusions interdites.**

- *« Fragilité latente. »* L'erreur peut avoir été **prévue et gérée**. Le fait autorisé est
  *messages d'erreur journalisés malgré un statut final réussi* ; l'interprétation appartient
  à l'analyse.
- **Un nombre de messages n'est pas un nombre d'incidents.** Une erreur racine se propage sur
  plusieurs objets.
- **Aucune explication de cause.** Le texte n'est pas extrait. Le débogage détaillé passe par
  les rapports d'exécution natifs.

---

### 4.4 Inventaire du catalogue — *automatique*

| | |
|---|---|
| **Source** | `catalog.folders`, `catalog.projects`, `catalog.packages`, `catalog.object_versions` |
| **Grain** | **une ligne par objet déployé**, hiérarchique |
| **Volumétrie** | statique, négligeable |
| **Logging** | aucun |
| **Famille** | 2 |

**Grain hiérarchique et non aplati au package** : `ObjectType`, `ObjectId`, `ParentObjectId`,
puis dossier, projet et package selon disponibilité. Un aplatissement au grain package serait
plus simple mais ferait disparaître dossiers vides et projets sans package — et rendrait
**impossible de distinguer « aucun package » de « inventaire incomplet »**.

**Colonnes.** Triplet selon le niveau, `package_guid`, `entry_point`, version du package,
format, `validation_status`, `last_validation_time`, `object_version_lsn`.
`created_by_name` et `deployed_by_name` sont **exclues**.

**Date de déploiement, à trois niveaux de preuve** portés par `DeploymentTimeEvidence` :

| Valeur | Source | Fiabilité |
|---|---|---|
| `CatalogVersion` | `object_versions.created_time` | mesurée, pour chaque version encore conservée |
| `CurrentProject` | `projects.last_deployed_time` | mesurée, version courante seulement |
| `InferredInterval` | dernière exécution de l'ancienne version, première de la nouvelle | inférée — **les deux bornes sont portées, jamais une fausse date centrale** |

L'inférence ne sert que pour une version observée dans les exécutions mais déjà purgée de
`object_versions` : `MAX_PROJECT_VERSIONS` vaut 10 sur le catalogue mesuré, contre 30 jours
d'exécutions, donc un parc qui déploie souvent épuise l'historique de versions en premier.

**Conclusion autorisée.** Écart entre objets déployés et objets réellement exécutés.
**Interdit** : le terme *code mort*. Formulation admise : *package sans exécution observée
dans la période*, la rétention pouvant simplement être plus courte que sa périodicité.

---

### 4.4 bis  Versions de projet — *automatique*

| | |
|---|---|
| **Source** | `catalog.object_versions`, **en union** avec les versions observées dans les exécutions |
| **Grain** | **une version connue du catalogue OU observée dans la fenêtre** |
| **Volumétrie** | bornée par `MAX_PROJECT_VERSIONS`, 10 sur le catalogue mesuré |
| **Logging** | aucun |
| **Famille** | 2, 5 |

**Extraction ajoutée après coup, et pourquoi.** La matrice logeait la datation des
déploiements dans l'inventaire. C'est un grain différent : un projet unique porte jusqu'à
`MAX_PROJECT_VERSIONS` versions, et les fondre obligerait soit à répéter chaque projet, soit à
ne garder que la version courante. Le principe retenu impose une extraction par grain — celle-ci en est une.

Elle porte les trois niveaux de preuve décrits en 4.4, et **les deux bornes de l'encadrement
sont renseignées quelle que soit la preuve** : quand une date mesurée existe, les bornes
permettent de la recouper. Vérifié sur le catalogue de référence, les dates mesurées tombent
bien à l'intérieur des encadrements inférés.

**Trois corrections apportées après relecture.** L'univers était limité aux versions
*observées*, ce qui faisait disparaître une version présente au catalogue mais jamais exécutée
dans la rétention. L'ordre des transitions s'appuyait sur `object_version_lsn` en le supposant
monotone : cette colonne **identifie** une version, elle ne prouve pas l'ordre de ses
activations, et les transitions sont désormais ordonnées par **première exécution observée**.
Enfin les comptages ignoraient la fenêtre que les tables de faits respectent.

**Conclusions interdites.**

- `project_lsn` versionne le **projet**. Une frontière signifie *le projet a été redéployé*,
  jamais *ce package a changé*. Trancher exige les sources `.dtsx`, donc un audit statique du code.
- Une **réactivation** d'une version antérieure n'est pas représentable à ce grain : la ligne
  résumerait deux épisodes distincts. Si le cas apparaît chez un client, le grain correct
  devient l'épisode d'activation et non la version.

---

### 4.5 Métadonnées de paramètres — *automatique*

| | |
|---|---|
| **Source** | `catalog.object_parameters` |
| **Grain** | une ligne par paramètre déclaré |
| **Volumétrie** | **29 lignes** statiques, contre 962 au grain exécution (mesuré) |
| **Logging** | aucun |
| **Famille** | 2 |

**Colonnes.** Projet et objet, `object_type`, `object_name`, `parameter_name`, `data_type`,
`required`, `sensitive`, `value_type` littéral ou référencé, `value_set`,
`referenced_variable_name`, `validation_status`. **`default_value` et `design_default_value`
sont exclues** : ce sont des valeurs.

**Conclusions autorisées.** Paramètres non valorisés, paramètres sensibles non marqués,
dépendance à un environnement. **Interdit** : toute lecture du contenu d'un paramètre.

---

### 4.6 Contexte du catalogue — *automatique*

| | |
|---|---|
| **Source** | `catalog.catalog_properties`, et la requête de diagnostic de phase 0 |
| **Grain** | une ligne par constat |
| **Logging** | aucun |
| **Famille** | 1 |

Il porte obligatoirement :

- un **`ExtractionTimestampUtc` unique**, qui est la valeur fermant toutes les exécutions en
  cours de toutes les extractions. Aucune requête ne recalcule son propre instant ;
- la **fenêtre temporelle appliquée** et les **limites de volume** en vigueur ;
- le **nombre de lignes par extraction**, sans quoi on ne distingue pas un jeu complet d'un
  refus pour volumétrie.

S'y ajoutent version du schéma, rétention paramétrée, nettoyage actif, versions conservées,
niveau de logging par défaut et profondeur réelle observée. **Sans ce fichier, aucun chiffre
n'est datable ni situable.**

---

### 4.7 Phases de composants — *conditionnelle, Performance*

| | |
|---|---|
| **Source** | `catalog.execution_component_phases` |
| **Grain** | une ligne par phase par composant |
| **Volumétrie** | **486 lignes par exécution** (mesuré sur trois runs en Performance). Quarante fois le grain des exécutables — première extraction concernée par le bornage de volume |
| **Logging** | **Performance** |
| **Famille** | 10 |

**Colonnes.** `phase_stats_id`, `execution_id`, `package_name`, `task_name`,
`subcomponent_name`, `phase`, `start_time`, `end_time`, `execution_path`.

**Conclusion autorisée.** Localisation du temps actif dans un flux. La phase d'amorçage de
sortie d'un composant source est un **proxy** du temps d'attente de la source, et s'annonce
comme tel.

**Conclusions interdites.** **Sommer les durées de phases** : elles sont concourantes, leur
somme dépasse la durée du flux, il faut raisonner en intervalles. **Parler de débit** : sans
volumes, ces phases n'en mesurent aucun.

**Si absent** : le chapitre existe et porte *information non disponible — niveau de logging
insuffisant*.

---

### 4.8 Statistiques de flux — *conditionnelle, Verbose*

| | |
|---|---|
| **Source** | `catalog.execution_data_statistics` |
| **Grain** | une ligne par chemin de flux |
| **Volumétrie** | 22 lignes par exécution (mesuré), soit deux par instance de flux : un flux émet par tampons et le dernier peut être vide |
| **Logging** | **Verbose**, le plus coûteux |
| **Famille** | 10 |

**Colonnes.** `data_stats_id`, `execution_id`, `package_name`, `task_name`,
`dataflow_path_id_string`, `dataflow_path_name`, `source_component_name`,
`destination_component_name`, `rows_sent`, `created_time`, `execution_path`. Les noms de
composants sont des **libellés de conception**, pas de la donnée client.

**Conclusion autorisée.** Débit observé sur un chemin donné.

**Interdit.** **Sommer les `rows_sent` de plusieurs branches ou sorties** en volume métier : un
flux qui duplique ou multidiffuse compte plusieurs fois les mêmes lignes.

---

## 5. Enrichissement optionnel par l'audit statique

`SsisRuntimeAudit` n'importe pas le module statique et n'exige pas ses CSV. Il
conserve les clés. L'assemblage se fait en aval, quand les sources `.dtsx` sont disponibles.

| Sans données statiques | Avec |
|---|---|
| chronologie et hiérarchie observées | dépendances déclarées |
| provenance `RuntimeObserved` | provenance `StaticDeclared` |
| **le terme « chemin critique » reste interdit** | analyse de dépendances possible |

---

## 6. Ce qui reste ouvert

- **Les paliers de confiance statistique.** Aucun seuil n'est ratifié. L'effectif, la médiane
  et les durées sont toujours publiés ; quartiles, P90, P95 et conclusion automatique sont
  conditionnés. Les seuils contrôlent **la force du langage, jamais la présence d'un package
  dans le rapport**.
- **La limite de volume** de 3.4, à fixer après un premier catalogue de taille client. La
  mesure des phases de composants — **486 lignes par exécution** sur un package trivial —
  suggère qu'elle devra être bien plus basse pour les extractions conditionnelles que pour les
  fondamentales, et sans doute exprimée par extraction plutôt qu'en une valeur unique.
- **`CUSTOMIZED_LOGGING_LEVEL`**, absent du catalogue mesuré : à confirmer chez un client qui
  utilise un niveau de logging personnalisé.

## 7. Volumétrie, pour mémoire

| | Lignes par exécution |
|---|---|
| Extraction naïve, tous grains bruts | ~173 |
| Après filtrage des messages et pivot des paramètres | **~12,9** |

**Ces chiffres ne comptent que les extractions fondamentales, au niveau Basic.** Les
conditionnelles changent complètement l'ordre de grandeur : les phases de composants, à elles
seules, valent **486 lignes par exécution** en Performance. C'est la raison pour laquelle la
limite de volume est par extraction et non globale.

Chez un client à cent mille exécutions : **1,3 million de lignes contre 17 millions.**
