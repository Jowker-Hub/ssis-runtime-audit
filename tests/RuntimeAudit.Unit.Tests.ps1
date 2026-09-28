# =============================================================================
# RuntimeAudit.Unit.Tests.ps1
# Tests SANS SERVEUR. Doivent passer sur n'importe quelle machine.
#
# LE CRITERE DE CETTE SUITE
#   Elle ne cherche pas la couverture. Elle cherche a ATTRAPER LES DEFAUTS QUI
#   ONT REELLEMENT EU LIEU. Chaque bloc porte le defaut qu'il verrouille, et la
#   plupart de ces defauts etaient MUETS : un CSV vide, un lecteur consomme, des
#   valeurs effacees, jamais une erreur.
#
#   Un test qui ne correspond a aucun defaut observe protege surtout l'illusion
#   d'etre couvert.
#
# EXECUTION
#   Import-Module Pester -RequiredVersion 5.7.1
#   Invoke-Pester -Path .\SsisRuntimeAudit\tests\RuntimeAudit.Unit.Tests.ps1
#
#   La version est EPINGLEE : Pester 3.4.0 est livre d'origine avec Windows, sa
#   syntaxe est incompatible, et l'autoloading peut le choisir.
#
# CE QUI N'EST PAS COUVERT ICI, ET POURQUOI
#   - La resolution des fonctions du module depuis un gestionnaire WinForms : il
#     faudrait une boucle de messages, donc une fenetre. Le defaut est documente
#     dans CLAUDE.md section 8.2 et corrige par capture via Get-Command.
#   - Tout ce qui exige un catalogue : voir la suite d'integration.
#
# Regle du module : aucun caractere non-ASCII dans ce fichier.
# =============================================================================

BeforeAll {
    $script:RacineModule = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $RacineModule 'SsisRuntimeAudit.psd1') -Force
    $script:CheminSql = Join-Path $RacineModule 'sql'
}

Describe 'Plan : validation a l''ouverture' {

    # Un plan invalide doit echouer AVANT la connexion. Decouvrir qu'un fichier
    # .sql manque apres trois extractions chez un client gache la session.

    It 'lit le plan livre et y trouve les neuf audits' {
        $plan = InModuleScope SsisRuntimeAudit -Parameters @{ p = $CheminSql } { param($p) Read-RuntimeAuditPlan -CheminSql $p }
        $plan.Audits.Count | Should -Be 9
    }

    It 'conserve les accents des libelles' {
        # plan.psd1 porte un BOM UTF-8. Sans lui, PowerShell 5.1 le lit en ANSI
        # et "Executions" revient sur 22 caracteres au lieu de 10.
        $plan = InModuleScope SsisRuntimeAudit -Parameters @{ p = $CheminSql } { param($p) Read-RuntimeAuditPlan -CheminSql $p }
        $nom = ($plan.Audits | Where-Object { $_.Cle -eq 'executions' }).Nom
        $nom.Length | Should -Be 10
        ([int][char]$nom[2]) | Should -Be 233     # e accent aigu, pas 195
    }

    It 'refuse une cle en double' {
        $temp = Join-Path $TestDrive 'doublon'
        Copy-Item -Path $CheminSql -Destination $temp -Recurse
        (Get-Content (Join-Path $temp 'plan.psd1') -Raw).Replace("Cle                   = 'messages'", "Cle                   = 'executions'") |
            Set-Content (Join-Path $temp 'plan.psd1') -Encoding UTF8
        { InModuleScope SsisRuntimeAudit -Parameters @{ p = $temp } { param($p) Read-RuntimeAuditPlan -CheminSql $p } } |
            Should -Throw -ExpectedMessage '*cle(s) en double*'
    }

    It 'refuse un fichier .sql introuvable' {
        $temp = Join-Path $TestDrive 'absent'
        Copy-Item -Path $CheminSql -Destination $temp -Recurse
        (Get-Content (Join-Path $temp 'plan.psd1') -Raw).Replace('11_executions.sql', '11_disparue.sql') |
            Set-Content (Join-Path $temp 'plan.psd1') -Encoding UTF8
        { InModuleScope SsisRuntimeAudit -Parameters @{ p = $temp } { param($p) Read-RuntimeAuditPlan -CheminSql $p } } |
            Should -Throw -ExpectedMessage '*fichier introuvable*'
    }

    It 'refuse une limite sans facteur d''estimation' {
        # Sans facteur, le pre-vol n'a rien a estimer et le refus explicite
        # devient impossible : l'extraction passerait sans borne.
        $temp = Join-Path $TestDrive 'sansfacteur'
        Copy-Item -Path $CheminSql -Destination $temp -Recurse
        (Get-Content (Join-Path $temp 'plan.psd1') -Raw).Replace('LignesParExecution    = 243', 'LignesParExecution    = $null') |
            Set-Content (Join-Path $temp 'plan.psd1') -Encoding UTF8
        { InModuleScope SsisRuntimeAudit -Parameters @{ p = $temp } { param($p) Read-RuntimeAuditPlan -CheminSql $p } } |
            Should -Throw -ExpectedMessage '*aucun LignesParExecution*'
    }
}

