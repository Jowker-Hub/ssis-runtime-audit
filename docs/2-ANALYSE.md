# 2. L'analyse

Comment ouvrir le rapport, et ce que chaque page vous dit.

---

## Ouvrir

Ouvrez `powerbi\SsisRuntimeAudit.pbip` dans Power BI Desktop, puis cliquez **Actualiser**.

Le rapport lit `C:\Audit\SsisRuntimeAudit` — le dossier où la collecte dépose ses fichiers.
Les deux moitiés de l'outil se rejoignent là, et il n'y a aucun paramètre à régler.

### Deux points qui font perdre du temps

**Il faut Power BI Desktop 2.157 ou supérieur.** Une version antérieure affiche une fenêtre
vide et n'ouvre jamais le modèle : le message qui l'explique se trouve dans une boîte de
dialogue restée en arrière-plan. Si plusieurs versions cohabitent sur votre poste, le
double-clic peut ouvrir la plus ancienne — lancez alors la version récente, puis
*Fichier → Ouvrir*.

**Le rapport se lit en apparence Claire.** *Fichier → Options et paramètres → Options → Global
→ Paramètres de rapport → Personnaliser l'apparence → Clair.* En apparence sombre, le texte
reste sombre et les visuels paraissent vides alors qu'ils sont correctement alimentés.

---

## Changer de collecte

Chaque exécution de la collecte crée son propre sous-dossier. Le rapport lit **la plus récente**
par défaut : après une nouvelle collecte, un simple *Actualiser* suffit.

Pour figer une collecte précise — par exemple pour annexer une analyse à un compte rendu, et
qu'elle continue de montrer ce que vous avez vu ce jour-là :

*Transformer les données → Gérer les paramètres → `DossierRun`*, puis choisissez un `Run_...`
dans la liste déroulante.

Pour lire des collectes stockées ailleurs, changez `DossierBase`.

La collecte réellement affichée figure dans le bandeau de chaque page, avec l'instant
d'extraction et le serveur.

---

## Les huit pages

Chaque page répond à **une seule question**. Le bandeau du bas rappelle en permanence la
couverture : combien d'exécutions, combien de packages, quelle fenêtre.

### Qualité et capacités — *commencez par là*

Ce que votre catalogue permet de mesurer, et ce qu'il ne permet pas. La couverture par niveau
de logging, les contrôles de qualité, et un cadre **« Non mesurable dans ce contexte »** qui
énumère ce que l'outil ne saura pas vous dire, quoi qu'il arrive.

Lue en premier, cette page évite de chercher pendant une heure une information que la source ne
contient pas.

### Vue d'ensemble — *où regarder en premier ?*

Les volumes de la période, un nuage qui croise fréquence et durée médiane, et une liste des
packages à examiner. La taille des bulles est la durée cumulée : elle répond à *où passe le
temps*, ce qui n'est pas la même question que *qu'est-ce qui est lent*.

### Durées et activité — *qu'est-ce qui consomme du temps ?*

Durée médiane, durée cumulée, fréquence, et la distribution des durées par package.

**L'axe des durées est logarithmique**, et ce n'est pas un détail : un parc SSIS mélange
couramment des packages de trois secondes et de trois heures. Une échelle linéaire écraserait
tout le bas de la distribution contre l'axe.

La **médiane** est la référence, pas la moyenne : quelques exécutions très longues suffisent à
déplacer une moyenne loin de ce qui se passe ordinairement.

### Stabilité et dérive — *qu'est-ce qui varie ou se dégrade ?*

L'évolution des durées dans le temps, les repères de déploiement, et la comparaison entre la
première et la seconde moitié de la période.

> **Un changement de version établit une coïncidence, pas une causalité.** Un déploiement qui
> précède une dégradation peut l'avoir causée — ou avoir eu lieu le même jour qu'un changement
> de volume, de plan d'exécution ou d'infrastructure. Le catalogue ne permet pas de trancher.

La colonne de variation affiche **« Effectif insuffisant »** plutôt qu'un pourcentage quand il y
a moins de cinq exécutions de chaque côté de la coupure. Comparer deux poignées de valeurs
produit du bruit qui ressemble à une tendance.

### Chronologie et Gantt — *qu'est-ce qui tourne en même temps ?*

Le déroulé des exécutions dans la journée, le nombre d'exécutions simultanées, et une carte de
chaleur par jour et par heure.

> **La concurrence observée ne prouve pas une saturation.** Le catalogue ne collecte aucun
> usage processeur, mémoire ou disque. Huit exécutions simultanées sur une machine à
> trente-deux cœurs ne saturent rien ; deux peuvent suffire ailleurs. Ces pages orientent
> l'investigation, elles ne la concluent pas.

### Stabilité opérationnelle — *qu'est-ce qui échoue ?*

Taux de réussite, échecs, interruptions, et les codes d'erreur les plus fréquents.

**Les interruptions sont comptées à part**, et c'est tout l'intérêt : rangées avec les échecs
elles disparaissent, rangées avec les réussites elles mentent. Une interruption dit
généralement quelque chose de l'exploitation — un redémarrage de service, un arrêt manuel — et
pas du package.

Le rapport porte les **codes** des messages, leur type et le composant source. Il ne porte pas
leur **texte** : un message SSIS contient couramment un nom de serveur, un chemin réseau ou un
extrait de requête. Pour lire un message, retournez au catalogue.

### Détail d'un package — *où part le temps dans ce package ?*

Le détail par tâche, la hiérarchie d'exécution, et — si le logging le permet — les phases des
composants et les lignes transitées.

Trois pièges de ce niveau de détail, dont le rapport tient compte :

- **une boucle produit une ligne par tour**, pas une par exécution ;
- **la tâche racine porte la durée du package entier** : la compter avec ses enfants compte le
  temps deux fois ;
- **les phases se chevauchent entre composants**, par construction — un flux traite en
  parallèle. Leur somme dépasse la durée du flux et ne représente rien.

---

## Ce que le rapport fait quand il n'a rien à montrer

**Il le dit.** Une zone dont les données ne sont pas disponibles affiche son motif — « le
niveau de logging actuel est Basic », par exemple — plutôt que de rester vide.

C'est délibéré. Zéro et « pas de donnée » sont deux constats opposés, et un visuel vide se lit
spontanément comme le premier. Les mesures de durée rendent donc une valeur absente plutôt
qu'un zéro lorsqu'il n'y a rien à mesurer.

---

## Le niveau de confiance

Plusieurs pages affichent un **niveau de confiance** : *Insuffisante*, *Faible*, *Moyenne*,
*Élevée*.

Il qualifie **la taille de l'échantillon, et rien d'autre**. Une confiance élevée ne dit pas
qu'une conclusion est vraie ; elle dit qu'il y a assez d'exécutions pour que la médiane et les
percentiles veuillent dire quelque chose.

L'inverse est plus utile encore : une confiance *insuffisante* interdit de conclure, quelle que
soit l'ampleur apparente de l'écart observé.

> Les seuils retenus sont conventionnels et n'ont pas été étalonnés sur un grand parc. Ils sont
> là pour être discutés.

---

Suite : [3-CAPACITES.md](3-CAPACITES.md) — ce que chaque extraction autorise à conclure.
