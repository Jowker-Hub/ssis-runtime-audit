# =============================================================================
# RuntimeAuditSql.ps1
# Connexion, controle de lecture seule, et execution parametree.
#
# TROIS REGLES QUI GOUVERNENT CE FICHIER
#
#   1. Le texte du fichier .sql est envoye SANS TRANSFORMATION. Il devient le
#      CommandText d'un SqlCommand, et les valeurs sont liees par SqlParameter.
#      Pas de concatenation, pas de sp_executesql construit a la main, pas de
#      substitution textuelle. Le fichier versionne est ce qui part.
#
#   2. Le mot de passe ne devient JAMAIS une chaine. Il reste en SecureString et
#      passe par SqlCredential, jamais par la chaine de connexion. Consequence :
#      absent de la ligne de commande, de Run.csv, des messages d'erreur et des
#      vues de sessions cote serveur.
#
#   3. UN LECTEUR SE REND AVEC UNE VIRGULE. Mesure : "return $lecteur" rend un
#      Object[] de lignes deja consommees, PowerShell deroulant les IEnumerable
#      en sortie. Il faut "return ,$lecteur". Meme cause que l'interdiction de
#      [ValidateNotNull()] sur un parametre de lecteur, documentee dans
#      RuntimeAuditCsv.ps1 : un lecteur est en avance seule, et toute
#      enumeration accidentelle le detruit en silence.
#
# Regle du module : aucun caractere non-ASCII dans ce fichier.
# =============================================================================

# Mots refuses. Liste noire assumee comme telle : elle ne sera jamais complete,
# et c'est pourquoi ce controle est un LINT et non une securite. La vraie
# protection reste un compte en lecture seule chez le client.
$script:RuntimeAuditMotsInterdits = @(
    'INSERT', 'UPDATE', 'DELETE', 'MERGE', 'CREATE', 'ALTER', 'DROP',
    'TRUNCATE', 'EXEC', 'EXECUTE', 'GRANT', 'REVOKE', 'DENY',
    'BACKUP', 'RESTORE', 'SHUTDOWN', 'RECONFIGURE'
)

function Remove-RuntimeAuditCommentaire {
    <#
    .SYNOPSIS
        Retire commentaires et litteraux chaine d'un texte T-SQL.

    .DESCRIPTION
        Fonction pure. Indispensable au controle de lecture seule : les en-tetes
        des requetes parlent de "lecture seule stricte, aucun objet cree" et
        declencheraient sinon un faux positif sur leur propre documentation.

        Les litteraux chaine sont retires pour la meme raison : un libelle
        contenant le mot DROP n'est pas un ordre DROP.

        Les commentaires de bloc imbriques, que T-SQL autorise, ne sont pas
        traites : le premier `*/` ferme. C'est une limite acceptee, elle rend le
        controle plus strict et non plus permissif.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Texte
    )

    $sansBloc   = [regex]::Replace($Texte, '/\*.*?\*/', ' ', 'Singleline')
    $sansLigne  = [regex]::Replace($sansBloc, '--[^\r\n]*', ' ')
    $sansChaine = [regex]::Replace($sansLigne, "N?'(?:[^']|'')*'", ' ')

    return $sansChaine
}

function Test-RuntimeAuditLectureSeule {
    <#
    .SYNOPSIS
        Refuse un texte T-SQL qui contient un ordre d'ecriture.

    .DESCRIPTION
        LINT, PAS SECURITE, et le document de conception le dit ainsi. Une liste
        noire ne sera jamais complete et il ne faut pas investir dans un
        pseudo-parseur T-SQL qui donnerait une fausse assurance. Ce controle
        protege d'un copier-coller malheureux, rien de plus.

        La vraie protection est ailleurs : un compte en lecture seule chez le
        client, et la promesse de n'y creer aucun objet.

    .OUTPUTS
        PSCustomObject : Accepte, MotsTrouves.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Texte
    )

    $nu = Remove-RuntimeAuditCommentaire -Texte $Texte
    $trouves = @()

    foreach ($mot in $script:RuntimeAuditMotsInterdits) {
        if ([regex]::IsMatch($nu, "\b$mot\b", 'IgnoreCase')) {
            $trouves += $mot
        }
    }

    return [PSCustomObject]@{
        Accepte     = ($trouves.Count -eq 0)
        MotsTrouves = $trouves
    }
}