Describe 'Selection : qui est lance, et pourquoi pas le reste' {

    BeforeAll {
        $script:Plan = InModuleScope SsisRuntimeAudit -Parameters @{ p = $CheminSql } { param($p) Read-RuntimeAuditPlan -CheminSql $p }
    }

    It 'rend une decision par audit du plan, y compris ceux qu''on ne lance pas' {
        # Non-suppression silencieuse : un audit qui disparait du compte rendu
        # est le meme defaut qu'une execution qui disparait du perimetre.
        $d = InModuleScope SsisRuntimeAudit -Parameters @{ pl = $Plan } { param($pl) Select-RuntimeAuditExtraction -Plan $pl -Cle @('executions') }
        $d.Count | Should -Be 9
    }

    It 'garde les decisions renseignees, jamais vides' {
        # DEFAUT REEL : une variable de boucle homonyme d'un parametre type
        # [string[]] convertissait chaque objet en tableau de chaines. Le CSV
        # sortait avec ses lignes, son en-tete correct, et TOUTES LES VALEURS
        # VIDES, sans la moindre erreur.
        $d = InModuleScope SsisRuntimeAudit -Parameters @{ pl = $Plan } { param($pl) Select-RuntimeAuditExtraction -Plan $pl -Tout }
        foreach ($ligne in $d) {
            $ligne.Cle    | Should -Not -BeNullOrEmpty
            $ligne.Statut | Should -Not -BeNullOrEmpty
        }
    }

    It 'retient les automatiques meme si on ne les demande pas' {
        $d = InModuleScope SsisRuntimeAudit -Parameters @{ pl = $Plan } { param($pl) Select-RuntimeAuditExtraction -Plan $pl -Cle @('executions') }
        ($d | Where-Object { $_.Cle -eq 'contexte' }).Retenue | Should -BeTrue
    }

    It 'declare indisponible une conditionnelle que le logging ne permet pas' {
        $d = InModuleScope SsisRuntimeAudit -Parameters @{ pl = $Plan } { param($pl) Select-RuntimeAuditExtraction -Plan $pl -Tout -LoggingObserve @('Basic') }
        ($d | Where-Object { $_.Cle -eq 'phases' }).Statut | Should -Be 'Indisponible'
        ($d | Where-Object { $_.Cle -eq 'executions' }).Statut | Should -Be 'Selectionnee'
    }

    It 'sert une extraction Performance par un catalogue en Verbose' {
        # Le logging minimal est un PLANCHER, pas une egalite.
        $d = InModuleScope SsisRuntimeAudit -Parameters @{ pl = $Plan } { param($pl) Select-RuntimeAuditExtraction -Plan $pl -Tout -LoggingObserve @('Verbose') }
        ($d | Where-Object { $_.Cle -eq 'phases' }).Statut | Should -Be 'Selectionnee'
    }

    It 'refuse une cle inconnue au lieu de l''ignorer' {
        { InModuleScope SsisRuntimeAudit -Parameters @{ pl = $Plan } { param($pl) Select-RuntimeAuditExtraction -Plan $pl -Cle @('nexistepas') } } |
            Should -Throw -ExpectedMessage '*inconnu*'
    }
}

