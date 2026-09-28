@{
    RootModule        = 'SsisRuntimeAudit.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c7f1a6d2-3b84-4e19-9a5c-6d0f2e8b41c3'
    Author            = 'Emmanuel Champel'
    Description       = 'Audit des temps d execution SSIS : extrait les faits de SSISDB vers un jeu de CSV, en lecture seule stricte.'

    # 5.1 est le plancher : c'est ce qui est installe par defaut sur les postes
    # et serveurs clients, ou l'on n'a generalement pas le droit d'installer
    # PowerShell 7. Le module doit tourner tel quel sur une machine d'audit.
    #
    # Consequence directe : pas de module SqlServer, pas d'Invoke-Sqlcmd. On
    # passe par System.Data.SqlClient, present dans le .NET Framework de toute
    # machine Windows.
    PowerShellVersion = '5.1'

    # Liste explicite plutot que '*' : le manifeste documente la surface
    # publique, et une fonction oubliee ici se voit immediatement au test.
    FunctionsToExport = @(
        'Invoke-SsisRuntimeAudit'
        'Get-SsisRuntimeAuditPlan'
        'Test-SsisRuntimeAuditPrerequis'
    , 'Test-SsisRuntimeAuditPrerequis')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('SSIS', 'Audit', 'Performance', 'SSISDB', 'SQLServer')
            ProjectUri = 'https://github.com/Jowker-Hub/SSIS-Toolkit'
        }
    }
}
