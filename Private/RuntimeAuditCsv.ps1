# =============================================================================
# RuntimeAuditCsv.ps1
# Ecriture CSV EN FLUX, avec publication atomique.
#
# POURQUOI PAS Export-SsisCsv DU MODULE VOISIN
#   Il passe par ConvertTo-Csv, assemble toutes les lignes en memoire, puis
#   ecrit d'un coup. Parfait pour quelques milliers de lignes d'audit statique,
#   intenable ici : mesure, 243 phases de composants par execution, donc 2,43
#   millions de lignes a dix mille runs. Les charger en DataTable, puis en
#   objets PowerShell, puis en chaines, multiplie la memoire par un facteur
#   qu'on ne maitrise pas.
#
#   Ce sont les CONVENTIONS du SSIS Toolkit qui sont reprises, pas son
#   implementation : D009 parlait de copie de convention, la distinction prend
#   ici tout son sens.
#
# PUBLICATION ATOMIQUE
#   On ecrit dans un fichier temporaire, et on ne le renomme qu'apres succes.
#   En cas d'echec le temporaire est supprime. Il ne reste JAMAIS de CSV
#   partiel : un fichier tronque serait indistinguable d'un fichier complet, et
#   personne ne s'en apercevrait avant d'avoir bati une analyse dessus.
#
# NEUTRALISATION DES FORMULES : DELIBEREMENT ABSENTE
#   Une valeur commencant par = + - ou @ est ecrite telle quelle. La cible est
#   Power BI, qui ne les interprete pas. Excel, lui, les executerait a
#   l'ouverture. C'est une decision, pas un oubli : neutraliser en prefixant
#   corromprait la donnee pour la cible reelle afin de proteger une cible qui
#   n'est pas la notre. Une ouverture manuelle dans Excel doit donc se faire en
#   passant par l'assistant d'importation.
#
# Regle du module : aucun caractere non-ASCII dans ce fichier.
# =============================================================================

function ConvertTo-RuntimeAuditCsvValeur {
    <#
    .SYNOPSIS
        Rend une valeur prete a etre ecrite dans un CSV.

    .DESCRIPTION
        Fonction pure, sans effet de bord : c'est elle qui porte toute la
        subtilite de l'echappement, donc c'est elle qu'il faut couvrir de tests.

        NULL et DBNull deviennent une chaine vide, conformement a la convention
        du SSIS Toolkit : valeur absente en chaine vide, jamais le mot NULL.

        Les guillemets ne sont poses QUE s'ils sont necessaires. Un CSV
        integralement guillemete est valide mais pese plus lourd, et le volume
        est ici un sujet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [AllowNull()]
        [object] $Valeur,

        [Parameter(Mandatory = $false)]
        [char] $Delimiteur = ','
    )

    if ($null -eq $Valeur -or $Valeur -is [System.DBNull]) { return '' }

    # InvariantCulture : sans cela, un decimal sortirait avec une virgule
    # decimale sur un poste francais, et casserait un CSV separe par virgules.
    $texte = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $Valeur)

    $doitEtreGuillemete = $texte.Contains($Delimiteur) -or
                          $texte.Contains('"') -or
                          $texte.Contains("`r") -or
                          $texte.Contains("`n")

    if (-not $doitEtreGuillemete) { return $texte }

    return '"' + $texte.Replace('"', '""') + '"'
}

