/* =============================================================================
   18_statistiques_flux.sql
   Extraction CONDITIONNELLE. Exige le niveau de logging **Verbose**.

   CE DONT CETTE REQUÊTE A BESOIN
     Source     : `catalog.execution_data_statistics`
     Logging    : **Verbose**, le plus coûteux du catalogue
     Droits     : voir 01_diagnostic.sql, domaine « Droits ». Un compte sans droit
                  recoit zero ligne, pas un refus. Lecture seule stricte.
     Famille    : 10
     Sortie     : StatistiquesFlux.csv

   PARAMÈTRES ATTENDUS, NON DÉCLARÉS ICI — voir l'en-tête de 11_executions.sql

   SI LA SOURCE EST VIDE
     Extraction déclarée indisponible dans `Extractions.csv`, pas de fichier
     d'en-têtes. Voir 17_phases_composants.sql.

   VOLUMÉTRIE
     Mesuré sur trois exécutions en Verbose du même package : 66 lignes, soit 22
     par exécution, c'est-à-dire **deux lignes par instance de flux de données**.
     Un flux émet ses lignes par tampons et le dernier peut être vide : sur une
     itération mesurée, le même chemin apparaît à 101 puis à 0.

     Conséquence : sommer `rows_sent` **par chemin** est correct. C'est sommer
     entre chemins qui ne l'est pas, voir le piège plus bas.

   LE CHEMIN PORTE LES INDICES D'ITÉRATION, ET N'EST PAS NORMALISÉ ICI
     Même situation qu'en 17_phases_composants.sql : la couche d'analyse joint
     `Executables.csv` sur (`ExecutionId`, `CheminExecution`) pour obtenir le
     chemin logique, plutôt que de maintenir une copie de plus de la règle.

   COÛT, À DIRE AVANT DE LE DEMANDER
     Verbose est le niveau le plus coûteux du catalogue, en volume comme en
     surcharge d'exécution. Le runner ne l'active jamais : l'élévation du logging
     est une recommandation écrite au client, jamais un geste de l'outil. Elle se
     demande sur un périmètre réduit et une fenêtre bornée, avec retour à la
     configuration initiale.

   LE PIÈGE
     **Les `rows_sent` de plusieurs branches ou sorties ne se somment pas en un
     volume métier.** Un flux qui duplique ou multidiffuse compte plusieurs fois
     les mêmes lignes. Le total d'un package n'est donc pas la somme de ses
     chemins, et cette requête ne fournit aucun total.

   CONCLUSION AUTORISÉE
     Débit observé sur un chemin donné, c'est-à-dire des lignes par seconde entre
     deux composants nommés. C'est la seule source de volume du catalogue, et la
     seule référence qui permette de rapporter une durée à une quantité de
     travail.

   MINIMISATION
     Les noms de composants et de chemins sont des **libellés de conception**,
     pas de la donnée client : ils sont conservés, comme tout libellé d'objet.
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
    d.data_stats_id                                             AS StatistiqueFluxId,
    d.execution_id                                              AS ExecutionId,

    /* Triplet obligatoire, matrice 3.2. */
    r.folder_name                                               AS Dossier,
    r.project_name                                              AS Projet,

    ISNULL(d.package_name, N'')                                 AS Package,
    ISNULL(d.task_name, N'')                                    AS Tache,
    ISNULL(d.execution_path, N'')                               AS CheminExecution,

    /* Identité du chemin de flux : l'identifiant technique et le libellé, tous
       deux posés à la conception. */
    ISNULL(d.dataflow_path_id_string, N'')                      AS CheminFluxId,
    ISNULL(d.dataflow_path_name, N'')                           AS CheminFlux,
    ISNULL(d.source_component_name, N'')                        AS ComposantSource,
    ISNULL(d.destination_component_name, N'')                   AS ComposantDestination,

    /* Volume par chemin, JAMAIS sommable en volume de package : voir le piège. */
    d.rows_sent                                                 AS LignesTransmises,

    CONVERT(varchar(40), d.created_time, 127)                   AS HeureMesure,
    DATEPART(TZOFFSET, d.created_time)                          AS DecalageUtcMinutes

FROM SSISDB.[catalog].execution_data_statistics AS d
JOIN retenues AS r ON r.execution_id = d.execution_id
ORDER BY d.execution_id, d.execution_path, d.data_stats_id;
