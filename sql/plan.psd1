#
# plan.psd1 - Contrat des extractions disponibles.
#
# Ce fichier n'est pas un menu, c'est le CONTRAT DES CAPACITES. Il declare ce
# que l'outil sait extraire, ce que chaque extraction exige, et ce qu'elle
# produit. La fenetre de selection n'en est qu'un affichage.
#
# AUCUNE DONNEE CLIENT ICI. Ce fichier est versionne.
#
# ENCODAGE : UTF-8 AVEC BOM, et c'est indispensable.
#   Verifie sous PowerShell 5.1 : sans BOM, « Executions » revient sur 22
#   caracteres avec le « e accent aigu » eclate en deux (195, 169). Avec BOM, 20
#   caracteres et le code 233 attendu. Les libelles etant destines a une fenetre
#   francaise, le BOM n'est pas une coquetterie.
#
#   Le code .ps1 du module reste, lui, strictement ASCII : convention reprise du
#   SSIS Toolkit voisin, et aucune raison de faire dependre du code de l'encodage.
#
# LES CHAMPS
#   Cle                   identifiant stable, utilise par -Audit. Ne change jamais.
#   Nom, Description      ce que voit l'operateur. Aucun nom de fichier a l'ecran.
#   Fichier               chemin relatif a sql\
#   Sortie                nom du CSV, DECOUPLE du nom de la requete
#   Nature                Automatique | Fondamentale | Conditionnelle
#   LoggingMinimal        Aucun | Basic | Performance | Verbose
#   SelectionParDefaut    etat initial de la case a cocher
#   Grain                 une ligne represente quoi
#   Familles              familles de signaux alimentees, D015
#   Parametres            valeurs que le runner lie au batch. UNIQUEMENT celles
#                         que la requete utilise reellement.
#   LignesParExecution    facteur d'estimation au pre-vol. $null = source statique.
#   LimiteLignesParDefaut refus au-dela. $null = sans limite, ASSUME et AFFICHE.
#
# POURQUOI UNE LIMITE EN LIGNES, ET LA MEME PARTOUT
#   Une limite en lignes EST deja par extraction, parce que le meme nombre de
#   lignes ne represente pas la meme fenetre selon le grain : 2 000 000 lignes,
#   c'est 2 000 000 d'executions pour Executions, et seulement 8 230 executions
#   pour PhasesComposants, qui en produit 243 chacune.
#
#   Ces valeurs sont PRUDENTES ET PROVISOIRES. Elles se calibrent sur un premier
#   catalogue de taille client. Ce qui est fige, c'est le contrat : estimation
#   avant extraction, refus explicite, aucune troncature.
#
@{
    Version = 2

    Audits = @(

        # ------------------------------------------------------- automatiques --
        @{
            Cle                   = 'contexte'
            Nom                   = 'Contexte du catalogue'
            Description           = 'Version, rétention, logging, profondeur réelle. Sans lui, aucun chiffre n''est datable.'
            Fichier               = '00_prevol\01_diagnostic.sql'
            Sortie                = 'CatalogContext.csv'
            Nature                = 'Automatique'
            LoggingMinimal        = 'Aucun'
            SelectionParDefaut    = $true
            Grain                 = 'Un constat'
            Familles              = @(1)
            Parametres            = @()
            LignesParExecution    = $null
            LimiteLignesParDefaut = $null
        }
        @{
            Cle                   = 'inventaire'
            Nom                   = 'Inventaire du catalogue'
            Description           = 'Dossiers, projets et packages déployés, objets vides compris.'
            Fichier               = '10_extraction\14_inventaire.sql'
            Sortie                = 'CatalogObjets.csv'
            Nature                = 'Automatique'
            LoggingMinimal        = 'Aucun'
            SelectionParDefaut    = $true
            Grain                 = 'Un objet déployé'
            Familles              = @(2)
            Parametres            = @()
            LignesParExecution    = $null
            LimiteLignesParDefaut = $null
        }
        @{
            Cle                   = 'parametres'
            Nom                   = 'Paramètres déclarés'
            Description           = 'Métadonnées seules. Aucune valeur ne sort, y compris non marquée sensible.'
            Fichier               = '10_extraction\15_parametres.sql'
            Sortie                = 'Parametres.csv'
            Nature                = 'Automatique'
            LoggingMinimal        = 'Aucun'
            SelectionParDefaut    = $true
            Grain                 = 'Un paramètre déclaré'
            Familles              = @(2)
            Parametres            = @()
            LignesParExecution    = $null
            LimiteLignesParDefaut = $null
        }
        @{
            Cle                   = 'versions'
            Nom                   = 'Versions de projet'
            Description           = 'Frontières de déploiement, avec le niveau de preuve de chaque date.'
            Fichier               = '10_extraction\16_versions.sql'
            Sortie                = 'VersionsProjet.csv'
            Nature                = 'Automatique'
            LoggingMinimal        = 'Aucun'
            SelectionParDefaut    = $true
            Grain                 = 'Une version connue ou observée'
            Familles              = @(2, 5)
            Parametres            = @('DebutFenetre', 'FinFenetre')
            LignesParExecution    = $null
            LimiteLignesParDefaut = $null
        }

        # ------------------------------------------------------ fondamentales --
        @{
            Cle                   = 'executions'
            Nom                   = 'Exécutions'
            Description           = 'Une ligne par exécution, statut détaillé conservé.'
            Fichier               = '10_extraction\11_executions.sql'
            Sortie                = 'Executions.csv'
            Nature                = 'Fondamentale'
            LoggingMinimal        = 'Basic'
            SelectionParDefaut    = $true
            Grain                 = 'Une exécution'
            Familles              = @(1, 3, 4, 5, 6, 8, 9)
            Parametres            = @('ExtractionTimestampUtc', 'DebutFenetre', 'FinFenetre')
            LignesParExecution    = 1
            LimiteLignesParDefaut = 2000000
        }
        @{
            Cle                   = 'executables'
            Nom                   = 'Exécutables et tâches'
            Description           = 'Itérations de boucle comprises, avec le chemin logique normalisé.'
            Fichier               = '10_extraction\12_executables.sql'
            Sortie                = 'Executables.csv'
            Nature                = 'Fondamentale'
            LoggingMinimal        = 'Basic'
            SelectionParDefaut    = $true
            Grain                 = 'Un exécutable par exécution'
            Familles              = @(7)
            Parametres            = @('DebutFenetre', 'FinFenetre')
            LignesParExecution    = 11.1
            LimiteLignesParDefaut = 2000000
        }
        @{
            Cle                   = 'messages'
            Nom                   = 'Erreurs et avertissements'
            Description           = 'Métadonnées seules. Le texte des messages ne sort jamais.'
            Fichier               = '10_extraction\13_messages.sql'
            Sortie                = 'Messages.csv'
            Nature                = 'Fondamentale'
            LoggingMinimal        = 'Basic'
            SelectionParDefaut    = $true
            Grain                 = 'Un message retenu'
            Familles              = @(6)
            Parametres            = @('DebutFenetre', 'FinFenetre')
            LignesParExecution    = 0.8
            LimiteLignesParDefaut = 2000000
        }

        # ----------------------------------------------------- conditionnelles --
        @{
            Cle                   = 'phases'
            Nom                   = 'Phases de composants'
            Description           = 'Localise le temps actif dans un flux. Phases CONCOURANTES : ne jamais sommer.'
            Fichier               = '10_extraction\17_phases_composants.sql'
            Sortie                = 'PhasesComposants.csv'
            Nature                = 'Conditionnelle'
            LoggingMinimal        = 'Performance'
            SelectionParDefaut    = $false
            Grain                 = 'Une phase de composant'
            Familles              = @(10)
            Parametres            = @('DebutFenetre', 'FinFenetre')
            # 1458 lignes pour 6 executions au niveau Performance ou plus.
            # La premiere valeur, 486, venait d'une division par 3 : j'avais oublie
            # que les runs en Verbose produisent aussi des phases, Verbose etant
            # au-dessus de Performance. Le facteur se derive TOUJOURS des
            # executions qui atteignent le niveau exige, jamais d'un sous-ensemble.
            LignesParExecution    = 243
            LimiteLignesParDefaut = 2000000
        }
        @{
            Cle                   = 'flux'
            Nom                   = 'Statistiques de flux'
            Description           = 'Seule source de volume. Les lignes de plusieurs branches ne se somment pas.'
            Fichier               = '10_extraction\18_statistiques_flux.sql'
            Sortie                = 'StatistiquesFlux.csv'
            Nature                = 'Conditionnelle'
            LoggingMinimal        = 'Verbose'
            SelectionParDefaut    = $false
            Grain                 = 'Un chemin de flux'
            Familles              = @(10)
            Parametres            = @('DebutFenetre', 'FinFenetre')
            LignesParExecution    = 22
            LimiteLignesParDefaut = 2000000
        }
    )
}