function Write-RuntimeAuditCsv {
    <#
    .SYNOPSIS
        Deverse un lecteur de donnees dans un CSV, ligne par ligne.

    .DESCRIPTION
        Aucun DataTable, aucun objet intermediaire : le lecteur alimente
        directement un StreamWriter. Le nombre de lignes et le schema sont
        collectes PENDANT le flux, pas apres, puisqu'il n'y a plus rien a
        parcourir une fois le flux consomme.

        Accepte n'importe quel IDataReader et pas seulement un SqlDataReader :
        c'est ce qui rend cette fonction testable sans serveur, avec le lecteur
        d'un DataTable.

    .PARAMETER Lecteur
        Un IDataReader ouvert. Il est consomme, jamais referme ici : c'est
        l'appelant qui l'a ouvert, c'est a lui de le fermer.

    .PARAMETER Chemin
        Chemin final du CSV. Le dossier doit exister.

    .OUTPUTS
        PSCustomObject : Lignes, Colonnes, Chemin.
    #>
    [CmdletBinding()]
    param(
        # PAS DE [ValidateNotNull()] SUR CE PARAMETRE, ET C'EST VITAL.
        #
        # Mesure : un attribut de validation fait ENUMERER la valeur par le
        # lieur de parametres. Un lecteur de donnees est en avance seule, donc
        # l'enumeration le consomme INTEGRALEMENT avant que le corps de la
        # fonction ne commence. Resultat observe : 0 ligne au lieu de 5, sans
        # la moindre erreur, avec un fichier reduit a son en-tete.
        #
        #   [ValidateNotNull()] -> 0 / 5 lignes
        #   sans attribut       -> 5 / 5 lignes
        #
        # Un garde-fou defensif qui detruit la donnee en silence est pire que
        # pas de garde-fou. La verification se fait donc dans le corps, ou elle
        # ne touche a rien.
        [Parameter(Mandatory = $true)]
        [System.Data.IDataReader] $Lecteur,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Chemin,

        [Parameter(Mandatory = $false)]
        [char] $Delimiteur = ','
    )

    # Controle deplace du bloc param vers le corps : voir la note sur le
    # parametre $Lecteur. Ici, aucune enumeration n'a lieu.
    if ($null -eq $Lecteur) { throw 'Lecteur absent.' }
    if ($Lecteur.IsClosed)  { throw 'Le lecteur est deja ferme.' }

    $dossier = Split-Path -Path $Chemin -Parent
    if ($dossier -and -not (Test-Path -LiteralPath $dossier)) {
        throw "Dossier de sortie introuvable : $dossier"
    }

    # Refus si la cible existe et est un DOSSIER. Sans ce controle, Move-Item ne
    # signale rien : il deplace le temporaire A L'INTERIEUR du dossier, et on se
    # retrouve avec "Executions.csv\Executions.csv.tmp". Mesure faite, le
    # runner aurait rapporte un succes sur un resultat introuvable.
    if ((Test-Path -LiteralPath $Chemin) -and (Get-Item -LiteralPath $Chemin).PSIsContainer) {
        throw "La cible existe et est un dossier, pas un fichier : $Chemin"
    }

    # Le temporaire vit a cote du fichier final, donc sur le meme volume : le
    # renommage est alors une operation de repertoire, pas une recopie.
    #
    # SON NOM PORTE UN GUID, ET CE N'EST PAS DE LA COQUETTERIE.
    #   Avec un nom fixe "Executions.csv.tmp", deux collectes visant le meme
    #   dossier ecrivent dans le MEME fichier temporaire. Le bloc de nettoyage
    #   de la premiere supprime alors le temporaire de la seconde, ou pire :
    #   les deux flux s'entrelacent et le CSV publie melange deux runs sans que
    #   rien ne leve. Un GUID rend la collision impossible par construction.
    $temporaire = "$Chemin.$([guid]::NewGuid().ToString('N')).tmp"

    $encodage = New-Object System.Text.UTF8Encoding($false)   # $false = sans BOM
    $ecrivain = $null
    $lignes   = 0
    $colonnes = @()

    try {
        $ecrivain = New-Object System.IO.StreamWriter($temporaire, $false, $encodage)
        # Fixe explicitement, pour que la sortie ne depende pas de la plateforme.
        $ecrivain.NewLine = "`r`n"

        $nbChamps = $Lecteur.FieldCount
        for ($i = 0; $i -lt $nbChamps; $i++) {
            $colonnes += $Lecteur.GetName($i)
        }

        # En-tete. Ecrit meme si aucune ligne ne suit : un jeu vide produit tout
        # de meme son fichier, pour que le schema ne varie pas d'un run a
        # l'autre. Une extraction EN ECHEC, elle, ne produit rien du tout.
        $entete = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $nbChamps; $i++) {
            if ($i -gt 0) { [void] $entete.Append($Delimiteur) }
            [void] $entete.Append((ConvertTo-RuntimeAuditCsvValeur -Valeur $colonnes[$i] -Delimiteur $Delimiteur))
        }
        $ecrivain.WriteLine($entete.ToString())

        # Un seul StringBuilder reutilise : en creer un par ligne ferait un objet
        # par ligne, ce que tout ce fichier cherche precisement a eviter.
        $ligne = New-Object System.Text.StringBuilder
        $tampon = New-Object 'object[]' $nbChamps

        while ($Lecteur.Read()) {
            [void] $ligne.Clear()
            [void] $Lecteur.GetValues($tampon)

            for ($i = 0; $i -lt $nbChamps; $i++) {
                if ($i -gt 0) { [void] $ligne.Append($Delimiteur) }
                [void] $ligne.Append((ConvertTo-RuntimeAuditCsvValeur -Valeur $tampon[$i] -Delimiteur $Delimiteur))
            }

            $ecrivain.WriteLine($ligne.ToString())
            $lignes++
        }

        $ecrivain.Flush()
        $ecrivain.Dispose()
        $ecrivain = $null

        # Publication. Move-Item -Force remplace un fichier existant, ce qui
        # permet de relancer une extraction sans nettoyer a la main.
        Move-Item -LiteralPath $temporaire -Destination $Chemin -Force
    }
    catch {
        # Le temporaire ne doit pas survivre a l'echec. S'il restait, un run
        # suivant pourrait le prendre pour un resultat.
        if ($null -ne $ecrivain) {
            try { $ecrivain.Dispose() } catch { }
        }
        if (Test-Path -LiteralPath $temporaire) {
            Remove-Item -LiteralPath $temporaire -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if ($null -ne $ecrivain) {
            try { $ecrivain.Dispose() } catch { }
        }
    }

    return [PSCustomObject]@{
        Chemin   = $Chemin
        Lignes   = $lignes
        Colonnes = $colonnes
    }
}

