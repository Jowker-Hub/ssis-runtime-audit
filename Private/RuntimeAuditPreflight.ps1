# =============================================================================
# RuntimeAuditPreflight.ps1
# Ce qu'on constate AVANT d'extraire quoi que ce soit.
#
# TROIS ROLES, ET LE TROISIEME EST LE PLUS IMPORTANT
#
#   1. Fixer l'instant d'extraction, une seule fois pour toutes les requetes.
#   2. Relever ce que le catalogue permet : droits et niveaux de logging.
#   3. ESTIMER LE VOLUME PAR GRAIN, et refuser avant de lancer.
#
#   Le troisieme est la seule protection contre une extraction qui explose chez
#   un client. Mesure : les phases de composants valent 243 lignes par
#   execution. Une fenetre confortable pour les executions produit la un fichier
#   ingerable, et on ne s'en apercoit qu'apres avoir monopolise le serveur.
#
# LE REFUS EST EXPLICITE, JAMAIS UNE TRONCATURE
#   Ni les premieres lignes, ni les dernieres, ni un Top N packages. Un
#   echantillon ainsi biaise serait indistinguable d'une vraie distribution,
#   donc strictement pire qu'une extraction refusee.
#
# Regle du module : aucun caractere non-ASCII dans ce fichier.
# =============================================================================

function Invoke-RuntimeAuditPrevol {
    <#
    .SYNOPSIS
        Constate l'etat du catalogue et estime le volume de chaque extraction.

    .PARAMETER Decisions
        Sortie de Select-RuntimeAuditExtraction. Seules les extractions retenues
        sont estimees : inutile de chiffrer ce qu'on ne lancera pas.

    .OUTPUTS
        PSCustomObject : ExtractionTimestampUtc, NombreExecutions,
        NiveauxLogging, Droits, Estimations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlConnection] $Connexion,

        [Parameter(Mandatory = $true)]
        [object] $Plan,

        [Parameter(Mandatory = $false)]
        [object[]] $Decisions,

        [Parameter(Mandatory = $false)]
        [object] $DebutFenetre,

        [Parameter(Mandatory = $false)]
        [object] $FinFenetre,

        # Fenetre glissante en jours. Calculee ICI, a partir de l'heure SERVEUR,
        # et non par l'appelant a partir de la sienne : voir la note ci-dessous.
        [Parameter(Mandatory = $false)]
        [int] $JoursFenetre
    )

    # ------------------------------------------------- 1. l'instant de reference
    # LU SUR LE SERVEUR, ET SURTOUT PAS SUR LE POSTE.
    #
    # Toutes les heures du catalogue viennent du serveur. Si l'horloge du poste
    # d'audit avance de deux minutes, fermer une execution en cours sur l'heure
    # du poste donne une duree fausse ; si elle retarde, on obtient une duree
    # NEGATIVE. C'est une difference d'une ligne de code et d'un bug silencieux.
    $commande = $Connexion.CreateCommand()
    $commande.CommandText = 'SELECT SYSDATETIMEOFFSET() AS maintenant;'
    $instant = [DateTimeOffset] $commande.ExecuteScalar()

    # La fenetre glissante se calcule sur CE MEME INSTANT.
    #
    # L'orchestration la calculait auparavant depuis l'horloge du poste, alors
    # que l'instant d'extraction venait du serveur : deux references a quelques
    # secondes ou quelques minutes l'une de l'autre dans le meme run. "Les 30
    # derniers jours" ne designaient donc pas les memes 30 jours que ceux que
    # le serveur voit, et la borne se deplacait avec la derive de l'horloge du
    # poste d'audit.
    #
    # Tout ce qui se rapporte au temps dans ce module vient desormais de la meme
    # source : le serveur.
    if ($JoursFenetre -gt 0) {
        $DebutFenetre = $instant.AddDays(-$JoursFenetre)
    }

    # ------------------------------------------------------------ 2. les droits
    # Les vues du catalogue sont filtrees par permissions : un compte sans droit
    # recoit zero ligne, pas un refus. Constater les roles est donc la condition
    # de lecture de tout le reste.
    $commande = $Connexion.CreateCommand()
    $commande.CommandText = @'
SELECT CAST(ISNULL(IS_MEMBER(N'ssis_admin'), 0) AS int)     AS ssis_admin,
       CAST(ISNULL(IS_MEMBER(N'ssis_logreader'), 0) AS int) AS ssis_logreader,
       CASE WHEN IS_MEMBER(N'ssis_logreader') IS NULL THEN 1 ELSE 0 END AS logreader_absent,
       CAST(ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) AS int) AS sysadmin;
