/* =============================================================================
   16_versions.sql
   Extraction automatique.
   **Grain : une version connue du catalogue OU observée dans la fenêtre.**

   CE DONT CETTE REQUÊTE A BESOIN
     Source     : `catalog.object_versions`, `catalog.executions`,
                  `catalog.projects`, `catalog.folders`
     Logging    : aucun
     Droits     : voir 01_diagnostic.sql, domaine « Droits ». Un compte sans droit
                  recoit zero ligne, pas un refus. Lecture seule stricte.
     Famille    : 2, 5
     Sortie     : VersionsProjet.csv

   PARAMÈTRES ATTENDUS, NON DÉCLARÉS ICI — voir l'en-tête de 11_executions.sql.
   La fenêtre ne borne QUE les observations d'exécution ; l'univers des versions
   connues du catalogue n'en dépend pas.

   POURQUOI CE FICHIER EXISTE
     Une version de projet n'est pas un objet déployé : un projet en porte jusqu'à
     `MAX_PROJECT_VERSIONS`. Les loger dans l'inventaire obligerait à répéter
     chaque projet ou à ne garder que la version courante. Grain distinct, donc
     extraction distincte — D016.

   TROIS CORRECTIONS APPORTÉES APRÈS RELECTURE

     1. **Le grain était faux.** La requête partait des seules versions observées
        dans les exécutions : une version présente au catalogue mais jamais
        exécutée dans la rétention disparaissait. L'univers est désormais l'UNION
        des deux sources, et deux drapeaux disent d'où vient chaque ligne.

     2. **Le tri était injustifié.** L'ancienne version ordonnait les transitions
        par `object_version_lsn` en affirmant qu'il était monotone. Cette colonne
        IDENTIFIE une version ; rien ne garantit qu'elle ordonne ses activations.
        Les transitions sont désormais ordonnées par **première exécution
        observée**, qui est un fait mesuré.

     3. **Les comptages ignoraient la fenêtre**, alors que les tables de faits la
        respectent. Un même rapport aurait mélangé deux périmètres.

   TROIS NIVEAUX DE PREUVE POUR LA DATE

     | `PreuveDeploiement` | Source | Fiabilité |
     |---|---|---|
     | `CatalogVersion`   | `object_versions.created_time` | mesurée |
     | `CurrentProject`   | `projects.last_deployed_time`  | mesurée, version courante |
     | `InferredInterval` | bornes d'exécutions            | inférée, DEUX bornes portées |

     L'inférence ne sert que pour une version observée mais purgée du catalogue :
     `MAX_PROJECT_VERSIONS` vaut 10 sur le catalogue de référence contre 30 jours
     d'exécutions, donc un parc qui déploie souvent épuise son historique de
     versions en premier.

   LIMITES À ÉNONCER EN RESTITUTION
     `project_lsn` versionne le **projet**, pas le package : une frontière signifie
     *le projet a été redéployé*, jamais *ce package a changé*.

     Une **réactivation** d'une version antérieure — restauration, redéploiement
     d'un ancien artefact — n'est pas représentable à ce grain : la ligne d'une
     version résumerait alors deux épisodes distincts. Si le cas se présente chez
     un client, le bon grain devient l'épisode d'activation et non la version.

   MINIMISATION
     `created_by`, `restored_by` et `deployed_by_name` sont des comptes de
     domaine : exclus. `description` est un texte libre : exclue au même titre que
     le texte des messages.
   ============================================================================= */

SET NOCOUNT ON;

WITH
projets AS (
    SELECT pr.project_id, pr.object_version_lsn, pr.last_deployed_time,
           f.name AS dossier, pr.name AS projet
    FROM SSISDB.[catalog].projects AS pr
    JOIN SSISDB.[catalog].folders  AS f ON f.folder_id = pr.folder_id
),

/* Versions encore présentes au catalogue : date MESURÉE, pour chacune d'elles et
   pas seulement pour la courante. Pas de fenêtre : c'est un état, pas un fait. */
conservees AS (
    SELECT p.dossier, p.projet,
           ov.object_version_lsn AS version_lsn,
           ov.created_time       AS date_version,
           ov.last_restored_time AS date_restauration
    FROM SSISDB.[catalog].object_versions AS ov
    JOIN projets AS p ON p.project_id = ov.object_id
    WHERE ov.object_type = 20          /* 20 = projet */
),

/* Versions vues à l'exécution DANS LA FENÊTRE. Toutes n'ont pas survécu à la
   purge du catalogue, et toutes celles du catalogue n'ont pas forcément tourné. */
