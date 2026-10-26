# SSIS Runtime Audit

## Interface integree : collecte et rapports PDF

[Telecharger l'application portable v0.1.6](https://github.com/Jowker-Hub/ssis-runtime-audit/raw/refs/heads/main/Interface-integree/v0.1.6/SSIS-Runtime-Audit-v0.1.6.zip)

Cette application regroupe la collecte SSISDB et la generation des rapports PDF
Erreurs et Performances. La version 0.1.6 reprend le rapport **Performances** revu
page par page : synthese, durees, variations intrajournalieres, top 5 des taches
et concurrence groupee par date. Elle integre le logo documentaire dbi HD et une
typographie Calibri uniforme. Decompresser toute l'archive puis lancer
`SSIS-Runtime-Audit.exe`.

Cette version complete le diagnostic de l'authentification Windows : le bandeau
affiche le compte qui execute l'interface et un echec de connexion indique le
compte du processus PowerShell ainsi que les codes SQL disponibles. Un journal
local borne conserve aussi le code de sortie et la sortie d'erreur PowerShell,
avec masquage des mots de passe, et son chemin apparait dans l'interface. Elle sert a
identifier precisement les problemes observes avec « Executer en tant qu'autre
utilisateur »; elle ne modifie aucun droit SQL.

**La validation de cette livraison concerne uniquement Performances. Le rapport
Erreurs reste celui de 0.1.3, sans modification ; sa revue est en attente et il
ne doit pas etre considere comme un livrable valide pour le moment.**

- [Instructions et prerequis](Interface-integree/v0.1.6/LISEZ-MOI.md)
- [Empreinte SHA-256](Interface-integree/v0.1.6/SHA256SUMS.txt)
- Windows 11 / Windows Server 2019 ou ulterieur, x64 ; runtime .NET embarque.
- Prototype non signe, en attente du certificat et des validations d'entreprise.
- Aucune donnee client ni aucun rapport QA inclus.

Le depot est public : le telechargement ne necessite pas de compte GitHub.
Les donnees collectees et les rapports produits ensuite peuvent etre confidentiels :
ne jamais les ajouter a ce depot.

Les versions integrees precedentes restent disponibles dans leurs dossiers
`Interface-integree/v0.1.5`, `Interface-integree/v0.1.4`, `Interface-integree/v0.1.3` et
`Interface-integree/v0.1.2`.

## Collecte et analyse Power BI : archives distinctes v0.1.9

Ces archives existantes restent disponibles a la racine. Leur numerotation est
distincte de celle de l'interface integree ci-dessus ; elles ne sont pas remplacees.

Le livrable est distribué en deux archives indépendantes :

| Archive | Usage | Point d'entrée |
|---|---|---|
| **SSIS Runtime Audit** | collecte SSISDB et génération des rapports PDF | `SSIS-Runtime-Audit.exe` |
| **Analyse** | exploration complémentaire dans Power BI Desktop | `Ouvrir-l-analyse.cmd` |

L'application intégrée permet de choisir le dossier de collecte, de suivre l'avancement des
extractions et de générer les rapports PDF Performance et Erreurs. Les données restent traitées
localement et la connexion SQL est strictement en lecture seule.

Le package est publié en mode **Prototype non signé** dans l'attente du certificat de signature
dbi services. Il cible Windows 11 et Windows Server 2019 ou plus récent.

L'archive d'analyse Power BI reste facultative et indépendante de l'application intégrée.