'@
    $lecteur = $commande.ExecuteReader()
    try {
        [void] $lecteur.Read()
        $droits = [PSCustomObject]@{
            SsisAdmin              = ([int] $lecteur['ssis_admin'] -eq 1)
            SsisLogreader          = ([int] $lecteur['ssis_logreader'] -eq 1)
            SsisLogreaderInexistant = ([int] $lecteur['logreader_absent'] -eq 1)
            Sysadmin               = ([int] $lecteur['sysadmin'] -eq 1)
        }
    }
    finally { $lecteur.Close() }

    # ------------------------------------- 3. le denominateur de l'estimation --
    # Le nombre d'executions DANS LA FENETRE. C'est lui qui multiplie chaque
    # facteur du plan. La fenetre est semi-ouverte, comme dans les extractions.
    # Le compte est ventile PAR NIVEAU DE LOGGING, et ce n'est pas un raffinement.
    #
    # Mesure qui l'impose : les phases de composants valent 243 lignes par
    # execution, mais SEULEMENT pour une execution lancee en Performance. Sur un
    # catalogue de 43 executions dont 6 seulement a ce niveau, multiplier par 43
    # donnait 20 898 lignes estimees contre 2 916 reelles - sept fois trop.
    #
    # Une extraction parfaitement realisable aurait ete refusee pour volume.
    # Le denominateur correct est le nombre d'executions dont le niveau de
    # logging ATTEINT le minimum exige par l'extraction.
    $commande = $Connexion.CreateCommand()
    $commande.CommandText = @'
SELECT ISNULL(CONVERT(int, p.parameter_value), 0) AS niveau, COUNT_BIG(*) AS nb
FROM SSISDB.[catalog].executions AS e
LEFT JOIN SSISDB.[catalog].execution_parameter_values AS p
       ON p.execution_id = e.execution_id
      AND p.object_type = 50
      AND p.parameter_name = N'LOGGING_LEVEL'
WHERE e.start_time IS NOT NULL
  AND (@DebutFenetre IS NULL OR e.start_time >= @DebutFenetre)
  AND (@FinFenetre   IS NULL OR e.start_time <  @FinFenetre)
GROUP BY ISNULL(CONVERT(int, p.parameter_value), 0);
'@
    foreach ($n in 'DebutFenetre', 'FinFenetre') {
        $p = $commande.Parameters.Add(
            (New-Object System.Data.SqlClient.SqlParameter("@$n", [System.Data.SqlDbType]::DateTimeOffset)))
        $valeur = if ($n -eq 'DebutFenetre') { $DebutFenetre } else { $FinFenetre }
        if ($null -eq $valeur) { $p.Value = [System.DBNull]::Value } else { $p.Value = $valeur }
    }

    $parNiveau = @{}
    $lecteur = $commande.ExecuteReader()
    try {
        while ($lecteur.Read()) { $parNiveau[[int] $lecteur['niveau']] = [long] $lecteur['nb'] }
    }
    finally { $lecteur.Close() }

    $nbExecutions = 0L
    foreach ($v in $parNiveau.Values) { $nbExecutions += $v }

    # -------------------------------- 4. la disponibilite et les estimations --
    # LE CALCUL EST DEHORS, DANS RuntimeAuditEstimation.ps1, ET C'EST LE POINT.
    #
    # Il vivait ici, entre deux appels SQL, donc intestable sans serveur. Il
    # s'est trompe deux fois dans la meme journee sur le meme facteur, x7 puis
    # x2, et dans les deux cas la consequence etait de REFUSER une extraction
    # parfaitement realisable.
    #
    # Le pre-vol ne fait donc plus qu'une chose ici : fournir des comptes deja
    # bornes par la fenetre. Le calcul, lui, se verifie sur des comptes connus
    # et sans serveur.
    $niveaux = @(Get-RuntimeAuditNiveauxObserves -ExecutionsParNiveau $parNiveau)

    $estimations = @(Get-RuntimeAuditEstimation -Plan $Plan `
                        -ExecutionsParNiveau $parNiveau -Decisions $Decisions)

    return [PSCustomObject]@{
        ExtractionTimestampUtc = $instant
        # Borne EFFECTIVE de la fenetre, calculee sur l'heure serveur. C'est elle
        # que l'appelant doit lier aux requetes, jamais une valeur qu'il aurait
        # calculee de son cote.
        DebutFenetre           = $DebutFenetre
        NombreExecutions       = $nbExecutions
        NiveauxLogging         = $niveaux
        Droits                 = $droits
        Estimations            = $estimations
    }
}
