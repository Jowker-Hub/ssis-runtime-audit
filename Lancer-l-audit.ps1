# =============================================================================
# Lancer-l-audit.ps1
# Ce que fait le double-clic sur Lancer-l-audit.cmd.
#
# La logique vit ici plutot que dans le .cmd : un script PowerShell se relit,
# se corrige et se teste, une ligne de commande batch de six cents caracteres,
# non.
#
# L'ENCHAINEMENT
#   1. Verifier les prerequis, et s'arreter si l'un d'eux est bloquant.
#   2. Ouvrir la fenetre de selection.
#   3. Dire ou sont les fichiers, et quoi faire ensuite.
#
# Le point 1 est la raison d'etre de ce script. Les deux blocages rencontres
# pendant la mise au point ne disaient pas ce qui se passait : un prerequis
# qu'on decouvre en butant dessus coute une demi-journee ; annonce avant, il
# coute une phrase.
#
# Regle du module : aucun caractere non-ASCII dans ce fichier.
# =============================================================================

[CmdletBinding()]
param(
    # Enchaine sans poser de question, meme en cas d'avertissement.
    [Parameter(Mandatory = $false)]
    [switch] $SansConfirmation
)

$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'SsisRuntimeAudit.psd1') -Force -ErrorAction Stop
}
catch {
    Write-Host ''
    Write-Host "  Le module n'a pas pu etre charge : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    return
}

Write-Host ''
Write-Host '  SSIS Runtime Audit' -ForegroundColor Cyan
Write-Host '  Collecte des temps d''execution depuis le catalogue SSISDB.'

$prerequis = Test-SsisRuntimeAuditPrerequis

if ($prerequis.Bloquants -gt 0) {
    Write-Host '  Impossible de continuer : voir les lignes en rouge ci-dessus.' -ForegroundColor Red
    Write-Host ''
    return
}

# UN AVERTISSEMENT N'ARRETE PAS, MAIS IL SE LIT.
#   Il signale ce qui marchera quand meme, et ce qui coincera plus tard - une
#   version de Power BI qui ne saura pas ouvrir le rapport, typiquement. La
#   collecte, elle, aboutira : rien ne justifie de la refuser.
if ($prerequis.Avertissements -gt 0 -and -not $SansConfirmation) {
    $reponse = Read-Host '  Continuer malgre les avertissements ? (O/n)'
    if ($reponse -and $reponse.Trim().ToLower() -notin @('o', 'oui', 'y', 'yes')) {
        Write-Host '  Interrompu.' -ForegroundColor Yellow
        Write-Host ''
        return
    }
}

try {
    $resultat = Invoke-SsisRuntimeAudit

    if ($null -eq $resultat) {
        Write-Host ''
        Write-Host '  Audit annule.' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    Write-Host ''
    if ($resultat.Succes) {
        Write-Host "  Collecte terminee : $($resultat.DossierSortie)" -ForegroundColor Green
    }
    else {
        Write-Host '  Collecte incomplete.' -ForegroundColor Yellow
        Write-Host '  Le detail, extraction par extraction, est dans Extractions.csv du dossier ci-dessous.'
        Write-Host "  $($resultat.DossierSortie)"
    }

    # CE QUI SUIT EST LA MOITIE DU TRAVAIL, ET PERSONNE NE LE DEVINE.
    #   Les CSV ne servent a rien tant qu'on ne les a pas ouverts. Le rapport
    #   pointe deja sur ce dossier : il ne reste qu'a actualiser.
    Write-Host ''
    Write-Host '  Pour lire les resultats :' -ForegroundColor Cyan
    Write-Host '    1. ouvrir powerbi\SsisRuntimeAudit.pbip dans Power BI Desktop'
    Write-Host '    2. cliquer Actualiser'
    Write-Host ''
    Write-Host '  Le rapport lit deja ce dossier : il n''y a aucun parametre a regler.'
}
catch {
    Write-Host ''
    Write-Host "  Echec : $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ''
