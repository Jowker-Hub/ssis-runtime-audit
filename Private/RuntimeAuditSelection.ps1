# =============================================================================
# RuntimeAuditSelection.ps1
# Quelles extractions on lance, et pourquoi on ne lance pas les autres.
#
# FONCTION PURE, ET C'EST DELIBERE.
#   Elle ne touche ni au disque, ni au reseau, ni a l'interface. Elle prend un
#   plan, une demande et ce que le pre-vol a observe, et rend une decision par
#   audit. Toute la logique de selection est donc testable sans serveur et sans
#   fenetre : la fenetre Windows Forms n'est qu'une coquille qui coche des cases
#   et appelle ceci.
#
#   Sans cette separation, l'interface deviendrait la seule partie non testable
#   du module, et c'est precisement la ou les erreurs se voient le moins.
#
# ELLE REND UNE LIGNE PAR AUDIT DU PLAN, y compris ceux qu'on ne lance pas.
#   C'est le principe de non-suppression silencieuse applique a l'extraction :
#   un audit qui disparait du compte rendu est le meme defaut qu'une execution
#   qui disparait du perimetre. Extractions.csv se construit directement sur
#   cette sortie.
#
# Regle du module : aucun caractere non-ASCII dans ce fichier.
# =============================================================================

function Select-RuntimeAuditExtraction {
    <#
    .SYNOPSIS
        Decide, pour chaque audit du plan, s'il est retenu et sinon pourquoi.

    .PARAMETER Plan
        Objet rendu par Read-RuntimeAuditPlan.

    .PARAMETER Cle
        Selection explicite. Les automatiques s'y ajoutent toujours.

    .PARAMETER Tout
        Retient tout ce que le logging observe permet.

    .PARAMETER LoggingObserve
        Niveaux REELLEMENT observes dans le catalogue, releves par le pre-vol.
        Vide ou absent : aucune contrainte n'est appliquee, et les
        conditionnelles suivent la demande. C'est le cas d'un appel hors ligne,
        typiquement un test.

    .OUTPUTS
        Une ligne par audit du plan : Cle, Nom, Nature, Sortie, Retenue,
        DemandeeExplicitement, Statut, Motif.

        Statut vaut Selectionnee, NonSelectionnee ou Indisponible. Les autres
        etats du contrat - ReussieAvecDonnees, ReussieVide, NonApplicable,
        VolumeExceedsLimit, Echec - sont poses plus tard, par le runner : ils
        dependent de ce que le serveur repond, pas de ce que l'operateur demande.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Plan,

        [Parameter(Mandatory = $false)]
        [string[]] $Cle,

        [Parameter(Mandatory = $false)]
        [switch] $Tout,

        [Parameter(Mandatory = $false)]
        [string[]] $LoggingObserve
    )

    # Une cle inconnue est une faute de frappe, pas une demande vide. La signaler
    # tout de suite evite un run qui produit silencieusement moins que demande.
    if ($Cle) {
        $connues = @($Plan.Audits | ForEach-Object { $_.Cle })
        $inconnues = @($Cle | Where-Object { $connues -notcontains $_ })
        if ($inconnues.Count -gt 0) {
            throw "Audit(s) inconnu(s) : $($inconnues -join ', '). Disponibles : $($connues -join ', ')."
        }
    }

    # Le meilleur niveau observe. Absent, on ne contraint rien : mieux vaut
    # tenter et rapporter un resultat vide que refuser sur une supposition.
    $rangObserve = $null
    if ($LoggingObserve -and $LoggingObserve.Count -gt 0) {
        $rangObserve = ($LoggingObserve | ForEach-Object { Get-RuntimeAuditRangLogging -Niveau $_ } | Measure-Object -Maximum).Maximum
    }

    $resultat = @()

    foreach ($audit in $Plan.Audits) {

        $rangRequis = Get-RuntimeAuditRangLogging -Niveau $audit.LoggingMinimal

        # DEMANDE EXPLICITE : une cle nommee dans -Cle, et rien d'autre.
        #
        # Ce drapeau existe pour que le verdict global sache distinguer deux
        # indisponibilites qui n'ont pas du tout le meme sens :
        #
        #   -Audit 'phases' sur un catalogue Basic  -> l'operateur a demande
        #       quelque chose qu'il n'a pas obtenu. Le run a echoue a tenir sa
        #       promesse, meme si aucune requete n'a plante.
        #
        #   -Tout sur un catalogue Basic            -> -Tout signifie "tout ce
        #       que le logging permet". Une conditionnelle absente est un
        #       constat de catalogue, pas un echec. Le traiter comme un echec
        #       rendrait -Tout inutilisable sur la majorite des parcs.
        #
        # Une automatique n'est jamais concernee : elle n'exige aucun logging,
        # donc elle ne peut pas tomber dans la branche d'indisponibilite.
        $explicite = [bool] ($Cle -and ($Cle -contains $audit.Cle))

        # --- disponibilite, qui prime sur la demande -------------------------
        if ($null -ne $rangObserve -and $rangRequis -gt $rangObserve) {
            $resultat += [PSCustomObject]@{
                Cle                   = $audit.Cle
                Nom                   = $audit.Nom
                Nature                = $audit.Nature
                Sortie                = $audit.Sortie
                Retenue               = $false
                DemandeeExplicitement = $explicite
                Statut                = 'Indisponible'
                Motif                 = "Exige le logging $($audit.LoggingMinimal) ; niveau le plus eleve observe : $(($LoggingObserve | Sort-Object -Unique) -join ', ')."
            }
            continue
        }

        # --- demande ----------------------------------------------------------
        # Une automatique n'est pas decochable : c'est le contexte sans lequel
        # les autres fichiers ne s'interpretent pas.
        $retenue = $false
        $motif   = ''

        if ($audit.Nature -eq 'Automatique') {
            $retenue = $true
            $motif   = 'Automatique, non decochable.'
        }
        elseif ($Tout) {
            $retenue = $true
            $motif   = 'Demandee par -Tout.'
        }
        elseif ($Cle) {
            if ($Cle -contains $audit.Cle) {
                $retenue = $true
                $motif   = 'Demandee explicitement.'
            }
            else {
                $motif = 'Hors de la selection demandee.'
            }
        }
        else {
            $retenue = $audit.SelectionParDefaut
            if ($retenue) { $motif = 'Selectionnee par defaut.' }
            else          { $motif = 'Decochee par defaut.' }
        }

        $resultat += [PSCustomObject]@{
            Cle                   = $audit.Cle
            Nom                   = $audit.Nom
            Nature                = $audit.Nature
            Sortie                = $audit.Sortie
            Retenue               = $retenue
            DemandeeExplicitement = $explicite
            Statut                = $(if ($retenue) { 'Selectionnee' } else { 'NonSelectionnee' })
            Motif                 = $motif
        }
    }

    return $resultat
}