function New-RuntimeAuditConnexion {
    <#
    .SYNOPSIS
        Ouvre une connexion a SSISDB, en authentification Windows ou SQL.

    .PARAMETER Identifiants
        Absent : authentification Windows. Fourni : authentification SQL Server,
        le mot de passe passant par SqlCredential et jamais par la chaine.

    .OUTPUTS
        SqlConnection ouverte. L'appelant la ferme.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Instance,

        [Parameter(Mandatory = $false)]
        [string] $BaseDeDonnees = 'SSISDB',

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential] $Identifiants,

        [Parameter(Mandatory = $false)]
        [int] $DelaiConnexionSecondes = 15
    )

    $constructeur = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $constructeur['Data Source']     = $Instance
    $constructeur['Initial Catalog'] = $BaseDeDonnees
    $constructeur['Connect Timeout'] = $DelaiConnexionSecondes
    # Pour que le DBA du client voie immediatement qui interroge son serveur et
    # sous quel outil, dans sys.dm_exec_sessions comme dans une trace.
    $constructeur['Application Name'] = 'SsisRuntimeAudit'

    $connexion = New-Object System.Data.SqlClient.SqlConnection

    if ($null -eq $Identifiants) {
        $constructeur['Integrated Security'] = $true
        $connexion.ConnectionString = $constructeur.ConnectionString
    }
    else {
        # SqlCredential EXIGE une chaine securisee en lecture seule, et refuse
        # toute chaine de connexion portant Integrated Security, User ID ou
        # Password. C'est precisement ce qui garantit que le mot de passe ne
        # peut pas fuir par la chaine.
        $motDePasse = $Identifiants.Password.Copy()
        $motDePasse.MakeReadOnly()

        $connexion.ConnectionString = $constructeur.ConnectionString
        $connexion.Credential = New-Object System.Data.SqlClient.SqlCredential(
            $Identifiants.UserName, $motDePasse)
    }

    $connexion.Open()
    return $connexion
}

function Get-RuntimeAuditNiveauxLogging {
    <#
    .SYNOPSIS
        Niveaux de logging REELLEMENT observes dans le catalogue.

    .DESCRIPTION
        Ce sont eux, et non le defaut serveur, qui decident de la disponibilite
        des extractions conditionnelles : un serveur regle sur Basic peut tres
        bien porter quelques executions lancees en Performance, et l'inverse est
        vrai aussi.

        Rend un tableau vide si aucune execution n'est visible - ce qui peut
        vouloir dire un catalogue vide OU un droit manquant, les vues etant
        filtrees par permissions. Le domaine "Droits" du diagnostic est la
        pour lever ce doute.

    .OUTPUTS
        Tableau de chaines parmi Aucun, Basic, Performance, Verbose.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlConnection] $Connexion
    )

    $requete = @'
SELECT DISTINCT CONVERT(nvarchar(10), p.parameter_value) AS niveau
FROM SSISDB.[catalog].execution_parameter_values AS p
WHERE p.object_type = 50 AND p.parameter_name = N'LOGGING_LEVEL';
'@

    $commande = $Connexion.CreateCommand()
    $commande.CommandText = $requete
    $commande.CommandTimeout = 30

    $correspondance = @{ '0' = 'Aucun'; '1' = 'Basic'; '2' = 'Performance'; '3' = 'Verbose' }
    $niveaux = @()

    $lecteur = $commande.ExecuteReader()
    try {
        while ($lecteur.Read()) {
            $brut = [string] $lecteur['niveau']
            if ($correspondance.ContainsKey($brut)) { $niveaux += $correspondance[$brut] }
        }
    }
    finally {
        $lecteur.Close()
    }

    return @($niveaux | Sort-Object -Unique)
}

function Invoke-RuntimeAuditLecteur {
    <#
    .SYNOPSIS
        Execute un fichier .sql et rend un lecteur ouvert.

    .DESCRIPTION
        Le texte du fichier part SANS TRANSFORMATION comme CommandText ; seules
        les valeurs sont liees. Le controle de lecture seule porte donc bien sur
        ce qui est reellement envoye.

    .PARAMETER Parametres
        Table de hachage nom -> valeur. Un nom absent de la requete serait
        refuse par SQL Server : le plan ne doit declarer que ce que la requete
        utilise vraiment.

    .OUTPUTS
        SqlDataReader ouvert. L'appelant le ferme.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlConnection] $Connexion,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $CheminRequete,

        [Parameter(Mandatory = $false)]
        [hashtable] $Parametres,

        [Parameter(Mandatory = $false)]
        [int] $DelaiSecondes = 600
    )

    if (-not (Test-Path -LiteralPath $CheminRequete)) {
        throw "Requete introuvable : $CheminRequete"
    }

    $texte = Get-Content -LiteralPath $CheminRequete -Raw

    # Le lint porte sur le TEXTE DU FICHIER, avant tout emballage technique :
    # controler autre chose que ce qui est versionne n'aurait pas de sens.
    $controle = Test-RuntimeAuditLectureSeule -Texte $texte
    if (-not $controle.Accepte) {
        throw "Requete refusee par le controle de lecture seule : $(($controle.MotsTrouves) -join ', '). Fichier : $CheminRequete"
    }

    $commande = $Connexion.CreateCommand()
    $commande.CommandText    = $texte
    $commande.CommandTimeout = $DelaiSecondes

    if ($Parametres) {
        foreach ($nom in $Parametres.Keys) {
            $p = $commande.Parameters.Add(
                (New-Object System.Data.SqlClient.SqlParameter("@$nom", [System.Data.SqlDbType]::DateTimeOffset)))
            if ($null -eq $Parametres[$nom]) { $p.Value = [System.DBNull]::Value }
            else { $p.Value = $Parametres[$nom] }
        }
    }

    # LA VIRGULE N'EST PAS UNE COQUETTERIE. Sans elle, PowerShell deroule le
    # lecteur en sortie et l'appelant recoit un Object[] de lignes deja
    # consommees, sans la moindre erreur. Voir l'en-tete de ce fichier.
    return , $commande.ExecuteReader()
}
