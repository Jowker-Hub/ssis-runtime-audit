# SSIS Runtime Audit

Mesure les **temps d'exécution** de vos packages SSIS à partir du catalogue SSISDB, et les
présente dans un rapport Power BI.

L'outil répond à quatre questions : *qu'est-ce qui consomme du temps ?*, *qu'est-ce qui varie ou
se dégrade ?*, *qu'est-ce qui tourne en même temps ?*, *qu'est-ce qui échoue ?*

---

## L'outil ne modifie rien

**Aucune requête ne crée, ne modifie ni ne supprime quoi que ce soit** sur votre serveur —
pas même une vue temporaire. Chaque requête est contrôlée avant d'être envoyée, et le contrôle
refuse le moindre ordre d'écriture.

Ce que l'outil produit vit entièrement sur le poste qui l'exécute, dans des fichiers CSV.

---

## Prérequis

| | |
|---|---|
| **Windows** avec PowerShell 5.1 | livré avec Windows, rien à installer |
| **Un accès en lecture au catalogue SSISDB** | voir [1-COLLECTE.md](docs/1-COLLECTE.md), qui donne la recette des droits minimaux |
| **Power BI Desktop récent** | version **2.157** ou supérieure. Les versions antérieures n'ouvrent pas le rapport |

Le lanceur vérifie tout cela et vous le dit avant de commencer.

---

## Démarrage

**1. Collecter** — double-cliquez sur `Lancer-l-audit.cmd`.

Une fenêtre s'ouvre : indiquez votre instance SQL, choisissez la période, lancez. Les fichiers
sont déposés dans `C:\Audit\SsisRuntimeAudit`, dans un sous-dossier horodaté.

**2. Lire** — ouvrez `powerbi\SsisRuntimeAudit.pbip` dans Power BI Desktop, puis cliquez
**Actualiser**.

Le rapport lit déjà ce dossier. Il n'y a aucun paramètre à régler.

> Si votre poste a plusieurs versions de Power BI Desktop, un double-clic sur le projet peut
> ouvrir la plus ancienne, qui refusera le rapport en affichant une fenêtre vide. Lancez alors
> la version récente, puis *Fichier → Ouvrir*.

---

## Ce que la collecte produit

Onze fichiers CSV par exécution, dans un sous-dossier `Run_AAAAMMJJ-HHMMSSZ` :

| Fichier | Contenu |
|---|---|
| `Executions.csv` | une ligne par exécution de package |
| `Executables.csv` | le détail par tâche à l'intérieur de chaque exécution |
| `Messages.csv` | les erreurs et avertissements |
| `PhasesComposants.csv` | les phases des flux de données — *exige le logging Performance* |
| `StatistiquesFlux.csv` | les lignes transitées par chemin — *exige le logging Verbose* |
| `CatalogContext.csv`, `CatalogObjets.csv`, `Parametres.csv`, `VersionsProjet.csv` | le contexte du catalogue |
| `Run.csv`, `Extractions.csv` | le compte rendu de la collecte |

**`Extractions.csv` mérite un coup d'œil à chaque fois.** Il porte une ligne par extraction
prévue, y compris celles qui n'ont rien produit, avec le motif. Une extraction indisponible et
une extraction sans résultat sont deux constats opposés, et ce fichier les distingue.

---

## Les huit pages du rapport

| Page | La question qu'elle traite |
|---|---|
| Vue d'ensemble | où regarder en premier ? |
| Durées et activité | qu'est-ce qui consomme du temps ? |
| Stabilité et dérive | qu'est-ce qui varie ou se dégrade ? |
| Chronologie | qu'est-ce qui tourne en même temps ? |
| Gantt des exécutions | comment s'enchaînent les exécutions dans la journée ? |
| Stabilité opérationnelle | qu'est-ce qui échoue ou s'interrompt ? |
| Détail d'un package | où part le temps dans ce package ? |
| Qualité et capacités | jusqu'où peut-on faire confiance à cette analyse ? |

**Commencez par la dernière.** Elle dit ce que votre catalogue permet réellement de mesurer —
et ce qu'il ne permet pas. Une page dont les données ne sont pas disponibles l'affiche en
clair, avec son motif, plutôt que de rester vide.

---

## Les trois guides

| | |
|---|---|
| [1-COLLECTE.md](docs/1-COLLECTE.md) | droits nécessaires, niveaux de logging, ce qui peut être refusé et pourquoi |
| [2-ANALYSE.md](docs/2-ANALYSE.md) | ouvrir le rapport, changer de collecte, lire chaque page |
| [3-CAPACITES.md](docs/3-CAPACITES.md) | **ce que chaque extraction autorise à conclure, et ce qu'elle interdit** |

Le troisième est le plus important des trois. Il existe parce qu'une donnée absente ou un
indicateur approximatif produisent très facilement une conclusion plus forte que ce que la
source permet.

---

*Emmanuel Champel*
