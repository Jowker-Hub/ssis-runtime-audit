# =============================================================================
# Invoke-AuditPlanifie.ps1
# Point d'entree pour une execution PLANIFIEE : Agent SQL, tache planifiee,
# chaine d'integration. C'est lui qu'on appelle, jamais la fonction du module.
#
# POURQUOI CE SCRIPT EXISTE : LE CODE DE SORTIE
#
#   Invoke-SsisRuntimeAudit signale un run incomplet par Write-Error. C'est le
#   bon signal pour un operateur devant sa console : le message s'affiche en
#   rouge, $? passe a faux, -ErrorAction Stop le transforme en exception.
#
#   MAIS LE PROCESSUS SORT QUAND MEME AVEC LE CODE 0. Mesure faite :
#
#       Write-Error suivi du retour d'un objet  -> code processus 0
#       exit 7                                  -> code processus 7
#
#   Un pas de travail de l'Agent SQL ne lit ni la console ni $?. Il lit le code
#   de sortie. Une collecte a moitie faite serait donc rapportee comme reussie,
#   nuit apres nuit, sans que personne ne le voie. C'est exactement la famille
#   de defauts que ce projet traque : un echec qui ne fait aucun bruit.
#
# POURQUOI LE MODULE N'APPELLE PAS exit LUI-MEME
#   exit dans une fonction de module termine le PROCESSUS HOTE. Appelee depuis
#   une console, l'audit fermerait la console de l'operateur ; appelee depuis un
#   script plus large, il en tuerait la suite. Le code de sortie est une
#   propriete du programme, pas de la fonction : il appartient a l'enveloppe.
#
# CODES RENDUS
#   0  collecte complete
#   1  collecte incomplete, ou echec avant meme de commencer
#
#   Deux codes suffisent : l'Agent ne sait qu'une chose, reussi ou non. Le
#   detail, extraction par extraction, est dans Extractions.csv du dossier du
#   run, qui est toujours ecrit, meme en cas d'echec partiel.
#
# EXEMPLE - pas de travail de type PowerShell dans l'Agent SQL
#   & "D:\Outils\SsisRuntimeAudit\Invoke-AuditPlanifie.ps1" `
#         -Serveur 'SRV-ETL-01' -Sortie 'D:\Audit\SRV-ETL-01' -Jours 30 -Tout
#
# Regle du module : aucun caractere non-ASCII dans ce fichier.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Serveur,

    [Parameter(Mandatory = $true)]
    [string] $Sortie,

    [Parameter(Mandatory = $false)]
    [string[]] $Audit,

    [Parameter(Mandatory = $false)]
    [switch] $Tout,

    [Parameter(Mandatory = $false)]
    [int] $Jours,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential] $Identifiants
)

try {
    Import-Module (Join-Path $PSScriptRoot 'SsisRuntimeAudit.psd1') -Force -ErrorAction Stop

    $parametres = @{
        Serveur     = $Serveur
        Sortie      = $Sortie
        # JAMAIS d'interface dans un contexte planifie. Sans ce commutateur, un
        # appel a qui il manque un parametre ouvrirait une fenetre Windows Forms
        # sur une session sans bureau : le pas de travail resterait bloque
        # jusqu'au delai d'attente, sans rien produire et sans rien dire.
        SansFenetre = $true
        ErrorAction = 'Stop'
    }
    if ($Audit)        { $parametres['Audit']        = $Audit }
    if ($Tout)         { $parametres['Tout']         = $true }
    if ($Jours -gt 0)  { $parametres['Jours']        = $Jours }
    if ($Identifiants) { $parametres['Identifiants'] = $Identifiants }

    $resultat = Invoke-SsisRuntimeAudit @parametres

    if ($null -eq $resultat) {
        Write-Error 'Aucun resultat rendu par la collecte.'
        exit 1
    }

    Write-Output "Dossier du run : $($resultat.DossierSortie)"

    # Le detail va sur la sortie standard : l'Agent SQL la conserve dans
    # l'historique du pas de travail, et c'est souvent tout ce dont on dispose
    # pour comprendre un echec de la nuit.
    foreach ($ligne in $resultat.Extractions) {
        Write-Output ("  {0,-12} {1,-20} {2}" -f $ligne.Cle, $ligne.Statut, $ligne.Message)
    }

    if (-not $resultat.Succes) {
        Write-Error 'Collecte incomplete : voir Extractions.csv dans le dossier du run.'
        exit 1
    }

    exit 0
}
catch {
    # -ErrorAction Stop fait remonter ici l'erreur non bloquante du module aussi
    # bien qu'une exception franche. Les deux valent 1 : pour l'ordonnanceur, la
    # seule question est de savoir si la collecte est exploitable.
    Write-Error $_
    exit 1
}
