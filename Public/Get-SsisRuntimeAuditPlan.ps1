function Get-SsisRuntimeAuditPlan {
<#
.SYNOPSIS
    Lit et valide le contrat des extractions, et dit ce que l'outil sait faire.

.DESCRIPTION
    Repond a la question "qu'est-ce que cet outil sait extraire", sans serveur et
    sans rien ecrire. C'est une question legitime en dehors de tout audit, et
    c'est aussi le moyen de verifier qu'un plan est valide avant de partir chez
    un client.

    La validation est stricte et leve a la premiere faute : cle ou sortie en
    double, fichier .sql introuvable, Nature ou LoggingMinimal hors liste,
    parametre inconnu, ou extraction bornee sans facteur d'estimation.

    LECTURE SEULE : rien n'est ecrit, aucune connexion n'est ouverte.

.PARAMETER CheminSql
    Dossier sql\ du module. Par defaut celui livre avec le module.

.PARAMETER LoggingObserve
    Niveaux de logging observes dans un catalogue, pour simuler ce que le
    pre-vol deciderait. Sans ce parametre, aucune contrainte n'est appliquee.

.EXAMPLE
    Get-SsisRuntimeAuditPlan

    Liste les extractions disponibles et leur etat de selection par defaut.

.EXAMPLE
    Get-SsisRuntimeAuditPlan -LoggingObserve 'Basic'

    Montre ce qui serait lance sur un parc entierement en Basic : les deux
    extractions conditionnelles ressortent Indisponible, avec leur motif.

.OUTPUTS
    Une ligne par audit du plan, y compris ceux qui ne seraient pas lances.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $CheminSql,

        [Parameter(Mandatory = $false)]
        [string[]] $LoggingObserve
    )

    if ([string]::IsNullOrEmpty($CheminSql)) {
        $CheminSql = Join-Path -Path $PSScriptRoot -ChildPath '..\sql'
    }

    $plan = Read-RuntimeAuditPlan -CheminSql $CheminSql

    Write-Verbose ("Plan version {0}, {1} audit(s), depuis {2}" -f $plan.Version, $plan.Audits.Count, $plan.CheminSql)

    $decisions = Select-RuntimeAuditExtraction -Plan $plan -LoggingObserve $LoggingObserve

    # On rend le plan enrichi de la decision, pas seulement la decision : c'est
    # ce qui permet d'afficher grain, logging requis et limite sans relire le
    # fichier.
    foreach ($audit in $plan.Audits) {
        $d = $decisions | Where-Object { $_.Cle -eq $audit.Cle } | Select-Object -First 1

        [PSCustomObject]@{
            Cle                   = $audit.Cle
            Nom                   = $audit.Nom
            Description           = $audit.Description
            Nature                = $audit.Nature
            LoggingMinimal        = $audit.LoggingMinimal
            Grain                 = $audit.Grain
            Sortie                = $audit.Sortie
            Familles              = $audit.Familles
            Parametres            = $audit.Parametres
            LignesParExecution    = $audit.LignesParExecution
            LimiteLignesParDefaut = $audit.LimiteLignesParDefaut
            Statut                = $d.Statut
            Motif                 = $d.Motif
        }
    }
}