function Write-RuntimeAuditObjetsCsv {
    <#
    .SYNOPSIS
        Ecrit des objets PowerShell en CSV, par le meme chemin que les lecteurs.

    .DESCRIPTION
        Run.csv et Extractions.csv ne viennent pas d'une requete mais d'objets
        construits par le runner. Plutot que de reimplementer l'echappement et la
        publication atomique, on batit une table en memoire et on la deverse par
        Write-RuntimeAuditCsv : une seule regle d'echappement dans tout le module,
        donc une seule a tester et une seule a corriger.

        Le volume est ici de quelques lignes, l'assemblage en memoire n'a donc
        pas l'inconvenient qu'il aurait sur une table de faits.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Objets,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Chemin
    )

    $table = New-Object System.Data.DataTable

    if ($Objets.Count -eq 0) {
        # Sans objet, pas de schema a deduire. On produit tout de meme le fichier,
        # vide : son absence et son vide ne disent pas la meme chose.
        [void] $table.Columns.Add('Vide', [string])
    }
    else {
        foreach ($p in $Objets[0].PSObject.Properties) {
            [void] $table.Columns.Add($p.Name, [string])
        }
        foreach ($o in $Objets) {
            $ligne = $table.NewRow()
            foreach ($p in $o.PSObject.Properties) {
                if ($null -eq $p.Value) { $ligne[$p.Name] = [System.DBNull]::Value }
                else { $ligne[$p.Name] = [string] $p.Value }
            }
            $table.Rows.Add($ligne)
        }
    }

    $lecteur = $table.CreateDataReader()
    try   { return Write-RuntimeAuditCsv -Lecteur $lecteur -Chemin $Chemin }
    finally { $lecteur.Close() }
}