Describe 'Echappement CSV' {

    # Fonction pure, et c'est elle qui porte toute la subtilite. Un CSV mal
    # echappe se lit sans erreur et decale toutes les colonnes.

    BeforeAll {
        $script:Echapper = { param($v) InModuleScope SsisRuntimeAudit -Parameters @{ x = $v } { param($x) ConvertTo-RuntimeAuditCsvValeur -Valeur $x } }
    }

    It 'laisse une valeur simple telle quelle' { (& $Echapper 'abc') | Should -Be 'abc' }
    It 'guillemete une valeur contenant le separateur' { (& $Echapper 'a,b') | Should -Be '"a,b"' }
    It 'double les guillemets internes' { (& $Echapper 'il a dit "oui"') | Should -Be '"il a dit ""oui"""' }
    It 'guillemete un retour a la ligne' {
        $attendu = '"' + "l1`nl2" + '"'
        (& $Echapper "l1`nl2") | Should -Be $attendu
    }
    It 'rend une chaine vide pour null' { (& $Echapper $null) | Should -Be '' }
    It 'rend une chaine vide pour DBNull' { (& $Echapper ([System.DBNull]::Value)) | Should -Be '' }

    It 'ecrit un decimal en culture invariante' {
        # Sans InvariantCulture, un poste francais sort "11,1" et casse un CSV
        # separe par virgules.
        (& $Echapper ([decimal]'11.1')) | Should -Be '11.1'
    }

    It 'laisse une formule telle quelle, et c''est une decision' {
        # La cible est Power BI, qui ne les interprete pas. Neutraliser
        # corromprait la donnee pour la vraie cible afin de proteger Excel.
        (& $Echapper '=1+1') | Should -Be '=1+1'
        (& $Echapper '@SUM(A1)') | Should -Be '@SUM(A1)'
    }
}

Describe 'Ecriture CSV : flux et publication atomique' {

    BeforeAll {
        $script:Jeu = {
            param($n)
            $t = New-Object System.Data.DataTable
            [void] $t.Columns.Add('A', [string])
            [void] $t.Columns.Add('B', [int])
            # La garde n'est pas cosmetique : en PowerShell, 1..0 rend 1,0 - la
            # plage DESCEND au lieu d'etre vide. Sans elle, le jeu dit "vide"
            # contenait deux lignes, et le test du fichier vide echouait sur son
            # propre piege.
            if ($n -gt 0) { 1..$n | ForEach-Object { [void] $t.Rows.Add("valeur $_", $_) } }
            # La virgule est OBLIGATOIRE : sans elle, PowerShell deroule le
            # lecteur en sortie et l'appelant recoit des lignes deja consommees.
            return , $t.CreateDataReader()
        }
    }

    It 'ecrit toutes les lignes du lecteur' {
        # DEFAUT REEL ET MUET : [ValidateNotNull()] sur le parametre du lecteur
        # le faisait ENUMERER par le lieur de parametres, donc consommer
        # integralement. 0 ligne au lieu de 5, aucune erreur, fichier reduit a
        # son en-tete. Ce test verrouille le retrait de l'attribut.
        $cible = Join-Path $TestDrive 'flux.csv'
        $r = InModuleScope SsisRuntimeAudit -Parameters @{ l = (& $Jeu 250); c = $cible } {
            param($l, $c) Write-RuntimeAuditCsv -Lecteur $l -Chemin $c
        }
        $r.Lignes | Should -Be 250
        (Get-Content $cible).Count | Should -Be 251     # en-tete comprise
    }

    It 'n''ecrit pas de BOM' {
        $cible = Join-Path $TestDrive 'bom.csv'
        InModuleScope SsisRuntimeAudit -Parameters @{ l = (& $Jeu 3); c = $cible } {
            param($l, $c) Write-RuntimeAuditCsv -Lecteur $l -Chemin $c
        } | Out-Null
        $octets = [System.IO.File]::ReadAllBytes($cible)
        "$($octets[0])-$($octets[1])-$($octets[2])" | Should -Not -Be '239-187-191'
    }

    It 'produit tout de meme le fichier sur un jeu vide' {
        # ReussieVide et Echec ne disent pas la meme chose : le vide produit son
        # fichier avec son en-tete, l'echec ne produit rien.
        $cible = Join-Path $TestDrive 'vide.csv'
        $r = InModuleScope SsisRuntimeAudit -Parameters @{ l = (& $Jeu 0); c = $cible } {
            param($l, $c) Write-RuntimeAuditCsv -Lecteur $l -Chemin $c
        }
        $r.Lignes | Should -Be 0
        Test-Path $cible | Should -BeTrue
    }

    It 'ne laisse aucun fichier temporaire derriere lui' {
        $cible = Join-Path $TestDrive 'propre.csv'
        InModuleScope SsisRuntimeAudit -Parameters @{ l = (& $Jeu 10); c = $cible } {
            param($l, $c) Write-RuntimeAuditCsv -Lecteur $l -Chemin $c
        } | Out-Null
        (Get-ChildItem $TestDrive -Filter '*.tmp' -Recurse).Count | Should -Be 0
    }

    It 'refuse une cible qui est un dossier' {
        # DEFAUT REEL : Move-Item ne leve pas, il deplace le temporaire A
        # L'INTERIEUR du dossier. Le runner rapportait un succes sur un
        # resultat introuvable.
        $cible = Join-Path $TestDrive 'dossier.csv'
        New-Item -Path $cible -ItemType Directory -Force | Out-Null
        { InModuleScope SsisRuntimeAudit -Parameters @{ l = (& $Jeu 5); c = $cible } {
            param($l, $c) Write-RuntimeAuditCsv -Lecteur $l -Chemin $c
        } } | Should -Throw -ExpectedMessage '*dossier*'
    }

    It 'refuse un lecteur deja ferme' {
        $l = & $Jeu 5
        $l.Close()
        { InModuleScope SsisRuntimeAudit -Parameters @{ l = $l; c = (Join-Path $TestDrive 'ferme.csv') } {
            param($l, $c) Write-RuntimeAuditCsv -Lecteur $l -Chemin $c
        } } | Should -Throw -ExpectedMessage '*ferme*'
    }
}

