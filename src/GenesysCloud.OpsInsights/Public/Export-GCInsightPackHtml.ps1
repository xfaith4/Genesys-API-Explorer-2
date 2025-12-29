function Export-GCInsightPackHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Result,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    # Proxy into the Core module implementation.
    if (Get-Module -Name 'GenesysCloud.OpsInsights.Core') {
        return GenesysCloud.OpsInsights.Core\Export-GCInsightPackHtml -Result $Result -Path $Path
    }

    throw "GenesysCloud.OpsInsights.Core is not loaded; cannot call Export-GCInsightPackHtml."
}

