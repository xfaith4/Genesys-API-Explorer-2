@{
    RootModule        = 'GenesysCloud.OpsInsights.Core.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c5d7f1f5-1d4a-4b40-9b40-2b4360c7bcdc'
    Author            = 'Ben'
    CompanyName       = 'Personal'
    Copyright         = '(c) Ben. All rights reserved.'
    Description       = 'Core, offline-safe helpers for GenesysCloud.OpsInsights.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @('*')
    CmdletsToExport   = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags        = 'GenesysCloud', 'Ops', 'Analytics'
            ReleaseNotes = 'Initial Core module packaging.'
        }
    }
}

