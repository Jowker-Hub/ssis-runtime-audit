# SSIS Runtime Audit - livraison portable 0.1.5

## Perimetre de cette livraison

Cette version est destinee au diagnostic du lancement avec **Executer en tant
qu'autre utilisateur**.

- Le bandeau affiche le compte Windows qui execute effectivement l'interface.
- En cas d'echec, le test de connexion affiche aussi le compte effectif du
  processus Windows PowerShell enfant.
- Les codes techniques SQL numero, classe et etat sont affiches lorsqu'ils sont
  disponibles, sans restituer le message fournisseur, la chaine de connexion
  ni un secret.
- Aucun droit SQL n'est cree ou modifie; la connexion reste en lecture seule.

La version reprend sans modification fonctionnelle les rapports PDF de 0.1.4.
La validation de cette livraison concerne toujours uniquement Performances.
Le rapport Erreurs reste en attente de revue et ne doit pas etre considere
comme valide.

## Test demande

1. Decompresser entierement `SSIS-Runtime-Audit-v0.1.5.zip` dans un nouveau
   dossier accessible en ecriture.
2. Lancer `SSIS-Runtime-Audit.exe` avec **Executer en tant qu'autre utilisateur**.
3. Verifier le compte affiche dans le bandeau.
4. Ouvrir Collecte, saisir la meme instance que dans SSMS et cliquer sur
   `Tester la connexion`.
5. Conserver une capture du resultat, y compris le compte PowerShell et les
   codes SQL eventuels.

Le guide utilisateur PDF est inclus dans `Application/Interface/Aide/`.

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
Get-FileHash -Algorithm SHA256 -LiteralPath .\SSIS-Runtime-Audit-v0.1.5.zip
```
