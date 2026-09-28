# =============================================================================
# RuntimeAuditEstimation.ps1
# Combien de lignes chaque extraction va produire, et laquelle depasse sa limite.
#
# FONCTION PURE, ET ELLE L'EST DEVENUE POUR UNE RAISON PRECISE.
#
#   Ce calcul vivait a l'interieur du pre-vol, entre deux appels SQL. Il etait
#   donc intestable sans serveur, et il s'est trompe DEUX FOIS dans la meme
#   journee, sur le meme facteur :
#
#     x7  en multipliant le facteur par TOUTES les executions de la fenetre, au
#         lieu des seules executions dont le logging atteint le niveau exige.
#         20 898 lignes estimees contre 2 916 reelles.
#
#     x2  en divisant 1 458 lignes mesurees par les 3 executions lancees en
#         Performance, alors que les 3 lancees en Verbose produisent aussi des
#         phases. Verbose est AU-DESSUS de Performance : le facteur se derive
#         toujours des executions qui ATTEIGNENT le niveau, jamais d'un
#         sous-ensemble.
#
#   Les deux fois, la consequence etait la meme et elle est grave : une
#   extraction parfaitement realisable refusee pour volume. L'outil se protege
#   alors contre un danger imaginaire et prive l'analyse de sa matiere.
#
#   Verifier que le plan PORTE un facteur n'attrape aucune de ces deux erreurs.
#   Seul un calcul isole, nourri de comptes connus, les attrape.
#
# CE QU'ELLE NE FAIT PAS
#   Elle ne refuse rien. Elle constate un depassement ; c'est l'orchestration
#   qui en tire un statut et n'ecrit aucun fichier. Le refus reste explicite,
#   jamais une troncature : un echantillon biaise serait indistinguable d'une
#   vraie distribution, donc strictement pire qu'une extraction refusee.
#
# Regle du module : aucun caractere non-ASCII dans ce fichier.
# =============================================================================

function Get-RuntimeAuditEstimation {
    <#
    .SYNOPSIS
        Estime le volume de chaque extraction du plan, sans toucher au serveur.

    .PARAMETER Plan
        Objet rendu par Read-RuntimeAuditPlan.

    .PARAMETER ExecutionsParNiveau
        Table de hachage niveau (0 a 3) -> nombre d'executions DANS LA FENETRE.
        C'est le seul intrant chiffre, et il doit deja etre borne : une fenetre
        differente donne une autre estimation, pas un autre calcul.

    .PARAMETER Decisions
        Sortie de Select-RuntimeAuditExtraction. Absente, tout est considere
        comme retenu : on estime alors le plan complet.

    .OUTPUTS
        Une ligne par audit : Cle, Nom, Retenue, LignesEstimees, Limite,
        Depassement, Motif.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Plan,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable] $ExecutionsParNiveau,

        [Parameter(Mandatory = $false)]
        [object[]] $Decisions
    )

    # LE DENOMINATEUR : combien d'executions atteignent AU MOINS un niveau.
    # Le logging minimal d'une extraction est un plancher, pas une egalite.
    # C'est cette seule ligne qui manquait lors de l'erreur x7.
    $auMoins = {
        param([int] $rang)
        $total = 0L
        foreach ($cle in $ExecutionsParNiveau.Keys) {
            if ([int] $cle -ge $rang) { $total += [long] $ExecutionsParNiveau[$cle] }
        }
        return $total
    }

    $estimations = @()

    foreach ($audit in $Plan.Audits) {

        $decision = $null
        if ($Decisions) {
            $decision = $Decisions | Where-Object { $_.Cle -eq $audit.Cle } | Select-Object -First 1
        }
        $retenue = ($null -eq $decision) -or $decision.Retenue

        # Une source statique n'a pas de facteur : son volume ne depend pas du
        # nombre d'executions, et il est negligeable par construction.
        if ($null -eq $audit.LignesParExecution) {
            $estimations += [PSCustomObject]@{
                Cle            = $audit.Cle
                Nom            = $audit.Nom
                Retenue        = $retenue
                LignesEstimees = $null
                Limite         = $audit.LimiteLignesParDefaut
                Depassement    = $false
                Motif          = 'Source statique, sans estimation.'
            }
            continue
        }

        $rang = Get-RuntimeAuditRangLogging -Niveau $audit.LoggingMinimal

        # Le plancher a 1 ecarte les executions au niveau Aucun : elles ne
        # produisent aucune trace, donc aucune ligne a extraire, et les compter
        # gonflerait toutes les estimations.
        $base = & $auMoins ([Math]::Max($rang, 1))

        $estime = [long] [Math]::Ceiling([double] $audit.LignesParExecution * $base)
        $limite = $audit.LimiteLignesParDefaut
        $depasse = ($retenue -and $null -ne $limite -and $limite -gt 0 -and $estime -gt $limite)

        $motif = if ($depasse) {
            "Estimation $estime lignes, limite $limite. Reduire la fenetre d'analyse."
        } else {
            "Estimation $estime lignes ($($audit.LignesParExecution) x $base execution(s) au niveau $($audit.LoggingMinimal) ou plus)."
        }

        $estimations += [PSCustomObject]@{
            Cle            = $audit.Cle
            Nom            = $audit.Nom
            Retenue        = $retenue
            LignesEstimees = $estime
            Limite         = $limite
            Depassement    = $depasse
            Motif          = $motif
        }
    }

    return $estimations
}

function Get-RuntimeAuditNiveauxObserves {
    <#
    .SYNOPSIS
        Traduit le compte ventile par niveau en noms de niveaux observes.

    .DESCRIPTION
        Pure, et derivee du MEME compte que l'estimation - donc bornee par la
        MEME fenetre.

        DEFAUT REEL QUE CELA CORRIGE : les niveaux etaient releves par une
        requete portant sur toute la retention, sans aucune borne. Une seule
        execution Verbose datant de six mois rendait StatistiquesFlux
        disponible pour une fenetre de sept jours ne contenant que du Basic.
        L'extraction tournait, ne trouvait rien, et sortait en ReussieVide.

        "Rien a signaler" et "le catalogue ne permet pas de repondre" sont deux
        verdicts opposes. Les confondre est exactement le genre d'erreur que la
        matrice de capacites existe pour empecher.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable] $ExecutionsParNiveau
    )

    $correspondance = @{ 0 = 'Aucun'; 1 = 'Basic'; 2 = 'Performance'; 3 = 'Verbose' }

    return @(
        $ExecutionsParNiveau.Keys |
            Where-Object { $correspondance.ContainsKey([int] $_) -and [long] $ExecutionsParNiveau[$_] -gt 0 } |
            ForEach-Object { $correspondance[[int] $_] } |
            Sort-Object -Unique
    )
}
