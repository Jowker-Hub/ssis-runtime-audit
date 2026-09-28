<#
    SsisRuntimeAudit - chargeur du module.

    Dot-source Private\ AVANT Public\ : les fonctions publiques appellent les
    helpers des leur definition. L'ordre inverse fonctionnerait en pratique,
    PowerShell ne resolvant les appels qu'a l'execution, mais il masquerait un
    helper manquant jusqu'au premier run chez un client. On veut l'erreur a
    l'import.

    Seules les fonctions de Public\ sont exportees. Un helper reste interne :
    c'est ce qui permet de le renommer sans casser d'usage externe.

    Convention reprise du SSIS Toolkit voisin : AUCUN CARACTERE NON-ASCII dans
    le code .ps1. Motif verifie sous 5.1 : un fichier sans BOM est lu en ANSI et
    les accents y eclatent en deux caracteres. Les libelles francais destines a
    l'affichage vivent dans sql\plan.psd1, qui porte un BOM pour cette raison.
#>

$ErrorActionPreference = 'Stop'

# DOSSIER DE COLLECTE PAR DEFAUT.
#
# Cette valeur est le point de rendez-vous des deux moities de l'outil : le
# runner y depose ses sous-dossiers Run_..., et le parametre DossierBase du
# modele semantique Power BI y pointe. Lancer l'audit puis actualiser le
# rapport suffit alors, sans rien regler.
#
# LA CHANGER ICI OBLIGE A LA CHANGER DANS LE MODELE, et inversement. Les deux
# endroits sont cites l'un dans l'autre pour qu'on ne puisse pas en modifier un
# seul sans voir l'autre.
#
# Le chemin est volontairement hors profil utilisateur : un chemin sous
# C:\Users\<login> serait propre a un poste, et l'outil doit pouvoir etre
# installe sur un serveur de rebond ou un poste partage.
$script:DossierSortieParDefaut = 'C:\Audit\SsisRuntimeAudit'

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Echec du chargement de $($file.Name) : $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function $public.BaseName
