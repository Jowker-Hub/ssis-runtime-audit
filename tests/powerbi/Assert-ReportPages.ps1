[CmdletBinding()]
param(
    [ValidateSet('vueensemble', 'durees', 'stabilite', 'chronologie', 'gantt', 'operationnel', 'package', 'qualite')]
    [string] $Page,

    # Run the reusable shell contract before analytical page content is added.
    [switch] $StructureOnly
)

$ErrorActionPreference = 'Stop'

$ExpectedPages = @('vueensemble', 'durees', 'stabilite', 'chronologie', 'gantt', 'operationnel', 'package', 'qualite')
$PagesRoot = Join-Path $PSScriptRoot '..\..\powerbi\SsisRuntimeAudit.Report\definition\pages'
$Metadata = Get-Content -Raw (Join-Path $PagesRoot 'pages.json') | ConvertFrom-Json
$ReportDefinition = Get-Content -Raw (Join-Path $PagesRoot '..\report.json') | ConvertFrom-Json

function Get-PageVisuals([string] $PageName) {
    $VisualFiles = @(Get-ChildItem (Join-Path $PagesRoot "$PageName\visuals") -Filter visual.json -Recurse -File -ErrorAction SilentlyContinue)
    return @($VisualFiles | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
}

function Get-VisualTitle($Visual) {
    $ContainerTitle = $null
    if ($Visual.visual.visualContainerObjects.title) {
        $ContainerTitle = $Visual.visual.visualContainerObjects.title[0].properties.text.expr.Literal.Value
    }
    if ($ContainerTitle) { return $ContainerTitle.Trim("'") }

    $CardLabel = $null
    if ($Visual.visual.objects.label) {
        $CardLabel = $Visual.visual.objects.label[0].properties.text.expr.Literal.Value
    }
    if ($CardLabel) { return $CardLabel.Trim("'") }

    return $null
}

function Assert-PageTitles([string] $PageName, [string[]] $ExpectedTitles) {
    $Titles = @(Get-PageVisuals $PageName | ForEach-Object { Get-VisualTitle $_ } | Where-Object { $_ })
    foreach ($ExpectedTitle in $ExpectedTitles) {
        if ($ExpectedTitle -notin $Titles) {
            throw "$PageName is missing required visual title: $ExpectedTitle"
        }
    }
}

function Assert-NoCustomVisuals([string] $PageName) {
    $NativeVisualTypes = @('actionButton', 'barChart', 'cardVisual', 'columnChart', 'comboChart', 'donutChart', 'lineChart', 'matrix', 'scatterChart', 'shape', 'slicer', 'tableEx', 'textbox')
    foreach ($Visual in (Get-PageVisuals $PageName)) {
        if ($Visual.visual.visualType -and $Visual.visual.visualType -notin $NativeVisualTypes) {
            throw "$PageName contains a non-native visual type: $($Visual.visual.visualType)"
        }
    }
}

function Get-PageVisualJson([string] $PageName) {
    return (Get-PageVisuals $PageName | ConvertTo-Json -Depth 100)
}

function Assert-PageText([string] $PageName, [string] $ExpectedText) {
    if ((Get-PageVisualJson $PageName) -notlike "*$ExpectedText*") {
        throw "$PageName is missing required text: $ExpectedText"
    }
}

function Assert-UsesMeasure([string] $PageName, [string] $Measure) {
    $MeasureProperty = '"Property": "' + $Measure + '"'
    if ((Get-PageVisualJson $PageName) -notlike "*$MeasureProperty*") {
        throw "$PageName does not use required measure: $Measure"
    }
}

function Assert-UniqueVisualIds([string] $PageName) {
    $Ids = @((Get-PageVisuals $PageName).name)
    $Duplicates = @($Ids | Group-Object | Where-Object Count -gt 1)
    if ($Duplicates) { throw "$PageName contains duplicate visual IDs." }
}

function Assert-OneActiveNavigationButton([string] $PageName) {
    $Buttons = @(Get-PageVisuals $PageName | Where-Object { $_.visual.visualType -eq 'actionButton' })
    $Active = @($Buttons | Where-Object {
        $_.visual.objects.fill[0].properties.fillColor.solid.color.expr.Literal.Value.Trim("'") -eq '#2F65A8'
    })
    if ($Active.Count -ne 1) { throw "$PageName must have exactly one active navigation button." }
}

function Assert-NoVisualType([string] $PageName, [string] $VisualType) {
    if (Get-PageVisuals $PageName | Where-Object { $_.visual.visualType -eq $VisualType }) {
        throw "$PageName contains forbidden visual type: $VisualType"
    }
}

function Assert-FunctionalVisualShadows([string] $PageName) {
    $Functional = @(Get-PageVisuals $PageName | Where-Object {
        $_.visual.visualType -and $_.visual.visualType -notin @('actionButton', 'shape', 'textbox')
    })
    foreach ($Visual in $Functional) {
        $Shadow = $Visual.visual.visualContainerObjects.dropShadow[0].properties
        if (-not $Shadow -or $Shadow.show.expr.Literal.Value -ne 'true' -or $Shadow.preset.expr.Literal.Value.Trim("'") -ne 'BottomRight') {
            throw "$PageName visual $($Visual.name) is missing the required bottom-right shadow."
        }
    }
}

function Get-VisualByTitle([string] $PageName, [string] $Title) {
    return @(Get-PageVisuals $PageName | Where-Object { (Get-VisualTitle $_) -eq $Title })
}

function Assert-VisualType([string] $PageName, [string] $Title, [string] $ExpectedType) {
    $Matches = @(Get-VisualByTitle $PageName $Title)
    if ($Matches.Count -ne 1) { throw "$PageName must contain exactly one visual titled $Title." }
    if ($Matches[0].visual.visualType -ne $ExpectedType) {
        throw "$PageName visual $Title must use $ExpectedType, found $($Matches[0].visual.visualType)."
    }
}

function Assert-SlicerHeader([string] $PageName, [string] $Header) {
    $Matches = @(Get-PageVisuals $PageName | Where-Object {
        $_.visual.visualType -eq 'slicer' -and
        $_.visual.objects.header[0].properties.text.expr.Literal.Value.Trim("'") -eq $Header
    })
    if ($Matches.Count -ne 1) { throw "$PageName must contain exactly one slicer headed $Header." }
}

function Assert-ContextButton([string] $PageName, [string] $Text, [string] $Target) {
    $Matches = @(Get-PageVisuals $PageName | Where-Object {
        $_.visual.visualType -eq 'actionButton' -and
        $_.visual.objects.text[1].properties.text.expr.Literal.Value.Trim("'") -eq $Text -and
        $_.visual.visualContainerObjects.visualLink[0].properties.navigationSection.expr.Literal.Value.Trim("'") -eq $Target
    })
    if ($Matches.Count -ne 1) { throw "$PageName must contain exactly one $Text button targeting $Target." }
}

function Assert-TextboxBody([string] $PageName, [string] $ExpectedText) {
    $Bodies = @(Get-PageVisuals $PageName | Where-Object { $_.visual.visualType -eq 'textbox' } | ForEach-Object {
        $_.visual.objects.general[0].properties.paragraphs[0].textRuns[0].value
    })
    if ($ExpectedText -notin $Bodies) { throw "$PageName is missing visible textbox body: $ExpectedText" }
}

function Assert-WideKpiCards([string] $PageName, [string[]] $Titles) {
    foreach ($Title in $Titles) {
        $Visual = @(Get-VisualByTitle $PageName $Title)
        if ($Visual.Count -ne 1 -or $Visual[0].position.width -lt 240) {
            throw "$PageName KPI $Title must be at least 240 canvas units wide."
        }
    }
}

function Get-LiteralValue($Property) {
    if (-not $Property -or -not $Property.expr -or -not $Property.expr.Literal) { return $null }
    return $Property.expr.Literal.Value
}

function Assert-BarCategoryLabelSpace([string] $PageName, [string[]] $Titles) {
    foreach ($Title in $Titles) {
        $Visual = @(Get-VisualByTitle $PageName $Title)
        if ($Visual.Count -ne 1) { throw "$PageName must contain exactly one visual titled $Title." }
        $MaximumSize = Get-LiteralValue $Visual[0].visual.objects.categoryAxis[0].properties.maxMarginFactor
        if (-not $MaximumSize -or [int]$MaximumSize.TrimEnd('D') -lt 35) {
            throw "$PageName bar chart $Title must reserve at least 35 percent for category labels."
        }
    }
}

function Assert-ReadablePercentileChart([string] $PageName, [string] $Title) {
    $Visual = @(Get-VisualByTitle $PageName $Title)
    if ($Visual.Count -ne 1) { throw "$PageName must contain exactly one visual titled $Title." }

    $LegendShow = Get-LiteralValue $Visual[0].visual.objects.legend[0].properties.show
    $LabelsShow = Get-LiteralValue $Visual[0].visual.objects.labels[0].properties.show
    if ($LegendShow -ne 'true') { throw "$PageName chart $Title must display its percentile legend." }
    if ($LabelsShow -ne 'false') { throw "$PageName chart $Title must hide overlapping point labels." }
}

function Assert-StabilityPageLayout {
    $Trend = @(Get-VisualByTitle 'stabilite' 'Évolution des durées')
    $Stability = @(Get-VisualByTitle 'stabilite' 'Stabilité par package')
    $Comparison = @(Get-VisualByTitle 'stabilite' 'Fenêtre récente vs ancienne')
    if ($Trend.Count -ne 1 -or $Stability.Count -ne 1 -or $Comparison.Count -ne 1) {
        throw 'stabilite must contain exactly one trend and two detail tables.'
    }

    $LegendShow = Get-LiteralValue $Trend[0].visual.objects.legend[0].properties.show
    if ($LegendShow -ne 'true') { throw 'stabilite trend must display its series legend.' }
    if ($Stability[0].position.width -lt 1000 -or $Comparison[0].position.width -lt 1000) {
        throw 'stabilite detail tables must use the full analytical width.'
    }
    if ($Stability[0].position.height -lt 130 -or $Comparison[0].position.height -lt 130) {
        throw 'stabilite detail tables must reserve enough height for package rows.'
    }
    if ($Comparison[0].position.y -le ($Stability[0].position.y + $Stability[0].position.height)) {
        throw 'stabilite detail tables must be stacked without overlap.'
    }

    foreach ($Table in @($Stability[0], $Comparison[0])) {
        $TotalsShow = Get-LiteralValue $Table.visual.objects.total[0].properties.totals
        $RowPadding = Get-LiteralValue $Table.visual.objects.grid[0].properties.rowPadding
        $PackageProjection = $Table.visual.query.queryState.Values.projections[0].field.Column
        if ($TotalsShow -ne 'false') { throw 'stabilite detail-table totals must be hidden.' }
        if (-not $RowPadding -or [int]$RowPadding.TrimEnd('D') -gt 2) {
            throw 'stabilite detail tables must use compact row padding.'
        }
        if ($PackageProjection.Expression.SourceRef.Entity -ne 'Executions' -or $PackageProjection.Property -ne 'Package') {
            throw 'stabilite detail tables must use Executions[Package] to exclude the technical blank member.'
        }
    }
}

function Assert-GanttModelContract {
    $ModelRoot = Join-Path $PSScriptRoot '..\..\powerbi\SsisRuntimeAudit.SemanticModel\definition'
    $ThresholdPath = Join-Path $ModelRoot 'tables\SeuilGantt.tmdl'
    $Threshold = if (Test-Path -LiteralPath $ThresholdPath) { Get-Content -Raw -LiteralPath $ThresholdPath } else { '' }
    $Measures = Get-Content -Raw -LiteralPath (Join-Path $ModelRoot 'tables\Mesures.tmdl')
    $Model = Get-Content -Raw -LiteralPath (Join-Path $ModelRoot 'model.tmdl')

    if ($Threshold -notlike '*GENERATESERIES ( 0, 120, 1 )*') {
        throw 'SeuilGantt must expose 0..120 minutes by one-minute steps.'
    }
    if ($Model -notlike '*ref table SeuilGantt*') {
        throw 'Model must reference SeuilGantt.'
    }
    foreach ($Measure in @(
        'Seuil Gantt selectionne (min)', 'Duree Gantt visible (s)', 'Duree Gantt preview (s)',
        'Executions Gantt affichees', 'Duree maximale Gantt (min)', 'Etat Gantt', 'Etat Gantt preview'
    )) {
        if ($Measures -notlike "*measure '$Measure'*") {
            throw "Missing Gantt measure: $Measure"
        }
    }
    if ($Measures -notlike '*Aucune exécution de 5 minutes ou plus*') {
        throw 'Etat Gantt preview must expose the approved fixed-threshold empty-state message.'
    }
}

Assert-GanttModelContract

if ((@($Metadata.pageOrder) -join '|') -ne ($ExpectedPages -join '|')) {
    throw 'Unexpected page order.'
}

foreach ($PageName in $ExpectedPages) {
    $PageDefinition = Get-Content -Raw (Join-Path $PagesRoot "$PageName\page.json") | ConvertFrom-Json
    if ($PageDefinition.width -ne 1280 -or $PageDefinition.height -ne 720) {
        throw "$PageName has an invalid canvas."
    }

    $Visuals = @(Get-PageVisuals $PageName)
    $Buttons = @($Visuals | Where-Object { $_.visual.visualType -eq 'actionButton' -and $_.position.x -eq 13 })

    if ($Buttons.Count -ne 8) {
        throw "$PageName must contain eight navigation buttons."
    }

    foreach ($Button in $Buttons) {
        $Target = $Button.visual.visualContainerObjects.visualLink[0].properties.navigationSection.expr.Literal.Value.Trim("'")
        if ($Target -notin $ExpectedPages) {
            throw "$PageName has a navigation button targeting an undeclared page: $Target"
        }
    }
}

if ($StructureOnly) {
    Write-Host "Validated report page structure: $($ExpectedPages -join ', ')."
    return
}

if (-not $Page -or $Page -eq 'durees') {
    Assert-PageTitles 'durees' @(
        'Durée médiane', 'Durée cumulée', 'Exécutions observées', 'Attente médiane',
        'Durée cumulée par package', 'Fréquence par package', 'Latence et fréquence',
        'Distribution des durées', 'Versions observées'
    )
    Assert-NoCustomVisuals 'durees'
    Assert-WideKpiCards 'durees' @('Durée médiane', 'Durée cumulée', 'Exécutions observées', 'Attente médiane')
    Assert-VisualType 'durees' 'Distribution des durées' 'lineChart'
    Assert-BarCategoryLabelSpace 'durees' @('Durée cumulée par package', 'Fréquence par package')
    Assert-ReadablePercentileChart 'durees' 'Distribution des durées'
}

if (-not $Page -or $Page -eq 'stabilite') {
    Assert-PageTitles 'stabilite' @(
        'Packages actifs', 'Exécutions mesurables', 'Durée médiane', 'Niveau de confiance',
        'Évolution des durées', 'Stabilité par package', 'Fenêtre récente vs ancienne'
    )
    Assert-PageText 'stabilite' 'Un changement de version établit une coïncidence, pas une causalité.'
    Assert-WideKpiCards 'stabilite' @('Packages actifs', 'Exécutions mesurables', 'Durée médiane', 'Niveau de confiance')
    Assert-TextboxBody 'stabilite' 'Un changement de version établit une coïncidence, pas une causalité.'
    Assert-StabilityPageLayout
}

if (-not $Page -or $Page -eq 'chronologie') {
    Assert-PageTitles 'chronologie' @(
        'Exécutions simultanées max', 'Attente médiane', 'Plage horaire observée', 'Machines observées',
        'Gantt des exécutions — aperçu ≥ 5 min', 'Exécutions simultanées — pas de 5 min',
        'Lecture du délai', 'État de la prévisualisation'
    )
    Assert-PageText 'chronologie' 'La concurrence observée ne prouve pas une saturation machine.'
    Assert-WideKpiCards 'chronologie' @('Exécutions simultanées max', 'Attente médiane', 'Plage horaire observée', 'Machines observées')
    Assert-TextboxBody 'chronologie' 'La concurrence observée ne prouve pas une saturation machine.'
    Assert-VisualType 'chronologie' 'Lecture du délai' 'cardVisual'
    Assert-UsesMeasure 'chronologie' 'Lecture delai demarrage'
    Assert-UsesMeasure 'chronologie' 'Duree Gantt preview (s)'
    Assert-UsesMeasure 'chronologie' 'Etat Gantt preview'
    Assert-ContextButton 'chronologie' 'Ouvrir le Gantt détaillé' 'gantt'

    $Gantt = @(Get-VisualByTitle 'chronologie' 'Gantt des exécutions — aperçu ≥ 5 min')
    if ($Gantt.Count -ne 1) { throw 'chronologie must contain exactly one execution Gantt.' }
    if ($Gantt[0].visual.visualType -in @('barChart', 'tableEx', 'matrix')) {
        throw 'chronologie execution timeline must use the approved custom Gantt visual.'
    }
    if ($Gantt[0].position.width -lt 1000 -or $Gantt[0].position.height -lt 200 -or $Gantt[0].position.height -gt 260) {
        throw 'chronologie execution Gantt must remain a compact full-width preview.'
    }
    foreach ($Field in @('LibelleExecution', 'HeureDebut')) {
        if ((($Gantt[0] | ConvertTo-Json -Depth 100)) -notlike "*`"Property`": `"$Field`"*") {
            throw "chronologie execution Gantt must use Executions[$Field]."
        }
    }
    $GanttRoles = @($Gantt[0].visual.query.queryState.PSObject.Properties.Name | Sort-Object)
    if (($GanttRoles -join '|') -ne 'Duration|StartDate|Task') {
        throw 'chronologie execution Gantt must first use the minimal Microsoft-supported Task, StartDate and Duration mapping.'
    }
    $DurationProjection = $Gantt[0].visual.query.queryState.Duration.projections[0]
    if ($DurationProjection.queryRef -ne 'Mesures.Duree Gantt preview (s)') {
        throw 'chronologie execution Gantt must use the fixed five-minute preview measure.'
    }
    $GanttSort = $Gantt[0].visual.query.sortDefinition.sort[0]
    if ($GanttSort.field.Column.Property -ne 'HeureDebut' -or $GanttSort.direction -ne 'Ascending') {
        throw 'chronologie execution Gantt must sort executions chronologically by HeureDebut.'
    }
    foreach ($RemovedTitle in @('Chronologie des exécutions', 'Concurrence par heure et jour')) {
        if (@(Get-VisualByTitle 'chronologie' $RemovedTitle).Count -ne 0) {
            throw "chronologie must remove the redundant visual: $RemovedTitle"
        }
    }
    $GanttRegistration = @($ReportDefinition.publicCustomVisuals | Where-Object { $_ -eq 'Gantt1448688115699' })
    if ($GanttRegistration.Count -ne 1) {
        throw 'chronologie must register the approved Microsoft Gantt AppSource visual.'
    }
}

if (-not $Page -or $Page -eq 'gantt') {
    Assert-PageTitles 'gantt' @(
        'Exécutions affichées', 'Durée maximale', 'Concurrence maximale',
        'Gantt des exécutions longues', 'État du Gantt'
    )
    foreach ($Header in @('Jour affiché', 'Durée minimale', 'Machine', 'Statut')) {
        Assert-SlicerHeader 'gantt' $Header
    }
    Assert-UsesMeasure 'gantt' 'Duree Gantt visible (s)'
    Assert-UsesMeasure 'gantt' 'Etat Gantt'
    Assert-ContextButton 'gantt' 'Retour à la chronologie' 'chronologie'

    $Gantt = @(Get-VisualByTitle 'gantt' 'Gantt des exécutions longues')
    if ($Gantt.Count -ne 1) { throw 'gantt must contain exactly one detailed execution Gantt.' }
    if ($Gantt[0].visual.visualType -ne 'Gantt1448688115699') {
        throw 'gantt must use the approved Microsoft Gantt custom visual.'
    }
    if ($Gantt[0].position.width -lt 1000 -or $Gantt[0].position.height -lt 380) {
        throw 'gantt detailed timeline must use the full analytical width and at least 380 canvas units of height.'
    }
    foreach ($Field in @('LibelleExecution', 'HeureDebut')) {
        if ((($Gantt[0] | ConvertTo-Json -Depth 100)) -notlike "*`"Property`": `"$Field`"*") {
            throw "gantt must use Executions[$Field]."
        }
    }
    $GanttRoles = @($Gantt[0].visual.query.queryState.PSObject.Properties.Name | Sort-Object)
    if (($GanttRoles -join '|') -ne 'Duration|StartDate|Task') {
        throw 'gantt must first use the minimal Microsoft-supported Task, StartDate and Duration mapping.'
    }
    $DurationProjection = $Gantt[0].visual.query.queryState.Duration.projections[0]
    if ($DurationProjection.queryRef -ne 'Mesures.Duree Gantt visible (s)') {
        throw 'gantt duration must use the dynamic threshold measure.'
    }
    $GanttSort = $Gantt[0].visual.query.sortDefinition.sort[0]
    if ($GanttSort.field.Column.Property -ne 'HeureDebut' -or $GanttSort.direction -ne 'Ascending') {
        throw 'gantt must sort executions chronologically by HeureDebut.'
    }
}

if (-not $Page -or $Page -eq 'operationnel') {
    Assert-PageTitles 'operationnel' @(
        'Taux de réussite', 'Exécutions en échec', 'Exécutions interrompues', 'Exécutions avec incident',
        'Résultats des exécutions', 'Packages concernés', 'Erreurs par code', 'Composants concernés'
    )
    Assert-UsesMeasure 'operationnel' 'Motif messages'
    Assert-WideKpiCards 'operationnel' @('Taux de réussite', 'Exécutions en échec', 'Exécutions interrompues', 'Exécutions avec incident')
}

if (-not $Page -or $Page -eq 'package') {
    Assert-PageTitles 'package' @(
        'Package sélectionné', 'Projet', 'Version', 'Exécutions', 'Durée médiane', 'Confiance',
        'Répartition du temps par exécutable', "Hiérarchie d’exécution", 'Durée par itération de boucle',
        'Phases de composants', 'Lignes transmises par chemin'
    )
    Assert-UsesMeasure 'package' 'Motif phases de composants'
    Assert-UsesMeasure 'package' 'Motif statistiques de flux'
    Assert-UsesMeasure 'package' 'Package selectionne'
    Assert-UsesMeasure 'package' 'Duree executable mediane (s)'
}

if (-not $Page -or $Page -eq 'qualite') {
    Assert-PageTitles 'qualite' @(
        'Fenêtre extraite', 'Exécutions observées', 'Packages actifs', 'Versions observées',
        'Capacités disponibles', 'Couverture des données', 'Contrôles de qualité',
        'Contexte du catalogue', 'Non mesurable dans ce contexte'
    )
    Assert-PageText 'qualite' 'Saturation machine'
    Assert-PageText 'qualite' 'Chemin critique'
    Assert-PageText 'qualite' "Cause d’une dérive"
    Assert-WideKpiCards 'qualite' @('Fenêtre extraite', 'Exécutions observées', 'Packages actifs', 'Versions observées')
    if (Get-PageVisuals 'qualite' | Where-Object { (Get-VisualTitle $_) -eq 'Couverture des données' -and $_.visual.visualType -eq 'columnChart' }) {
        throw 'qualite must not use a stacked dummy-category coverage chart.'
    }
    Assert-PageTitles 'qualite' @('Couverture Basic', 'Couverture Performance', 'Couverture Verbose', 'Exécutions détaillées')
}

$PagesToCheck = if ($Page) { @($Page) } else { $ExpectedPages }
foreach ($PageName in $PagesToCheck) {
    Assert-UniqueVisualIds $PageName
    Assert-OneActiveNavigationButton $PageName
    Assert-NoVisualType $PageName 'pageNavigator'
    if ($PageName -in @('chronologie', 'gantt')) {
        $CustomVisualTypes = @(Get-PageVisuals $PageName | ForEach-Object { $_.visual.visualType } | Where-Object {
            $_ -and $_ -notin @('actionButton', 'barChart', 'cardVisual', 'columnChart', 'comboChart', 'donutChart', 'lineChart', 'matrix', 'scatterChart', 'shape', 'slicer', 'tableEx', 'textbox')
        } | Sort-Object -Unique)
        if ((@($CustomVisualTypes) -join '|') -ne 'Gantt1448688115699') {
            throw 'chronologie may use only the approved Microsoft Gantt custom visual.'
        }
    }
    else {
        Assert-NoCustomVisuals $PageName
    }
    Assert-FunctionalVisualShadows $PageName
}

Write-Host "Validated report page structure: $($ExpectedPages -join ', ')."
