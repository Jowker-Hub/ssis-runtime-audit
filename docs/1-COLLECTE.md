# 1. La collecte

Comment extraire les faits d'exécution de votre catalogue SSISDB.

---

## Ce dont vous avez besoin

Un compte capable de **lire** le catalogue SSISDB. Rien de plus : l'outil n'écrit jamais.

Deux modes d'authentification sont proposés dans la fenêtre — Windows, ou SQL Server avec
identifiant et mot de passe. En mode SQL, le mot de passe n'entre jamais dans la chaîne de
connexion ; il est transmis séparément au pilote.

### Le droit juste, et pourquoi il demande une manipulation

Les vues du catalogue SSISDB sont filtrées par permissions. **Un compte sans droit suffisant ne
reçoit pas un refus : il reçoit zéro ligne.** Un catalogue parfaitement calme et un compte mal
habilité se ressemblent trait pour trait — c'est le piège principal de cet exercice, et c'est
pourquoi la première chose que l'outil relève, ce sont les droits.

SQL Server prévoit un rôle exactement taillé pour ce besoin, `ssis_logreader` : il ouvre tout
l'historique d'exécution sans donner la moindre administration. **Mais SQL Server ne le crée
pas.** La vue `catalog.executions` le cite dans sa clause de filtrage, et il n'existe nulle
part tant que personne ne l'a créé.

La recette minimale, à exécuter une fois par un administrateur :

```sql
USE SSISDB;

-- Le role, que SQL Server ne cree pas de lui-meme
CREATE ROLE ssis_logreader;

-- Le compte qui fera la collecte
CREATE USER [DOMAINE\compte_audit] FOR LOGIN [DOMAINE\compte_audit];
ALTER ROLE ssis_logreader ADD MEMBER [DOMAINE\compte_audit];

-- La lecture sur chaque projet dont on veut voir les executions
GRANT READ ON OBJECT::[catalog].[projects] TO ssis_logreader;
```

Le dernier point compte : **un `GRANT READ` manquant sur un projet rend ses exécutions
invisibles**, silencieusement. Si l'outil vous rapporte des packages visibles mais aucun
paramètre ni aucune version, c'est le symptôme — pas un catalogue vide.

### À défaut

`sysadmin` ou `ssis_admin` fonctionnent, évidemment. L'outil vous préviendra : la collecte
reste en lecture seule, mais la garantie repose alors sur la discipline de l'outil et non sur
les permissions du serveur. Cette mention est inscrite dans `Run.csv`, pour que le lecteur du
rapport le sache.

---

## Le niveau de logging décide de ce qui est mesurable

SSIS enregistre plus ou moins de détail selon le niveau demandé **à chaque exécution**. Ce
n'est pas un réglage global du serveur : deux exécutions du même package, le même jour, peuvent
avoir des niveaux différents.

| Niveau | Ce que la collecte peut en tirer |
|---|---|
| **Aucun** | rien |
| **Basic** | les exécutions, le détail par tâche, les erreurs et avertissements |
| **Performance** | en plus : les phases des composants de flux de données |
| **Verbose** | en plus : le nombre de lignes transitées par chemin de flux |

**Le niveau est un plancher, pas une égalité.** Une exécution lancée en Verbose produit tout ce
que Performance produit.

La majorité des parcs tournent en **Basic**, et c'est très bien : les trois extractions
fondamentales suffisent à répondre aux questions de temps. Les deux extractions conditionnelles
sont un supplément de diagnostic, pas une condition.

Si une extraction n'est pas disponible, elle est déclarée telle dans `Extractions.csv` avec son
motif, et la page correspondante du rapport l'affiche en clair. **Elle ne produit pas un fichier
vide** : un fichier réduit à ses en-têtes ressemblerait à une extraction réussie sans résultat.

> Monter le niveau de logging est une **recommandation**, jamais une action de l'outil. C'est
> une modification de votre configuration, elle vous appartient. Sachez seulement que Verbose
> est coûteux et ne se laisse pas en permanence.

---

## Lancer la collecte

**Par la fenêtre** — double-cliquez sur `Lancer-l-audit.cmd`.

Les prérequis sont contrôlés, puis la fenêtre s'ouvre. Vous y renseignez l'instance, le mode
d'authentification, la période d'analyse, et vous cochez les extractions. Les neuf sont
proposées cochées ; celles que votre niveau de logging ne permet pas sont grisées.

**En ligne de commande** — pour rejouer une collecte sans clic :

```powershell
Import-Module .\SsisRuntimeAudit.psd1
Invoke-SsisRuntimeAudit -Serveur 'SRV-ETL-01' -Tout -Jours 30 -SansFenetre
```

**Par l'Agent SQL** — utilisez `Invoke-AuditPlanifie.ps1`, qui rend un code de sortie non nul
si la collecte est incomplète. Un pas de travail de l'Agent ne lit ni la console ni les
messages : il lit le code de sortie, et la fonction du module rend toujours zéro.

```powershell
& "D:\Outils\ssis-runtime-audit\Invoke-AuditPlanifie.ps1" `
      -Serveur 'SRV-ETL-01' -Sortie 'D:\Audit' -Jours 30 -Tout
```

---

## Ce qui peut être refusé, et pourquoi c'est voulu

Avant d'extraire, l'outil **estime le volume** de chaque extraction à partir du nombre
d'exécutions de la période. Au-delà de deux millions de lignes, il refuse — et il le dit avec
le motif.

Il ne tronque **jamais**. Ni les premières lignes, ni les dernières, ni les N packages les plus
lents : un échantillon ainsi biaisé serait indiscernable d'une vraie distribution, donc pire
qu'une extraction refusée.

La parade est simple : **réduisez la période**. Les phases de composants valent à elles seules
environ 243 lignes par exécution — quarante fois le détail par tâche. Une fenêtre de trente
jours sur un parc chargé les fait exploser bien avant les autres.

---

## Si la collecte se passe mal

| Ce que vous voyez | Ce que ça signifie |
|---|---|
| Zéro exécution, alors que le parc tourne | droits insuffisants. Voir la recette plus haut |
| Des packages visibles, mais aucun paramètre ni version | un `GRANT READ` manque sur les projets |
| « Collecte incomplète » | une ou plusieurs extractions n'ont pas abouti. `Extractions.csv` dit laquelle et pourquoi |
| Une extraction « Indisponible » | le niveau de logging de la période ne la permet pas |
| Une extraction « VolumeExceedsLimit » | réduisez la période |

Dans tous les cas, `Extractions.csv` du dossier de collecte porte une ligne par extraction
prévue, avec son statut et son motif. **C'est le premier fichier à ouvrir.**

---

Suite : [2-ANALYSE.md](2-ANALYSE.md)
