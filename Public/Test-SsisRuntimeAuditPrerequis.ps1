function Test-SsisRuntimeAuditPrerequis {
<#
.SYNOPSIS
    Verifie que le poste peut collecter ET analyser, avant de commencer.

.DESCRIPTION
    Rend un constat par prerequis, avec ce qu'il faut faire quand il n'est pas
    tenu. Aucun controle ne modifie quoi que ce soit.

    POURQUOI CE CONTROLE EXISTE
      Les deux blocages rencontres sur ce projet ne disaient pas ce qui se
      passait. Un .ps1 double-clique s'ouvre dans le bloc-notes ; et Power BI
      Desktop, devant un rapport au format PBIR qu'il ne sait pas lire, affiche
      une fenetre vide avec un dialogue derriere - le moteur ne demarre jamais,
      et rien a l'ecran ne relie la cause a l'effet.

      Un prerequis qu'on decouvre en butant dessus coute une demi-journee. Le
      meme, annonce avant, coute une phrase.

    TROIS NIVEAUX, ET LA DIFFERENCE COMPTE
      Bloquant      la collecte ou l'analyse ne peut pas aboutir.
      Avertissement elle aboutira, mais quelque chose merite d'etre su.
      OK            rien a signaler.

.PARAMETER Silencieux
    N'affiche rien, rend seulement les constats. Pour un appel par script.

.OUTPUTS
    PSCustomObject : Bloquants, Avertissements, Constats.

.EXAMPLE
    Test-SsisRuntimeAuditPrerequis

    Affiche le tableau des prerequis.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch] $Silencieux
    )

    $constats = @()

    function Add-Constat {
        param([string] $Domaine, [string] $Statut, [string] $Constat, [string] $QuoiFaire = '')
        $script:resultat += [PSCustomObject]@{
            Domaine   = $Domaine
            Statut    = $Statut
            Constat   = $Constat
            QuoiFaire = $QuoiFaire
        }
    }

    $script:resultat = @()

    # ------------------------------------------------------------ PowerShell
    $v = $PSVersionTable.PSVersion
    if ($v.Major -ge 5) {
        Add-Constat 'PowerShell' 'OK' "Version $v."
    }
    else {
        Add-Constat 'PowerShell' 'Bloquant' "Version $v, trop ancienne." `
            'Le module exige PowerShell 5.1, livre avec Windows depuis 2016.'
    }

    # ----------------------------------------------------- Acces aux donnees
    # System.Data.SqlClient vient du .NET Framework : rien a installer. Le
    # controle existe pour distinguer une absence de pilote d'un probleme de
    # reseau ou de droits, qui se ressemblent dans les messages d'erreur.
    try {
        [void][System.Data.SqlClient.SqlConnection]
        Add-Constat 'Acces SQL' 'OK' 'Le pilote SqlClient est disponible.'
    }
    catch {
        Add-Constat 'Acces SQL' 'Bloquant' 'Le pilote SqlClient est introuvable.' `
            'Installer le .NET Framework 4.7.2 ou superieur.'
    }

    # ------------------------------------------------------ Dossier de sortie
    $dossier = $script:DossierSortieParDefaut
    try {
        if (-not (Test-Path -LiteralPath $dossier)) {
            [void] (New-Item -Path $dossier -ItemType Directory -Force -ErrorAction Stop)
        }
        $temoin = Join-Path $dossier ('.ecriture_' + [guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::WriteAllText($temoin, 'test')
        Remove-Item -LiteralPath $temoin -Force
        Add-Constat 'Dossier de collecte' 'OK' "$dossier accessible en ecriture."
    }
    catch {
        Add-Constat 'Dossier de collecte' 'Bloquant' "$dossier inaccessible en ecriture." `
            'Choisir un autre dossier dans la fenetre, ou demander les droits sur celui-ci.'
    }

    # --------------------------------------------------- Power BI Desktop ---
    # LE CONTROLE LE PLUS UTILE DES DEUX, ET LE MOINS EVIDENT.
    #
    # Le rapport est au format PBIR - un dossier par page, un fichier par
    # visuel. Une version trop ancienne de Desktop le refuse avec le message
    # "Report is using the PBIR format. Please enable the preview feature
    # 'Store reports using enhanced metadata format'", DERRIERE une fenetre
    # principale restee vide. Sans ce controle, on croit a un plantage.
    #
    # LE SEUIL EST DONNE PAR LA MESURE, PAS PAR LA DOCUMENTATION :
    #   2.143.1204  refuse                        (constate)
    #   2.157.1354  ouvre sans rien regler        (constate)
    # La frontiere exacte entre les deux n'est pas connue. On avertit donc en
    # dessous de la version connue pour fonctionner, en le disant.
    $VersionPowerBiConnueBonne = [version] '2.157.1354.0'

    $installations = @()

    $chemin = 'C:\Program Files\Microsoft Power BI Desktop\bin\PBIDesktop.exe'
    if (Test-Path -LiteralPath $chemin) {
        $installations += [PSCustomObject]@{
            Origine = 'Program Files'
            Version = [version] ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($chemin).FileVersion)
            Chemin  = $chemin
        }
    }

    try {
        $store = Get-AppxPackage -Name '*PowerBIDesktop*' -ErrorAction SilentlyContinue
        foreach ($s in @($store)) {
            if ($s) {
                $installations += [PSCustomObject]@{
                    Origine = 'Microsoft Store'
                    Version = [version] $s.Version
                    Chemin  = $s.InstallLocation
                }
            }
        }
    }
    catch { }

    if ($installations.Count -eq 0) {
        Add-Constat 'Power BI Desktop' 'Avertissement' 'Aucune installation detectee.' `
            ('La collecte fonctionne sans lui. Le rapport, non : installer Power BI Desktop ' +
             "version $VersionPowerBiConnueBonne ou superieure.")
    }
    else {
        $meilleure = ($installations | Sort-Object Version -Descending)[0]

        if ($meilleure.Version -ge $VersionPowerBiConnueBonne) {
            Add-Constat 'Power BI Desktop' 'OK' `
                "Version $($meilleure.Version) ($($meilleure.Origine)) : lit le format du rapport."
        }
        else {
            Add-Constat 'Power BI Desktop' 'Avertissement' `
                "Version $($meilleure.Version) ($($meilleure.Origine)), anterieure a $VersionPowerBiConnueBonne." `
                ('Le rapport est au format PBIR. Une version trop ancienne affiche une fenetre ' +
                 "vide et n'ouvre jamais le modele. Mettre a jour Power BI Desktop, ou activer " +
                 "l'option Fichier > Options > Preversion > Store reports using enhanced metadata format.")
        }

        # L'ASSOCIATION DES .pbip PEUT DESIGNER UNE AUTRE INSTALLATION QUE LA
        # MEILLEURE. Mesure faite sur le poste de developpement : deux versions
        # cohabitent, et le double-clic tombait sur l'ancienne - celle qui
        # refuse. Le constat est separe parce que la reponse l'est aussi :
        # ouvrir le projet depuis la bonne version, plutot que de double-cliquer.
        if ($installations.Count -gt 1) {
            $associee = $null
            try {
                $cle = 'Registry::HKEY_CLASSES_ROOT\PowerBI.Project\shell\open\command'
                if (Test-Path $cle) {
                    $cmd = (Get-ItemProperty $cle).'(default)'
                    if ($cmd -match '"([^"]+PBIDesktop\.exe)"') {
                        $exe = $Matches[1]
                        if (Test-Path -LiteralPath $exe) {
                            $associee = [version] ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion)
                        }
                    }
                }
            }
            catch { }

            if ($associee -and $associee -lt $VersionPowerBiConnueBonne) {
                Add-Constat 'Power BI Desktop' 'Avertissement' `
                    ("Le double-clic sur le projet ouvre la version $associee, " +
                     "alors que la version $($meilleure.Version) est installee.") `
                    ('Ouvrir le projet depuis la version recente : la lancer, puis Fichier > Ouvrir.')
            }
        }
    }

    $constats      = $script:resultat
    $bloquants     = @($constats | Where-Object { $_.Statut -eq 'Bloquant' })
    $avertissements = @($constats | Where-Object { $_.Statut -eq 'Avertissement' })

    if (-not $Silencieux) {
        Write-Host ''
        Write-Host '  Prerequis' -ForegroundColor Cyan
        Write-Host '  ---------'
        foreach ($c in $constats) {
            $couleur = switch ($c.Statut) {
                'OK'            { 'Green' }
                'Avertissement' { 'Yellow' }
                default         { 'Red' }
            }
            Write-Host ('  {0,-14} ' -f $c.Statut) -ForegroundColor $couleur -NoNewline
            Write-Host ('{0,-20} {1}' -f $c.Domaine, $c.Constat)
            if ($c.QuoiFaire) {
                Write-Host ('                 {0,-20} -> {1}' -f '', $c.QuoiFaire) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
    }

    return [PSCustomObject]@{
        Bloquants      = $bloquants.Count
        Avertissements = $avertissements.Count
        Constats       = $constats
    }
}
