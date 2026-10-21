# SSIS Runtime Audit - livraison portable 0.1.4

## Perimetre de cette livraison

La validation de cette version porte sur le **rapport Performances**. Il reprend
la presentation revue et validee page par page, avec la charte dbi et Calibri.

- Synthese des points d'attention et distribution des durees plus lisibles.
- Comparaison des durees habituelles et des pics; distinction entre executions
  du package enfant et executions du parent racine SSISDB.
- Variations intrajournalieres du top 5 des packages: medianes et maximums par
  demi-heure, effectifs affiches, plages adaptees aux observations.
- Top 5 des taches avec temps cumule, moyenne par execution et effectif distincts.
- Horloge de concurrence chiffree et creneaux regroupes par date; adaptation aux
  extractions longues, au-dela de deux jours.
- Les commentaires dependent des donnees et signalent les limites de mesure.

**Rapport Erreurs : conserve sans modification par rapport a 0.1.3. Sa revue
est en attente. Il ne doit pas etre considere comme un livrable valide dans
cette livraison. Choisir Performances pour la validation client actuelle.**

## Demarrage

1. Decompresser entierement `SSIS-Runtime-Audit-v0.1.4.zip` dans un dossier
   accessible en ecriture, distinct de celui de la version precedente.
2. Lancer `SSIS-Runtime-Audit.exe` a la racine du dossier extrait.
3. Utiliser Collecte ou choisir une extraction existante dans Rapports PDF.
4. Selectionner **Performances**, la periode et le dossier de sortie.

Le guide utilisateur PDF est inclus dans `Application/Interface/Aide/`.
Les fichiers collectes ne sont pas inclus; les anciennes versions sont conservees.

## Securite et confidentialite

Windows 11 ou Windows Server 2019+, x64; runtime .NET embarque. Collecte SQL en
lecture seule avec Windows PowerShell 5.1 et les droits SQL adaptes.

**Prototype non signe**, dans l'attente du certificat et des validations de
l'entreprise. Utilisation uniquement lorsque la politique informatique locale
l'autorise. Cette archive n'est ni une homologation ni un moyen de contourner
une restriction de securite.

L'archive ne contient ni donnees client, ni rapports QA, ni projet Power BI,
ni sources C#. Les collectes, journaux et PDF generes peuvent etre confidentiels:
ne pas les ajouter au depot public.

## Integrite

Comparer l'empreinte de l'archive avec `SHA256SUMS.txt`:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\SSIS-Runtime-Audit-v0.1.4.zip
```
