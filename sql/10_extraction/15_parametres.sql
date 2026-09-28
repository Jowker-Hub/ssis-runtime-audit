/* =============================================================================
   15_parametres.sql
   Extraction automatique. Métadonnées des paramètres déclarés.
   **Aucune valeur ne sort.**

   CE DONT CETTE REQUÊTE A BESOIN
     Source     : `catalog.object_parameters`, `catalog.projects`, `catalog.folders`
     Logging    : aucun
     Droits     : voir 01_diagnostic.sql, domaine « Droits ». Un compte sans droit
                  recoit zero ligne, pas un refus. Lecture seule stricte.
     Famille    : 2
     Sortie     : Parametres.csv

   AUCUN PARAMÈTRE D'ENTRÉE. La source est statique : elle décrit ce qui est
   déclaré dans le catalogue, pas ce qui s'est exécuté. La fenêtre d'analyse ne
   s'y applique donc pas.

   POURQUOI CE GRAIN ET PAS CELUI DE L'EXÉCUTION
     Mesuré : `execution_parameter_values` pèse 26 lignes par exécution, soit 962
     lignes pour 37 exécutions. `object_parameters` décrit la même chose en
     **29 lignes statiques**. Les seules valeurs qui varient d'une exécution à
     l'autre sont les paramètres système, et ils sortent en colonnes de
     11_executions.sql.

   POURQUOI AUCUNE VALEUR NE SORT — ce n'est pas une précaution, c'est un fait
     Mesuré sur la première exécution réelle venue :

       CM.Ventes.ConnectionString
         = Data Source=SRV-ETL-01;Initial Catalog=EntrepotVentes;Provider=...
         sensitive = 0

     Les gestionnaires de connexion sont exposés en paramètres `CM.<nom>.*`,
     portent serveur et base **en clair**, et ne sont PAS marqués sensibles. Seul
     `Password` l'est. Se fier au drapeau `sensitive` laisserait donc sortir la
     topologie du client.

     `default_value` et `design_default_value` sont exclues pour cette raison.
   ============================================================================= */

SET NOCOUNT ON;

SELECT
    /* --- rattachement -------------------------------------------------------- */
    f.name                                                      AS Dossier,
    pr.name                                                     AS Projet,
    /* Un paramètre de projet n'appartient à aucun package : la colonne reste
       vide plutôt qu'absente, pour que le schéma ne varie pas. */
    CASE WHEN op.object_type = 30 THEN op.object_name ELSE N'' END AS Package,

    op.object_type                                              AS PorteeCode,
    CASE op.object_type
        WHEN 20 THEN N'Projet'
        WHEN 30 THEN N'Package'
        ELSE N'Inconnu' END                                     AS Portee,

    /* --- le paramètre --------------------------------------------------------- */
    op.parameter_name                                           AS Parametre,
    op.data_type                                                AS TypeDonnee,
    CASE WHEN op.required  = 1 THEN N'True' ELSE N'False' END   AS Obligatoire,
    CASE WHEN op.sensitive = 1 THEN N'True' ELSE N'False' END   AS Sensible,
    CASE WHEN op.value_set = 1 THEN N'True' ELSE N'False' END   AS ValeurDefinie,

    /* `value_type` vaut V pour une valeur littérale et R pour une référence à
       une variable d'environnement. C'est la colonne qui dit si le paramètre est
       piloté par l'environnement ou figé dans le déploiement. */
    ISNULL(op.value_type, N'')                                  AS TypeValeur,
    CASE op.value_type
        WHEN N'V' THEN N'Litterale'
        WHEN N'R' THEN N'ReferenceEnvironnement'
        ELSE N'' END                                            AS OrigineValeur,
    ISNULL(op.referenced_variable_name, N'')                    AS VariableReferencee,

    /* Un paramètre marqué comme gestionnaire de connexion se reconnaît à son
       préfixe. C'est le sous-ensemble le plus exposé, et celui qui justifie à lui
       seul l'exclusion des valeurs. */
    CASE WHEN op.parameter_name LIKE N'CM.%' THEN N'True' ELSE N'False' END
                                                                AS EstGestionnaireConnexion,

    /* --- validation ----------------------------------------------------------- */
    ISNULL(op.validation_status, N'')                           AS StatutValidation,
    ISNULL(CONVERT(varchar(40), op.last_validation_time, 127), N'')
                                                                AS DerniereValidation

    /* `default_value` et `design_default_value` : EXCLUES. Ce sont des valeurs,
       et la mesure ci-dessus montre ce qu'elles transportent.

       `description` est exclue pour la MÊME raison, corrigée après relecture :
       c'est un texte libre, qui peut contenir un nom de client, un chemin, un
       numéro de ticket ou un commentaire quelconque. Elle n'alimente aucun
       signal de la matrice. Le raisonnement qui exclut le texte des messages
       s'applique mot pour mot. */

FROM SSISDB.[catalog].object_parameters AS op
JOIN SSISDB.[catalog].projects AS pr ON pr.project_id = op.project_id
JOIN SSISDB.[catalog].folders  AS f  ON f.folder_id   = pr.folder_id
ORDER BY f.name, pr.name, op.object_type, op.object_name, op.parameter_name;
