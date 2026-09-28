/* =============================================================================
   01_diagnostic.sql
   Phase 0. La porte : ce qu'on peut mesurer chez ce client, et ce qu'on ne peut
   pas.

   CE DONT CETTE REQUÊTE A BESOIN (3.3)
     Source     : SSISDB.
     Logging    : aucun. Elle constate le niveau de logging, elle n'en dépend pas.
     Adaptation : aucune.
     Droits     : aucun privilege particulier n'est exige pour EXECUTER cette
                  requete — mais les vues du schema catalog sont FILTREES PAR
                  PERMISSIONS, et un compte sans droit recoit zero ligne plutot
                  qu'un refus. C'est precisement ce que son domaine « Droits »
                  mesure, et c'est pourquoi il figure en tete du resultat.
                  Lecture seule stricte.

   CE QU'ELLE PRODUIT
     Un constat par ligne, en quatre colonnes : domaine, constat, valeur,
     lecture. Format volontairement haut et étroit — il se lit à l'écran chez le
     client, se colle dans un compte rendu, et s'exporte en CSV sans schéma à
     maintenir. Aucun percentile, aucun classement : la phase 0 ne juge rien,
     elle inventorie ce qui est mesurable.

     Elle doit répondre proprement sur un catalogue VIDE. Une installation
     fraîche, ou dont la rétention vient de purger, est un cas client réel, et
     un diagnostic qui rend des zéros indistinguables d'une absence de données
     est pire qu'un diagnostic qui refuse de répondre.

   CE QU'ELLE A APPRIS DU TERRAIN
     Cinq de ses constats n'étaient pas dans le cadrage initial. Ils viennent
     tous d'observations faites sur un vrai catalogue :

       - une exécution en statut « réussi » peut porter des erreurs. Le statut
         seul ne dit donc pas qu'un run est propre ;
       - le corps du package ne représente qu'une part du temps écoulé, le
         reste étant validation, préparation et libération. Analyser les seules
         statistiques d'exécutables fait rater cette part ;
       - CALLER_INFO vaut 'SQLAGENT' pour une étape SSIS de l'Agent. Cela
         identifie l'Agent ; cela n'identifie PAS ce qui n'est pas l'Agent. Une
         valeur vide couvre aussi bien un lancement manuel qu'un orchestrateur
         tiers, un appel T-SQL ou un script — le générateur d'historique du
         projet en est lui-même un exemple. D'où trois catégories et non deux ;
       - une tâche dans une boucle produit une ligne par itération, l'indice
         étant porté entre crochets dans le chemin d'exécution ;
       - une exécution encore en cours a une fin nulle. Toute mesure de
         concurrence doit la traiter, sans quoi elle disparaît du calcul et fait
         disparaître avec elle le chevauchement des autres.
   ============================================================================= */

SET NOCOUNT ON;

/* Instant de référence unique. Toutes les mesures qui ont besoin d'un « maintenant »
   s'y rapportent : sinon deux lignes du même diagnostic ne sont pas mesurées
   contre le même instant, et les durées des exécutions en cours divergent. */
DECLARE @maintenant datetimeoffset(7) = SYSDATETIMEOFFSET();

WITH
runs AS (
    SELECT e.execution_id, e.folder_name, e.project_name, e.package_name,
           e.project_lsn, e.status, e.start_time, e.end_time, e.created_time,
           e.machine_name, e.caller_name,
           COALESCE(e.end_time, @maintenant) AS fin_effective
    FROM SSISDB.[catalog].executions AS e
),
/* Le chemin racine est le seul à ne contenir qu'un seul antislash : « \Package ».
   Ses enfants en ont au moins deux. C'est plus robuste que de reconstituer le
   nom du package, qui porte l'extension .dtsx là où le chemin ne la porte pas. */
