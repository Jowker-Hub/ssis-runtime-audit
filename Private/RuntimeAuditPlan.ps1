# =============================================================================
# RuntimeAuditPlan.ps1
# Lecture et validation du contrat des extractions.
#
# Un plan invalide doit echouer A L'OUVERTURE, jamais au milieu d'un run chez un
# client : l'acces client est une ressource rare, et decouvrir qu'un fichier .sql
# manque apres trois extractions gache la session.
#
# Regle du module : aucun caractere non-ASCII dans ce fichier.
# =============================================================================

# Valeurs admises. Listes FERMEES : une valeur hors liste est une faute de frappe
# dans le plan, pas une extension silencieuse du vocabulaire.
$script:RuntimeAuditNatures    = @('Automatique', 'Fondamentale', 'Conditionnelle')
$script:RuntimeAuditLoggings   = @('Aucun', 'Basic', 'Performance', 'Verbose')
$script:RuntimeAuditParametres = @('ExtractionTimestampUtc', 'DebutFenetre', 'FinFenetre')

# Ordre des niveaux de logging. Un audit exigeant Performance est servi par
# Performance comme par Verbose : c'est un plancher, pas une egalite.
$script:RuntimeAuditRangLogging = @{
    'Aucun'       = 0
    'Basic'       = 1
    'Performance' = 2
    'Verbose'     = 3
}

function Get-RuntimeAuditRangLogging {
    <#
    .SYNOPSIS
        Rang numerique d'un niveau de logging, -1 si inconnu.
    #>
    [CmdletBinding()]
    param([string] $Niveau)

    if ([string]::IsNullOrWhiteSpace($Niveau)) { return -1 }
    if ($script:RuntimeAuditRangLogging.ContainsKey($Niveau)) {
        return $script:RuntimeAuditRangLogging[$Niveau]
    }
    return -1
}

