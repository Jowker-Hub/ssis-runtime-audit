/* =============================================================================
   17_phases_composants.sql
   Extraction CONDITIONNELLE. Exige le niveau de logging **Performance**.

   CE DONT CETTE REQUÊTE A BESOIN
     Source     : `catalog.execution_component_phases`
     Logging    : **Performance** au minimum
     Droits     : voir 01_diagnostic.sql, domaine « Droits ». Un compte sans droit
                  recoit zero ligne, pas un refus. Lecture seule stricte.
     Famille    : 10
     Sortie     : PhasesComposants.csv

   PARAMÈTRES ATTENDUS, NON DÉCLARÉS ICI — voir l'en-tête de 11_executions.sql

   SI LA SOURCE EST VIDE
     Le runner ne produit **pas** un fichier d'en-têtes : il déclare l'extraction
     indisponible dans `Extractions.csv` avec son motif. Un fichier vide
     ressemblerait à une extraction réussie sans résultat, ce qui est un tout
     autre constat.

   VOLUMÉTRIE — LA PLUS FORTE DE TOUTES LES EXTRACTIONS
     Mesuré sur six exécutions d'un package trivial à boucle de dix tours :
     **1 458 lignes, soit 243 par exécution**. C'est vingt-deux fois le grain des
     exécutables et deux cent quarante-trois fois celui des exécutions.

     Le dénominateur est bien six, et non les trois exécutions lancées en
     Performance : les trois lancées en Verbose produisent aussi des phases,
     Verbose étant au-dessus de Performance. Diviser par trois donnait 486, un
     facteur deux fois trop fort qui aurait fait refuser des extractions
     parfaitement réalisables.

     Cette extraction est donc la première à devoir être refusée par le bornage
     de volume du runner. Une fenêtre large en Performance produit un fichier
     ingérable, et c'est normal : Performance est un niveau de diagnostic, pas un
     niveau d'exploitation.

   LE CHEMIN PORTE LES INDICES D'ITÉRATION, ET N'EST PAS NORMALISÉ ICI
     Mesuré : `\Package\Conteneur de boucles For[1]\Data Flow Task`. Agréger sur
     `CheminExecution` séparerait donc chaque itération.

     La normalisation n'est **pas** refaite ici. `Executables.csv` porte déjà, pour
     le même couple (`ExecutionId`, `CheminExecution`), la forme brute et la forme
     logique. La couche d'analyse joint sur ces deux colonnes et récupère le
     chemin logique sans qu'une quatrième copie de la règle ait à être maintenue.

   LE PIÈGE, ET IL EST GRAVE
     **Les phases sont CONCOURANTES et ne se somment pas.** L'amorçage de sortie
     d'un composant et le traitement d'entrée du suivant se recouvrent : leur
     somme dépasse la durée réelle du flux. Toute analyse doit raisonner en
     INTERVALLES, jamais en cumul de durées.

     C'est pourquoi cette requête ne calcule aucune durée agrégée et se contente
     de porter les bornes. La tentation de sommer se traite en ne fournissant pas
     de colonne à sommer.

   CONCLUSION AUTORISÉE, ET SA LIMITE
     Localisation du temps actif dans un flux de données. La phase d'amorçage de
     sortie d'un composant source est un **proxy** du temps d'attente de la
     source, et s'annonce comme tel. **Aucun débit** n'est calculable ici : sans
     volumes, ces phases n'en mesurent pas.
   ============================================================================= */

SET NOCOUNT ON;

WITH retenues AS (
    SELECT e.execution_id, e.folder_name, e.project_name
    FROM SSISDB.[catalog].executions AS e
    WHERE e.start_time IS NOT NULL
      AND (@DebutFenetre IS NULL OR e.start_time >= @DebutFenetre)
      AND (@FinFenetre   IS NULL OR e.start_time <  @FinFenetre)   /* borne haute EXCLUSIVE : avec <=, deux fenetres adjacentes extraient deux fois le run pose exactement dessus */
)
SELECT
    p.phase_stats_id                                            AS PhaseId,
    p.execution_id                                              AS ExecutionId,

    /* Triplet obligatoire sur toute ligne identifiant un package, matrice 3.2.
       ExecutionId permettrait une jointure indirecte, mais un CSV doit se lire
       seul et le rapprochement de D020 ne doit pas exiger Executions.csv. */
    r.folder_name                                               AS Dossier,
    r.project_name                                              AS Projet,

    ISNULL(p.package_name, N'')                                 AS Package,
    ISNULL(p.task_name, N'')                                    AS Tache,
    ISNULL(p.subcomponent_name, N'')                            AS SousComposant,
    ISNULL(p.phase, N'')                                        AS Phase,
    ISNULL(p.execution_path, N'')                               AS CheminExecution,

    /* Bornes seulement. Aucune colonne de durée : voir le piège en en-tête.
       Le calcul d'un temps actif se fait par union d'intervalles dans la couche
       d'analyse, pas par somme. */
    CONVERT(varchar(40), p.start_time, 127)                     AS HeureDebut,
    ISNULL(CONVERT(varchar(40), p.end_time, 127), N'')          AS HeureFin,
    DATEPART(TZOFFSET, p.start_time)                            AS DecalageUtcMinutes

FROM SSISDB.[catalog].execution_component_phases AS p
JOIN retenues AS r ON r.execution_id = p.execution_id
ORDER BY p.execution_id, p.execution_path, p.start_time, p.phase_stats_id;
