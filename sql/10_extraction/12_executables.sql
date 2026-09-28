/* =============================================================================
   12_executables.sql
   Extraction fondamentale. Une ligne par exécutable et par exécution,
   itérations de boucle comprises.

   CE DONT CETTE REQUÊTE A BESOIN
     Source     : `catalog.executable_statistics`, `catalog.executables`
     Logging    : Basic
     Droits     : voir 01_diagnostic.sql, domaine « Droits ». Un compte sans droit
                  recoit zero ligne, pas un refus. Lecture seule stricte.
     Famille    : 7
     Sortie     : Executables.csv

   PARAMÈTRES ATTENDUS, NON DÉCLARÉS ICI — voir l'en-tête de 11_executions.sql

       DECLARE @DebutFenetre datetimeoffset(7) = NULL;
       DECLARE @FinFenetre   datetimeoffset(7) = NULL;

     La fenêtre porte sur l'heure de début de l'EXÉCUTION, pas de l'exécutable :
     toutes les tables de faits dynamiques doivent couvrir exactement le même
     ensemble d'exécutions, sans quoi les jointures en aval ont des trous.

   VOLUMÉTRIE
     Mesuré : 11,1 lignes par exécution en moyenne, 13,0 sur le package le plus
     imbriqué. **C'est le grain qui explose en premier** : une tâche dans une
     boucle de 500 tours produit 500 lignes à elle seule. Le bornage se fait par
     refus explicite du runner, jamais par troncature ni Top N.

   LA NORMALISATION DU CHEMIN, RAISON D'ÊTRE DE CETTE REQUÊTE
     Mesuré : 310 lignes sur 409, soit 76 %, portent un indice d'itération.
     Agréger sur le chemin brut est donc faux aux trois quarts, et non à la
     marge. Le chemin logique est produit ici, une fois, plutôt que dans chaque
     analyse en aval.
   ============================================================================= */

SET NOCOUNT ON;

WITH
retenues AS (
    SELECT e.execution_id, e.folder_name, e.project_name
    FROM SSISDB.[catalog].executions AS e
    WHERE e.start_time IS NOT NULL
      AND (@DebutFenetre IS NULL OR e.start_time >= @DebutFenetre)
      AND (@FinFenetre   IS NULL OR e.start_time <  @FinFenetre)   /* borne haute EXCLUSIVE : avec <=, deux fenetres adjacentes extraient deux fois le run pose exactement dessus */
),
stats AS (
    SELECT s.statistics_id, s.execution_id, s.executable_id, s.execution_path,
           s.start_time, s.end_time, s.execution_duration, s.execution_result,
           s.execution_value,
           /* Triplet obligatoire sur toute ligne identifiant un package, matrice
              3.2. ExecutionId permettrait une jointure indirecte, mais un CSV
              doit se lire seul et le rapprochement de D020 ne doit pas exiger
              le chargement d'Executions.csv. */
           r.folder_name, r.project_name
    FROM SSISDB.[catalog].executable_statistics AS s
    JOIN retenues AS r ON r.execution_id = s.execution_id
),

/* ---------------------------------------------------------------------------
   Retrait des indices d'itération, par récursion.

   L'indice est porté entre crochets sur le segment du conteneur :
   `\Package\Conteneur de boucles For[3]\Data Flow Task`. Des boucles imbriquées
   en produisent plusieurs sur un même chemin, d'où la récursion.

   **On ne retire QUE des crochets dont le contenu est entièrement numérique.**
   Un nom d'objet SSIS peut légitimement contenir un crochet ; le retirer
   corromprait le chemin. Quand un crochet non numérique est rencontré, la
   récursion s'arrête et la ligne est signalée par NormalisationComplete à
   False, plutôt que de produire un chemin faux en silence.
   --------------------------------------------------------------------------- */