function Read-RuntimeAuditPlan {
    <#
    .SYNOPSIS
        Lit sql\plan.psd1 et valide son contenu. Leve a la premiere faute.

    .PARAMETER CheminSql
        Dossier sql\ contenant plan.psd1 et les requetes.

    .OUTPUTS
        PSCustomObject : Version, CheminSql, Audits (tableau enrichi de CheminComplet).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $CheminSql
    )

    if (-not (Test-Path -LiteralPath $CheminSql)) {
        throw "Dossier sql introuvable : $CheminSql"
    }
    $CheminSql = (Resolve-Path -LiteralPath $CheminSql).ProviderPath

    $fichierPlan = Join-Path -Path $CheminSql -ChildPath 'plan.psd1'
    if (-not (Test-Path -LiteralPath $fichierPlan)) {
        throw "Plan introuvable : $fichierPlan"
    }

    try {
        $brut = Import-PowerShellDataFile -LiteralPath $fichierPlan
    }
    catch {
        throw "Plan illisible : $($_.Exception.Message)"
    }

    if (-not $brut.ContainsKey('Audits') -or $null -eq $brut.Audits) {
        throw "Plan invalide : aucune cle 'Audits'."
    }

    $obligatoires = @(
        'Cle', 'Nom', 'Description', 'Fichier', 'Sortie',
        'Nature', 'LoggingMinimal', 'SelectionParDefaut', 'Grain', 'Parametres'
    )

    $audits = @()
    $index  = 0

    foreach ($a in @($brut.Audits)) {
        $index++
        $etiquette = "audit #$index"
        if ($a.ContainsKey('Cle') -and $a.Cle) { $etiquette = "audit '$($a.Cle)'" }

        foreach ($champ in $obligatoires) {
            if (-not $a.ContainsKey($champ)) {
                throw "Plan invalide : champ '$champ' manquant sur $etiquette."
            }
        }

        if ($script:RuntimeAuditNatures -notcontains $a.Nature) {
            throw "Plan invalide : Nature '$($a.Nature)' inconnue sur $etiquette. Attendu : $($script:RuntimeAuditNatures -join ', ')."
        }
        if ($script:RuntimeAuditLoggings -notcontains $a.LoggingMinimal) {
            throw "Plan invalide : LoggingMinimal '$($a.LoggingMinimal)' inconnu sur $etiquette. Attendu : $($script:RuntimeAuditLoggings -join ', ')."
        }

        foreach ($p in @($a.Parametres)) {
            if ($script:RuntimeAuditParametres -notcontains $p) {
                throw "Plan invalide : parametre '$p' inconnu sur $etiquette. Attendu : $($script:RuntimeAuditParametres -join ', ')."
            }
        }

        $cheminComplet = Join-Path -Path $CheminSql -ChildPath $a.Fichier
        if (-not (Test-Path -LiteralPath $cheminComplet)) {
            throw "Plan invalide : fichier introuvable pour $etiquette : $cheminComplet"
        }

        $limite = $null
        if ($a.ContainsKey('LimiteLignesParDefaut')) { $limite = $a.LimiteLignesParDefaut }
        $facteur = $null
        if ($a.ContainsKey('LignesParExecution')) { $facteur = $a.LignesParExecution }

        # Une extraction dynamique sans facteur d'estimation ne pourrait pas etre
        # bornee : le pre-vol n'aurait rien a estimer, et le refus explicite
        # deviendrait impossible. On l'interdit plutot que de la laisser passer.
        if ($null -ne $limite -and $null -eq $facteur) {
            throw "Plan invalide : $etiquette porte une limite mais aucun LignesParExecution. Le pre-vol ne pourrait rien estimer."
        }

        $audits += [PSCustomObject]@{
            Cle                   = [string] $a.Cle
            Nom                   = [string] $a.Nom
            Description           = [string] $a.Description
            Fichier               = [string] $a.Fichier
            CheminComplet         = $cheminComplet
            Sortie                = [string] $a.Sortie
            Nature                = [string] $a.Nature
            LoggingMinimal        = [string] $a.LoggingMinimal
            SelectionParDefaut    = [bool] $a.SelectionParDefaut
            Grain                 = [string] $a.Grain
            Familles              = @($a.Familles)
            Parametres            = @($a.Parametres)
            LignesParExecution    = $facteur
            LimiteLignesParDefaut = $limite
        }
    }

    if ($audits.Count -eq 0) {
        throw "Plan invalide : aucun audit declare."
    }

    # Unicite. Une cle dupliquee rendrait -Audit ambigu ; une sortie dupliquee
    # ferait qu'une extraction ecrase silencieusement une autre.
    $clesDoublons = $audits | Group-Object -Property Cle | Where-Object { $_.Count -gt 1 }
    if ($clesDoublons) {
        throw "Plan invalide : cle(s) en double : $(($clesDoublons | ForEach-Object { $_.Name }) -join ', ')."
    }
    $sortiesDoublons = $audits | Group-Object -Property Sortie | Where-Object { $_.Count -gt 1 }
    if ($sortiesDoublons) {
        throw "Plan invalide : sortie(s) en double : $(($sortiesDoublons | ForEach-Object { $_.Name }) -join ', ')."
    }

    $version = 0
    if ($brut.ContainsKey('Version')) { $version = [int] $brut.Version }

    return [PSCustomObject]@{
        Version   = $version
        CheminSql = $CheminSql
        Audits    = $audits
    }
}

function Get-RuntimeAuditVersionModule {
    <#
    .SYNOPSIS
        Version declaree au manifeste, pour la colonne du meme nom dans Run.csv.

    .DESCRIPTION
        Lue au manifeste plutot que codee en dur : un seul endroit a mettre a
        jour lors d'une livraison. Un chiffre sans la version de l'outil qui l'a
        produit n'est pas reproductible.
    #>
    [CmdletBinding()]
    param()

    $manifeste = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'SsisRuntimeAudit.psd1'
    if (-not (Test-Path -LiteralPath $manifeste)) { return '' }
    try   { return (Import-PowerShellDataFile -LiteralPath $manifeste).ModuleVersion }
    catch { return '' }
}
