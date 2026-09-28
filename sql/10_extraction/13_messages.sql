/* =============================================================================
   13_messages.sql
   Extraction fondamentale. Métadonnées des messages d'erreur et d'alerte.
   **Le texte des messages ne sort jamais.**

   CE DONT CETTE REQUÊTE A BESOIN
     Source     : `catalog.event_messages`
     Logging    : Basic
     Droits     : voir 01_diagnostic.sql, domaine « Droits ». Un compte sans droit
                  recoit zero ligne, pas un refus. Lecture seule stricte.
     Famille    : 6
     Sortie     : Messages.csv

   PARAMÈTRES ATTENDUS, NON DÉCLARÉS ICI — voir l'en-tête de 11_executions.sql

       DECLARE @DebutFenetre datetimeoffset(7) = NULL;
       DECLARE @FinFenetre   datetimeoffset(7) = NULL;

   LE FILTRE EST VERSIONNÉ ICI, PAS EXPOSÉ EN PARAMÈTRE
     Quatre types retenus : 100 annulation de requête, 110 avertissement,
     120 erreur, 130 échec de tâche. Le changer changerait le SENS du fichier et
     rendrait deux missions incomparables — c'est pourquoi il n'est pas offert au
     réglage.

     Seuls 110 et 120 ont été observés sur le catalogue de référence ; 100 et 130
     sont documentés et retenus sans attendre de les voir.

   POURQUOI CE FILTRE CHANGE TOUT
     Mesuré : 136 messages par exécution au grain brut, **0,8 après filtrage**.
     Un facteur 167, qui fait passer la table la plus volumineuse du catalogue au
     rang de la plus légère des quatre. `OnInformation` pèse à lui seul 65 % du
     volume brut.

     Ce 0,8 est un **plancher**, mesuré sur un parc presque sain. Un parc qui
     plante beaucoup le fera monter. C'est au pré-vol de le mesurer, et au runner
     de refuser explicitement si la limite est dépassée — jamais de retirer un
     type de message pour faire rentrer le fichier.
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
messages AS (
    /* `operation_id` vaut l'`execution_id` pour une exécution de package. La
       jointure sur `retenues` écarte au passage les opérations qui ne sont pas
       des exécutions — déploiements, validations, maintenance. */
    SELECT m.event_message_id, m.operation_id, m.message_time, m.message_type,
           m.message_source_type, m.package_name, m.event_name,
           m.message_source_name, m.message_source_id, m.subcomponent_name,
           m.package_path, m.execution_path, m.message_code,
           /* Triplet obligatoire, matrice 3.2 : un CSV doit se lire seul. */
           r.folder_name, r.project_name
    FROM SSISDB.[catalog].event_messages AS m
    JOIN retenues AS r ON r.execution_id = m.operation_id
    WHERE m.message_type IN (100, 110, 120, 130)
),

/* Même règle de normalisation qu'en 12_executables.sql. La règle est énoncée
   une seule fois, en 3.3 de `MATRICE-CAPACITES.md` ; les deux extractions
   l'implémentent parce qu'elles sont à des grains différents. Toute évolution
   de la règle doit être reportée dans les deux.

   Mesuré : aucun message du corpus de référence ne portait d'indice, la boucle
   ayant tourné sans erreur. Une erreur SURVENANT dans une boucle en porterait
   un, et l'attribuer à la mauvaise tâche fausserait le comptage par tâche. */
nettoyage AS (
    SELECT event_message_id,
           CAST(execution_path AS nvarchar(4000)) AS chemin,
           0 AS niveaux
    FROM messages

    UNION ALL

    SELECT n.event_message_id,
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
    SELECT event_message_id, chemin, niveaux
    FROM (
        SELECT event_message_id, chemin, niveaux,
               ROW_NUMBER() OVER (PARTITION BY event_message_id ORDER BY niveaux DESC) AS rang
        FROM nettoyage
    ) AS x
    WHERE rang = 1
)
SELECT
    m.event_message_id                                          AS MessageId,
    m.operation_id                                              AS ExecutionId,
    m.folder_name                                               AS Dossier,
    m.project_name                                              AS Projet,

    /* --- nature -------------------------------------------------------------- */
    m.message_type                                              AS TypeCode,
    CASE m.message_type
        WHEN 100 THEN N'AnnulationRequete'
        WHEN 110 THEN N'Avertissement'
        WHEN 120 THEN N'Erreur'
        WHEN 130 THEN N'EchecTache'
        ELSE N'Inconnu' END                                     AS Type,
    m.message_source_type                                       AS SourceTypeCode,
    m.message_code                                              AS CodeMessage,   /* NULL conserve : 0 peut etre une vraie valeur */
    ISNULL(m.event_name, N'')                                   AS Evenement,

    /* --- localisation -------------------------------------------------------- */
    ISNULL(m.package_name, N'')                                 AS Package,
    ISNULL(m.message_source_name, N'')                          AS Source,
    ISNULL(m.subcomponent_name, N'')                            AS SousComposant,
    ISNULL(m.package_path, N'')                                 AS CheminPackage,
    ISNULL(m.execution_path, N'')                               AS CheminExecution,
    ISNULL(c.chemin, N'')                                       AS CheminLogique,
    ISNULL(c.niveaux, 0)                                        AS NiveauxIteration,

    /* --- temps ---------------------------------------------------------------- */
    CONVERT(varchar(40), m.message_time, 127)                   AS HeureMessage,
    DATEPART(TZOFFSET, m.message_time)                          AS DecalageUtcMinutes

    /* Aucune colonne de texte. `event_messages.message` transporte couramment
       chemins réseau, chaînes de connexion et ordres SQL complets : c'est la
       règle 3.1 de la matrice, et elle ne souffre pas d'exception. Le débogage
       détaillé passe par les rapports d'exécution natifs de SSMS.

       `message_source_id` n'est pas extrait non plus : c'est un GUID de
       composant sans valeur d'analyse tant qu'on ne dispose pas des sources. */

FROM messages AS m
LEFT JOIN chemins AS c ON c.event_message_id = m.event_message_id
ORDER BY m.operation_id, m.message_time, m.event_message_id
OPTION (MAXRECURSION 32);