observees AS (
    SELECT e.folder_name   AS dossier,
           e.project_name  AS projet,
           e.project_lsn   AS version_lsn,
           MIN(e.start_time)              AS premiere_execution,
           MAX(e.start_time)              AS derniere_execution,
           COUNT_BIG(*)                   AS nb_executions,
           COUNT(DISTINCT e.package_name) AS nb_packages
    FROM SSISDB.[catalog].executions AS e
    WHERE e.start_time IS NOT NULL
      AND e.project_lsn IS NOT NULL
      AND (@DebutFenetre IS NULL OR e.start_time >= @DebutFenetre)
      AND (@FinFenetre   IS NULL OR e.start_time <  @FinFenetre)
    GROUP BY e.folder_name, e.project_name, e.project_lsn
),

/* Encadrement de la livraison : entre la fin de la version précédente et le début
   de celle-ci. L'ordre est celui des PREMIÈRES EXÉCUTIONS OBSERVÉES, seul fait
   mesuré disponible — surtout pas le LSN, qui identifie sans ordonner. */
transitions AS (
    SELECT o.*,
           LAG(o.derniere_execution) OVER (
               PARTITION BY o.dossier, o.projet ORDER BY o.premiere_execution
           ) AS fin_version_precedente
    FROM observees AS o
),

/* L'univers est l'union des deux sources, jamais l'une seule. */
univers AS (
    SELECT dossier, projet, version_lsn FROM conservees
    UNION
    SELECT dossier, projet, version_lsn FROM observees
)
SELECT
    u.dossier                                                   AS Dossier,
    u.projet                                                    AS Projet,
    u.version_lsn                                               AS VersionProjetLsn,

    /* --- provenance de la ligne ---------------------------------------------- */
    CASE WHEN c.version_lsn IS NOT NULL THEN N'True' ELSE N'False' END
                                                                AS ConnueDuCatalogue,
    CASE WHEN t.version_lsn IS NOT NULL THEN N'True' ELSE N'False' END
                                                                AS ObserveeDansFenetre,
    CASE WHEN u.version_lsn = p.object_version_lsn THEN N'True' ELSE N'False' END
                                                                AS EstVersionCourante,

    /* --- datation et niveau de preuve ---------------------------------------- */
    ISNULL(CONVERT(varchar(40),
        COALESCE(c.date_version,
                 CASE WHEN u.version_lsn = p.object_version_lsn
                      THEN p.last_deployed_time END), 127), N'') AS DateDeploiement,
    CASE
        WHEN c.version_lsn IS NOT NULL             THEN N'CatalogVersion'
        WHEN u.version_lsn = p.object_version_lsn  THEN N'CurrentProject'
        WHEN t.version_lsn IS NOT NULL             THEN N'InferredInterval'
        ELSE N'Aucune'
    END                                                         AS PreuveDeploiement,

    /* Les deux bornes, renseignées quelle que soit la preuve : quand une date
       mesurée existe, elles permettent de la recouper. Vérifié sur le catalogue
       de référence, les dates mesurées tombent bien à l'intérieur. */
    ISNULL(CONVERT(varchar(40), t.fin_version_precedente, 127), N'')
                                                                AS BorneInferieure,
    ISNULL(CONVERT(varchar(40), t.premiere_execution, 127), N'') AS BorneSuperieure,
    DATEDIFF(HOUR, t.fin_version_precedente, t.premiere_execution)
                                                                AS IncertitudeHeures,
    ISNULL(CONVERT(varchar(40), c.date_restauration, 127), N'') AS DateRestauration,

    /* --- activité dans la fenêtre --------------------------------------------- */
    /* NULL, et non zéro, pour une version connue du catalogue mais non observée :
       « aucune exécution dans la fenêtre » n'est pas « zéro exécution jamais ». */
    t.nb_executions                                             AS NombreExecutions,
    t.nb_packages                                               AS NombrePackagesExecutes,
    ISNULL(CONVERT(varchar(40), t.premiere_execution, 127), N'') AS PremiereExecution,
    ISNULL(CONVERT(varchar(40), t.derniere_execution, 127), N'') AS DerniereExecution,
    DATEDIFF(DAY, t.premiere_execution, t.derniere_execution)   AS DureeVieJours

FROM univers AS u
JOIN projets AS p ON p.dossier = u.dossier AND p.projet = u.projet
LEFT JOIN conservees  AS c ON c.dossier = u.dossier AND c.projet = u.projet
                          AND c.version_lsn = u.version_lsn
LEFT JOIN transitions AS t ON t.dossier = u.dossier AND t.projet = u.projet
                          AND t.version_lsn = u.version_lsn
ORDER BY u.dossier, u.projet, t.premiere_execution, u.version_lsn;