Describe 'Lint de lecture seule' {

    BeforeAll {
        $script:Controler = { param($t) InModuleScope SsisRuntimeAudit -Parameters @{ x = $t } { param($x) Test-RuntimeAuditLectureSeule -Texte $x } }
    }

    It 'accepte les neuf requetes livrees' {
        # Le lint doit laisser passer ce qu'on livre, sinon il est inutilisable.
        foreach ($f in Get-ChildItem $CheminSql -Recurse -Filter '*.sql') {
            (& $Controler (Get-Content $f.FullName -Raw)).Accepte | Should -BeTrue -Because $f.Name
        }
    }

    It 'ne se declenche pas sur un commentaire' {
        # Les en-tetes des requetes parlent de "aucun objet cree" : sans
        # retrait des commentaires, elles se refuseraient elles-memes.
        (& $Controler '/* jamais de DROP ici */ SELECT 1').Accepte | Should -BeTrue
        (& $Controler "-- pas de DELETE`nSELECT 1").Accepte | Should -BeTrue
    }

    It 'ne se declenche pas sur un litteral chaine' {
        (& $Controler "SELECT 'CREATE TABLE' AS x").Accepte | Should -BeTrue
        (& $Controler "SELECT N'il a dit ''DROP''' AS x").Accepte | Should -BeTrue
    }

    It 'refuse un vrai ordre d''ecriture' {
        (& $Controler 'SELECT 1; DROP TABLE t;').Accepte | Should -BeFalse
        (& $Controler 'UPDATE t SET a = 1').Accepte | Should -BeFalse
        (& $Controler '/* EXEC */ EXEC sp_who').Accepte | Should -BeFalse
    }
}

