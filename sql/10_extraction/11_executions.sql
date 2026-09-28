/* =============================================================================
   11_executions.sql
   Extraction fondamentale. Une ligne par exécution, statut détaillé conservé.

   CE DONT CETTE REQUÊTE A BESOIN
     Source     : `catalog.executions`, `catalog.execution_parameter_values`
     Logging    : Basic
     Droits     : voir 01_diagnostic.sql, domaine « Droits ». Un compte sans droit
                  recoit zero ligne, pas un refus. Lecture seule stricte.
     Familles   : 1, 3, 4, 5, 6, 8, 9
     Sortie     : Executions.csv

   PARAMÈTRES ATTENDUS, NON DÉCLARÉS ICI

     @ExtractionTimestampUtc  datetimeoffset(7)   ferme les exécutions en cours
     @DebutFenetre            datetimeoffset(7)   NULL = pas de borne basse
     @FinFenetre              datetimeoffset(7)   NULL = pas de borne haute, EXCLUSIVE

     **Ce n'est PAS une entorse à la règle « fichier exécuté tel quel ».** Le
     texte de ce fichier devient le `CommandText` d'un `SqlCommand`, sans
     transformation ni concaténation, et les `SqlParameter` sont liés à côté :
     SQL Server reçoit un batch paramétré, et le fichier versionné part tel qu'il
     est écrit. La règle s'énonce ainsi :

       La logique SQL est exécutée depuis le fichier versionné, SANS
       transformation. Seules les valeurs des paramètres déclarés dans le plan
       sont liées par le runner.

     `@ExtractionTimestampUtc` est lu UNE FOIS au pré-vol et partagé par toutes
     les extractions : la matrice impose que toutes ferment les exécutions en
     cours sur le même instant, sans quoi deux extractions du même jeu cessent
     d'être comparables. C'est la seule requête qui en a besoin.

     Pour exécuter ce fichier à la main dans SSMS, coller ce préambule devant :

       DECLARE @ExtractionTimestampUtc datetimeoffset(7) = SYSDATETIMEOFFSET();
       DECLARE @DebutFenetre datetimeoffset(7) = NULL;
       DECLARE @FinFenetre   datetimeoffset(7) = NULL;

   MINIMISATION
     Aucun nom de compte ne sort : `executed_as_name`, `caller_name` et
     `stopped_by_name` sont lus pour en dériver une catégorie ou un booléen, et
     ne figurent dans aucune colonne de sortie. Seuls les paramètres système,
     `object_type = 50`, ont leur valeur extraite.
   ============================================================================= */

SET NOCOUNT ON;

WITH
/* Les paramètres système pivotés. Un pivot plutôt qu'un grain séparé : mesuré,
   ce grain vaut 26 lignes par exécution, dont seules celles-ci nous servent.
   CUSTOMIZED_LOGGING_LEVEL est absent du catalogue de référence et n'apparaît
   sans doute que si un niveau personnalisé est défini : il est donc lu par le
   même pivot, qui rend NULL s'il n'existe pas, jamais en le supposant présent. */
