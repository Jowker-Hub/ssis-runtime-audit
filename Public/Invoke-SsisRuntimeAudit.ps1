function Invoke-SsisRuntimeAudit {
<#
.SYNOPSIS
    Extrait les faits d'execution d'un SSISDB vers un jeu de CSV.

.DESCRIPTION
    Enchaine la selection, le pre-vol et les extractions, puis rend compte.
    N'ecrit RIEN sur le serveur : lecture seule stricte, et chaque requete est
    passee au controle de lecture seule avant d'etre envoyee.

    UNE LIGNE PAR AUDIT DU PLAN dans Extractions.csv, y compris pour ceux qui
    n'ont pas ete lances. C'est la non-suppression silencieuse appliquee a
    l'extraction : un audit qui disparait du compte rendu est le meme defaut
    qu'une execution qui disparait du perimetre.

    UN ECHEC N'INTERROMPT PAS LES SUIVANTS. L'acces client est une ressource
    rare, et s'arreter a la deuxieme extraction sur neuf gacherait la session.
    Mais une extraction en echec NE PRODUIT AUCUN FICHIER : un CSV reduit a ses
    en-tetes ressemblerait a une extraction reussie sans resultat, ce qui est un
    tout autre constat.

.PARAMETER Serveur
    Instance SQL. Sans lui et sans -SansFenetre, la fenetre le demande.

.PARAMETER Audit
    Cles des extractions voulues. Les automatiques s'y ajoutent toujours.

.PARAMETER Tout
    Toutes les extractions que le logging observe permet.

.PARAMETER Jours
    Fenetre d'analyse, en jours glissants. Absent : toute la retention.

.PARAMETER SansFenetre
    N'affiche jamais l'interface. Pour une execution planifiee.

.EXAMPLE
    Invoke-SsisRuntimeAudit

    Ouvre la fenetre de selection.

.EXAMPLE
    Invoke-SsisRuntimeAudit -Serveur 'SRV-ETL-01' -Tout -Jours 30 -Sortie 'D:\Audit' -SansFenetre

    Rejoue une session sans clic.

.OUTPUTS
    PSCustomObject : Succes, DossierSortie (le sous-dossier du run), DossierBase,
    Extractions.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $Serveur,

        [Parameter(Mandatory = $false)]
        [string[]] $Audit,

        [Parameter(Mandatory = $false)]
        [switch] $Tout,

        [Parameter(Mandatory = $false)]
        [string] $Sortie,

        [Parameter(Mandatory = $false)]
        [int] $Jours,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential] $Identifiants,

        [Parameter(Mandatory = $false)]
        [switch] $SansFenetre,

        [Parameter(Mandatory = $false)]
        [string] $CheminSql
    )

    if ([string]::IsNullOrEmpty($CheminSql)) {
        $CheminSql = Join-Path -Path $PSScriptRoot -ChildPath '..\sql'
    }
    $plan = Read-RuntimeAuditPlan -CheminSql $CheminSql

    # ------------------------------------------------------- 1. les choix -----
    # La fenetre ne s'affiche que si on ne lui a pas deja tout dit. Une session
    # doit pouvoir etre rejouee sans clic.
    $interactif = (-not $SansFenetre) -and (-not $Tout) -and (-not $Audit)

    # LE DOSSIER PROPOSE PAR DEFAUT EST CELUI QUE LE RAPPORT POWER BI LIT.
    #
    # Les deux moities de l'outil doivent se rejoindre sans que personne ait a
    # le savoir : le runner depose ses collectes ici, et le parametre
    # DossierBase du modele semantique pointe sur le meme chemin. Lancer
    # l'audit puis actualiser le rapport suffit alors, sans rien regler.
    #
    # Le champ etait vide au lancement. L'operateur devait donc choisir un
    # dossier, puis retrouver le parametre dans Power BI pour l'aligner - deux
    # manipulations, et un rapport vide en cas d'oubli, sans rien pour le
    # signaler. Le chemin reste modifiable : c'est une proposition, pas une
    # contrainte.
    #
    # LE DEFAUT VAUT AUSSI HORS FENETRE, et pas seulement pour la saisie.
    # Reserve au mode interactif, il laissait "Invoke-SsisRuntimeAudit -Tout"
    # echouer sur "Dossier de sortie non precise" - un refus correct, mais qui
    # oblige a connaitre un chemin pour une commande qui, autrement, ne demande
    # rien. L'automatisation, elle, passe par Invoke-AuditPlanifie.ps1, ou
    # -Sortie est obligatoire : une tache planifiee doit nommer sa destination.
    if ([string]::IsNullOrWhiteSpace($Sortie)) {
        $Sortie = $script:DossierSortieParDefaut
    }

    if ($interactif) {
        $choix = Show-RuntimeAuditFenetre -Plan $plan -Instance $Serveur -DossierSortie $Sortie
        if ($null -eq $choix) {
            Write-Verbose 'Annule par l''operateur.'
            return $null
        }
        $Serveur      = $choix.Instance
        $Sortie       = $choix.DossierSortie
        $Identifiants = $choix.Identifiants
        $Audit        = $choix.Cles
        $Tout         = $false
        if ($null -ne $choix.JoursFenetre) { $Jours = $choix.JoursFenetre }
    }

    if ([string]::IsNullOrWhiteSpace($Serveur)) { throw 'Instance SQL non precisee.' }
    if ([string]::IsNullOrWhiteSpace($Sortie))  { throw 'Dossier de sortie non precise.' }

    if (-not (Test-Path -LiteralPath $Sortie)) {
        [void] (New-Item -Path $Sortie -ItemType Directory -Force)
    }
    $Sortie = (Resolve-Path -LiteralPath $Sortie).ProviderPath

    # ------------------------------------------------------- 2. le pre-vol ----
    $connexion = New-RuntimeAuditConnexion -Instance $Serveur -Identifiants $Identifiants
    try {
        $decisions = Select-RuntimeAuditExtraction -Plan $plan -Cle $Audit -Tout:$Tout

        # La fenetre glissante est calculee PAR LE PRE-VOL, sur l'heure SERVEUR.
        # La calculer ici depuis [DateTimeOffset]::Now melangeait deux horloges
        # dans le meme run : l'instant d'extraction venait du serveur et la borne
        # de fenetre du poste. "Les 30 derniers jours" ne designaient alors pas
        # les memes 30 jours que ceux que le serveur voit.
        $prevol = Invoke-RuntimeAuditPrevol -Connexion $connexion -Plan $plan `
                      -Decisions $decisions -JoursFenetre $Jours

        $debut = $prevol.DebutFenetre

        # ------------------------------------------- 2 bis. le dossier du run --
        # UN SOUS-DOSSIER PAR RUN, ET LE JEU DE ONZE CSV EST PUBLIE DEDANS.
        #
        # L'ecriture d'UN fichier etait deja atomique - temporaire puis
        # renommage. La publication du JEU ne l'etait pas, et c'est elle qui
        # compte pour l'analyse :
        #
        #   1. un premier run produit PhasesComposants.csv ;
        #   2. le run suivant porte sur une fenetre sans Performance ;
        #   3. Extractions.csv dit que les phases n'ont pas ete produites ;
        #   4. PhasesComposants.csv, celui d'AVANT, est toujours la.
        #
        # Le dossier melangeait donc deux collectes, et la promesse "une
        # extraction en echec ne produit aucun fichier" devenait fausse a
        # l'echelle du dossier. Un lecteur - ou Power BI - n'avait aucun moyen
        # de s'en apercevoir : le fichier est valide, seulement il date.
        #
        # Le sous-dossier regle aussi la concurrence, et donne l'historique des
        # collectes par-dessus le marche.
        #
        # Il est nomme sur l'INSTANT SERVEUR, comme tout ce qui date dans ce
        # module.
        $DossierBase = $Sortie
        $etiquette = $prevol.ExtractionTimestampUtc.ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $Sortie = Join-Path -Path $DossierBase -ChildPath "Run_${etiquette}Z"

        # Deux runs dans la meme seconde restent deux runs. Ecraser le premier
        # serait reintroduire, au niveau du dossier, le defaut qu'on corrige.
        $suffixe = 1
        while (Test-Path -LiteralPath $Sortie) {
            $suffixe++
            $Sortie = Join-Path -Path $DossierBase -ChildPath "Run_${etiquette}Z_$suffixe"
        }
        [void] (New-Item -Path $Sortie -ItemType Directory -Force)
        Write-Verbose "Dossier du run : $Sortie"

        # La disponibilite se recalcule AVEC le logging reellement observe : la
        # premiere passe ne pouvait pas le connaitre, faute de connexion.
        $decisions = Select-RuntimeAuditExtraction -Plan $plan -Cle $Audit -Tout:$Tout `
                         -LoggingObserve $prevol.NiveauxLogging

        # Tous les CSV se rapportent au MEME instant, celui du serveur.
        $parametres = @{
            ExtractionTimestampUtc = $prevol.ExtractionTimestampUtc
            DebutFenetre           = $debut
            FinFenetre             = $null
        }

        # --------------------------------------------------- 3. les extractions
        $resultats = @()
        $chrono = [System.Diagnostics.Stopwatch]::StartNew()

        # ATTENTION AU NOM DE CETTE VARIABLE.
        #
        # Elle s'appelait $audit, comme le parametre -Audit, qui est type
        # [string[]]. Les variables PowerShell etant insensibles a la casse,
        # c est LA MEME variable, et la contrainte de type du parametre persiste :
        # chaque objet d extraction etait silencieusement converti en tableau de
        # chaines a l affectation, et toutes ses proprietes devenaient vides.
        #
        # Mesure : Extractions.csv sortait avec ses neuf lignes et son en-tete
        # corrects, mais TOUTES LES VALEURS VIDES. Aucune erreur.
        foreach ($extraction in $plan.Audits) {

            $decision   = $decisions | Where-Object { $_.Cle -eq $extraction.Cle } | Select-Object -First 1
            $estimation = $prevol.Estimations | Where-Object { $_.Cle -eq $extraction.Cle } | Select-Object -First 1
            $cible      = Join-Path -Path $Sortie -ChildPath $extraction.Sortie

            $ligne = [ordered]@{
                Cle            = $extraction.Cle
                Nom            = $extraction.Nom
                Fichier        = $extraction.Fichier
                Sortie         = $extraction.Sortie
                # Portee jusque dans Extractions.csv : c'est elle qui explique
                # pourquoi une meme ligne Indisponible fait echouer un run et
                # pas un autre. Un verdict dont on ne peut pas relire le motif
                # est un verdict qu'on finit par ignorer.
                DemandeeExplicitement = [bool] $decision.DemandeeExplicitement
                Statut         = ''
                Lignes         = $null
                LignesEstimees = $estimation.LignesEstimees
                DureeSecondes  = $null
                Message        = ''
            }

            if (-not $decision.Retenue) {
                $ligne.Statut  = $decision.Statut     # NonSelectionnee ou Indisponible
                $ligne.Message = $decision.Motif
                $resultats += [PSCustomObject] $ligne
                continue
            }

            if ($estimation -and $estimation.Depassement) {
                $ligne.Statut  = 'VolumeExceedsLimit'
                $ligne.Message = $estimation.Motif
                $resultats += [PSCustomObject] $ligne
                Write-Warning "$($extraction.Nom) : $($estimation.Motif)"
                $resultats[-1] | Out-Null
                continue
            }

            # Seules les valeurs que la requete utilise reellement sont liees.
            $liees = @{}
            foreach ($nom in $extraction.Parametres) { $liees[$nom] = $parametres[$nom] }

            $depart = $chrono.Elapsed
            try {
                $lecteur = Invoke-RuntimeAuditLecteur -Connexion $connexion `
                               -CheminRequete $extraction.CheminComplet -Parametres $liees
                try {
                    $ecriture = Write-RuntimeAuditCsv -Lecteur $lecteur -Chemin $cible
                }
                finally { $lecteur.Close() }

                $ligne.Lignes        = $ecriture.Lignes
                $ligne.DureeSecondes = [math]::Round(($chrono.Elapsed - $depart).TotalSeconds, 2)
                $ligne.Statut        = if ($ecriture.Lignes -gt 0) { 'ReussieAvecDonnees' } else { 'ReussieVide' }
                Write-Verbose "$($extraction.Nom) : $($ecriture.Lignes) ligne(s) -> $($extraction.Sortie)"
            }
            catch {
                $ligne.DureeSecondes = [math]::Round(($chrono.Elapsed - $depart).TotalSeconds, 2)

                # Objet introuvable : la vue n'existe pas sur ce catalogue, ce qui
                # est un constat de version et non une panne. Le distinguer evite
                # de faire passer un catalogue ancien pour un incident.
                $exception = $_.Exception
                $estObjetManquant = $false
                while ($exception -and -not $estObjetManquant) {
                    if ($exception -is [System.Data.SqlClient.SqlException] -and $exception.Number -eq 208) {
                        $estObjetManquant = $true
                    }
                    $exception = $exception.InnerException
                }

                $ligne.Statut  = if ($estObjetManquant) { 'NonApplicable' } else { 'Echec' }
                $ligne.Message = $_.Exception.Message
                Write-Warning "$($extraction.Nom) : $($_.Exception.Message)"
            }

            $resultats += [PSCustomObject] $ligne
        }
    }
    finally {
        $connexion.Close()
    }

    # ------------------------------------------------ 4. les fichiers de contexte
    $contexte = [PSCustomObject]@{
        ExtractionTimestampUtc = $prevol.ExtractionTimestampUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        Serveur                = $Serveur
        ModeAuthentification   = $(if ($null -eq $Identifiants) { 'Windows' } else { 'SqlServer' })
        VersionModule          = (Get-RuntimeAuditVersionModule)
        VersionPlan            = $plan.Version
        FenetreJours           = $(if ($Jours -gt 0) { $Jours } else { '' })
        FenetreDebut           = $(if ($debut) { $debut.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') } else { '' })
        ExecutionsDansFenetre  = $prevol.NombreExecutions
        NiveauxLoggingObserves = ($prevol.NiveauxLogging -join ' ')
        MembreSsisAdmin        = $(if ($prevol.Droits.SsisAdmin) { 'True' } else { 'False' })
        MembreSsisLogreader    = $(if ($prevol.Droits.SsisLogreader) { 'True' } else { 'False' })
        RoleLogreaderInexistant = $(if ($prevol.Droits.SsisLogreaderInexistant) { 'True' } else { 'False' })
        MembreSysadmin         = $(if ($prevol.Droits.Sysadmin) { 'True' } else { 'False' })
        # Le compte utilise avait-il, au moment du run, de quoi ecrire ?
        #
        # L'outil ne REFUSE PAS de tourner pour autant, et c'est delibere :
        # beaucoup d'environnements ne donnent d'acces qu'a un compte large, et
        # surtout l'absence de role large ne prouve rien. Une permission
        # accordee directement, un groupe Windows, un chainage de propriete
        # suffisent a ecrire sans etre sysadmin. Refuser sur ce seul critere
        # donnerait une certification qu'on n'est pas en mesure de tenir.
        #
        # Le constat est donc rapporte, pas arbitre : il est trace dans Run.csv
        # et signale a l'operateur. La vraie mesure reste un compte dedie en
        # lecture seule, qui releve de la preparation de mission.
        CompteAuxDroitsLarges  = $(if ($prevol.Droits.Sysadmin -or $prevol.Droits.SsisAdmin) { 'True' } else { 'False' })
    }

    if ($prevol.Droits.Sysadmin -or $prevol.Droits.SsisAdmin) {
        $roles = @()
        if ($prevol.Droits.Sysadmin)  { $roles += 'sysadmin' }
        if ($prevol.Droits.SsisAdmin) { $roles += 'ssis_admin' }
        Write-Warning ("Le compte utilise est membre de $($roles -join ' et ') : il dispose de droits " +
                       "d'ecriture sur le catalogue. La collecte reste en lecture seule, mais la " +
                       "protection repose alors sur la discipline et non sur les permissions. " +
                       "Preferer un compte dedie en lecture seule chez le client.")
    }

    Write-RuntimeAuditObjetsCsv -Objets @($contexte)  -Chemin (Join-Path $Sortie 'Run.csv')         | Out-Null
    Write-RuntimeAuditObjetsCsv -Objets $resultats    -Chemin (Join-Path $Sortie 'Extractions.csv') | Out-Null

    # ------------------------------------------------------------ 5. le verdict
    # UNE INDISPONIBILITE N'EST PAS TOUJOURS UN ECHEC, ET PARFOIS SI.
    #
    #   -Audit 'phases' sur un catalogue Basic : l'operateur a nomme une
    #       extraction et ne l'a pas obtenue. Le run n'a pas tenu sa promesse,
    #       meme si aucune requete n'a plante. C'est un echec.
    #
    #   -Tout sur le meme catalogue : -Tout veut dire "tout ce que le logging
    #       permet". L'absence d'une conditionnelle est un constat de catalogue.
    #       Compter cela comme un echec rendrait -Tout inutilisable sur la
    #       plupart des parcs, qui tournent en Basic.
    #
    # Sans cette distinction, un run pouvait rendre Succes=True en n'ayant pas
    # produit ce qu'on lui avait explicitement demande.
    $echecs = @($resultats | Where-Object {
        $_.Statut -in @('Echec', 'VolumeExceedsLimit') -or
        ($_.Statut -eq 'Indisponible' -and $_.DemandeeExplicitement)
    })
    $succes = ($echecs.Count -eq 0)

    $resume = [PSCustomObject]@{
        Succes        = $succes
        DossierSortie = $Sortie
        DossierBase   = $DossierBase
        Extractions   = $resultats
    }

    if (-not $succes) {
        # Un etat global non reussi des qu'une extraction demandee n'a pas abouti,
        # meme si les autres CSV sont produits : sans cela une chaine automatisee
        # croirait la collecte complete.
        Write-Error ("Collecte incomplete : $($echecs.Count) extraction(s) non aboutie(s) - " +
                     (($echecs | ForEach-Object { "$($_.Cle) ($($_.Statut))" }) -join ', '))
    }

    return $resume
}
