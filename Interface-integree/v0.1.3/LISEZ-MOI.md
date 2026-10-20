# SSIS Runtime Audit — livraison portable 0.1.3

Application Windows x64 : collecte SSISDB et generation des rapports PDF Erreurs et Performances, avec interface modulaire et identite graphique dbi services.

## Nouveautes de la version 0.1.3

- Logo documentaire dbi HD integre aux couvertures et pieds de page des deux rapports.
- Typographie uniformisee sur Calibri et Calibri gras, titres et graphiques compris.
- Pagination QA conservee : 11 pages pour les erreurs et 9 pour les performances.
- Les extractions de duree variable et les jours sans observations restent pris en compte.

## Demarrage

1. Decompresser entierement `SSIS-Runtime-Audit-v0.1.3.zip` dans un dossier accessible en ecriture.
2. Lancer `SSIS-Runtime-Audit.exe` a la racine du dossier extrait.
3. Utiliser la page Collecte, ou choisir un dossier existant depuis Rapports PDF.
4. Choisir Erreurs, Performances ou les deux, puis le dossier de sortie et lancer la generation.

Le guide utilisateur PDF est inclus dans `Application/Interface/Aide/`.

## Contenu et confidentialite

- Executable a la racine ; modules dans `Application/Collecte` et `Application/Rapports`.
- Configuration JSON, ressources et aide dans `Application/Interface`.
- Dossiers `Collectes`, `Rapports-generes` et `Journaux` initialement vides.

Cette archive ne contient ni donnees client, ni rapports QA, ni projet Power BI, ni sources C#.
La collecte SQL est en lecture seule. Les collectes, journaux et PDF produits ensuite peuvent contenir des informations confidentielles et ne doivent pas etre publies.

## Statut et prerequis

Cibles : Windows 11 et Windows Server 2019 ou ulterieur, x64. La collecte utilise Windows PowerShell 5.1 et necessite les droits SQL adequats sur SSISDB. Le runtime .NET de l'application est embarque.

Livraison **Prototype non signee** : certificat d'entreprise et validation de securite/manager toujours en attente. La presence de cette archive n'atteste pas une homologation de production.

## Integrite

Comparer le resultat de cette commande avec `SHA256SUMS.txt` avant utilisation :

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\SSIS-Runtime-Audit-v0.1.3.zip
```

Les archives Collecte et Analyse Power BI v0.1.9 restent disponibles a la racine du depot ; leur numerotation est distincte de celle de cette interface integree.
