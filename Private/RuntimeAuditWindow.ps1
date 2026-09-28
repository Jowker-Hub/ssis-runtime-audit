# =============================================================================
# RuntimeAuditWindow.ps1
# Fenêtre de sélection. COQUILLE, et rien d'autre.
#
# Elle collecte des choix et les rend. Elle ne décide pas ce qui est lançable :
# c'est Select-RuntimeAuditExtraction, fonction pure, qui le fait — et c'est ce
# qui garde la logique testable sans interface. Si une règle de sélection se
# retrouvait ici, elle deviendrait la seule partie non testable du module.
#
# ENCODAGE : UTF-8 AVEC BOM, indispensable.
#   La convention du module interdit le non-ASCII dans le code, parce que
#   PowerShell 5.1 lit un fichier sans BOM en ANSI. Vérifié : « Périmètre » sort
#   sur 25 caractères avec le é éclaté en 195/169 sans BOM, sur 22 caractères
#   avec le code 233 attendu avec BOM. Les libellés d'une fenêtre française ne
#   peuvent pas être en ASCII, donc ce fichier porte un BOM. C'est le seul .ps1
#   du module dans ce cas, et c'est assumé.
#
# TROIS ÉCARTS ASSUMÉS PAR RAPPORT À LA MAQUETTE
#   1. Barre de titre Windows standard, et non un chrome redessiné. Un chrome
#      personnalisé impose de réimplémenter déplacement, redimensionnement et
#      ancrage : beaucoup de code fragile pour du décor.
#   2. Pastilles de disponibilité à angles droits. Les coins arrondis
#      exigeraient de redessiner chaque cellule de la grille.
#   3. Pas de case à cocher dans l'en-tête du tableau — non natif. Les deux
#      liens « Tout sélectionner » et « Tout désélectionner » font le travail.
#
# MISE À L'ÉCHELLE
#   Le processus est rendu conscient du DPI avant toute création de fenêtre.
#   Sans cela, Windows ment au processus sur la taille de l'écran puis agrandit
#   la fenêtre à l'affichage : mesuré à 125 %, une fenêtre déclarée à 660 points
#   sortait à plus de 820 pixels et son pied de page passait sous le bord de
#   l'écran, avec un rendu flou par-dessus le marché.
#
#   La taille reste bornée à la zone de travail réelle, parce qu'un écran plus
#   petit que prévu existe aussi.
# =============================================================================

