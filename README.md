# SSIS Runtime Audit

## Interface integree : collecte et rapports PDF

[Telecharger l'application portable v0.1.4](https://github.com/Jowker-Hub/ssis-runtime-audit/raw/refs/heads/main/Interface-integree/v0.1.4/SSIS-Runtime-Audit-v0.1.4.zip)

Cette application regroupe la collecte SSISDB et la generation des rapports PDF
Erreurs et Performances. La version 0.1.4 livre le rapport **Performances** revu
page par page : synthese, durees, variations intrajournalieres, top 5 des taches
et concurrence groupee par date. Elle integre le logo documentaire dbi HD et une
typographie Calibri uniforme. Decompresser toute l'archive puis lancer
`SSIS-Runtime-Audit.exe`.

**La validation de cette livraison concerne uniquement Performances. Le rapport
Erreurs reste celui de 0.1.3, sans modification ; sa revue est en attente et il
ne doit pas etre considere comme un livrable valide pour le moment.**

- [Instructions et prerequis](Interface-integree/v0.1.4/LISEZ-MOI.md)
- [Empreinte SHA-256](Interface-integree/v0.1.4/SHA256SUMS.txt)
- Windows 11 / Windows Server 2019 ou ulterieur, x64 ; runtime .NET embarque.
- Prototype non signe, en attente du certificat et des validations d'entreprise.
- Aucune donnee client ni aucun rapport QA inclus.

Le depot est public : le telechargement ne necessite pas de compte GitHub.
Les donnees collectees et les rapports produits ensuite peuvent etre confidentiels :
ne jamais les ajouter a ce depot.

Les versions integrees precedentes restent disponibles dans leurs dossiers
`Interface-integree/v0.1.3` et `Interface-integree/v0.1.2`.

## Collecte et analyse Power BI : archives distinctes v0.1.9

Ces archives existantes restent disponibles a la racine. Leur numerotation est
distincte de celle de l'interface integree ci-dessus ; elles ne sont pas remplacees.

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