nettoyage AS (
    SELECT statistics_id,
           CAST(execution_path AS nvarchar(4000)) AS chemin,
           0 AS niveaux
    FROM stats

    UNION ALL

    SELECT n.statistics_id,
           CAST(STUFF(n.chemin,
                      CHARINDEX(N'[', n.chemin),
                      CHARINDEX(N']', n.chemin, CHARINDEX(N'[', n.chemin)) - CHARINDEX(N'[', n.chemin) + 1,
                      N'') AS nvarchar(4000)),
           n.niveaux + 1
    FROM nettoyage AS n
    WHERE CHARINDEX(N'[', n.chemin) > 0
      AND CHARINDEX(N']', n.chemin, CHARINDEX(N'[', n.chemin)) > CHARINDEX(N'[', n.chemin)
      AND SUBSTRING(n.chemin,
                    CHARINDEX(N'[', n.chemin) + 1,
                    CHARINDEX(N']', n.chemin, CHARINDEX(N'[', n.chemin)) - CHARINDEX(N'[', n.chemin) - 1)
          NOT LIKE N'%[^0-9]%'
),
chemins AS (
    /* La dernière ligne de chaque récursion, donc celle où plus rien de
       numérique ne reste à retirer. */
    SELECT statistics_id, chemin, niveaux
    FROM (
        SELECT statistics_id, chemin, niveaux,
               ROW_NUMBER() OVER (PARTITION BY statistics_id ORDER BY niveaux DESC) AS rang
        FROM nettoyage
    ) AS x
    WHERE rang = 1
)
SELECT
    /* --- rattachement -------------------------------------------------------- */
    s.execution_id                                              AS ExecutionId,
    s.statistics_id                                             AS StatistiqueId,
    s.folder_name                                               AS Dossier,
    s.project_name                                              AS Projet,
    s.executable_id                                             AS ExecutableId,
    /* Clé de rapprochement avec l'audit statique au grain de la tâche, D020. */
    ISNULL(CONVERT(nvarchar(50), x.executable_guid), N'')       AS ExecutableGuid,
    ISNULL(x.executable_name, N'')                              AS Executable,
    ISNULL(x.package_name, N'')                                 AS Package,
    ISNULL(x.package_path, N'')                                 AS CheminPackage,

    /* --- chemins ------------------------------------------------------------- */
    s.execution_path                                            AS CheminExecution,
    c.chemin                                                    AS CheminLogique,
    c.niveaux                                                   AS NiveauxIteration,
    CASE WHEN CHARINDEX(N'[', c.chemin) > 0 THEN N'False' ELSE N'True' END
                                                                AS NormalisationComplete,

    /* Contrôle croisé gratuit. `package_path` est le chemin de CONCEPTION, déjà
       dépourvu d'indices — mesuré, aucun crochet sur 409 lignes. Le chemin
       logique calculé ici vient du chemin d'EXÉCUTION, qui porte en plus la
       chaîne des parents.

       Les deux coïncident tant qu'aucun package enfant n'est appelé par un
       Execute Package Task dans la même instance d'exécution. Le corpus de
       référence n'en contenait aucun : cette colonne est là pour que la
       divergence se voie le jour où elle se produit, au lieu d'être découverte
       par un chiffre faux. */
    CASE WHEN c.chemin = x.package_path THEN N'True' ELSE N'False' END
                                                                AS CheminsConcordants,
    /* Profondeur dans l'arbre : le nombre d'antislashs du chemin logique. Le
       package racine est à 1. Indispensable pour ne PAS sommer un conteneur
       avec ses enfants. */
    LEN(c.chemin) - LEN(REPLACE(c.chemin, N'\', N''))           AS Profondeur,
    CASE WHEN LEN(c.chemin) - LEN(REPLACE(c.chemin, N'\', N'')) = 1
         THEN N'True' ELSE N'False' END                         AS EstRacine,

    /* --- temps ---------------------------------------------------------------- */
    CONVERT(varchar(40), s.start_time, 127)                     AS HeureDebut,
    ISNULL(CONVERT(varchar(40), s.end_time, 127), N'')          AS HeureFin,
    DATEPART(TZOFFSET, s.start_time)                            AS DecalageUtcMinutes,
    s.execution_duration                                        AS DureeMillisecondes,
    s.execution_result                                          AS ResultatCode,
    CASE s.execution_result
        WHEN 0 THEN N'Reussi'   WHEN 1 THEN N'Echec'
        WHEN 2 THEN N'Termine'  WHEN 3 THEN N'Annule'
        ELSE N'Inconnu' END                                     AS Resultat,

    /* --- valeur de retour, métadonnées seulement ----------------------------- */
    /* La valeur elle-même ne sort JAMAIS : c'est un sql_variant défini par
       l'utilisateur, un nombre n'y prouve aucun nombre de lignes et une chaîne
       peut contenir n'importe quelle donnée métier. Seules sa présence et son
       type de base sortent. Si une mission connaît la convention d'un package,
       la valeur relèvera d'un enrichissement local documenté, hors du socle. */
    CASE WHEN s.execution_value IS NULL THEN N'False' ELSE N'True' END
                                                                AS ValeurRetourPresente,
    ISNULL(CAST(SQL_VARIANT_PROPERTY(s.execution_value, 'BaseType') AS nvarchar(30)), N'')
                                                                AS ValeurRetourTypeBase

FROM stats AS s
JOIN chemins AS c ON c.statistics_id = s.statistics_id
LEFT JOIN SSISDB.[catalog].executables AS x
       ON x.execution_id = s.execution_id AND x.executable_id = s.executable_id
ORDER BY s.execution_id, s.statistics_id
OPTION (MAXRECURSION 32);   /* 32 niveaux de boucles imbriquees : large */