systeme AS (
    SELECT
        p.execution_id,
        MAX(CASE WHEN p.parameter_name = N'LOGGING_LEVEL'            THEN CONVERT(nvarchar(50), p.parameter_value) END) AS logging_level,
        MAX(CASE WHEN p.parameter_name = N'CUSTOMIZED_LOGGING_LEVEL' THEN CONVERT(nvarchar(128), p.parameter_value) END) AS logging_level_personnalise,
        MAX(CASE WHEN p.parameter_name = N'CALLER_INFO'              THEN CONVERT(nvarchar(128), p.parameter_value) END) AS caller_info,
        MAX(CASE WHEN p.parameter_name = N'SYNCHRONIZED'             THEN CONVERT(nvarchar(10), p.parameter_value) END) AS synchronise,
        MAX(CASE WHEN p.parameter_name = N'DUMP_ON_ERROR'            THEN CONVERT(nvarchar(10), p.parameter_value) END) AS dump_sur_erreur,
        MAX(CASE WHEN p.parameter_name = N'DUMP_ON_EVENT'            THEN CONVERT(nvarchar(10), p.parameter_value) END) AS dump_sur_evenement,
        MAX(CASE WHEN p.parameter_name = N'DUMP_EVENT_CODE'          THEN CONVERT(nvarchar(50), p.parameter_value) END) AS dump_code_evenement
    FROM SSISDB.[catalog].execution_parameter_values AS p
    WHERE p.object_type = 50          /* liste blanche : système uniquement, D017 */
    GROUP BY p.execution_id
),
base AS (
    SELECT
        e.*,
        /* Fin effective : l'instant d'extraction ferme les exécutions en cours.
           Sans cela elles disparaissent de tout calcul de recouvrement, et font
           disparaître avec elles le chevauchement des autres. */
        COALESCE(e.end_time, @ExtractionTimestampUtc) AS fin_effective,
        CASE WHEN e.end_time IS NULL THEN 1 ELSE 0 END AS est_en_vol
    FROM SSISDB.[catalog].executions AS e
    WHERE e.start_time IS NOT NULL
      AND (@DebutFenetre IS NULL OR e.start_time >= @DebutFenetre)
      AND (@FinFenetre   IS NULL OR e.start_time <  @FinFenetre)   /* borne haute EXCLUSIVE : avec <=, deux fenetres adjacentes extraient deux fois le run pose exactement dessus */
)
SELECT
    /* --- identité ---------------------------------------------------------- */
    b.execution_id                                              AS ExecutionId,
    b.folder_name                                               AS Dossier,
    b.project_name                                              AS Projet,
    b.package_name                                              AS Package,
    b.project_lsn                                               AS VersionProjet,
    ISNULL(b.environment_folder_name, N'')                      AS DossierEnvironnement,
    ISNULL(b.environment_name, N'')                             AS Environnement,
    ISNULL(b.reference_type, N'')                               AS TypeReferenceEnvironnement,

    /* --- contexte d'exécution ---------------------------------------------- */
    ISNULL(b.server_name,  N'')                                 AS Serveur,
    ISNULL(b.machine_name, N'')                                 AS Machine,
    CASE WHEN b.use32bitruntime = 1 THEN N'True' ELSE N'False' END AS Mode32Bits,
    b.cpu_count                                                 AS NombreCoeurs,
    b.total_physical_memory_kb                                  AS MemoirePhysiqueKo,
    b.available_physical_memory_kb                              AS MemoireDisponibleKo,
    b.total_page_file_kb                                        AS PaginationTotaleKo,
    b.available_page_file_kb                                    AS PaginationDisponibleKo,
    /* Colonne du run, pas un agregat : nombre de fois que CETTE instance a ete
       executee. Le nom source, executed_count, induit en erreur. */
    b.executed_count                                            AS RangExecutionInstance,

    /* --- issue --------------------------------------------------------------- */
    b.status                                                    AS StatutCode,
    CASE b.status
        WHEN 1 THEN N'Creee'      WHEN 2 THEN N'EnCours'    WHEN 3 THEN N'Annulee'
        WHEN 4 THEN N'Echec'      WHEN 5 THEN N'EnAttente'  WHEN 6 THEN N'Interrompue'
        WHEN 7 THEN N'Reussie'    WHEN 8 THEN N'EnArret'    WHEN 9 THEN N'Terminee'
        ELSE N'Inconnu' END                                     AS Statut,
    CASE WHEN b.status IN (3, 4, 6, 7, 9) THEN N'True' ELSE N'False' END AS EstTerminee,
    /* Le nom de qui a demandé l'arrêt ne sort pas ; le fait qu'un arrêt ait été
       demandé est une information d'exploitation, pas une donnée personnelle. */
    CASE WHEN b.stopped_by_sid IS NOT NULL THEN N'True' ELSE N'False' END AS ArretDemande,

    /* Pas de colonne « dump produit ». Mesuré : `dump_id` est un GUID renseigné
       sur 100 % des exécutions, c'est un identifiant attribué d'office et non un
       marqueur. Le catalogue ne contient aucune table de dumps permettant de
       savoir si un fichier a réellement été écrit. La seule information fiable
       est la CONFIGURATION du dump, qui sort plus bas via DumpSurErreur et
       DumpSurEvenement. */

    /* --- temps ---------------------------------------------------------------- */
    CONVERT(varchar(40), b.created_time, 127)                   AS HeureInitialisation,
    CONVERT(varchar(40), b.start_time,   127)                   AS HeureDebut,
    ISNULL(CONVERT(varchar(40), b.end_time, 127), N'')          AS HeureFin,
    CONVERT(varchar(40), b.fin_effective, 127)                  AS HeureFinEffective,
    DATEPART(TZOFFSET, b.start_time)                            AS DecalageUtcMinutes,

    /* Durée nulle si l'exécution n'est pas finie : une durée partielle affichée
       comme une durée serait fausse. DureeEffective, elle, sert au recouvrement
       d'intervalles et vaut jusqu'à l'instant d'extraction. */
    CASE WHEN b.end_time IS NOT NULL
         THEN DATEDIFF(SECOND, b.start_time, b.end_time) END    AS DureeSecondes,
    DATEDIFF(SECOND, b.start_time, b.fin_effective)             AS DureeEffectiveSecondes,
    CASE WHEN b.est_en_vol = 1 THEN N'True' ELSE N'False' END   AS EnVolALExtraction,

    /* Délai entre initialisation de l'instance et démarrage effectif. C'est un
       SYMPTOME : une hausse concomitante à une forte concurrence justifie une
       investigation sur la mise en file ou la capacité. Ce n'est pas la preuve
       que SSISDB a bridé quoi que ce soit. */
    DATEDIFF(SECOND, b.created_time, b.start_time)              AS DelaiDemarrageSecondes,

    /* --- calendrier ----------------------------------------------------------- */
    /* DATEPART(WEEKDAY) dépend de SET DATEFIRST, qui dépend de la langue de la
       connexion. Normalisé pour que 1 soit toujours lundi. */
    CONVERT(varchar(10), b.start_time, 23)                      AS DateDebut,
    ((DATEPART(WEEKDAY, b.start_time) + @@DATEFIRST - 2) % 7) + 1 AS JourSemaineIso,
    CASE WHEN ((DATEPART(WEEKDAY, b.start_time) + @@DATEFIRST - 2) % 7) + 1 >= 6
         THEN N'True' ELSE N'False' END                         AS EstWeekEnd,
    DATEPART(DAY,   b.start_time)                               AS JourDuMois,
    DATEPART(HOUR,  b.start_time)                               AS HeureDuJour,
    DATEPART(MONTH, b.start_time)                               AS Mois,
    DATEPART(QUARTER, b.start_time)                             AS Trimestre,
    CASE WHEN DATEPART(DAY, b.start_time)
              = DATEPART(DAY, EOMONTH(CAST(b.start_time AS date)))
         THEN N'True' ELSE N'False' END                         AS EstDernierJourDuMois,

    /* --- paramètres système -------------------------------------------------- */
    ISNULL(s.logging_level, N'')                                AS NiveauLogging,
    ISNULL(s.logging_level_personnalise, N'')                   AS NiveauLoggingPersonnalise,
    ISNULL(s.synchronise, N'')                                  AS Synchronise,
    ISNULL(s.dump_sur_erreur, N'')                              AS DumpSurErreur,
    ISNULL(s.dump_sur_evenement, N'')                           AS DumpSurEvenement,
    ISNULL(s.dump_code_evenement, N'')                          AS DumpCodeEvenement,

    /* Trois catégories, jamais deux. SQLAGENT identifie l'Agent SQL ; une valeur
       vide n'identifie rien — un orchestrateur tiers, un appel T-SQL ou un script
       la laissent vide tout autant qu'un lancement manuel. La valeur brute sort
       aussi : ce n'est pas un nom de compte, et elle porte le nom du job. */
    CASE WHEN s.caller_info = N'SQLAGENT' THEN N'AgentSql'
         WHEN NULLIF(s.caller_info, N'') IS NOT NULL THEN N'AutreDeclaree'
         ELSE N'Indeterminee' END                               AS OrigineDeclaree,
    /* Valeur brute restreinte a une liste blanche. CALLER_INFO est un parametre
       systeme, mais son TEXTE est pose par l'appelant : une chaine libre non
       reconnue peut transporter n'importe quoi. Seules les valeurs documentees
       sortent ; le reste est vide, et OrigineDeclaree porte deja l'information. */
    CASE WHEN s.caller_info = N'SQLAGENT' THEN s.caller_info ELSE N'' END AS CallerInfo

FROM base AS b
LEFT JOIN systeme AS s ON s.execution_id = b.execution_id
ORDER BY b.start_time, b.execution_id;
