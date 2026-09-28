/* =============================================================================
   14_inventaire.sql
   Extraction automatique. Une ligne par objet déployé, en conservant les
   objets vides.

   CE DONT CETTE REQUÊTE A BESOIN
     Source     : `catalog.folders`, `catalog.projects`, `catalog.packages`
     Logging    : aucun
     Droits     : voir 01_diagnostic.sql, domaine « Droits ». Un compte sans droit
                  recoit zero ligne, pas un refus. Lecture seule stricte.
     Famille    : 2
     Sortie     : CatalogObjets.csv

   AUCUN PARAMÈTRE D'ENTRÉE. Source statique, la fenêtre d'analyse ne s'y
   applique pas : ce fichier décrit ce qui est DÉPLOYÉ, pas ce qui s'est exécuté.

   POURQUOI UN GRAIN HIÉRARCHIQUE ET NON UN APLATISSEMENT AU PACKAGE
     Un aplatissement serait plus simple, mais ferait disparaître les dossiers
     vides et les projets sans package. On ne pourrait alors plus distinguer
     « ce projet n'a aucun package » de « l'inventaire est incomplet » — et le
     second est un défaut d'extraction qu'il faut pouvoir repérer.

     Trois niveaux, empilés par UNION ALL, avec `ObjetParentId` pour reconstituer
     l'arbre. Les colonnes propres à un niveau restent présentes et vides sur les
     autres : le schéma ne varie pas.

   MINIMISATION
     `created_by_name` et `deployed_by_name` sont des comptes de domaine et ne
     sortent pas. Leur présence est signalée quand elle a un sens, jamais leur
     valeur.
   ============================================================================= */

SET NOCOUNT ON;

WITH inventaire AS (

    /* ------------------------------------------------------------ dossiers --- */
    SELECT
        1                                   AS rang_niveau,
        N'Dossier'                          AS type_objet,
        N''                                 AS type_parent,
        f.folder_id                         AS objet_id,
        CAST(NULL AS bigint)                AS objet_parent_id,
        f.name                              AS dossier,
        N''                                 AS projet,
        N''                                 AS package,
        N''                                 AS guid_package,
        N''                                 AS point_entree,
        N''                                 AS version_package,
        N''                                 AS format,
        CAST(NULL AS bigint)                AS version_projet_lsn,
        CAST(NULL AS datetimeoffset(7))     AS date_deploiement,
        N''                                 AS preuve_deploiement,
        N''                                 AS statut_validation,
        CAST(NULL AS datetimeoffset(7))     AS derniere_validation,
        f.created_time                      AS date_creation
    FROM SSISDB.[catalog].folders AS f

    UNION ALL

    /* ------------------------------------------------------------- projets --- */
    SELECT
        2, N'Projet', N'Dossier',
        pr.project_id,
        pr.folder_id,
        f.name, pr.name, N'', N'', N'', N'',
        CAST(pr.project_format_version AS nvarchar(20)),
        pr.object_version_lsn,
        pr.last_deployed_time,
        /* Niveau de preuve porté par la donnée elle-même, et non par une règle
           générale. `last_deployed_time` est une date MESURÉE, mais seulement
           pour la version courante : les versions antérieures relèvent de
           16_versions.sql, et celles qui en sont déjà purgées de l'inférence
           décrite là-bas. */
        N'CurrentProject',
        ISNULL(pr.validation_status, N''),
        pr.last_validation_time,
        pr.created_time
    FROM SSISDB.[catalog].projects AS pr
    JOIN SSISDB.[catalog].folders  AS f ON f.folder_id = pr.folder_id

    UNION ALL

    /* ------------------------------------------------------------ packages --- */
    SELECT
        3, N'Package', N'Projet',
        pk.package_id,
        pk.project_id,
        f.name, pr.name, pk.name,
        CONVERT(nvarchar(50), pk.package_guid),
        CASE WHEN pk.entry_point = 1 THEN N'True' ELSE N'False' END,
        CONCAT(pk.version_major, N'.', pk.version_minor, N'.', pk.version_build),
        CAST(pk.package_format_version AS nvarchar(20)),
        CAST(NULL AS bigint),
        CAST(NULL AS datetimeoffset(7)),
        N'',
        ISNULL(pk.validation_status, N''),
        pk.last_validation_time,
        CAST(NULL AS datetimeoffset(7))
    FROM SSISDB.[catalog].packages AS pk
    JOIN SSISDB.[catalog].projects AS pr ON pr.project_id = pk.project_id
    JOIN SSISDB.[catalog].folders  AS f  ON f.folder_id   = pr.folder_id
)
SELECT
    i.type_objet                                                AS TypeObjet,
    i.objet_id                                                  AS ObjetId,

    /* Cles GLOBALES et textuelles. folder_id, project_id et package_id viennent
       de trois espaces d'identifiants independants : rien ne garantit qu'ils ne
       prennent pas la meme valeur, et ObjetId seul ne permet donc pas une
       relation parent-enfant fiable. Les identifiants numeriques restent pour
       le diagnostic, jamais comme cle du modele. */
    CONCAT(i.type_objet, N':', i.objet_id)                      AS ObjetCle,
    CASE WHEN i.objet_parent_id IS NULL THEN N''
         ELSE CONCAT(i.type_parent, N':', i.objet_parent_id) END AS ObjetParentCle,
    ISNULL(CAST(i.objet_parent_id AS nvarchar(20)), N'')        AS ObjetParentId,

    /* Le triplet reste porté à tous les niveaux où il a un sens : c'est la clé
       du rapprochement optionnel avec l'audit statique, D020. */
    i.dossier                                                   AS Dossier,
    i.projet                                                    AS Projet,
    i.package                                                   AS Package,
    i.guid_package                                              AS PackageGuid,

    i.point_entree                                              AS EstPointEntree,
    i.version_package                                           AS VersionPackage,
    i.format                                                    AS VersionFormat,
    ISNULL(CAST(i.version_projet_lsn AS nvarchar(20)), N'')     AS VersionProjetLsn,

    ISNULL(CONVERT(varchar(40), i.date_deploiement, 127), N'')  AS DateDeploiement,
    i.preuve_deploiement                                        AS PreuveDeploiement,

    i.statut_validation                                         AS StatutValidation,
    ISNULL(CONVERT(varchar(40), i.derniere_validation, 127), N'') AS DerniereValidation,
    ISNULL(CONVERT(varchar(40), i.date_creation, 127), N'')     AS DateCreation

FROM inventaire AS i
ORDER BY i.dossier, i.rang_niveau, i.projet, i.package;