racines AS (
    SELECT s.execution_id, s.execution_duration
    FROM SSISDB.[catalog].executable_statistics AS s
    WHERE LEN(s.execution_path) - LEN(REPLACE(s.execution_path, N'\', N'')) = 1
),
erreurs AS (
    SELECT m.operation_id, COUNT(*) AS nb_erreurs
    FROM SSISDB.[catalog].event_messages AS m
    WHERE m.message_type = 120            /* OnError, code constaté sur le terrain */
    GROUP BY m.operation_id
),
proprietes AS (
    SELECT property_name, property_value
    FROM SSISDB.[catalog].catalog_properties
),
constats AS (

    /* ------------------------------------------------------- 0. Les droits --
       EN PREMIER, et c'est delibere. Les vues du schema catalog sont FILTREES
       PAR PERMISSIONS : un compte sans droit ne recoit pas un refus, il recoit
       ZERO LIGNE. Mesure sur le catalogue de reference : un compte authentifie
       sans role voit 0 execution la ou il y en a 43.

       Un audit qui rapporterait « 0 execution » a cause d'un droit manquant
       serait pire qu'un audit qui refuse de tourner. Ces trois lignes sont donc
       la condition de lecture de toutes les suivantes.

       La definition de `catalog.executions` retient quatre voies d'acces :
       appartenance a ssis_admin, a sysadmin, a ssis_logreader, ou permission
       explicite sur chaque operation. */
    SELECT 1 AS rang, N'Droits' AS domaine, N'Membre de ssis_admin' AS constat,
           CASE WHEN ISNULL(IS_MEMBER(N'ssis_admin'), 0) = 1 THEN N'True' ELSE N'False' END AS valeur,
           N'Donne tout, y compris l''administration du catalogue. Plus que ce qu''un audit demande.' AS lecture
    UNION ALL
    /* IS_MEMBER rend NULL quand le role n'existe pas, et SQL Server ne cree PAS
       ssis_logreader alors que la vue le prevoit. C'est le droit le plus juste
       pour cet audit, et il se cree en une ligne chez le client. */
    SELECT 2, N'Droits', N'Membre de ssis_logreader',
           CASE WHEN IS_MEMBER(N'ssis_logreader') IS NULL THEN N'role inexistant'
                WHEN IS_MEMBER(N'ssis_logreader') = 1 THEN N'True' ELSE N'False' END,
           N'Ouvre tout l''historique d''execution sans donner l''administration. A creer si absent : CREATE ROLE ssis_logreader.'
    UNION ALL
    SELECT 3, N'Droits', N'Membre de sysadmin',
           CASE WHEN IS_SRVROLEMEMBER(N'sysadmin') = 1 THEN N'True' ELSE N'False' END,
           N'Contourne tout filtrage. Un audit ne devrait pas en avoir besoin.'
    UNION ALL
    /* Le signal qui trahit un droit manquant. Des packages visibles mais aucun
       parametre ni aucune version : c'est le symptome exact d'un compte qui a
       ssis_logreader sans permission READ sur les projets. Un projet sans aucun
       parametre existe, mais c'est rare, et le doute merite d'etre leve. */
    SELECT 4, N'Droits', N'Visibilite coherente',
           CASE WHEN (SELECT COUNT(*) FROM SSISDB.[catalog].packages) > 0
                     AND (SELECT COUNT(*) FROM SSISDB.[catalog].object_parameters) = 0
                     AND (SELECT COUNT(*) FROM SSISDB.[catalog].object_versions) = 0
                THEN N'SUSPECTE' ELSE N'True' END,
           N'Croise packages visibles et parametres/versions. A SUSPECTE, c''est le symptome d''un GRANT READ manquant sur les projets, et non d''un catalogue vide.'

    /* ---------------------------------------------------- 1. Le catalogue --- */
    UNION ALL
    SELECT 10 AS rang, N'Catalogue' AS domaine, N'Version du schema' AS constat,
           (SELECT property_value FROM proprietes WHERE property_name = N'SCHEMA_VERSION') AS valeur,
           N'Conditionne les colonnes disponibles. worker_agent_id n''existe pas avant 2017.' AS lecture
    UNION ALL
    SELECT 11, N'Catalogue', N'Build du schema',
           (SELECT property_value FROM proprietes WHERE property_name = N'SCHEMA_BUILD'),
           N'Version du moteur qui heberge le catalogue.'
    UNION ALL
    SELECT 12, N'Catalogue', N'Fenetre de retention parametree',
           ISNULL((SELECT property_value + N' jours' FROM proprietes WHERE property_name = N'RETENTION_WINDOW'), N'non defini'),
           N'Ce qui est PREVU. A comparer a la profondeur reelle plus bas : le job de maintenance peut ne pas tourner.'
    UNION ALL
    SELECT 13, N'Catalogue', N'Nettoyage des operations actif',
           ISNULL((SELECT property_value FROM proprietes WHERE property_name = N'OPERATION_CLEANUP_ENABLED'), N'non defini'),
           N'Desactive, le catalogue croit sans limite et la retention affichee est fictive.'
    UNION ALL
    SELECT 14, N'Catalogue', N'Versions de projet conservees',
           ISNULL((SELECT property_value FROM proprietes WHERE property_name = N'MAX_PROJECT_VERSIONS'), N'non defini'),
           N'Historique de deploiement, generalement bien plus court que l''historique d''executions.'
    UNION ALL
    SELECT 15, N'Catalogue', N'Niveau de logging par defaut du serveur',
           ISNULL((SELECT CASE property_value WHEN N'0' THEN N'0 - Aucun' WHEN N'1' THEN N'1 - Basic'
                               WHEN N'2' THEN N'2 - Performance' WHEN N'3' THEN N'3 - Verbose'
                               WHEN N'4' THEN N'4 - Personnalise' ELSE property_value END
                   FROM proprietes WHERE property_name = N'SERVER_LOGGING_LEVEL'), N'non defini'),
           N'Valeur par defaut seulement. Le niveau reellement applique est par execution, voir Capacites.'

    /* ------------------------------------------------- 2. Ce qui est deploye - */
    UNION ALL
    SELECT 20, N'Inventaire', N'Dossiers, projets, packages',
           CONCAT((SELECT COUNT(*) FROM SSISDB.[catalog].folders), N' / ',
                  (SELECT COUNT(*) FROM SSISDB.[catalog].projects), N' / ',
                  (SELECT COUNT(*) FROM SSISDB.[catalog].packages)),
           N'Mode projet. Un parc deploye en mode package n''apparait pas ici et releve d''une autre source.'
    UNION ALL
    SELECT 21, N'Inventaire', N'Environnements et references',
           CONCAT((SELECT COUNT(*) FROM SSISDB.[catalog].environments), N' environnement(s), ',
                  (SELECT COUNT(*) FROM SSISDB.[catalog].environment_references), N' reference(s)'),
           N'Sans reference, les executions ne portent pas de nom d''environnement.'

    /* ----------------------------------------------------- 3. Volumetrie ---- */
    UNION ALL
    SELECT 30, N'Volumetrie', N'Executions enregistrees',
           CAST((SELECT COUNT_BIG(*) FROM runs) AS nvarchar(20)),
           N'Si zero, tout ce qui suit est sans objet et la phase 0 s''arrete ici.'
    UNION ALL
    SELECT 31, N'Volumetrie', N'Packages ayant reellement tourne',
           CAST((SELECT COUNT(DISTINCT CONCAT(folder_name, N'|', project_name, N'|', package_name)) FROM runs) AS nvarchar(20)),
           N'A comparer au nombre de packages deployes : l''ecart, ce sont les packages jamais executes.'
    UNION ALL
    SELECT 32, N'Volumetrie', N'Lignes de statistiques d''executables',
           CAST((SELECT COUNT_BIG(*) FROM SSISDB.[catalog].executable_statistics) AS nvarchar(20)),
           N'Decide entre import direct et agregation prealable pour la restitution.'
    UNION ALL
    SELECT 33, N'Volumetrie', N'Messages d''evenement',
           CAST((SELECT COUNT_BIG(*) FROM SSISDB.[catalog].event_messages) AS nvarchar(20)),
           N'Table la plus volumineuse. Seules ses metadonnees sont extraites, jamais le texte.'

    /* ------------------------------------------------------ 4. Profondeur --- */
    UNION ALL
    SELECT 40, N'Profondeur', N'Periode couverte',
           ISNULL((SELECT CONCAT(CONVERT(varchar(19), MIN(start_time), 120), N' -> ',
                                 CONVERT(varchar(19), MAX(start_time), 120))
                   FROM runs WHERE start_time IS NOT NULL), N'aucune donnee'),
           N'Profondeur REELLE, a confronter a la retention parametree.'
    UNION ALL
    SELECT 41, N'Profondeur', N'Jours d''historique disponibles',
           ISNULL((SELECT CAST(DATEDIFF(DAY, MIN(start_time), MAX(start_time)) AS nvarchar(20))
                   FROM runs WHERE start_time IS NOT NULL), N'aucune donnee'),
           N'Nettement inferieur a la retention parametree : le nettoyage purge, ou le parc est jeune.'
    UNION ALL
    SELECT 42, N'Profondeur', N'Versions de projet observees',
           CONCAT((SELECT COUNT(DISTINCT project_lsn) FROM runs), N' dans les executions, ',
                  (SELECT COUNT(*) FROM SSISDB.[catalog].object_versions), N' dans l''historique'),
           N'Les frontieres de version segmentent les comparaisons a code constant.'

    /* -------------------------------------------- 5. Qualite des donnees ---- */
    /* Une ligne par statut plutot qu'une liste concatenee. La concatenation
       passerait par FOR XML PATH, qui exige QUOTED_IDENTIFIER ON : la requete
       dependrait alors d'une option de session du client, et sqlcmd la
       positionne a OFF par defaut. STRING_AGG reglerait le probleme mais
       n'existe pas avant 2017, donc pas chez tout le monde. */
    UNION ALL
    SELECT 50, N'Qualite', CONCAT(N'Statut : ',
               CASE status WHEN 1 THEN N'cree' WHEN 2 THEN N'en cours' WHEN 3 THEN N'annule'
                           WHEN 4 THEN N'echec' WHEN 5 THEN N'en attente' WHEN 6 THEN N'interrompu'
                           WHEN 7 THEN N'reussi' WHEN 8 THEN N'en arret' WHEN 9 THEN N'termine'
                           ELSE CONCAT(N'inconnu (', status, N')') END),
           CAST(COUNT(*) AS nvarchar(20)),
           N'Annulations et interruptions ne sont pas des echecs et ne se regroupent pas avec eux.'
    FROM runs GROUP BY status
    UNION ALL
    SELECT 51, N'Qualite', N'Executions reussies portant des erreurs',
           CAST((SELECT COUNT(*) FROM runs r JOIN erreurs e ON e.operation_id = r.execution_id
                 WHERE r.status = 7) AS nvarchar(20)),
           N'Messages d''erreur journalises malgre un statut final reussi. Le statut seul ne suffit donc pas. L''erreur peut avoir ete prevue et geree : c''est un fait a investiguer, pas un defaut etabli.'
    UNION ALL
    SELECT 52, N'Qualite', N'Executions sans heure de fin',
           CAST((SELECT COUNT(*) FROM runs WHERE end_time IS NULL) AS nvarchar(20)),
           N'En cours, ou interrompues sans trace. Toute mesure de concurrence doit les traiter.'
    UNION ALL
    SELECT 53, N'Qualite', N'Durees negatives',
           CAST((SELECT COUNT(*) FROM runs WHERE end_time IS NOT NULL
                   AND DATEDIFF(SECOND, start_time, end_time) < 0) AS nvarchar(20)),
           N'Anomalie d''horloge. Non nul, il faut comprendre avant de publier quoi que ce soit.'

    /* ------------------------------------------------ 6. Ce qui est mesurable */
    UNION ALL
    SELECT 60, N'Capacites', CONCAT(N'Logging applique : ',
               CASE CONVERT(nvarchar(10), p.parameter_value)
                    WHEN N'0' THEN N'Aucun' WHEN N'1' THEN N'Basic'
                    WHEN N'2' THEN N'Performance' WHEN N'3' THEN N'Verbose'
                    WHEN N'4' THEN N'Personnalise'
                    ELSE CONVERT(nvarchar(10), p.parameter_value) END),
           CAST(COUNT(*) AS nvarchar(20)),
           N'Par execution, pas par serveur. C''est cette ligne qui decide ce que la phase 3 pourra faire.'
    FROM SSISDB.[catalog].execution_parameter_values AS p
    WHERE p.parameter_name = N'LOGGING_LEVEL'
    GROUP BY CONVERT(nvarchar(10), p.parameter_value)
    UNION ALL
    SELECT 61, N'Capacites', N'Phases de composants disponibles',
           CONCAT(CAST((SELECT COUNT_BIG(*) FROM SSISDB.[catalog].execution_component_phases) AS nvarchar(20)),
                  N' ligne(s)'),
           N'Exige Performance. A zero, la decomposition par phase est inaccessible.'
    UNION ALL
    SELECT 62, N'Capacites', N'Statistiques de flux disponibles',
           CONCAT(CAST((SELECT COUNT_BIG(*) FROM SSISDB.[catalog].execution_data_statistics) AS nvarchar(20)),
                  N' ligne(s)'),
           N'Exige Verbose. A zero, aucun debit en lignes par seconde n''est calculable.'
    UNION ALL
    /* Trois categories, jamais deux. SQLAGENT identifie l'Agent ; une valeur
       vide n'identifie rien du tout. */
    SELECT 63, N'Capacites', CONCAT(N'Origine declaree : ',
               CASE WHEN CONVERT(nvarchar(50), p.parameter_value) = N'SQLAGENT' THEN N'AgentSql'
                    WHEN NULLIF(CONVERT(nvarchar(50), p.parameter_value), N'') IS NOT NULL THEN N'AutreDeclaree'
                    ELSE N'Indeterminee' END),
           CAST(COUNT(*) AS nvarchar(20)),
           N'CALLER_INFO identifie l''Agent, pas son contraire. Indeterminee couvre le manuel comme un orchestrateur tiers ou un script.'
    FROM runs AS r
    LEFT JOIN SSISDB.[catalog].execution_parameter_values AS p
           ON p.execution_id = r.execution_id AND p.parameter_name = N'CALLER_INFO'
    GROUP BY CASE WHEN CONVERT(nvarchar(50), p.parameter_value) = N'SQLAGENT' THEN N'AgentSql'
                  WHEN NULLIF(CONVERT(nvarchar(50), p.parameter_value), N'') IS NOT NULL THEN N'AutreDeclaree'
                  ELSE N'Indeterminee' END

    /* --------------------------------------------- 7. Pieges a confirmer ---- */
    UNION ALL
    SELECT 70, N'Pieges', N'Lignes issues d''iterations de boucle',
           CONCAT(CAST((SELECT COUNT_BIG(*) FROM SSISDB.[catalog].executable_statistics
                        WHERE execution_path LIKE N'%[[]%') AS nvarchar(20)), N' sur ',
                  CAST((SELECT COUNT_BIG(*) FROM SSISDB.[catalog].executable_statistics) AS nvarchar(20))),
           N'L''indice est entre crochets dans le chemin. Il faut le retirer pour agreger par chemin logique.'
    UNION ALL
    SELECT 71, N'Pieges', N'Part du temps hors corps de package',
           ISNULL((SELECT CONCAT(CAST(100 - (100.0 * SUM(rc.execution_duration)
                                    / NULLIF(SUM(DATEDIFF(MILLISECOND, r.start_time, r.end_time)), 0))
                                 AS decimal(5,1)), N' %')
                   FROM runs r JOIN racines rc ON rc.execution_id = r.execution_id
                   WHERE r.end_time IS NOT NULL
                     AND DATEDIFF(MILLISECOND, r.start_time, r.end_time) > 0), N'aucune donnee'),
           N'Validation, preparation et liberation. Une part elevee signifie que le temps n''est PAS dans les taches.'
    UNION ALL
    /* Le compte inclut l'execution elle-meme : verifie, 17 avec soi contre 16
       pairs. Une valeur de 1 signifie donc AUCUN pair concurrent, et le libelle
       doit le dire, sans quoi on lit un parallelisme la ou il n'y en a pas. */
    SELECT 72, N'Pieges', N'Nombre maximal d''executions simultanees',
           ISNULL((SELECT CAST(MAX(n) AS nvarchar(20)) FROM (
                       SELECT COUNT(*) AS n
                       FROM runs a JOIN runs b
                         ON b.start_time < a.fin_effective AND b.fin_effective > a.start_time
                       WHERE a.start_time IS NOT NULL
                       GROUP BY a.execution_id) AS c), N'aucune donnee'),
           N'Se compte elle-meme : 1 signifie aucun pair concurrent. Fins nulles fermees a l''horodatage d''extraction.'
)
SELECT domaine, constat, valeur, lecture
FROM constats
ORDER BY rang;