function Show-RuntimeAuditFenetre {
    <#
    .SYNOPSIS
        Affiche la fenêtre de sélection et rend les choix de l'opérateur.

    .PARAMETER Plan
        Objet rendu par Read-RuntimeAuditPlan.

    .OUTPUTS
        $null si l'opérateur annule. Sinon un objet portant Instance,
        Identifiants, JoursFenetre, DossierSortie et Cles.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Plan,

        [Parameter(Mandatory = $false)]
        [string] $Instance = '',

        [Parameter(Mandatory = $false)]
        [string] $DossierSortie = ''
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # Conscience du DPI, AVANT toute creation de fenetre.
    #
    # Sans cela Windows ment au processus sur la taille de l'ecran, puis agrandit
    # la fenetre a l'affichage. Mesure faite sur un ecran a 125 % : une fenetre
    # declaree a 660 points sortait a plus de 820 pixels, et son pied de page
    # avec les boutons passait sous le bord de l'ecran. Le rendu etait flou par
    # dessus le marche.
    #
    # SetProcessDPIAware ne peut etre appele qu'une fois par processus et echoue
    # silencieusement ensuite : d'ou le try/catch, qui n'est pas de la
    # complaisance mais le contrat de l'API.
    try {
        if (-not ([System.Management.Automation.PSTypeName]'RuntimeAudit.Dpi').Type) {
            Add-Type -Namespace 'RuntimeAudit' -Name 'Dpi' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
'@
        }
        [void][RuntimeAudit.Dpi]::SetProcessDPIAware()
    }
    catch { Write-Verbose "Conscience DPI non applicable : $($_.Exception.Message)" }

    # Références de fonctions capturées AVANT de construire la fenêtre.
    #
    # Mesuré : un gestionnaire d'événement WinForms ne résout PAS les fonctions
    # privées du module. Le bouton « Tester la connexion » échouait sur
    # « The term 'New-RuntimeAuditConnexion' is not recognized », dans les deux
    # modes d'authentification, alors que les mêmes fonctions marchent
    # parfaitement quand on les appelle depuis le corps du module.
    #
    # La boucle de messages invoque le gestionnaire dans un état de session qui
    # ne porte pas la portée du module, et `.GetNewClosure()` ne suffit pas à la
    # rétablir. Un objet de commande, lui, transporte son module : `& $fn`
    # fonctionne d'où qu'on l'appelle.
    #
    # Le défaut était INVISIBLE à la relecture et n'apparaît qu'en cliquant.
    $fnConnexion = Get-Command -Name 'New-RuntimeAuditConnexion'     -CommandType Function
    $fnNiveaux   = Get-Command -Name 'Get-RuntimeAuditNiveauxLogging' -CommandType Function
    $fnSelection = Get-Command -Name 'Select-RuntimeAuditExtraction'  -CommandType Function

    $bleuFonce  = [System.Drawing.Color]::FromArgb(27, 54, 93)
    $grisFond   = [System.Drawing.Color]::FromArgb(246, 248, 251)
    $vertPale   = [System.Drawing.Color]::FromArgb(223, 245, 228)
    $vertTexte  = [System.Drawing.Color]::FromArgb(22, 101, 52)
    $rougePale  = [System.Drawing.Color]::FromArgb(254, 226, 226)
    $rougeTexte = [System.Drawing.Color]::FromArgb(153, 27, 27)
    $policeTitre = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $policeSous  = New-Object System.Drawing.Font('Segoe UI', 9)
    $policeGroupe = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SSIS Runtime Audit'
    # Hauteur volontairement modeste : mesure faite, une fenetre de 760 points
    # depasse le bas d'un ecran 1080 a 125 %, et le pied de page avec les boutons
    # sort du champ. La grille a sa barre de defilement, la fenetre n'a pas
    # besoin d'afficher les neuf lignes d'un coup.
    $zone = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = New-Object System.Drawing.Size(
        [Math]::Min(980, $zone.Width  - 60),
        [Math]::Min(660, $zone.Height - 60))
    $form.MinimumSize = New-Object System.Drawing.Size(860, 520)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $grisFond
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # ------------------------------------------------------------- bandeau ---
    $bandeau = New-Object System.Windows.Forms.Panel
    $bandeau.Dock = 'Top'
    # Hauteur donnee AVEC MARGE : mesure faite, le sous-titre debordait et se
    # faisait rogner par la section Connexion des que le systeme agrandit les
    # polices. Un bandeau serre au pixel pres ne survit pas au premier reglage
    # d'affichage different.
    $bandeau.Height = 82
    $bandeau.BackColor = $bleuFonce
    $titre = New-Object System.Windows.Forms.Label
    $titre.Text = 'SSIS Runtime Audit'
    $titre.Font = $policeTitre
    $titre.ForeColor = [System.Drawing.Color]::White
    $titre.AutoSize = $true
    $titre.Location = New-Object System.Drawing.Point(18, 10)
    $sousTitre = New-Object System.Windows.Forms.Label
    $sousTitre.Text = "Collecte des données d'exécution SSIS"
    $sousTitre.Font = $policeSous
    $sousTitre.ForeColor = [System.Drawing.Color]::FromArgb(190, 205, 225)
    $sousTitre.AutoSize = $true
    $sousTitre.Location = New-Object System.Drawing.Point(20, 48)
    $bandeau.Controls.AddRange(@($titre, $sousTitre))

    # ------------------------------------------------------------ connexion ---
    $grpConnexion = New-Object System.Windows.Forms.GroupBox
    $grpConnexion.Text = ' Connexion '
    $grpConnexion.Font = $policeGroupe
    $grpConnexion.Location = New-Object System.Drawing.Point(14, 94)
    $grpConnexion.Size = New-Object System.Drawing.Size(940, 150)
    $grpConnexion.Anchor = 'Top,Left,Right'

    $lblInstance = New-Object System.Windows.Forms.Label
    $lblInstance.Text = 'Instance SQL :'
    $lblInstance.Location = New-Object System.Drawing.Point(16, 30)
    $lblInstance.Size = New-Object System.Drawing.Size(120, 22)
    $lblInstance.Font = $form.Font

    $txtInstance = New-Object System.Windows.Forms.TextBox
    $txtInstance.Location = New-Object System.Drawing.Point(140, 27)
    $txtInstance.Size = New-Object System.Drawing.Size(560, 24)
    $txtInstance.Anchor = 'Top,Left,Right'
    $txtInstance.Text = $Instance

    $lblAuth = New-Object System.Windows.Forms.Label
    $lblAuth.Text = 'Authentification :'
    $lblAuth.Location = New-Object System.Drawing.Point(16, 62)
    $lblAuth.Size = New-Object System.Drawing.Size(120, 22)
    $lblAuth.Font = $form.Font

    $radWindows = New-Object System.Windows.Forms.RadioButton
    $radWindows.Text = 'Windows'
    $radWindows.Location = New-Object System.Drawing.Point(140, 60)
    $radWindows.Size = New-Object System.Drawing.Size(100, 24)
    $radWindows.Checked = $true
    $radWindows.Font = $form.Font

    $radSql = New-Object System.Windows.Forms.RadioButton
    $radSql.Text = 'SQL Server'
    $radSql.Location = New-Object System.Drawing.Point(250, 60)
    $radSql.Size = New-Object System.Drawing.Size(110, 24)
    $radSql.Font = $form.Font

    $lblUtilisateur = New-Object System.Windows.Forms.Label
    $lblUtilisateur.Text = 'Utilisateur :'
    $lblUtilisateur.Location = New-Object System.Drawing.Point(16, 92)
    $lblUtilisateur.Size = New-Object System.Drawing.Size(120, 22)
    $lblUtilisateur.Font = $form.Font

    $txtUtilisateur = New-Object System.Windows.Forms.TextBox
    $txtUtilisateur.Location = New-Object System.Drawing.Point(140, 89)
    $txtUtilisateur.Size = New-Object System.Drawing.Size(240, 24)
    $txtUtilisateur.Enabled = $false

    $lblMotDePasse = New-Object System.Windows.Forms.Label
    $lblMotDePasse.Text = 'Mot de passe :'
    $lblMotDePasse.Location = New-Object System.Drawing.Point(400, 92)
    $lblMotDePasse.AutoSize = $true
    $lblMotDePasse.Font = $form.Font

    $txtMotDePasse = New-Object System.Windows.Forms.TextBox
    $txtMotDePasse.Location = New-Object System.Drawing.Point(505, 89)
    $txtMotDePasse.Size = New-Object System.Drawing.Size(195, 24)
    $txtMotDePasse.UseSystemPasswordChar = $true
    $txtMotDePasse.Enabled = $false

    $btnTester = New-Object System.Windows.Forms.Button
    $btnTester.Text = 'Tester la connexion'
    $btnTester.Location = New-Object System.Drawing.Point(725, 26)
    $btnTester.Size = New-Object System.Drawing.Size(195, 32)
    $btnTester.Anchor = 'Top,Right'
    $btnTester.Font = $form.Font

    $lblEtatConnexion = New-Object System.Windows.Forms.Label
    $lblEtatConnexion.Text = 'Connexion non testée'
    $lblEtatConnexion.Location = New-Object System.Drawing.Point(725, 66)
    $lblEtatConnexion.Size = New-Object System.Drawing.Size(200, 40)
    $lblEtatConnexion.Anchor = 'Top,Right'
    $lblEtatConnexion.Font = $form.Font
    $lblEtatConnexion.ForeColor = [System.Drawing.Color]::DimGray

    $grpConnexion.Controls.AddRange(@(
        $lblInstance, $txtInstance, $lblAuth, $radWindows, $radSql,
        $lblUtilisateur, $txtUtilisateur, $lblMotDePasse, $txtMotDePasse,
        $btnTester, $lblEtatConnexion))

    # ------------------------------------------------------------ périmètre ---
    $grpPerimetre = New-Object System.Windows.Forms.GroupBox
    $grpPerimetre.Text = ' Périmètre '
    $grpPerimetre.Font = $policeGroupe
    $grpPerimetre.Location = New-Object System.Drawing.Point(14, 252)
    $grpPerimetre.Size = New-Object System.Drawing.Size(940, 100)
    $grpPerimetre.Anchor = 'Top,Left,Right'

    $lblPeriode = New-Object System.Windows.Forms.Label
    $lblPeriode.Text = "Période d'analyse :"
    $lblPeriode.Location = New-Object System.Drawing.Point(16, 30)
    $lblPeriode.Size = New-Object System.Drawing.Size(130, 22)
    $lblPeriode.Font = $form.Font

    $radRetention = New-Object System.Windows.Forms.RadioButton
    $radRetention.Text = 'Toute la rétention'
    $radRetention.Location = New-Object System.Drawing.Point(150, 28)
    $radRetention.Size = New-Object System.Drawing.Size(150, 24)
    $radRetention.Checked = $true
    $radRetention.Font = $form.Font

    $radJours = New-Object System.Windows.Forms.RadioButton
    $radJours.Text = 'Les'
    $radJours.Location = New-Object System.Drawing.Point(320, 28)
    $radJours.Size = New-Object System.Drawing.Size(50, 24)
    $radJours.Font = $form.Font

    $numJours = New-Object System.Windows.Forms.NumericUpDown
    $numJours.Location = New-Object System.Drawing.Point(370, 28)
    $numJours.Size = New-Object System.Drawing.Size(60, 24)
    $numJours.Minimum = 1
    $numJours.Maximum = 3650
    $numJours.Value = 30
    $numJours.Enabled = $false

    $lblJours = New-Object System.Windows.Forms.Label
    $lblJours.Text = 'derniers jours'
    $lblJours.Location = New-Object System.Drawing.Point(438, 31)
    $lblJours.Size = New-Object System.Drawing.Size(110, 22)
    $lblJours.Font = $form.Font

    $lblSortie = New-Object System.Windows.Forms.Label
    $lblSortie.Text = 'Dossier de sortie :'
    $lblSortie.Location = New-Object System.Drawing.Point(16, 64)
    $lblSortie.Size = New-Object System.Drawing.Size(130, 22)
    $lblSortie.Font = $form.Font

    $txtSortie = New-Object System.Windows.Forms.TextBox
    $txtSortie.Location = New-Object System.Drawing.Point(150, 61)
    $txtSortie.Size = New-Object System.Drawing.Size(660, 24)
    $txtSortie.Anchor = 'Top,Left,Right'
    $txtSortie.Text = $DossierSortie

    $btnParcourir = New-Object System.Windows.Forms.Button
    $btnParcourir.Text = 'Parcourir...'
    $btnParcourir.Location = New-Object System.Drawing.Point(820, 59)
    $btnParcourir.Size = New-Object System.Drawing.Size(100, 28)
    $btnParcourir.Anchor = 'Top,Right'
    $btnParcourir.Font = $form.Font

    $grpPerimetre.Controls.AddRange(@(
        $lblPeriode, $radRetention, $radJours, $numJours, $lblJours,
        $lblSortie, $txtSortie, $btnParcourir))

    # ---------------------------------------------------------- extractions ---
    $grpExtractions = New-Object System.Windows.Forms.GroupBox
    $grpExtractions.Text = ' Extractions '
    $grpExtractions.Font = $policeGroupe
    $grpExtractions.Location = New-Object System.Drawing.Point(14, 360)
    $grpExtractions.Size = New-Object System.Drawing.Size(940, 220)
    $grpExtractions.Anchor = 'Top,Bottom,Left,Right'

    $lnkTout = New-Object System.Windows.Forms.LinkLabel
    $lnkTout.Text = 'Tout sélectionner'
    $lnkTout.Location = New-Object System.Drawing.Point(16, 24)
    # AutoSize plutot qu'une largeur fixe : mesure faite, « Tout selectionner »
    # sortait tronque en « Tout selectionne » des que la police systeme grandit.
    $lnkTout.AutoSize = $true
    $lnkTout.Font = $form.Font

    $lblSep = New-Object System.Windows.Forms.Label
    $lblSep.Text = '|'
    # Position calculee depuis la largeur REELLE du lien precedent. Avec
    # AutoSize, une position fixe se chevaucherait des que la police change.
    $lblSep.Location = New-Object System.Drawing.Point(($lnkTout.Right + 8), 24)
    $lblSep.Size = New-Object System.Drawing.Size(10, 22)
    $lblSep.Font = $form.Font

    $lnkRien = New-Object System.Windows.Forms.LinkLabel
    $lnkRien.Text = 'Tout désélectionner'
    $lnkRien.Location = New-Object System.Drawing.Point(($lblSep.Right + 8), 24)
    $lnkRien.AutoSize = $true
    $lnkRien.Font = $form.Font

    # Une grille plutot qu'une liste : la maquette demande trois colonnes, et
    # une DataGridView les aligne sans calcul de position. La barre de
    # défilement apparaît d'elle-même si les neuf lignes ne tiennent pas.
    $grille = New-Object System.Windows.Forms.DataGridView
    $grille.Location = New-Object System.Drawing.Point(16, 52)
    $grille.Size = New-Object System.Drawing.Size(908, 150)
    $grille.Anchor = 'Top,Bottom,Left,Right'
    $grille.AllowUserToAddRows = $false
    $grille.AllowUserToDeleteRows = $false
    $grille.AllowUserToResizeRows = $false
    $grille.RowHeadersVisible = $false
    $grille.SelectionMode = 'FullRowSelect'
    $grille.MultiSelect = $false
    $grille.BackgroundColor = [System.Drawing.Color]::White
    $grille.BorderStyle = 'FixedSingle'
    $grille.Font = $form.Font
    $grille.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $grille.EnableHeadersVisualStyles = $false
    $grille.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(238, 242, 248)
    $grille.RowTemplate.Height = 28

    $colCoche = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colCoche.HeaderText = ''
    $colCoche.Name = 'Coche'
    $colCoche.Width = 40
    $colNom = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colNom.HeaderText = 'Extraction'
    $colNom.Name = 'Nom'
    $colNom.Width = 300
    $colNom.ReadOnly = $true
    $colGrain = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colGrain.HeaderText = 'Ce qui sera produit'
    $colGrain.Name = 'Sortie'
    $colGrain.Width = 240
    $colGrain.ReadOnly = $true
    $colLogging = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colLogging.HeaderText = 'Logging requis'
    $colLogging.Name = 'Logging'
    $colLogging.Width = 130
    $colLogging.ReadOnly = $true
    $colDispo = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDispo.HeaderText = 'Disponibilité'
    $colDispo.Name = 'Dispo'
    $colDispo.Width = 150
    $colDispo.ReadOnly = $true
    [void] $grille.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]] @($colCoche, $colNom, $colGrain, $colLogging, $colDispo))

    $grpExtractions.Controls.AddRange(@($lnkTout, $lblSep, $lnkRien, $grille))

    # ------------------------------------------------------------- pied de page
    $pied = New-Object System.Windows.Forms.Panel
    $pied.Dock = 'Bottom'
    $pied.Height = 56
    $pied.BackColor = $grisFond

    $lblEtat = New-Object System.Windows.Forms.Label
    $lblEtat.Location = New-Object System.Drawing.Point(16, 18)
    $lblEtat.Size = New-Object System.Drawing.Size(640, 22)
    $lblEtat.Font = $form.Font
    $lblEtat.ForeColor = [System.Drawing.Color]::DimGray

    $btnAnnuler = New-Object System.Windows.Forms.Button
    $btnAnnuler.Text = 'Annuler'
    $btnAnnuler.Size = New-Object System.Drawing.Size(120, 34)
    $btnAnnuler.Font = $form.Font
    $btnAnnuler.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $btnLancer = New-Object System.Windows.Forms.Button
    $btnLancer.Text = "Lancer l'audit"
    $btnLancer.Size = New-Object System.Drawing.Size(150, 34)
    $btnLancer.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $btnLancer.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $btnLancer.ForeColor = [System.Drawing.Color]::White
    $btnLancer.FlatStyle = 'Flat'

    # Les boutons vivent dans un panneau a flux inverse, PAS en position absolue
    # avec une ancre a droite. Mesure faite : une ancre se calcule a partir de la
    # taille que le parent avait AU MOMENT DE L'AJOUT, et un panneau ancre a sa
    # taille par defaut a cet instant. Les deux boutons partaient hors champ et
    # la fenetre s'affichait sans aucun moyen de la valider.
    $boutons = New-Object System.Windows.Forms.FlowLayoutPanel
    $boutons.Dock = 'Right'
    $boutons.FlowDirection = 'RightToLeft'
    $boutons.Width = 300
    $boutons.Padding = New-Object System.Windows.Forms.Padding(0, 10, 12, 0)
    $boutons.WrapContents = $false
    $boutons.Controls.AddRange(@($btnLancer, $btnAnnuler))

    $pied.Controls.AddRange(@($boutons, $lblEtat))
    $form.Controls.AddRange(@($grpConnexion, $grpPerimetre, $grpExtractions, $pied, $bandeau))
    $form.AcceptButton = $btnLancer
    $form.CancelButton = $btnAnnuler

    # ============================================================ comportement =
    # L'état vit dans une table partagée : les gestionnaires d'événements
    # s'exécutent dans leur propre portée et ne peuvent pas écrire dans les
    # variables de la fonction autrement.
    # L'etat transite par le Tag de la fenetre, PAS par une variable partagee.
    # Mesure : une table de hachage capturee par closure n'est pas vue de la meme
    # facon selon le chemin d'appel, et le niveau de logging observe n'arrivait
    # jamais jusqu'a la barre d'etat. L'objet Form, lui, traverse toutes les
    # fermetures sans ambiguite — tous les autres appels sur $form le prouvent.
    $form.Tag = @{
        LoggingObserve = @()
        Resultat       = $null
    }

    $rafraichir = {
        $decisions = & $fnSelection -Plan $Plan -Tout -LoggingObserve $form.Tag.LoggingObserve
        $grille.Rows.Clear()
        foreach ($audit in $Plan.Audits) {
            $d = $decisions | Where-Object { $_.Cle -eq $audit.Cle } | Select-Object -First 1
            $dispo = ($d.Statut -ne 'Indisponible')
            $i = $grille.Rows.Add(@($dispo, $audit.Nom, $audit.Sortie, $audit.LoggingMinimal,
                                    $(if ($dispo) { 'Disponible' } else { 'Indisponible' })))
            $ligne = $grille.Rows[$i]
            $ligne.Tag = $audit.Cle
            $ligne.Cells['Dispo'].Style.BackColor = $(if ($dispo) { $vertPale } else { $rougePale })
            $ligne.Cells['Dispo'].Style.ForeColor = $(if ($dispo) { $vertTexte } else { $rougeTexte })
            if (-not $dispo) {
                # Non cochable plutôt que cochable-mais-ignorée : une case qu'on
                # peut cocher sans effet est un mensonge d'interface.
                $ligne.Cells['Coche'].ReadOnly = $true
                $ligne.Cells['Nom'].Style.ForeColor = [System.Drawing.Color]::Gray
                $ligne.Cells['Logging'].Style.ForeColor = [System.Drawing.Color]::Gray
                $ligne.Cells['Sortie'].Style.ForeColor = [System.Drawing.Color]::Gray
                $ligne.Cells['Coche'].ToolTipText = $d.Motif
            }
        }
        # Sinon la premiere ligne apparait surlignee en bleu, ce qui ressemble a un
        # etat selectionne alors que ce n'en est pas un.
        $grille.ClearSelection()
        & $majEtat
    }

    $majEtat = {
        $n = 0
        foreach ($ligne in $grille.Rows) {
            if ($ligne.Cells['Coche'].Value -eq $true) { $n++ }
        }
        $texte = "Prêt — $n extraction(s) sélectionnée(s) sur $($grille.Rows.Count)"
        # Le niveau de logging observé vit ICI et non dans la boîte de connexion :
        # mesuré, le libellé y était coincé sous le bouton et « Basic, Performance,
        # Verbose » sortait tronqué à « Basic, Perf ». La barre d'état est large,
        # et c'est de toute façon une information de périmètre, pas de connexion.
        if ($form.Tag.LoggingObserve.Count -gt 0) {
            $texte += "   |   Logging observé : $($form.Tag.LoggingObserve -join ', ')"
        }
        $lblEtat.Text = $texte
        $btnLancer.Enabled = ($n -gt 0)
    }

    $basculerAuth = {
        $txtUtilisateur.Enabled = $radSql.Checked
        $txtMotDePasse.Enabled  = $radSql.Checked
    }.GetNewClosure()

    $radWindows.Add_CheckedChanged($basculerAuth)
    $radSql.Add_CheckedChanged($basculerAuth)
    $radJours.Add_CheckedChanged({ $numJours.Enabled = $radJours.Checked }.GetNewClosure())

    $grille.Add_CellValueChanged({ & $majEtat }.GetNewClosure())
    # Sans cela, une case cochée ne notifie qu'au changement de ligne.
    $grille.Add_CurrentCellDirtyStateChanged({
        if ($grille.IsCurrentCellDirty) {
            $grille.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    }.GetNewClosure())

    $lnkTout.Add_LinkClicked({
        foreach ($l in $grille.Rows) { if (-not $l.Cells['Coche'].ReadOnly) { $l.Cells['Coche'].Value = $true } }
        & $majEtat
    }.GetNewClosure())

    $lnkRien.Add_LinkClicked({
        foreach ($l in $grille.Rows) { if (-not $l.Cells['Coche'].ReadOnly) { $l.Cells['Coche'].Value = $false } }
        & $majEtat
    }.GetNewClosure())

    $btnParcourir.Add_Click({
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Dossier de sortie des CSV'
        if ($txtSortie.Text) { $d.SelectedPath = $txtSortie.Text }
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtSortie.Text = $d.SelectedPath }
    }.GetNewClosure())

    $identifiants = {
        if (-not $radSql.Checked) { return $null }
        if ([string]::IsNullOrWhiteSpace($txtUtilisateur.Text)) { return $null }
        $mdp = New-Object System.Security.SecureString
        foreach ($c in $txtMotDePasse.Text.ToCharArray()) { $mdp.AppendChar($c) }
        return New-Object System.Management.Automation.PSCredential($txtUtilisateur.Text, $mdp)
    }.GetNewClosure()

    $btnTester.Add_Click({
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $cn = & $fnConnexion -Instance $txtInstance.Text -Identifiants (& $identifiants)
            try {
                $form.Tag.LoggingObserve = @(& $fnNiveaux -Connexion $cn)
            }
            finally { $cn.Close() }

            $lblEtatConnexion.ForeColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
            $lblEtatConnexion.Text = if ($form.Tag.LoggingObserve.Count -gt 0) {
                'Connexion réussie'
            } else {
                # Zéro exécution visible ne veut PAS dire catalogue vide : les vues
                # du catalogue sont filtrées par permissions, et un compte sans
                # droit reçoit zéro ligne plutôt qu'un refus.
                "Connexion réussie`nAucune exécution visible"
            }
            & $rafraichir
        }
        catch {
            $form.Tag.LoggingObserve = @()
            $lblEtatConnexion.ForeColor = [System.Drawing.Color]::FromArgb(153, 27, 27)
            $lblEtatConnexion.Text = 'Connexion impossible'
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Connexion impossible',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    }.GetNewClosure())

    $btnLancer.Add_Click({
        if ([string]::IsNullOrWhiteSpace($txtInstance.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show('Indiquez une instance SQL.', 'Champ manquant')
            return
        }
        if ([string]::IsNullOrWhiteSpace($txtSortie.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show('Indiquez un dossier de sortie.', 'Champ manquant')
            return
        }
        $cles = @()
        foreach ($l in $grille.Rows) {
            if ($l.Cells['Coche'].Value -eq $true) { $cles += [string] $l.Tag }
        }
        $form.Tag.Resultat = [PSCustomObject]@{
            Instance      = $txtInstance.Text.Trim()
            Identifiants  = (& $identifiants)
            JoursFenetre  = $(if ($radJours.Checked) { [int] $numJours.Value } else { $null })
            DossierSortie = $txtSortie.Text.Trim()
            Cles          = $cles
        }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    }.GetNewClosure())

    & $rafraichir

    # Le focus va au champ instance, pas a la grille : sans cela la grille le
    # prend a l'ouverture et resurligne sa premiere ligne, ce qui ressemble a un
    # etat selectionne alors que ce n'en est pas un.
    $form.Add_Shown({ $txtInstance.Focus(); $grille.ClearSelection() }.GetNewClosure())

    [void] $form.ShowDialog()

    # Le resultat est lu AVANT Dispose : apres, le Tag n'est plus accessible.
    $resultatFinal = $form.Tag.Resultat
    $form.Dispose()

    return $resultatFinal
}
