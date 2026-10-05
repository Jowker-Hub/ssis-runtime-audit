# SSIS Runtime Audit

Le livrable est distribué en deux archives indépendantes :

| Archive | Machine cible | Point d'entrée |
|---|---|---|
| **Collecte** | machine ayant accès à SSISDB | `Lancer-l-audit.cmd` |
| **Analyse** | poste ou VM équipé de Power BI Desktop | `Ouvrir-l-analyse.cmd` |

Le collecteur produit un dossier `Run_...`. Ce dossier entier est la frontière entre les deux
outils : copiez-le dans `Donnees\` du livrable d'analyse, puis ouvrez le rapport.

Les deux archives sont portables. Elles ne nécessitent ni Git, ni installation, ni droits
administrateur locaux. La collecte SQL reste strictement en lecture seule.

Les guides détaillés vivent dans le dossier `Application\Documentation` de chaque archive.