Describe 'Convention d''encodage du module' {

    # DEFAUT REEL : un tiret cadratin dans une chaine d'un fichier sans BOM a
    # casse le chargement du module. La regle existe parce que PowerShell 5.1
    # lit un fichier sans BOM en ANSI.

    It 'tout .ps1 non-ASCII porte un BOM' {
        # LE BALAYAGE COUVRE tests\, ET IL A FALLU UN DEFAUT POUR L'APPRENDRE.
        #
        # Il excluait ce dossier - les fixtures ne sont pas chargees par le
        # module, l'exclusion paraissait sans consequence. Resultat : deux
        # fichiers portaient des caracteres non-ASCII sans BOM, dont ce fichier
        # de tests lui-meme, et le test passait au vert en les ignorant.
        #
        # Un test qui s'exclut de sa propre regle certifie le perimetre qu'il a
        # choisi, pas la regle.
        $fautifs = @()
        foreach ($f in Get-ChildItem $RacineModule -Recurse -Include '*.ps1', '*.psm1', '*.psd1') {
            $octets = [System.IO.File]::ReadAllBytes($f.FullName)
            $aBom = ($octets.Length -ge 3 -and $octets[0] -eq 239 -and $octets[1] -eq 187 -and $octets[2] -eq 191)
            $aNonAscii = ($octets | Where-Object { $_ -gt 127 }).Count -gt 0
            if ($aNonAscii -and -not $aBom) { $fautifs += $f.Name }
        }
        $fautifs -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Estimation de volume : le calcul qui s''est trompe deux fois' {

    # C'EST LE BLOC LE PLUS IMPORTANT DE LA SUITE.
    #
    # Le facteur d'estimation a ete faux deux fois dans la meme journee, x7 puis
    # x2, et les deux fois la consequence etait de REFUSER une extraction
    # realisable. Verifier que le plan PORTE un facteur n'attrape ni l'une ni
    # l'autre : seul le calcul, nourri de comptes connus, les attrape.
    #
    # Les comptes ci-dessous sont ceux du catalogue reel de developpement :
    # 43 executions, dont 6 atteignant Performance (3 en Performance, 3 en
    # Verbose), et 1 458 phases mesurees.

    BeforeAll {
        $script:Plan = InModuleScope SsisRuntimeAudit -Parameters @{ p = $CheminSql } { param($p) Read-RuntimeAuditPlan -CheminSql $p }
        # niveau -> nombre d'executions dans la fenetre
        $script:Comptes = @{ 1 = 37; 2 = 3; 3 = 3 }
        $script:Estimer = {
            param($comptes, $decisions)
            InModuleScope SsisRuntimeAudit -Parameters @{ pl = $Plan; c = $comptes; d = $decisions } {
                param($pl, $c, $d) Get-RuntimeAuditEstimation -Plan $pl -ExecutionsParNiveau $c -Decisions $d
            }
        }
    }

    It 'compte les executions Verbose dans le denominateur d''une extraction Performance' {
        # L'ERREUR x2, EXACTEMENT. Verbose est AU-DESSUS de Performance : une
        # execution en Verbose produit des phases elle aussi. Diviser 1 458 par
        # les 3 seules executions Performance donnait 486 au lieu de 243.
        $e = (& $Estimer $Comptes $null) | Where-Object { $_.Cle -eq 'phases' }
        $e.LignesEstimees | Should -Be 1458      # 243 x 6, et non 243 x 3
    }

    It 'n''applique pas le facteur a toutes les executions de la fenetre' {
        # L'ERREUR x7. Multiplier par les 43 executions au lieu des 6 qui
        # atteignent Performance donnait 10 449 lignes ici.
        $e = (& $Estimer $Comptes $null) | Where-Object { $_.Cle -eq 'phases' }
        $e.LignesEstimees | Should -Not -Be (243 * 43)
    }

    It 'traite le logging minimal comme un plancher, pas une egalite' {
        # Un catalogue entierement en Verbose doit servir une extraction
        # Performance : les 43 executions comptent toutes.
        $e = (& $Estimer @{ 3 = 43 } $null) | Where-Object { $_.Cle -eq 'phases' }
        $e.LignesEstimees | Should -Be (243 * 43)
    }

    It 'exclut du denominateur les executions au niveau Aucun' {
        # Niveau 0 : aucune trace produite, donc aucune ligne a extraire.
        # Les compter gonflerait toutes les estimations.
        $e = (& $Estimer @{ 0 = 1000; 1 = 10 } $null) | Where-Object { $_.Cle -eq 'executions' }
        $e.LignesEstimees | Should -Be 10
    }

    It 'n''estime pas une source statique' {
        $e = (& $Estimer $Comptes $null) | Where-Object { $_.Cle -eq 'inventaire' }
        $e.LignesEstimees | Should -BeNullOrEmpty
        $e.Depassement    | Should -BeFalse
    }

    It 'signale un depassement de limite sans jamais tronquer' {
        # 2 000 000 / 243 = 8 231 executions suffisent a depasser.
        $e = (& $Estimer @{ 2 = 20000 } $null) | Where-Object { $_.Cle -eq 'phases' }
        $e.Depassement | Should -BeTrue
        $e.Motif       | Should -BeLike '*limite*'
    }

    It 'ne declare pas de depassement sur une extraction non retenue' {
        # Refuser pour volume ce qu'on n'allait pas lancer transformerait un
        # non-choix en echec de run.
        $d = InModuleScope SsisRuntimeAudit -Parameters @{ pl = $Plan } { param($pl) Select-RuntimeAuditExtraction -Plan $pl -Cle @('executions') }
        $e = (& $Estimer @{ 2 = 20000 } $d) | Where-Object { $_.Cle -eq 'phases' }
        $e.Retenue     | Should -BeFalse
        $e.Depassement | Should -BeFalse
    }
}

Describe 'Niveaux observes : bornes par la fenetre, pas par la retention' {

    # DEFAUT REEL : les niveaux etaient releves par une requete portant sur
    # toute la retention, sans aucune borne de temps. Une execution Verbose
    # datant de six mois rendait StatistiquesFlux disponible pour une fenetre de
    # sept jours ne contenant que du Basic. L'extraction tournait, ne trouvait
    # rien, et sortait en ReussieVide.
    #
    # "Rien a signaler" et "le catalogue ne permet pas de repondre" sont deux
    # verdicts opposes.

    BeforeAll {
        $script:Niveaux = {
            param($comptes)
            InModuleScope SsisRuntimeAudit -Parameters @{ c = $comptes } {
                param($c) Get-RuntimeAuditNiveauxObserves -ExecutionsParNiveau $c
            }
        }
    }

    It 'ne rend que les niveaux reellement presents dans le compte' {
        (& $Niveaux @{ 1 = 40 }) | Should -Be @('Basic')
    }

    It 'ignore un niveau presente avec zero execution' {
        # C'est la forme que prend, dans le compte, une fenetre qui ne contient
        # plus les executions Verbose de la retention.
        (& $Niveaux @{ 1 = 40; 3 = 0 }) | Should -Be @('Basic')
    }

    It 'rend une conditionnelle indisponible quand sa fenetre ne la porte pas' {
        # Le contrat complet, bout en bout : compte borne -> niveaux -> decision.
        $plan = InModuleScope SsisRuntimeAudit -Parameters @{ p = $CheminSql } { param($p) Read-RuntimeAuditPlan -CheminSql $p }
        $n = & $Niveaux @{ 1 = 40 }
        $d = InModuleScope SsisRuntimeAudit -Parameters @{ pl = $plan; n = $n } {
            param($pl, $n) Select-RuntimeAuditExtraction -Plan $pl -Tout -LoggingObserve $n
        }
        ($d | Where-Object { $_.Cle -eq 'flux' }).Statut | Should -Be 'Indisponible'
    }
}

Describe 'Demande explicite : quelle indisponibilite fait echouer un run' {

    # -Audit 'phases' sur un catalogue Basic : l'operateur a nomme une
    # extraction et ne l'a pas obtenue. C'est un echec.
    #
    # -Tout sur le meme catalogue : -Tout veut dire "tout ce que le logging
    # permet". Une conditionnelle absente est un constat de catalogue. Compter
    # cela comme un echec rendrait -Tout inutilisable sur la plupart des parcs,
    # qui tournent en Basic.
    #
    # Sans cette distinction, un run rendait Succes=True sans avoir produit ce
    # qu'on lui avait explicitement demande.

    BeforeAll {
        $script:Plan = InModuleScope SsisRuntimeAudit -Parameters @{ p = $CheminSql } { param($p) Read-RuntimeAuditPlan -CheminSql $p }
    }

    It 'marque explicite une cle nommee dans -Cle' {
        $d = InModuleScope SsisRuntimeAudit -Parameters @{ pl = $Plan } {
            param($pl) Select-RuntimeAuditExtraction -Plan $pl -Cle @('phases') -LoggingObserve @('Basic')
        }
        $p = $d | Where-Object { $_.Cle -eq 'phases' }
        $p.Statut                | Should -Be 'Indisponible'
        $p.DemandeeExplicitement | Should -BeTrue
    }

    It 'ne marque pas explicite ce que -Tout a balaye' {
        $d = InModuleScope SsisRuntimeAudit -Parameters @{ pl = $Plan } {
            param($pl) Select-RuntimeAuditExtraction -Plan $pl -Tout -LoggingObserve @('Basic')
        }
        $p = $d | Where-Object { $_.Cle -eq 'phases' }
        $p.Statut                | Should -Be 'Indisponible'
        $p.DemandeeExplicitement | Should -BeFalse
    }

    It 'renseigne le drapeau sur toutes les lignes, jamais nul' {
        $d = InModuleScope SsisRuntimeAudit -Parameters @{ pl = $Plan } {
            param($pl) Select-RuntimeAuditExtraction -Plan $pl -Cle @('phases') -LoggingObserve @('Basic')
        }
        foreach ($ligne in $d) { $ligne.DemandeeExplicitement | Should -BeIn @($true, $false) }
    }
}
