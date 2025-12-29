<#
.SYNOPSIS
    Genesys Cloud API Explorer GUI Tool (WPF)

.DESCRIPTION
    Uses WPF to provide a more structured API explorer experience with
    grouped navigation, dynamic parameter inputs, and a transparency-focused
    log so every request/response step is visible.

.NOTES
    - Valid JSON catalog required from the Genesys Cloud API Explorer.
    - Paste your OAuth token into the supplied field before sending requests.
#>

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ScriptRoot) {
    $ScriptRoot = Get-Location
}

$DeveloperDocsUrl = "https://developer.genesys.cloud"
$SupportDocsUrl = "https://help.mypurecloud.com"

function Get-TraceLogPath {
    try {
        $base = [System.IO.Path]::GetTempPath()
        if (-not $base) { $base = $ScriptRoot }
        $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        return (Join-Path -Path $base -ChildPath "GenesysApiExplorer.trace.$stamp.log")
    }
    catch {
        return $null
    }
}

$script:TraceEnabled = $false
try {
    $traceRaw = [string]$env:GENESYS_API_EXPLORER_TRACE
    $script:TraceEnabled = ($traceRaw -match '^(1|true|yes|on)$')
}
catch { }

$script:TraceLogPath = if ($script:TraceEnabled) { Get-TraceLogPath } else { $null }

function Write-TraceLog {
    param([string]$Message)

    if (-not $script:TraceEnabled) { return }
    if ([string]::IsNullOrWhiteSpace($script:TraceLogPath)) { return }

    try {
        $ts = (Get-Date).ToString('o')
        Add-Content -LiteralPath $script:TraceLogPath -Value "$ts $Message" -Encoding utf8
    }
    catch { }
}

function Open-Url {
    param ([string]$Url)

    if (-not $Url) { return }
    try {
        Start-Process -FilePath $Url
    }
    catch {
        Write-Warning "Unable to open URL '$Url': $($_.Exception.Message)"
    }
}

function Launch-Url {
    param ([string]$Url)
    Open-Url -Url $Url
}

function Get-FirstNonEmptyValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object[]]$Values = @(),
        [Parameter()]
        [object]$Default = $null
    )

    if ($null -eq $Values -or $Values.Count -eq 0) {
        try {
            $caller = $null
            try { $caller = (Get-PSCallStack | Select-Object -Skip 1 -First 1).Command } catch { }
            Write-TraceLog "Get-FirstNonEmptyValue: Values is null/empty; returning default. Caller='$caller'"
        }
        catch { }
        return $Default
    }

    foreach ($v in $Values) {
        if ($null -eq $v) { continue }
        if ($v -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
        }
        else {
            return $v
        }
    }
    return $Default
}

function Get-InsightPackCatalog {
    param(
        [Parameter(Mandatory)]
        [string]$PackDirectory,

        [Parameter()]
        [string]$LegacyPackDirectory
    )

    $dirs = New-Object System.Collections.Generic.List[string]
    if ($PackDirectory -and (Test-Path -LiteralPath $PackDirectory)) { $dirs.Add($PackDirectory) | Out-Null }
    if ($LegacyPackDirectory -and (Test-Path -LiteralPath $LegacyPackDirectory) -and (-not ($LegacyPackDirectory -eq $PackDirectory))) {
        $dirs.Add($LegacyPackDirectory) | Out-Null
    }

    $items = New-Object System.Collections.Generic.List[object]
    $script:InsightPackCatalogErrors = New-Object System.Collections.Generic.List[string]
    Write-TraceLog "Get-InsightPackCatalog: PackDirectory='$PackDirectory' (exists=$(Test-Path -LiteralPath $PackDirectory)); LegacyPackDirectory='$LegacyPackDirectory' (exists=$(Test-Path -LiteralPath $LegacyPackDirectory))"
    foreach ($dir in $dirs) {
        $files = @()
        try {
            $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop | Where-Object { $_.Extension -eq '.json' } | Sort-Object Name)
            Write-TraceLog "Get-InsightPackCatalog: dir='$dir' jsonCount=$($files.Count)"
        }
        catch {
            try { $script:InsightPackCatalogErrors.Add("$dir :: $($_.Exception.Message)") | Out-Null } catch { }
            Write-TraceLog "Get-InsightPackCatalog: dir='$dir' enumerate error: $($_.Exception.Message)"
            continue
        }

        foreach ($file in $files) {
            $packPath = $file.FullName
            try {
                $raw = Get-Content -LiteralPath $packPath -Raw -Encoding utf8
                $pack = $raw | ConvertFrom-Json
                if (-not $pack) {
                    Write-TraceLog "Get-InsightPackCatalog: file='$packPath' parsed pack is null"
                    continue
                }
                if (-not $pack.id) {
                    Write-TraceLog "Get-InsightPackCatalog: file='$packPath' missing/empty id"
                    continue
                }

                $examples = @()
                if ($pack -and ($pack.PSObject.Properties.Name -contains 'examples') -and $pack.examples) {
                    foreach ($ex in @($pack.examples)) {
                        if (-not $ex) { continue }
                        $examples += [pscustomobject]@{
                            Title      = [string](Get-FirstNonEmptyValue -Values @($ex.title, $ex.name) -Default 'Example')
                            Notes      = [string](Get-FirstNonEmptyValue -Values @($ex.notes) -Default '')
                            Parameters = $ex.parameters
                        }
                    }
                }

                $items.Add([pscustomobject]@{
                        Id                 = [string]$pack.id
                        Name               = [string](Get-FirstNonEmptyValue -Values @($pack.name, $pack.id) -Default $pack.id)
                        Version            = [string](Get-FirstNonEmptyValue -Values @($pack.version) -Default '')
                        Description        = [string](Get-FirstNonEmptyValue -Values @($pack.description) -Default '')
                        Scopes             = @(Get-FirstNonEmptyValue -Values @($pack.scopes, $pack.requiredScopes) -Default @())
                        Owner              = [string](Get-FirstNonEmptyValue -Values @($pack.owner) -Default '')
                        Maturity           = [string](Get-FirstNonEmptyValue -Values @($pack.maturity) -Default '')
                        ExpectedRuntimeSec = if ($pack.PSObject.Properties.Name -contains 'expectedRuntimeSec') { $pack.expectedRuntimeSec } else { $null }
                        Tags               = @($pack.tags)
                        Endpoints          = @(
                            foreach ($step in @($pack.pipeline)) {
                                if (-not $step -or -not $step.type) { continue }
                                $t = $step.type.ToString().ToLowerInvariant()
                                if ($t -eq 'gcrequest') {
                                    (Get-FirstNonEmptyValue -Values @($step.uri, $step.path) -Default $null)
                                }
                                elseif ($t -eq 'jobpoll' -and $step.create) {
                                    (Get-FirstNonEmptyValue -Values @($step.create.uri, $step.create.path) -Default $null)
                                }
                                elseif ($t -eq 'join' -and $step.lookup) {
                                    (Get-FirstNonEmptyValue -Values @($step.lookup.uri, $step.lookup.path) -Default $null)
                                }
                            }
                        ) | Where-Object { $_ }
                        Examples           = $examples
                        FileName           = $file.Name
                        FullPath           = $file.FullName
                        Pack               = $pack
                        Display            = if ($pack.name) { "$($pack.name)  [$($pack.id)]" } else { [string]$pack.id }
                    }) | Out-Null
                Write-TraceLog "Get-InsightPackCatalog: loaded id='$($pack.id)' name='$($pack.name)' file='$($file.Name)'"
            }
            catch {
                try { $script:InsightPackCatalogErrors.Add("$packPath :: $($_.Exception.Message)") | Out-Null } catch { }
                Write-TraceLog "Get-InsightPackCatalog: file='$packPath' parse error: $($_.Exception.Message)"
            }
        }
    }

    Write-TraceLog "Get-InsightPackCatalog: totalLoaded=$($items.Count)"
    return @($items | Sort-Object Name, Id)
}

function Get-InsightTimePresets {
    return @(
        [pscustomobject]@{ Key = 'last7'; Name = 'Last 7 days (ending now)' },
        [pscustomobject]@{ Key = 'last30'; Name = 'Last 30 days (ending now)' },
        [pscustomobject]@{ Key = 'thisWeek'; Name = 'This week (Mon 00:00 → now, UTC)' },
        [pscustomobject]@{ Key = 'lastWeek'; Name = 'Last full week (Mon → Mon, UTC)' },
        [pscustomobject]@{ Key = 'thisMonth'; Name = 'This month (1st 00:00 → now, UTC)' },
        [pscustomobject]@{ Key = 'lastMonth'; Name = 'Last full month (1st → 1st, UTC)' }
    )
}

function Resolve-InsightUtcWindowFromPreset {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PresetKey
    )

    $now = (Get-Date).ToUniversalTime()

    function Start-OfWeekUtc {
        param([datetime]$UtcNow)

        $dow = [int]$UtcNow.DayOfWeek
        $mondayIndex = 1
        $daysSinceMonday = ($dow - $mondayIndex)
        if ($daysSinceMonday -lt 0) { $daysSinceMonday += 7 }
        $start = $UtcNow.Date.AddDays(-1 * $daysSinceMonday)
        return [datetime]::SpecifyKind($start, [System.DateTimeKind]::Utc)
    }

    function Start-OfMonthUtc {
        param([datetime]$UtcNow)
        $start = New-Object datetime($UtcNow.Year, $UtcNow.Month, 1, 0, 0, 0)
        return [datetime]::SpecifyKind($start, [System.DateTimeKind]::Utc)
    }

    switch ($PresetKey) {
        'last7' {
            return [pscustomobject]@{ StartUtc = $now.AddDays(-7); EndUtc = $now }
        }
        'last30' {
            return [pscustomobject]@{ StartUtc = $now.AddDays(-30); EndUtc = $now }
        }
        'thisWeek' {
            return [pscustomobject]@{ StartUtc = (Start-OfWeekUtc -UtcNow $now); EndUtc = $now }
        }
        'lastWeek' {
            $thisWeekStart = Start-OfWeekUtc -UtcNow $now
            return [pscustomobject]@{ StartUtc = $thisWeekStart.AddDays(-7); EndUtc = $thisWeekStart }
        }
        'thisMonth' {
            return [pscustomobject]@{ StartUtc = (Start-OfMonthUtc -UtcNow $now); EndUtc = $now }
        }
        'lastMonth' {
            $thisMonthStart = Start-OfMonthUtc -UtcNow $now
            return [pscustomobject]@{ StartUtc = $thisMonthStart.AddMonths(-1); EndUtc = $thisMonthStart }
        }
        default {
            throw "Unknown time preset key: $PresetKey"
        }
    }
}

function New-InsightPackParameterRow {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$Type,

        [Parameter()]
        [bool]$Required = $false,

        [Parameter()]
        $DefaultValue,

        [Parameter()]
        [string]$Description
    )

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,2,0,2'
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '220' }))
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '*' }))

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = if ($Required) { "$Name *" } else { $Name }
    $label.FontWeight = 'SemiBold'
    $label.VerticalAlignment = 'Center'
    if ($Description) { $label.ToolTip = $Description }
    [System.Windows.Controls.Grid]::SetColumn($label, 0)
    [void]$grid.Children.Add($label)

    $control = $null
    $normalizedType = if ($Type) { $Type.ToLowerInvariant() } else { '' }
    if ($normalizedType -in @('bool', 'boolean')) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.VerticalAlignment = 'Center'
        $cb.IsChecked = if ($null -ne $DefaultValue) { [bool]$DefaultValue } else { $false }
        if ($Description) { $cb.ToolTip = $Description }
        $control = $cb
    }
    else {
        $tb = New-Object System.Windows.Controls.TextBox
        $tb.MinWidth = 220
        $tb.Height = 26
        $tb.VerticalContentAlignment = 'Center'
        $tb.Text = if ($null -ne $DefaultValue) { [string]$DefaultValue } else { '' }
        if ($Description) { $tb.ToolTip = $Description }
        $control = $tb
    }

    [System.Windows.Controls.Grid]::SetColumn($control, 1)
    [void]$grid.Children.Add($control)

    return [pscustomobject]@{
        Name    = $Name
        Control = $control
        Row     = $grid
    }
}

function Render-InsightPackParameters {
    param(
        [Parameter(Mandatory)]
        $Pack,

        [Parameter(Mandatory)]
        [System.Windows.Controls.Panel]$Panel
    )

    $Panel.Children.Clear()
    $script:InsightParamInputs = @{}

    if (-not $Pack -or -not $Pack.parameters) {
        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Text = '(No parameters)'
        $hint.Foreground = 'Gray'
        [void]$Panel.Children.Add($hint)
        return
    }

    foreach ($prop in ($Pack.parameters.PSObject.Properties | Sort-Object Name)) {
        $paramName = $prop.Name
        $definition = $prop.Value

        $type = $null
        $required = $false
        $default = $null
        $desc = $null

        if ($definition -is [psobject]) {
            $names = @($definition.PSObject.Properties.Name)
            $isSchema = ($names -contains 'type') -or ($names -contains 'required') -or ($names -contains 'default') -or ($names -contains 'description')
            if ($isSchema) {
                $type = [string]$definition.type
                if ($names -contains 'required') { $required = [bool]$definition.required }
                if ($names -contains 'default') { $default = $definition.default }
                if ($names -contains 'description') { $desc = [string]$definition.description }
            }
            else {
                $default = $definition
            }
        }
        else {
            $default = $definition
        }

        $row = New-InsightPackParameterRow -Name $paramName -Type $type -Required:$required -DefaultValue $default -Description $desc
        $script:InsightParamInputs[$paramName] = $row.Control
        [void]$Panel.Children.Add($row.Row)
    }
}

function Get-InsightPackParameterValues {
    $values = @{}
    foreach ($name in $script:InsightParamInputs.Keys) {
        $control = $script:InsightParamInputs[$name]
        if ($control -is [System.Windows.Controls.CheckBox]) {
            $values[$name] = [bool]$control.IsChecked
            continue
        }
        if ($control -is [System.Windows.Controls.TextBox]) {
            $text = $control.Text
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $values[$name] = $text.Trim()
            }
        }
    }
    return $values
}

function Show-HelpWindow {
    $helpXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Explorer Help" Height="420" Width="520" ResizeMode="NoResize" WindowStartupLocation="CenterOwner">
  <Border Margin="10" Padding="12" BorderBrush="LightGray" BorderThickness="1" Background="White">
    <StackPanel>
      <TextBlock Text="Genesys Cloud API Explorer Help" FontSize="16" FontWeight="Bold" Margin="0 0 0 8"/>
      <TextBlock TextWrapping="Wrap">
        This explorer mirrors the Genesys Cloud API catalog while keeping transparency front and center. Use the grouped navigator to select any endpoint, provide query/path/body values, and press Submit to send requests.
      </TextBlock>
      <TextBlock TextWrapping="Wrap" Margin="0 6 0 0">
        Feature highlights: dynamic parameter rendering, large payload inspector/export, schema viewer, job watcher for bulk requests, and favorites storage alongside logs that capture every action.
      </TextBlock>
      <StackPanel Margin="0 12 0 0">
        <TextBlock FontWeight="Bold">Usage notes</TextBlock>
        <TextBlock TextWrapping="Wrap" Margin="0 2 0 0">
          - Provide an OAuth token before submitting calls. An invalid token will surface through the log and response panel.
        </TextBlock>
        <TextBlock TextWrapping="Wrap" Margin="0 2 0 0">
          - When a job endpoint returns an identifier, the Job Watch tab polls it automatically and saves results to a temp file you can inspect/export.
        </TextBlock>
        <TextBlock TextWrapping="Wrap" Margin="0 2 0 0">
          - Favorites persist under your Windows profile (~\GenesysApiExplorerFavorites.json) and store both endpoint metadata and body payloads.
        </TextBlock>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0 12 0 0">
        <Button Name="OpenDevDocs" Width="140" Height="30" Content="Developer Portal" Margin="0 0 10 0"/>
        <Button Name="OpenSupportDocs" Width="140" Height="30" Content="Genesys Support"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0 8 0 0">
        <Button Name="CloseHelp" Width="90" Height="28" Content="Close"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@

    $helpWindow = [System.Windows.Markup.XamlReader]::Parse($helpXaml)
    if (-not $helpWindow) {
        Write-Warning "Unable to instantiate help window."
        return
    }

    $openDevButton = $helpWindow.FindName("OpenDevDocs")
    $openSupportButton = $helpWindow.FindName("OpenSupportDocs")
    $closeButton = $helpWindow.FindName("CloseHelp")

    if ($openDevButton) {
        $openDevButton.Add_Click({ Launch-Url -Url $DeveloperDocsUrl })
    }
    if ($openSupportButton) {
        $openSupportButton.Add_Click({ Launch-Url -Url $SupportDocsUrl })
    }
    if ($closeButton) {
        $closeButton.Add_Click({ $helpWindow.Close() })
    }

    if ($Window) {
        $helpWindow.Owner = $Window
    }
    $helpWindow.ShowDialog() | Out-Null
}

function Show-SettingsDialog {
    param (
        [string]$CurrentJsonPath
    )

    $settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Endpoints Configuration" Height="360" Width="760"
        MinHeight="340" MinWidth="640"
        ResizeMode="CanResizeWithGrip"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False">
  <StackPanel Margin="20" VerticalAlignment="Top" HorizontalAlignment="Stretch">
    <TextBlock Text="Genesys Cloud API Endpoints Configuration" FontSize="14" FontWeight="Bold" Margin="0 0 0 15"/>

    <StackPanel Margin="0 0 0 15">
      <TextBlock Text="Current Endpoints File:" FontWeight="Bold" Margin="0 0 0 5"/>
      <TextBox Name="CurrentPathText" IsReadOnly="True" Height="30" Padding="8" Background="#F5F5F5"
               HorizontalAlignment="Stretch" MinWidth="520" TextWrapping="Wrap"/>
    </StackPanel>

    <StackPanel Margin="0 0 0 15">
      <TextBlock Text="Upload Custom Endpoints JSON:" FontWeight="Bold" Margin="0 0 0 8"/>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox Name="SelectedFileText" Grid.Column="0" Height="30" Padding="8" IsReadOnly="True" Margin="0 0 10 0"/>
        <Button Name="BrowseButton" Grid.Column="1" Content="Browse..." Width="100" Height="30"/>
      </Grid>
      <TextBlock Text="Select a JSON file containing Genesys Cloud API endpoint definitions." Foreground="Gray" Margin="0 8 0 0" TextWrapping="Wrap"/>
    </StackPanel>

    <StackPanel Margin="0 0 0 15">
      <TextBlock Text="Note: The JSON file must contain a 'paths' property with API endpoint definitions." Foreground="#555555" TextWrapping="Wrap" FontSize="11" FontStyle="Italic"/>
    </StackPanel>

    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0 20 0 0">
      <Button Name="ApplyButton" Content="Apply" Width="100" Height="32" Margin="0 0 10 0"/>
      <Button Name="CancelButton" Content="Cancel" Width="100" Height="32"/>
    </StackPanel>
  </StackPanel>
</Window>
"@

    $settingsWindow = [System.Windows.Markup.XamlReader]::Parse($settingsXaml)
    $currentPathText = $settingsWindow.FindName("CurrentPathText")
    $selectedFileText = $settingsWindow.FindName("SelectedFileText")
    $browseButton = $settingsWindow.FindName("BrowseButton")
    $applyButton = $settingsWindow.FindName("ApplyButton")
    $cancelButton = $settingsWindow.FindName("CancelButton")

    if (-not $CurrentJsonPath) {
        $CurrentJsonPath = if ($PSScriptRoot) {
            Join-Path -Path $PSScriptRoot -ChildPath "GenesysCloudAPIEndpoints.json"
        }
        else {
            Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) -ChildPath "GenesysCloudAPIEndpoints.json"
        }
    }

    if ($currentPathText) {
        $currentPathText.Text = $CurrentJsonPath
    }

    # Use script scope for the selected file so closures can access/modify it
    $script:SettingsDialogSelectedFile = ""

    $browseButton.Add_Click({
            $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
            $openFileDialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
            $initialDir = if ($CurrentJsonPath -and (Test-Path -Path $CurrentJsonPath)) {
                Split-Path -Parent $CurrentJsonPath
            }
            else {
                (Get-Location).ProviderPath
            }
            if (-not $initialDir) {
                $initialDir = (Get-Location).ProviderPath
            }
            $openFileDialog.InitialDirectory = $initialDir

            if ($openFileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $script:SettingsDialogSelectedFile = $openFileDialog.FileName
                if ($selectedFileText) {
                    $selectedFileText.Text = $script:SettingsDialogSelectedFile
                }
            }
        })

    $applyButton.Add_Click({
            if (-not $script:SettingsDialogSelectedFile) {
                [System.Windows.MessageBox]::Show("Please select a JSON file.", "No File Selected", "OK", "Information")
                return
            }

            if (-not (Test-Path -Path $script:SettingsDialogSelectedFile)) {
                [System.Windows.MessageBox]::Show("The selected file does not exist.", "File Not Found", "OK", "Error")
                return
            }

            try {
                $testJson = Get-Content -Path $script:SettingsDialogSelectedFile -Raw | ConvertFrom-Json -ErrorAction Stop

                $hasPaths = $false
                if ($testJson.paths) {
                    $hasPaths = $true
                }
                else {
                    foreach ($prop in $testJson.PSObject.Properties) {
                        if ($prop.Value -and $prop.Value.paths) {
                            $hasPaths = $true
                            break
                        }
                    }
                }

                if (-not $hasPaths) {
                    [System.Windows.MessageBox]::Show("The selected file does not contain valid Genesys Cloud API endpoint definitions (missing 'paths' property).", "Invalid Format", "OK", "Error")
                    return
                }

                $settingsWindow.DialogResult = $true
                $settingsWindow.Close()
            }
            catch {
                [System.Windows.MessageBox]::Show("Error reading JSON file: $($_.Exception.Message)", "JSON Error", "OK", "Error")
            }
        })

    $cancelButton.Add_Click({
            $settingsWindow.DialogResult = $false
            $settingsWindow.Close()
        })

    $settingsWindow.ShowDialog() | Out-Null

    if ($settingsWindow.DialogResult) {
        return $script:SettingsDialogSelectedFile
    }
    else {
        return $null
    }
}

function ConvertTo-FormEncodedString {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Values
    )

    $pairs = foreach ($entry in $Values.GetEnumerator()) {
        $value = if ($null -eq $entry.Value) { '' } else { $entry.Value }
        "$($entry.Key)=$([System.Uri]::EscapeDataString($value))"
    }

    return ($pairs -join '&')
}

function Get-ExplorerSettingsPath {
    $base = if ($env:USERPROFILE) { $env:USERPROFILE } else { $ScriptRoot }
    return (Join-Path -Path $base -ChildPath 'GenesysApiExplorer.settings.json')
}

function Load-ExplorerSettings {
    $path = Get-ExplorerSettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $settings = @{}
        foreach ($p in $obj.PSObject.Properties) {
            $settings[$p.Name] = $p.Value
        }
        return $settings
    }
    catch {
        return @{}
    }
}

function Save-ExplorerSettings {
    param([hashtable]$Settings)
    try {
        $path = Get-ExplorerSettingsPath
        ($Settings | ConvertTo-Json) | Set-Content -LiteralPath $path -Encoding utf8
    }
    catch { }
}

$script:Region = 'mypurecloud.com'
$script:AccessToken = ''
$script:OAuthType = '(none)'
$script:TokenValidated = $false

function Set-ExplorerRegion {
    param([Parameter(Mandatory)][string]$Region)

    $regionValue = $Region.Trim()
    if ($regionValue -notin @('mypurecloud.com', 'usw2.pure.cloud')) {
        $regionValue = 'mypurecloud.com'
    }

    $script:Region = $regionValue
    $script:TokenValidated = $false
    Set-Variable -Name ApiBaseUrl -Scope Script -Value ("https://api.$regionValue")
}

try {
    $saved = Load-ExplorerSettings
    if ($saved -and $saved.ContainsKey('Region') -and $saved.Region) {
        Set-ExplorerRegion -Region ([string]$saved.Region)
    }
    else {
        Set-ExplorerRegion -Region $script:Region
    }
}
catch {
    Set-ExplorerRegion -Region $script:Region
}

function Set-ExplorerAccessToken {
    param(
        [string]$Token,
        [string]$OAuthType
    )

    $tokenValue = if ($Token) { $Token.Trim() } else { '' }
    $script:AccessToken = $tokenValue
    $script:TokenValidated = $false

    if ([string]::IsNullOrWhiteSpace($tokenValue)) {
        $script:OAuthType = '(none)'
    }
    else {
        $script:OAuthType = if ($OAuthType) { $OAuthType } else { 'Manual' }
    }
}

function Get-ExplorerAccessToken {
    if ($script:AccessToken) { return $script:AccessToken.Trim() }
    return ''
}

function Update-AuthUiState {
    if ($regionStatusText) { $regionStatusText.Text = "Region: $($script:Region)" }
    if ($oauthTypeText) { $oauthTypeText.Text = "OAuth: $($script:OAuthType)" }

    $hasToken = -not [string]::IsNullOrWhiteSpace((Get-ExplorerAccessToken))
    if ($tokenReadyIndicator) {
        $tokenReadyIndicator.Text = if ($script:TokenValidated) { '●' } else { '●' }
        $tokenReadyIndicator.Foreground = if (-not $hasToken) { 'Gray' } elseif ($script:TokenValidated) { 'Green' } else { 'Orange' }
        $tokenReadyIndicator.ToolTip = if (-not $hasToken) { 'No token set' } elseif ($script:TokenValidated) { 'Token validated' } else { 'Token set (not validated)' }
    }

    if ($tokenStatusText) {
        if (-not $hasToken) {
            $tokenStatusText.Text = 'No token'
            $tokenStatusText.Foreground = 'Gray'
        }
        elseif ($script:TokenValidated) {
            $tokenStatusText.Text = '✓ Valid'
            $tokenStatusText.Foreground = 'Green'
        }
        else {
            $tokenStatusText.Text = 'Token set'
            $tokenStatusText.Foreground = 'Orange'
        }
    }
}

function Show-AppSettingsDialog {
    param(
        [string]$CurrentRegion,
        [string]$CurrentOAuthType,
        [string]$CurrentToken
    )

    $settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="App Settings" Height="340" Width="760"
        MinHeight="340" MinWidth="640"
        ResizeMode="CanResizeWithGrip"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False">
  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Text="Application Settings" FontSize="14" FontWeight="Bold" Margin="0 0 0 12"/>

    <StackPanel Grid.Row="1" Margin="0 0 0 12">
      <TextBlock Text="Region" FontWeight="Bold" Margin="0 0 0 6"/>
      <ComboBox Name="RegionCombo" Height="28" SelectedIndex="0">
        <ComboBoxItem Content="mypurecloud.com"/>
        <ComboBoxItem Content="usw2.pure.cloud"/>
      </ComboBox>
      <TextBlock Text="This controls the API base URL, exported PowerShell, and exported cURL." Foreground="Gray" FontSize="11" Margin="0 6 0 0"/>
    </StackPanel>

    <StackPanel Grid.Row="2" Margin="0 0 0 12">
      <TextBlock Text="OAuth Token" FontWeight="Bold" Margin="0 0 0 6"/>
      <TextBox Name="TokenText" Height="60" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
               ToolTip="Paste a Genesys Cloud OAuth access token (Bearer)."
               ToolTipService.Placement="Top" ToolTipService.InitialShowDelay="450" ToolTipService.ShowDuration="12000"/>
      <TextBlock Text="Token is stored in memory only (not written to disk)." Foreground="Gray" FontSize="11" Margin="0 6 0 0"/>
    </StackPanel>

    <StackPanel Grid.Row="3" Orientation="Horizontal" VerticalAlignment="Top">
      <TextBlock Text="OAuth Type:" FontWeight="Bold" VerticalAlignment="Center" Margin="0 0 8 0"/>
      <TextBlock Name="OAuthTypeValue" VerticalAlignment="Center" Foreground="SlateGray" Margin="0 0 16 0"/>
      <Button Name="ClearTokenButton" Width="120" Height="28" Content="Clear Token"/>
    </StackPanel>

    <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0 20 0 0">
      <Button Name="ApplyButton" Content="Apply" Width="100" Height="32" Margin="0 0 10 0"/>
      <Button Name="CancelButton" Content="Cancel" Width="100" Height="32"/>
    </StackPanel>
  </Grid>
</Window>
"@

    $win = [System.Windows.Markup.XamlReader]::Parse($settingsXaml)
    if (-not $win) { return $null }
    if ($Window) { $win.Owner = $Window }

    $regionCombo = $win.FindName('RegionCombo')
    $tokenText = $win.FindName('TokenText')
    $oauthTypeValue = $win.FindName('OAuthTypeValue')
    $clearTokenButton = $win.FindName('ClearTokenButton')
    $applyButton = $win.FindName('ApplyButton')
    $cancelButton = $win.FindName('CancelButton')

    if ($tokenText) { $tokenText.Text = $CurrentToken }
    if ($oauthTypeValue) { $oauthTypeValue.Text = if ($CurrentOAuthType) { $CurrentOAuthType } else { '(none)' } }

    if ($regionCombo -and $CurrentRegion) {
        $idx = -1
        foreach ($item in $regionCombo.Items) {
            $idx++
            if ($item.Content -eq $CurrentRegion) { $regionCombo.SelectedIndex = $idx; break }
        }
    }

    if ($clearTokenButton) {
        $clearTokenButton.Add_Click({
                if ($tokenText) { $tokenText.Text = '' }
                if ($oauthTypeValue) { $oauthTypeValue.Text = '(none)' }
            })
    }

    if ($tokenText) {
        $tokenText.Add_TextChanged({
                $txt = $tokenText.Text
                if ([string]::IsNullOrWhiteSpace($txt)) {
                    if ($oauthTypeValue) { $oauthTypeValue.Text = '(none)' }
                }
                else {
                    if ($oauthTypeValue) { $oauthTypeValue.Text = 'Manual' }
                }
            })
    }

    $result = $null
    if ($applyButton) {
        $applyButton.Add_Click({
                $regionValue = 'mypurecloud.com'
                if ($regionCombo -and $regionCombo.SelectedItem) {
                    $regionValue = $regionCombo.SelectedItem.Content.ToString().Trim()
                }
                $tokenValue = if ($tokenText) { $tokenText.Text } else { '' }
                $oauthType = if ($oauthTypeValue) { $oauthTypeValue.Text } else { '(none)' }

                $script:AppSettingsDialogResult = [pscustomobject]@{
                    Region    = $regionValue
                    Token     = $tokenValue
                    OAuthType = $oauthType
                }
                $win.DialogResult = $true
                $win.Close()
            })
    }

    if ($cancelButton) {
        $cancelButton.Add_Click({
                $win.DialogResult = $false
                $win.Close()
            })
    }

    $script:AppSettingsDialogResult = $null
    $win.ShowDialog() | Out-Null
    if ($win.DialogResult) { return $script:AppSettingsDialogResult }
    return $null
}

function Show-LoginWindow {
    $loginXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Genesys Cloud Login" Height="450" Width="500" ResizeMode="NoResize" WindowStartupLocation="CenterOwner">
  <Grid Margin="20">
    <TabControl Name="LoginTabs">
      <TabItem Header="User Login (Web)">
        <StackPanel Margin="10">
          <TextBlock Text="Region" FontWeight="Bold" Margin="0 0 0 5"/>
          <ComboBox Name="UserRegionCombo" Margin="0 0 0 15" SelectedIndex="0">
            <ComboBoxItem Content="mypurecloud.com (US East)"/>
            <ComboBoxItem Content="usw2.pure.cloud (US West)"/>
            <ComboBoxItem Content="mypurecloud.ie (EU West)"/>
            <ComboBoxItem Content="mypurecloud.de (EU Central)"/>
            <ComboBoxItem Content="mypurecloud.jp (Japan)"/>
            <ComboBoxItem Content="mypurecloud.com.au (Australia)"/>
            <ComboBoxItem Content="use2.us-gov-pure.cloud (FedRAMP)"/>
          </ComboBox>

          <TextBlock Text="Client ID (PKCE Grant)" FontWeight="Bold" Margin="0 0 0 5"/>
          <TextBox Name="UserClientIdInput" Height="28" Margin="0 0 0 5"/>
          <TextBlock Text="Ensure this Client ID is configured for Code Grant (PKCE) with Redirect URI: http://localhost:8080" FontSize="10" Foreground="Gray" TextWrapping="Wrap" Margin="0 0 0 15"/>

          <Button Name="UserLoginButton" Content="Login with Browser" Height="32" Margin="0 10 0 0"/>
        </StackPanel>
      </TabItem>

      <TabItem Header="Client Credentials">
        <StackPanel Margin="10">
          <TextBlock Text="Region" FontWeight="Bold" Margin="0 0 0 5"/>
          <ComboBox Name="ClientRegionCombo" Margin="0 0 0 15" SelectedIndex="0">
            <ComboBoxItem Content="mypurecloud.com (US East)"/>
            <ComboBoxItem Content="usw2.pure.cloud (US West)"/>
            <ComboBoxItem Content="mypurecloud.ie (EU West)"/>
            <ComboBoxItem Content="mypurecloud.de (EU Central)"/>
            <ComboBoxItem Content="mypurecloud.jp (Japan)"/>
            <ComboBoxItem Content="mypurecloud.com.au (Australia)"/>
            <ComboBoxItem Content="use2.us-gov-pure.cloud (FedRAMP)"/>
          </ComboBox>

          <TextBlock Text="Client ID" FontWeight="Bold" Margin="0 0 0 5"/>
          <TextBox Name="ClientClientIdInput" Height="28" Margin="0 0 0 15"/>

          <TextBlock Text="Client Secret" FontWeight="Bold" Margin="0 0 0 5"/>
          <PasswordBox Name="ClientSecretInput" Height="28" Margin="0 0 0 15"/>

          <Button Name="ClientLoginButton" Content="Get Token" Height="32" Margin="0 10 0 0"/>
        </StackPanel>
      </TabItem>
    </TabControl>
  </Grid>
</Window>
"@

    $loginWindow = [System.Windows.Markup.XamlReader]::Parse($loginXaml)
    if (-not $loginWindow) { return $null }

    if ($Window) { $loginWindow.Owner = $Window }

    # User Login Controls
    $userRegionCombo = $loginWindow.FindName("UserRegionCombo")
    $userClientIdInput = $loginWindow.FindName("UserClientIdInput")
    $userLoginButton = $loginWindow.FindName("UserLoginButton")

    # Client Login Controls
    $clientRegionCombo = $loginWindow.FindName("ClientRegionCombo")
    $clientClientIdInput = $loginWindow.FindName("ClientClientIdInput")
    $clientSecretInput = $loginWindow.FindName("ClientSecretInput")
    $clientLoginButton = $loginWindow.FindName("ClientLoginButton")

    # Stored Settings Key (simple persistence for convenience)
    $settingsPath = Join-Path -Path $env:USERPROFILE -ChildPath "GenesysApiExplorer.settings.json"
    $savedSettings = @{}
    if (Test-Path $settingsPath) {
        try { $savedSettings = Get-Content $settingsPath -Raw | ConvertFrom-Json } catch {}
    }

    # Restore saved values
    if ($savedSettings.UserClientId) { $userClientIdInput.Text = $savedSettings.UserClientId }
    if ($savedSettings.ClientClientId) { $clientClientIdInput.Text = $savedSettings.ClientClientId }
    if ($savedSettings.Region) {
        $idx = -1
        foreach ($item in $userRegionCombo.Items) {
            $idx++
            if ($item.Content -match $savedSettings.Region) {
                $userRegionCombo.SelectedIndex = $idx
                $clientRegionCombo.SelectedIndex = $idx
                break
            }
        }
    }

    $script:LoginResult = $null
    $script:LastLoginOAuthType = $null
    $script:LastLoginRegion = $null

    # --- Client Credentials Flow ---
    $clientLoginButton.Add_Click({
            $regionText = $clientRegionCombo.SelectedItem.Content.ToString().Split(' ')[0]
            $clientId = $clientClientIdInput.Text.Trim()
            $clientSecret = $clientSecretInput.Password

            if (-not $clientId -or -not $clientSecret) {
                [System.Windows.MessageBox]::Show("Please enter Client ID and Secret.", "Missing Credentials", "OK", "Warning")
                return
            }

            try {
                $authHeader = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${clientId}:${clientSecret}"))
                $body = @{ grant_type = "client_credentials" }

                $loginWindow.Cursor = [System.Windows.Input.Cursors]::Wait

                $formBody = ConvertTo-FormEncodedString -Values $body
                $headers = @{
                    Authorization  = "Basic $authHeader"
                    'Content-Type' = 'application/x-www-form-urlencoded'
                }
                $response = Invoke-GCRequest -Method Post -Uri "https://login.$regionText/oauth/token" -Headers $headers -Body $formBody

                if ($response.access_token) {
                    $script:LoginResult = $response.access_token
                    $script:LastLoginOAuthType = 'Client Credentials'
                    $script:LastLoginRegion = $regionText

                    # Save settings
                    $savedSettings.ClientClientId = $clientId
                    $savedSettings.Region = $regionText
                    $savedSettings | ConvertTo-Json | Set-Content $settingsPath

                    $loginWindow.Close()
                }
            }
            catch {
                [System.Windows.MessageBox]::Show("Authentication failed: $($_.Exception.Message)", "Login Error", "OK", "Error")
            }
            finally {
                $loginWindow.Cursor = [System.Windows.Input.Cursors]::Arrow
            }
        })

    # --- User PKCE Flow ---
    $userLoginButton.Add_Click({
            $regionText = $userRegionCombo.SelectedItem.Content.ToString().Split(' ')[0]
            $clientId = $userClientIdInput.Text.Trim()
            $redirectUri = "http://localhost:8080"

            if (-not $clientId) {
                [System.Windows.MessageBox]::Show("Please enter a Client ID.", "Missing info", "OK", "Warning")
                return
            }

            # Save settings immediately
            $savedSettings.UserClientId = $clientId
            $savedSettings.Region = $regionText
            $savedSettings | ConvertTo-Json | Set-Content $settingsPath

            # 1. Generate Code Verifier and Challenge (PKCE)
            # Verifier: Random 32-96 bytes, base64url encoded
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            $bytes = New-Object byte[] 32
            $rng.GetBytes($bytes)
            $verifier = [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').Replace('=', '')

            # Challenge: SHA256(verifier) -> base64url
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            $challengeBytes = $sha256.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))
            $challenge = [Convert]::ToBase64String($challengeBytes).Replace('+', '-').Replace('/', '_').Replace('=', '')

            $authUrl = "https://login.$regionText/oauth/authorize?client_id=$clientId&response_type=code&redirect_uri=$redirectUri&code_challenge=$challenge&code_challenge_method=S256"

            # Create a browser window
            $browserXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Genesys Cloud Authorization" Height="600" Width="500" WindowStartupLocation="CenterScreen">
  <WebBrowser Name="AuthBrowser"/>
</Window>
"@
            $browserWindow = [System.Windows.Markup.XamlReader]::Parse($browserXaml)
            $browser = $browserWindow.FindName("AuthBrowser")

            $browser.Add_Navigated({
                    param($sender, $e)
                    $url = $e.Uri.AbsoluteUri

                    # Check for Authorization Code redirect
                    if ($url -match "[?&]code=([^&]+)") {
                        $authCode = $Matches[1]
                        $browserWindow.Close() # Close immediately to prevent user confusion

                        # 2. Exchange Code for Token
                        try {
                            $loginWindow.Cursor = [System.Windows.Input.Cursors]::Wait

                            $tokenBody = @{
                                grant_type    = "authorization_code"
                                client_id     = $clientId
                                code          = $authCode
                                redirect_uri  = $redirectUri
                                code_verifier = $verifier
                            }

                            $formBody = ConvertTo-FormEncodedString -Values $tokenBody
                            $headers = @{
                                'Content-Type' = 'application/x-www-form-urlencoded'
                            }

                            $response = Invoke-GCRequest -Method Post -Uri "https://login.$regionText/oauth/token" -Headers $headers -Body $formBody

                            if ($response.access_token) {
                                $script:LoginResult = $response.access_token
                                $script:LastLoginOAuthType = 'User PKCE'
                                $script:LastLoginRegion = $regionText
                                $loginWindow.Close()
                            }
                        }
                        catch {
                            [System.Windows.MessageBox]::Show("Token exchange failed: $($_.Exception.Message)", "Login Error", "OK", "Error")
                        }
                        finally {
                            $loginWindow.Cursor = [System.Windows.Input.Cursors]::Arrow
                        }
                    }
                })

            $browser.Navigate($authUrl)
            $browserWindow.ShowDialog() | Out-Null
        })

    $loginWindow.ShowDialog() | Out-Null
    return $script:LoginResult
}

function Show-SplashScreen {
    $splashXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Genesys Cloud  Explorer" WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        WindowStyle="None" AllowsTransparency="True" Background="White" Topmost="True"
        SizeToContent="WidthAndHeight" MinWidth="520" MinHeight="320">
  <Border Margin="10" Padding="14" BorderBrush="#FF2C2C2C" BorderThickness="1" CornerRadius="6" Background="#FFF8F9FB">
    <StackPanel>
      <TextBlock Text="Genesys Cloud  Explorer" FontSize="18" FontWeight="Bold"/>
      <TextBlock Text="Instant access to every Genesys Cloud endpoint with schema insight, job tracking, and saved favorites." TextWrapping="Wrap" Margin="0 6"/>
      <TextBlock Text="Features in this release:" FontWeight="Bold" Margin="0 8 0 0"/>
      <TextBlock Text="• Grouped endpoint navigation with parameter assistance." Margin="0 2"/>
      <TextBlock Text="• Transparency log, schema viewer, and large-response inspection/export." Margin="0 2"/>
      <TextBlock Text="• Job Watch tab polls bulk jobs and stages outputs in temp files for export." Margin="0 2"/>
      <TextBlock Text="• Favorites persist locally and include payloads for reuse." Margin="0 2"/>
      <TextBlock TextWrapping="Wrap" Margin="0 10 0 0">
        Visit the Genesys Cloud developer documentation or help center from the Help menu when you're ready for deeper reference.
      </TextBlock>
      <Button Name="ContinueButton" Content="Continue" Width="120" Height="32" HorizontalAlignment="Right" Margin="0 12 0 0"/>
    </StackPanel>
  </Border>
</Window>
"@

    $splashWindow = [System.Windows.Markup.XamlReader]::Parse($splashXaml)
    if (-not $splashWindow) {
        return
    }

    $continueButton = $splashWindow.FindName("ContinueButton")
    if ($continueButton) {
        $continueButton.Add_Click({
                $splashWindow.Close()
            })
    }

    $splashWindow.ShowDialog() | Out-Null
}

function Load-PathsFromJson {
    param ([Parameter(Mandatory = $true)] [string]$JsonPath)

    $json = Get-Content -Path $JsonPath -Raw | ConvertFrom-Json
    if ($json.paths) {
        return [PSCustomObject]@{
            Paths       = $json.paths
            Definitions = if ($json.definitions) { $json.definitions } else { @{} }
        }
    }

    foreach ($prop in $json.PSObject.Properties) {
        if ($prop.Value -and $prop.Value.paths) {
            return [PSCustomObject]@{
                Paths       = $prop.Value.paths
                Definitions = if ($prop.Value.definitions) { $prop.Value.definitions } else { @{} }
            }
        }
    }

    throw "Cannot locate a 'paths' section in '$JsonPath'."
}

function Build-GroupMap {
    param ([Parameter(Mandatory = $true)] $Paths)

    $map = @{}
    foreach ($prop in $Paths.PSObject.Properties) {
        $path = $prop.Name
        if ($path -match "^/api/v2/([^/]+)") {
            $group = $Matches[1]
        }
        else {
            $group = "Other"
        }

        if (-not $map.ContainsKey($group)) {
            $map[$group] = @()
        }

        $map[$group] += $path
    }

    return $map
}

function Get-PathObject {
    param (
        $ApiPaths,
        [string]$Path
    )

    $prop = $ApiPaths.PSObject.Properties | Where-Object { $_.Name -eq $Path }
    return $prop.Value
}

function Get-MethodObject {
    param (
        $PathObject,
        [string]$MethodName
    )

    $methodProp = $PathObject.PSObject.Properties | Where-Object { $_.Name -eq $MethodName }
    return $methodProp.Value
}

function Get-GroupForPath {
    param ([string]$Path)

    if ($Path -match "^/api/v2/([^/]+)") {
        return $Matches[1]
    }

    return "Other"
}

function Get-ParameterControlValue {
    param ($Control)

    if (-not $Control) { return $null }

    # Handle CheckBox (wrapped in StackPanel)
    if ($Control.ValueControl -and $Control.ValueControl -is [System.Windows.Controls.CheckBox]) {
        $checkBox = $Control.ValueControl
        if ($checkBox.IsChecked -eq $true) {
            return "true"
        }
        elseif ($checkBox.IsChecked -eq $false) {
            return "false"
        }
    }

    # Handle ComboBox
    if ($Control -is [System.Windows.Controls.ComboBox]) {
        $controlValue = $Control.SelectedItem
        if ($controlValue) {
            return $controlValue.ToString()
        }
        return $null
    }

    # Handle TextBox
    if ($Control -is [System.Windows.Controls.TextBox]) {
        return $Control.Text
    }

    return $null
}

function Select-ComboBoxItemByText {
    param (
        [System.Windows.Controls.ComboBox]$ComboBox,
        [string]$Text
    )

    if (-not $ComboBox -or -not $Text) { return $false }

    foreach ($item in $ComboBox.Items) {
        if ($item -and $item.ToString().Equals($Text, [System.StringComparison]::InvariantCultureIgnoreCase)) {
            $ComboBox.SelectedItem = $item
            return $true
        }
    }

    return $false
}

function Set-ParameterControlValue {
    param (
        $Control,
        $Value
    )

    if (-not $Control) { return }

    # Handle CheckBox (wrapped in StackPanel)
    if ($Control.ValueControl -and $Control.ValueControl -is [System.Windows.Controls.CheckBox]) {
        $checkBox = $Control.ValueControl
        if ($Value -eq "true" -or $Value -eq $true) {
            $checkBox.IsChecked = $true
        }
        elseif ($Value -eq "false" -or $Value -eq $false) {
            $checkBox.IsChecked = $false
        }
        else {
            $checkBox.IsChecked = $null
        }
    }

    # Handle ComboBox
    if ($Control -is [System.Windows.Controls.ComboBox]) {
        $Control.SelectedItem = $Value
        return
    }

    # Handle TextBox
    if ($Control -is [System.Windows.Controls.TextBox]) {
        $Control.Text = $Value
        return
    }
}

function Test-JsonString {
    param ([string]$JsonString)

    if ([string]::IsNullOrWhiteSpace($JsonString)) {
        return $true  # Empty is valid (will be handled by required check)
    }

    try {
        $null = $JsonString | ConvertFrom-Json -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Test-ParameterValue {
    param (
        [string]$Value,
        [object]$ValidationMetadata
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{ Valid = $true }  # Empty values handled by required field check
    }

    if (-not $ValidationMetadata) {
        return @{ Valid = $true }
    }

    $errors = @()

    # Validate integer type
    if ($ValidationMetadata.Type -eq "integer") {
        $intValue = $null
        if (-not [int]::TryParse($Value, [ref]$intValue)) {
            $errors += "Must be an integer value"
        }
        else {
            if ($null -ne $ValidationMetadata.Minimum -and $intValue -lt $ValidationMetadata.Minimum) {
                $errors += "Must be at least $($ValidationMetadata.Minimum)"
            }
            if ($null -ne $ValidationMetadata.Maximum -and $intValue -gt $ValidationMetadata.Maximum) {
                $errors += "Must be at most $($ValidationMetadata.Maximum)"
            }
        }
    }

    # Validate number type (float/double)
    if ($ValidationMetadata.Type -eq "number") {
        $numValue = $null
        if (-not [double]::TryParse($Value, [ref]$numValue)) {
            $errors += "Must be a numeric value"
        }
        else {
            if ($null -ne $ValidationMetadata.Minimum -and $numValue -lt $ValidationMetadata.Minimum) {
                $errors += "Must be at least $($ValidationMetadata.Minimum)"
            }
            if ($null -ne $ValidationMetadata.Maximum -and $numValue -gt $ValidationMetadata.Maximum) {
                $errors += "Must be at most $($ValidationMetadata.Maximum)"
            }
        }
    }

    # Validate array type (comma-separated values)
    if ($ValidationMetadata.Type -eq "array") {
        # Arrays are entered as comma-separated values
        # Just validate that it's not completely malformed
        # Individual item validation could be added for specific item types
        if ($ValidationMetadata.ItemType -eq "integer") {
            $items = $Value -split ',' | ForEach-Object { $_.Trim() }
            foreach ($item in $items) {
                if (-not [string]::IsNullOrWhiteSpace($item)) {
                    $intValue = $null
                    if (-not [int]::TryParse($item, [ref]$intValue)) {
                        $errors += "Array item '$item' must be an integer"
                        break
                    }
                }
            }
        }
    }

    if ($errors.Count -gt 0) {
        return @{ Valid = $false; Errors = $errors }
    }

    return @{ Valid = $true }
}

function Test-NumericValue {
    param (
        [string]$Value,
        [string]$Type,
        [object]$Minimum,
        [object]$Maximum
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{ IsValid = $true; ErrorMessage = $null }
    }

    # Try to parse the number
    $number = $null
    $parseSuccess = $false

    if ($Type -eq "integer") {
        $parseSuccess = [int]::TryParse($Value, [ref]$number)
        if (-not $parseSuccess) {
            return @{ IsValid = $false; ErrorMessage = "Must be a valid integer" }
        }
    }
    elseif ($Type -eq "number") {
        $parseSuccess = [double]::TryParse($Value, [ref]$number)
        if (-not $parseSuccess) {
            return @{ IsValid = $false; ErrorMessage = "Must be a valid number" }
        }
    }

    # Check minimum constraint
    if ($null -ne $Minimum -and $number -lt $Minimum) {
        return @{ IsValid = $false; ErrorMessage = "Must be >= $Minimum" }
    }

    # Check maximum constraint
    if ($null -ne $Maximum -and $number -gt $Maximum) {
        return @{ IsValid = $false; ErrorMessage = "Must be <= $Maximum" }
    }

    return @{ IsValid = $true; ErrorMessage = $null }
}

function Test-StringFormat {
    param (
        [string]$Value,
        [string]$Format = $null,
        [string]$Pattern = $null
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{ IsValid = $true; ErrorMessage = $null }
    }

    # Check pattern first if provided
    if ($Pattern) {
        try {
            if ($Value -notmatch $Pattern) {
                return @{ IsValid = $false; ErrorMessage = "Does not match required pattern" }
            }
        }
        catch {
            # Regex error - skip pattern validation
        }
    }

    # Check format
    switch ($Format) {
        "email" {
            # Simple email validation
            if ($Value -notmatch '^[^@]+@[^@]+\.[^@]+$') {
                return @{ IsValid = $false; ErrorMessage = "Must be a valid email address" }
            }
        }
        { $_ -in @("uri", "url") } {
            # Simple URL validation
            if ($Value -notmatch '^https?://') {
                return @{ IsValid = $false; ErrorMessage = "Must be a valid URL (http:// or https://)" }
            }
        }
        { $_ -in @("date", "date-time") } {
            # Try to parse as date
            $date = $null
            if (-not [DateTime]::TryParse($Value, [ref]$date)) {
                return @{ IsValid = $false; ErrorMessage = "Must be a valid date/time" }
            }
        }
    }

    return @{ IsValid = $true; ErrorMessage = $null }
}

function Test-ArrayValue {
    param (
        [string]$Value,
        [object]$ItemType
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{ IsValid = $true; ErrorMessage = $null }
    }

    # Array values are comma-separated
    $items = $Value -split ',' | ForEach-Object { $_.Trim() }

    # If itemType is string, anything is valid
    if ($ItemType.type -eq "string") {
        return @{ IsValid = $true; ErrorMessage = $null }
    }

    # If itemType is integer or number, validate each item
    if ($ItemType.type -in @("integer", "number")) {
        foreach ($item in $items) {
            if ([string]::IsNullOrWhiteSpace($item)) { continue }

            $testResult = Test-NumericValue -Value $item -Type $ItemType.type -Minimum $null -Maximum $null
            if (-not $testResult.IsValid) {
                return @{ IsValid = $false; ErrorMessage = "Array items must be valid $($ItemType.type) values" }
            }
        }
    }

    return @{ IsValid = $true; ErrorMessage = $null }
}

function Test-ParameterVisibility {
    param (
        [object]$Parameter,
        [array]$AllParameters,
        [hashtable]$ParameterInputs
    )

    # Default: all parameters are visible
    # This function provides infrastructure for future conditional parameter logic

    # Check for custom visibility metadata (for future use)
    if ($Parameter.'x-conditional-on') {
        $conditionParam = $Parameter.'x-conditional-on'
        $conditionValue = $Parameter.'x-conditional-value'

        # Check if the condition parameter exists and has the required value
        if ($ParameterInputs.ContainsKey($conditionParam)) {
            $actualValue = Get-ParameterControlValue -Control $ParameterInputs[$conditionParam]

            if ($actualValue -ne $conditionValue) {
                return $false  # Hide parameter
            }
        }
    }

    # Check for mutually exclusive parameters (for future use)
    if ($Parameter.'x-mutually-exclusive-with') {
        $exclusiveParams = $Parameter.'x-mutually-exclusive-with'

        foreach ($exclusiveParam in $exclusiveParams) {
            if ($ParameterInputs.ContainsKey($exclusiveParam)) {
                $exclusiveValue = Get-ParameterControlValue -Control $ParameterInputs[$exclusiveParam]

                if (-not [string]::IsNullOrWhiteSpace($exclusiveValue)) {
                    return $false  # Hide parameter if mutually exclusive parameter has a value
                }
            }
        }
    }

    return $true  # Show parameter
}

function Update-ParameterVisibility {
    param (
        [array]$Parameters,
        [hashtable]$ParameterInputs,
        [System.Windows.Controls.Panel]$ParameterPanel
    )

    # Update visibility for all parameters based on current values
    foreach ($param in $Parameters) {
        if ($ParameterInputs.ContainsKey($param.name)) {
            $control = $ParameterInputs[$param.name]
            $isVisible = Test-ParameterVisibility -Parameter $param -AllParameters $Parameters -ParameterInputs $ParameterInputs

            # Find the Grid row that contains this control
            $parent = $control.Parent
            if ($parent -and $parent -is [System.Windows.Controls.Grid]) {
                if ($isVisible) {
                    $parent.Visibility = "Visible"
                }
                else {
                    $parent.Visibility = "Collapsed"
                }
            }
        }
    }
}

function Export-PowerShellScript {
    param (
        [string]$Method,
        [string]$Path,
        [hashtable]$Parameters,
        [string]$Token,
        [string]$Region = "mypurecloud.com",

        # Auto = prefer Invoke-GCRequest when available (fallback to Invoke-WebRequest)
        # Portable = always use Invoke-WebRequest
        # OpsInsights = require Invoke-GCRequest (module transport)
        [Parameter()]
        [ValidateSet('Auto', 'Portable', 'OpsInsights')]
        [string]$Mode = 'Auto'
    )

    $script = @"
# Generated PowerShell script for Genesys Cloud API
# Endpoint: $Method $Path
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

`$token = "$Token"
`$region = "$Region"
`$baseUrl = "https://api.`$region"
`$path = "$Path"

"@

    # Build headers
    $script += @"
`$headers = @{
    "Authorization" = "Bearer `$token"
    "Content-Type" = "application/json"
}

"@

    # Build query parameters
    $queryParams = @()
    $pathParams = @{}
    $bodyContent = ""

    if ($Parameters) {
        foreach ($paramName in $Parameters.Keys) {
            $paramValue = $Parameters[$paramName]
            if ([string]::IsNullOrWhiteSpace($paramValue)) { continue }

            # Determine parameter type based on name and path
            $pattern = "{$paramName}"
            if ($Path -match [regex]::Escape($pattern)) {
                # Path parameter
                $pathParams[$paramName] = $paramValue
            }
            elseif ($paramName -eq "body") {
                # Body parameter
                $bodyContent = $paramValue
            }
            else {
                # Query parameter
                $queryParams += "$paramName=$([System.Uri]::EscapeDataString($paramValue))"
            }
        }
    }

    # Replace path parameters
    foreach ($paramName in $pathParams.Keys) {
        $escapedParam = [regex]::Escape("{$paramName}")
        $script += "`$path = `$path -replace '$escapedParam', '$($pathParams[$paramName])'`r`n"
    }

    # Build full URL with query parameters
    if ($queryParams.Count -gt 0) {
        $script += "`$url = `"`$baseUrl`$path?$($queryParams -join '&')`"`r`n"
    }
    else {
        $script += "`$url = `"`$baseUrl`$path`"`r`n"
    }

    $script += "`r`n"

    # Build request command (export mode)
    if ($bodyContent) {
        $script += "`$body = @'`r`n"
        $script += $bodyContent
        $script += "`r`n'@`r`n`r`n"
        if ($Mode -eq 'Portable') {
            $script += @"
	try {
	    `$iwr = @{ Uri = `$url; Method = "$Method"; Headers = `$headers; Body = `$body; ContentType = "application/json"; ErrorAction = "Stop" }
	    if (`$PSVersionTable.PSVersion.Major -lt 6) { `$iwr.UseBasicParsing = `$true }
	    `$response = Invoke-WebRequest @iwr
	    Write-Host "Success: `$(`$response.StatusCode)"
	    `$response.Content | ConvertFrom-Json | ConvertTo-Json -Depth 10
	} catch {
	    Write-Error "Request failed: `$(`$_.Exception.Message)"
	}
"@
        }
        elseif ($Mode -eq 'OpsInsights') {
            $script += @"
	try {
	    Import-Module GenesysCloud.OpsInsights -ErrorAction Stop | Out-Null
	    `$response = Invoke-GCRequest -Method $Method -Uri `$url -Headers `$headers -Body `$body -AsResponse
	    Write-Host "Success: `$(`$response.StatusCode)"
	    `$response.Content | ConvertFrom-Json | ConvertTo-Json -Depth 10
	} catch {
	    Write-Error "Request failed: `$(`$_.Exception.Message)"
	}
"@
        }
        else {
            $script += @"
	try {
	    try { Import-Module GenesysCloud.OpsInsights -ErrorAction SilentlyContinue | Out-Null } catch { }

	    if (Get-Command Invoke-GCRequest -ErrorAction SilentlyContinue) {
	        `$response = Invoke-GCRequest -Method $Method -Uri `$url -Headers `$headers -Body `$body -AsResponse
	    }
	    else {
	        `$iwr = @{ Uri = `$url; Method = "$Method"; Headers = `$headers; Body = `$body; ContentType = "application/json"; ErrorAction = "Stop" }
	        if (`$PSVersionTable.PSVersion.Major -lt 6) { `$iwr.UseBasicParsing = `$true }
	        `$response = Invoke-WebRequest @iwr
	    }

	    Write-Host "Success: `$(`$response.StatusCode)"
	    `$response.Content | ConvertFrom-Json | ConvertTo-Json -Depth 10
	} catch {
	    Write-Error "Request failed: `$(`$_.Exception.Message)"
	}
"@
        }
    }
    else {
        if ($Mode -eq 'Portable') {
            $script += @"
	try {
	    `$iwr = @{ Uri = `$url; Method = "$Method"; Headers = `$headers; ErrorAction = "Stop" }
	    if (`$PSVersionTable.PSVersion.Major -lt 6) { `$iwr.UseBasicParsing = `$true }
	    `$response = Invoke-WebRequest @iwr
	    Write-Host "Success: `$(`$response.StatusCode)"
	    `$response.Content | ConvertFrom-Json | ConvertTo-Json -Depth 10
	} catch {
	    Write-Error "Request failed: `$(`$_.Exception.Message)"
	}
"@
        }
        elseif ($Mode -eq 'OpsInsights') {
            $script += @"
	try {
	    Import-Module GenesysCloud.OpsInsights -ErrorAction Stop | Out-Null
	    `$response = Invoke-GCRequest -Method $Method -Uri `$url -Headers `$headers -AsResponse
	    Write-Host "Success: `$(`$response.StatusCode)"
	    `$response.Content | ConvertFrom-Json | ConvertTo-Json -Depth 10
	} catch {
	    Write-Error "Request failed: `$(`$_.Exception.Message)"
	}
"@
        }
        else {
            $script += @"
	try {
	    try { Import-Module GenesysCloud.OpsInsights -ErrorAction SilentlyContinue | Out-Null } catch { }

	    if (Get-Command Invoke-GCRequest -ErrorAction SilentlyContinue) {
	        `$response = Invoke-GCRequest -Method $Method -Uri `$url -Headers `$headers -AsResponse
	    }
	    else {
	        `$iwr = @{ Uri = `$url; Method = "$Method"; Headers = `$headers; ErrorAction = "Stop" }
	        if (`$PSVersionTable.PSVersion.Major -lt 6) { `$iwr.UseBasicParsing = `$true }
	        `$response = Invoke-WebRequest @iwr
	    }

	    Write-Host "Success: `$(`$response.StatusCode)"
	    `$response.Content | ConvertFrom-Json | ConvertTo-Json -Depth 10
	} catch {
	    Write-Error "Request failed: `$(`$_.Exception.Message)"
	}
"@
        }
    }

    return $script
}

function Export-CurlCommand {
    param (
        [string]$Method,
        [string]$Path,
        [hashtable]$Parameters,
        [string]$Token,
        [string]$Region = "mypurecloud.com"
    )

    $baseUrl = "https://api.$Region"
    $fullPath = $Path

    # Build query parameters and handle path parameters
    $queryParams = @()
    $bodyContent = ""

    if ($Parameters) {
        foreach ($paramName in $Parameters.Keys) {
            $paramValue = $Parameters[$paramName]
            if ([string]::IsNullOrWhiteSpace($paramValue)) { continue }

            $pattern = "{$paramName}"
            if ($fullPath -match [regex]::Escape($pattern)) {
                # Path parameter
                $fullPath = $fullPath -replace [regex]::Escape($pattern), $paramValue
            }
            elseif ($paramName -eq "body") {
                # Body parameter
                $bodyContent = $paramValue
            }
            else {
                # Query parameter - escape for URL
                $encodedValue = [System.Uri]::EscapeDataString($paramValue)
                $queryParams += "$paramName=$encodedValue"
            }
        }
    }

    # Build full URL
    $url = "$baseUrl$fullPath"
    if ($queryParams.Count -gt 0) {
        $url += "?" + ($queryParams -join "&")
    }

    # Build cURL command
    $curl = "curl -X $($Method.ToUpper()) `"$url`" ``"
    $curl += "`r`n  -H `"Authorization: Bearer $Token`" ``"
    $curl += "`r`n  -H `"Content-Type: application/json`""

    if ($bodyContent) {
        # Escape body for shell - single quotes are safest for JSON
        $escapedBody = $bodyContent -replace "'", "'\\''"
        $curl += " ``"
        $curl += "`r`n  -d '$escapedBody'"
    }

    return $curl
}

function Populate-ParameterValues {
    param ([Parameter(ValueFromPipeline)] $ParameterSet)

    if (-not $ParameterSet) { return }
    foreach ($entry in $ParameterSet) {
        $name = $entry.name
        if (-not $name) { continue }

        $paramControl = $paramInputs[$name]
        if ($paramControl -and $null -ne $entry.value) {
            Set-ParameterControlValue -Control $paramControl -Value $entry.value
        }
    }
}

function Resolve-SchemaReference {
    param (
        $Schema,
        $Definitions
    )

    if (-not $Schema) {
        return $null
    }

    $current = $Schema
    $depth = 0
    while ($current.'$ref' -and $depth -lt 10) {
        if ($current.'$ref' -match "#/definitions/(.+)") {
            $refName = $Matches[1]
            if ($Definitions -and $Definitions.$refName) {
                $current = $Definitions.$refName
            }
            else {
                return $current
            }
        }
        else {
            break
        }
        $depth++
    }

    return $current
}

function Format-SchemaType {
    param (
        $Schema,
        $Definitions
    )

    $resolved = Resolve-SchemaReference -Schema $Schema -Definitions $Definitions
    if (-not $resolved) {
        return "unknown"
    }

    $type = $resolved.type
    if (-not $type -and $resolved.'$ref') {
        $type = "ref"
    }

    if ($type -eq "array" -and $resolved.items) {
        $itemType = Format-SchemaType -Schema $resolved.items -Definitions $Definitions
        return "array of $itemType"
    }

    if ($type) {
        return $type
    }

    return "object"
}

function Flatten-Schema {
    param (
        $Schema,
        $Definitions,
        [string]$Prefix = "",
        [int]$Depth = 0
    )

    if ($Depth -ge 10) {
        return @()
    }

    $resolved = Resolve-SchemaReference -Schema $Schema -Definitions $Definitions
    if (-not $resolved) {
        return @()
    }

    $entries = @()
    $type = $resolved.type

    if ($type -eq "object" -or $resolved.properties) {
        $requiredSet = @{}
        $requiredList = if ($resolved.required) { $resolved.required } else { @() }
        foreach ($req in $requiredList) {
            $requiredSet[$req] = $true
        }

        $props = $resolved.properties
        if ($props) {
            foreach ($prop in $props.PSObject.Properties) {
                $fieldName = if ($Prefix) { "$Prefix.$($prop.Name)" } else { $prop.Name }
                $propResolved = Resolve-SchemaReference -Schema $prop.Value -Definitions $Definitions
                $entries += [PSCustomObject]@{
                    Field       = $fieldName
                    Type        = Format-SchemaType -Schema $prop.Value -Definitions $Definitions
                    Description = $propResolved.description
                    Required    = if ($requiredSet.ContainsKey($prop.Name)) { "Yes" } else { "No" }
                }

                if ($propResolved.type -eq "object" -or $propResolved.type -eq "array" -or $propResolved.'$ref') {
                    $entries += Flatten-Schema -Schema $prop.Value -Definitions $Definitions -Prefix $fieldName -Depth ($Depth + 1)
                }
            }
        }
    }
    elseif ($type -eq "array" -and $resolved.items) {
        $itemField = if ($Prefix) { "$Prefix[]" } else { "[]" }
        $entries += [PSCustomObject]@{
            Field       = $itemField
            Type        = Format-SchemaType -Schema $resolved.items -Definitions $Definitions
            Description = $resolved.items.description
            Required    = "No"
        }

        $entries += Flatten-Schema -Schema $resolved.items -Definitions $Definitions -Prefix $itemField -Depth ($Depth + 1)
    }

    return $entries
}

function Get-ResponseSchema {
    param ($MethodObject)

    if (-not $MethodObject) { return $null }

    $preferredCodes = @("200", "201", "202", "203", "default")
    foreach ($code in $preferredCodes) {
        $resp = $MethodObject.responses.$code
        if ($resp -and $resp.schema) {
            return $resp.schema
        }
    }

    foreach ($resp in $MethodObject.responses.PSObject.Properties) {
        if ($resp.Value -and $resp.Value.schema) {
            return $resp.Value.schema
        }
    }

    return $null
}

function Update-SchemaList {
    param ($Schema)

    if (-not $schemaList) { return }
    $schemaList.Items.Clear()

    $entries = Flatten-Schema -Schema $Schema -Definitions $Definitions
    if (-not $entries -or $entries.Count -eq 0) {
        $entries = @([PSCustomObject]@{
                Field       = "(no schema available)"
                Type        = ""
                Description = ""
                Required    = ""
            })
    }

    foreach ($entry in $entries) {
        $schemaList.Items.Add($entry) | Out-Null
    }
}

function Get-EnumValues {
    param (
        $Schema,
        [string]$PropertyName
    )

    if (-not $Schema) {
        return @()
    }

    # First check if the schema has properties
    $properties = $Schema.properties
    if (-not $properties) {
        return @()
    }

    # Look for the property by name
    $property = $properties.PSObject.Properties[$PropertyName]
    if (-not $property) {
        return @()
    }

    # Check if the property has enum values
    $propValue = $property.Value
    if ($propValue -and $propValue.enum) {
        # Comma operator forces PowerShell to treat the array as a single object
        # preventing automatic unwrapping when the array is returned
        return , $propValue.enum
    }

    return @()
}

function Initialize-FilterBuilderEnum {
    $convPredicate = Resolve-SchemaReference -Schema $script:Definitions.ConversationDetailQueryPredicate -Definitions $script:Definitions
    $segmentPredicate = Resolve-SchemaReference -Schema $script:Definitions.SegmentDetailQueryPredicate -Definitions $script:Definitions

    $script:FilterBuilderEnums.Conversation.Dimensions = Get-EnumValues -Schema $convPredicate -PropertyName "dimension"
    $script:FilterBuilderEnums.Conversation.Metrics = Get-EnumValues -Schema $convPredicate -PropertyName "metric"
    $script:FilterBuilderEnums.Conversation.Types = Get-EnumValues -Schema $convPredicate -PropertyName "type"

    $script:FilterBuilderEnums.Segment.Dimensions = Get-EnumValues -Schema $segmentPredicate -PropertyName "dimension"
    $script:FilterBuilderEnums.Segment.Metrics = Get-EnumValues -Schema $segmentPredicate -PropertyName "metric"
    $script:FilterBuilderEnums.Segment.Types = Get-EnumValues -Schema $segmentPredicate -PropertyName "type"
    $script:FilterBuilderEnums.Segment.PropertyTypes = Get-EnumValues -Schema $segmentPredicate -PropertyName "propertyType"

    $operatorValues = Get-EnumValues -Schema $convPredicate -PropertyName "operator"
    if ($operatorValues.Count -gt 0) {
        $script:FilterBuilderEnums.Operators = $operatorValues
    }
}
function Update-FilterFieldOptions {
    param (
        [string]$Scope,
        [string]$PredicateType,
        [System.Windows.Controls.ComboBox]$ComboBox
    )

    if (-not $ComboBox) { return }

    $ComboBox.Items.Clear()
    $ComboBox.IsEnabled = $true

    switch ("$Scope|$PredicateType") {
        "Conversation|metric" {
            $items = $script:FilterBuilderEnums.Conversation.Metrics
        }
        "Conversation|dimension" {
            $items = $script:FilterBuilderEnums.Conversation.Dimensions
        }
        "Segment|metric" {
            $items = $script:FilterBuilderEnums.Segment.Metrics
        }
        "Segment|dimension" {
            $items = $script:FilterBuilderEnums.Segment.Dimensions
        }
        default {
            # For property type or unknown types, no field selection is needed
            $items = @()
        }
    }
    if (-not $items -or $items.Count -eq 0) {
        $ComboBox.Items.Add("(no fields available)") | Out-Null
        $ComboBox.IsEnabled = $false
        $ComboBox.SelectedIndex = 0
        return
    }

    foreach ($item in $items) {
        $ComboBox.Items.Add($item) | Out-Null
    }

    $ComboBox.SelectedIndex = 0
}

function Format-FilterSummary {
    param ($Filter)

    if (-not $Filter) { return "" }

    $predicate = if ($Filter.predicates -and $Filter.predicates.Count -gt 0) { $Filter.predicates[0] } else { $null }
    if (-not $predicate) { return "$($Filter.type) filter" }

    $fieldName = if ($predicate.dimension) {
        $predicate.dimension
    }
    elseif ($predicate.metric) {
        $predicate.metric
    }
    elseif ($predicate.property) {
        "$($predicate.property) ($($predicate.propertyType))"
    }
    else {
        "<field>"
    }

    $valueText = "<no value>"
    if ($predicate.range) {
        $valueText = "(range)"
    }
    elseif ($null -ne $predicate.value) {
        $valueText = $predicate.value
    }

    return "$($Filter.type): $($predicate.type) $fieldName $($predicate.operator) $valueText"
}
function Reset-FilterBuilderData {
    $script:FilterBuilderData.ConversationFilters = New-Object System.Collections.ArrayList
    $script:FilterBuilderData.SegmentFilters = New-Object System.Collections.ArrayList
    if ($conversationFiltersList) { $conversationFiltersList.Items.Clear() }
    if ($segmentFiltersList) { $segmentFiltersList.Items.Clear() }
    if ($filterIntervalInput) {
        $filterIntervalInput.Text = $script:FilterBuilderData.Interval
    }
    if ($removeConversationPredicateButton) {
        $removeConversationPredicateButton.IsEnabled = $false
    }
    if ($removeSegmentPredicateButton) {
        $removeSegmentPredicateButton.IsEnabled = $false
    }
}

function Update-FilterList {
    param ([string]$Scope)

    if ($Scope -eq "Conversation") {
        if (-not $conversationFiltersList) { return }
        $conversationFiltersList.Items.Clear()
        foreach ($filter in $script:FilterBuilderData.ConversationFilters) {
            $summary = Format-FilterSummary -Filter $filter
            $conversationFiltersList.Items.Add($summary) | Out-Null
        }
    }
    else {
        if (-not $segmentFiltersList) { return }
        $segmentFiltersList.Items.Clear()
        foreach ($filter in $script:FilterBuilderData.SegmentFilters) {
            $summary = Format-FilterSummary -Filter $filter
            $segmentFiltersList.Items.Add($summary) | Out-Null
        }
    }
}

function Get-BodyTextBox {
    if ($script:CurrentBodyControl) {
        if ($script:CurrentBodyControl.ValueControl -and ($script:CurrentBodyControl.ValueControl -is [System.Windows.Controls.TextBox])) {
            return $script:CurrentBodyControl.ValueControl
        }
        if ($script:CurrentBodyControl -is [System.Windows.Controls.TextBox]) {
            return $script:CurrentBodyControl
        }
    }
    return $null
}
function Invoke-FilterBuilderBody {
    $bodyTextBox = Get-BodyTextBox
    if (-not $bodyTextBox) { return }

    $intervalValue = if ($filterIntervalInput -and ($filterIntervalInput.Text.Trim())) {
        $filterIntervalInput.Text.Trim()
    }
    else {
        $script:FilterBuilderData.Interval
    }

    $payload = [ordered]@{}
    if ($intervalValue) {
        $payload.interval = $intervalValue
        $script:FilterBuilderData.Interval = $intervalValue
    }

    if ($script:FilterBuilderData.ConversationFilters.Count -gt 0) {
        $payload.conversationFilters = $script:FilterBuilderData.ConversationFilters
    }
    if ($script:FilterBuilderData.SegmentFilters.Count -gt 0) {
        $payload.segmentFilters = $script:FilterBuilderData.SegmentFilters
    }

    $json = $payload | ConvertTo-Json -Depth 10
    $bodyTextBox.Text = $json
}
function Set-FilterBuilderVisibility {
    param ([bool]$Visible)

    if ($filterBuilderExpander) {
        $filterBuilderExpander.Visibility = if ($Visible) { "Visible" } else { "Collapsed" }
        $filterBuilderExpander.IsExpanded = $Visible
    }

    if (-not $filterBuilderBorder) { return }
    $filterBuilderBorder.Visibility = if ($Visible) { "Visible" } else { "Collapsed" }

    if (-not $Visible) {
        Release-FilterBuilderResources
        if ($filterBuilderHintText) {
            $filterBuilderHintText.Text = ""
        }
    }
    else {
        Initialize-FilterBuilderControl
    }
}
function Update-FilterBuilderHint {
    if (-not $filterBuilderHintText) { return }
    $convDims = $script:FilterBuilderEnums.Conversation.Dimensions.Count
    $convMetrics = $script:FilterBuilderEnums.Conversation.Metrics.Count
    $convTypes = $script:FilterBuilderEnums.Conversation.Types.Count
    $segDims = $script:FilterBuilderEnums.Segment.Dimensions.Count
    $segMetrics = $script:FilterBuilderEnums.Segment.Metrics.Count
    $segTypes = $script:FilterBuilderEnums.Segment.Types.Count
    $segPropTypes = $script:FilterBuilderEnums.Segment.PropertyTypes.Count
    $hint = "Conversation types ($convTypes) · dims ($convDims) · metrics ($convMetrics); Segment types ($segTypes) · dims ($segDims) · metrics ($segMetrics) · prop types ($segPropTypes)."
    $filterBuilderHintText.Text = $hint
}

function Release-FilterBuilderResources {
    if ($conversationFiltersList) {
        $conversationFiltersList.Items.Clear()
        $conversationFiltersList.ItemsSource = $null
    }
    if ($segmentFiltersList) {
        $segmentFiltersList.Items.Clear()
        $segmentFiltersList.ItemsSource = $null
    }
    if ($conversationFieldCombo) {
        $conversationFieldCombo.Items.Clear()
        $conversationFieldCombo.ItemsSource = $null
    }
    if ($segmentFieldCombo) {
        $segmentFieldCombo.Items.Clear()
        $segmentFieldCombo.ItemsSource = $null
    }
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

function Parse-FilterValueInput {
    param ([string]$Text)

    $value = if ($Text) { $Text.Trim() } else { "" }
    if (-not $value) { return $null }

    if ($value.StartsWith("{") -and $value.EndsWith("}")) {
        try {
            $parsed = $value | ConvertFrom-Json -ErrorAction Stop
            return $parsed
        }
        catch {
            Write-Verbose "Filter value is not valid JSON; falling back to literal string."
        }
    }

    return $value
}

function Add-FilterEntry {
    param (
        [string]$Scope,
        $FilterObject
    )

    if ($Scope -eq "Conversation") {
        $script:FilterBuilderData.ConversationFilters.Add($FilterObject) | Out-Null
    }
    else {
        $script:FilterBuilderData.SegmentFilters.Add($FilterObject) | Out-Null
    }
    Refresh-FilterList -Scope $Scope
}

function Show-FilterBuilderMessage {
    param (
        [string]$Message,
        [string]$Title = "Filter Builder"
    )

    [System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
}

function Build-FilterFromInput {
    param (
        [string]$Scope,
        $FilterTypeCombo,
        $PredicateTypeCombo,
        $FieldCombo,
        $OperatorCombo,
        $ValueInput,
        $PropertyTypeCombo
    )

    $filterType = if ($FilterTypeCombo -and $FilterTypeCombo.SelectedItem) { $FilterTypeCombo.SelectedItem } else { "and" }
    $predicateType = if ($PredicateTypeCombo -and $PredicateTypeCombo.SelectedItem) { $PredicateTypeCombo.SelectedItem } else { "dimension" }
    $fieldName = if ($FieldCombo -and $FieldCombo.SelectedItem) { $FieldCombo.SelectedItem } else { "" }
    $operator = if ($OperatorCombo -and $OperatorCombo.SelectedItem) { $OperatorCombo.SelectedItem } else { "" }

    if (-not $fieldName -or $fieldName -eq "(no fields available)") {
        Show-FilterBuilderMessage -Message "Please select a valid field before adding a predicate."
        return $null
    }
    if (-not $operator) {
        Show-FilterBuilderMessage -Message "Please select an operator."
        return $null
    }

    $valueInput = Parse-FilterValueInput -Text $ValueInput.Text
    if ($operator -ne "exists" -and $null -eq $valueInput) {
        Show-FilterBuilderMessage -Message "Provide a value or range for the predicate."
        return $null
    }

    $predicate = [PSCustomObject]@{
        type     = $predicateType
        operator = $operator
    }

    if ($predicateType -eq "metric") {
        $predicate.metric = $fieldName
    }
    elseif ($predicateType -eq "property") {
        $predicate.property = $fieldName
        if ($PropertyTypeCombo -and $PropertyTypeCombo.SelectedItem) {
            $predicate.propertyType = $PropertyTypeCombo.SelectedItem
        }
    }
    else {
        $predicate.dimension = $fieldName
    }

    if ($valueInput -and ($valueInput -is [System.Management.Automation.PSCustomObject] -or $valueInput -is [System.Collections.IDictionary])) {
        $predicate.range = $valueInput
    }
    elseif ($null -ne $valueInput) {
        $predicate.value = $valueInput
    }

    return [PSCustomObject]@{
        type       = $filterType
        predicates = @($predicate)
    }
}

function Initialize-FilterBuilderControl {
    if (-not $conversationFilterTypeCombo) { return }

    $conversationFilterTypeCombo.Items.Clear()
    $conversationFilterTypeCombo.Items.Add("and") | Out-Null
    $conversationFilterTypeCombo.Items.Add("or") | Out-Null
    $conversationFilterTypeCombo.SelectedIndex = 0

    $segmentFilterTypeCombo.Items.Clear()
    $segmentFilterTypeCombo.Items.Add("and") | Out-Null
    $segmentFilterTypeCombo.Items.Add("or") | Out-Null
    $segmentFilterTypeCombo.SelectedIndex = 0

    $conversationPredicateTypeCombo.Items.Clear()
    if ($script:FilterBuilderEnums.Conversation.Types.Count -gt 0) {
        foreach ($type in $script:FilterBuilderEnums.Conversation.Types) {
            $conversationPredicateTypeCombo.Items.Add($type) | Out-Null
        }
    }
    else {
        # Fallback to default values if enum extraction fails
        $conversationPredicateTypeCombo.Items.Add("dimension") | Out-Null
        $conversationPredicateTypeCombo.Items.Add("property") | Out-Null
        $conversationPredicateTypeCombo.Items.Add("metric") | Out-Null
    }
    $conversationPredicateTypeCombo.SelectedIndex = 0

    $segmentPredicateTypeCombo.Items.Clear()
    if ($script:FilterBuilderEnums.Segment.Types.Count -gt 0) {
        foreach ($type in $script:FilterBuilderEnums.Segment.Types) {
            $segmentPredicateTypeCombo.Items.Add($type) | Out-Null
        }
    }
    else {
        # Fallback to default values if enum extraction fails
        $segmentPredicateTypeCombo.Items.Add("dimension") | Out-Null
        $segmentPredicateTypeCombo.Items.Add("property") | Out-Null
        $segmentPredicateTypeCombo.Items.Add("metric") | Out-Null
    }
    $segmentPredicateTypeCombo.SelectedIndex = 0

    if ($conversationOperatorCombo) {
        $conversationOperatorCombo.Items.Clear()
        foreach ($op in $script:FilterBuilderEnums.Operators) {
            $conversationOperatorCombo.Items.Add($op) | Out-Null
        }
        $conversationOperatorCombo.SelectedIndex = 0
    }
    if ($segmentOperatorCombo) {
        $segmentOperatorCombo.Items.Clear()
        foreach ($op in $script:FilterBuilderEnums.Operators) {
            $segmentOperatorCombo.Items.Add($op) | Out-Null
        }
        $segmentOperatorCombo.SelectedIndex = 0
    }

    if ($segmentPropertyTypeCombo) {
        $segmentPropertyTypeCombo.Items.Clear()
        if ($script:FilterBuilderEnums.Segment.PropertyTypes.Count -gt 0) {
            foreach ($propType in $script:FilterBuilderEnums.Segment.PropertyTypes) {
                $segmentPropertyTypeCombo.Items.Add($propType) | Out-Null
            }
        }
        else {
            # Fallback to default values if enum extraction fails
            $segmentPropertyTypeCombo.Items.Add("bool") | Out-Null
            $segmentPropertyTypeCombo.Items.Add("integer") | Out-Null
            $segmentPropertyTypeCombo.Items.Add("real") | Out-Null
            $segmentPropertyTypeCombo.Items.Add("date") | Out-Null
            $segmentPropertyTypeCombo.Items.Add("string") | Out-Null
            $segmentPropertyTypeCombo.Items.Add("uuid") | Out-Null
        }
        if ($segmentPropertyTypeCombo.Items.Count -gt 0) {
            $segmentPropertyTypeCombo.SelectedIndex = 0
        }
    }

    Update-FilterFieldOptions -Scope "Conversation" -PredicateType "dimension" -ComboBox $conversationFieldCombo
    Update-FilterFieldOptions -Scope "Segment" -PredicateType "dimension" -ComboBox $segmentFieldCombo
}

# Script-level variables to track tree population progress
$script:InspectorNodeCount = 0
$script:InspectorMaxNodes = 2000
$script:InspectorMaxDepth = 15

# Maximum length for log message truncation
$script:LogMaxMessageLength = 500

function Add-InspectorTreeNode {
    param (
        $Tree,
        $Data,
        [string]$Label = "root",
        [int]$Depth = 0
    )

    if (-not $Tree) { return }

    # Check if we've exceeded the maximum node count to prevent freezing
    if ($script:InspectorNodeCount -ge $script:InspectorMaxNodes) {
        if ($Depth -eq 0) {
            $limitNode = New-Object System.Windows.Controls.TreeViewItem
            $limitNode.Header = "[Maximum node limit reached ($($script:InspectorMaxNodes) nodes). Use Raw tab for full data.]"
            $limitNode.Foreground = [System.Windows.Media.Brushes]::OrangeRed
            $Tree.Items.Add($limitNode) | Out-Null
        }
        return
    }

    # Check if we've exceeded the maximum depth to prevent deep recursion
    if ($Depth -ge $script:InspectorMaxDepth) {
        $depthNode = New-Object System.Windows.Controls.TreeViewItem
        $depthNode.Header = "[Max depth reached - use Raw tab for full data]"
        $depthNode.Foreground = [System.Windows.Media.Brushes]::Gray
        $Tree.Items.Add($depthNode) | Out-Null
        return
    }

    $script:InspectorNodeCount++
    $node = New-Object System.Windows.Controls.TreeViewItem
    $isEnumerable = ($Data -is [System.Collections.IEnumerable]) -and -not ($Data -is [string])
    if ($Data -and $Data.PSObject.Properties.Count -gt 0) {
        $node.Header = "$($Label) (object)"
        foreach ($prop in $Data.PSObject.Properties) {
            if ($script:InspectorNodeCount -ge $script:InspectorMaxNodes) {
                $ellipsis = New-Object System.Windows.Controls.TreeViewItem
                $ellipsis.Header = "[... node limit reached]"
                $ellipsis.Foreground = [System.Windows.Media.Brushes]::Gray
                $node.Items.Add($ellipsis) | Out-Null
                break
            }
            Add-InspectorTreeNode -Tree $node -Data $prop.Value -Label "$($prop.Name)" -Depth ($Depth + 1)
        }
    }
    elseif ($isEnumerable) {
        $node.Header = "$($Label) (array)"
        $count = 0
        foreach ($item in $Data) {
            if ($count -ge 150) {
                $ellipsis = New-Object System.Windows.Controls.TreeViewItem
                $ellipsis.Header = "[... $($Data.Count - 150) more items]"
                $ellipsis.Foreground = [System.Windows.Media.Brushes]::Gray
                $node.Items.Add($ellipsis) | Out-Null
                break
            }
            if ($script:InspectorNodeCount -ge $script:InspectorMaxNodes) {
                $ellipsis = New-Object System.Windows.Controls.TreeViewItem
                $ellipsis.Header = "[... node limit reached]"
                $ellipsis.Foreground = [System.Windows.Media.Brushes]::Gray
                $node.Items.Add($ellipsis) | Out-Null
                break
            }

            Add-InspectorTreeNode -Tree $node -Data $item -Label "[$count]" -Depth ($Depth + 1)
            $count++
        }
    }
    else {
        $valueText = if ($null -ne $Data) { $Data.ToString() } else { "<null>" }
        $node.Header = "$($Label): $valueText"
    }

    $node.IsExpanded = $Depth -lt 2
    $Tree.Items.Add($node) | Out-Null
}

function Show-DataInspector {
    param ([string]$JsonText)

    $sourceText = $JsonText
    if (-not $sourceText -and $script:LastResponseFile -and (Test-Path -Path $script:LastResponseFile)) {
        $fileInfo = Get-Item -Path $script:LastResponseFile
        if ($fileInfo.Length -gt 5MB) {
            $result = [System.Windows.MessageBox]::Show("The stored result is large ($([math]::Round($fileInfo.Length / 1MB, 1)) MB). Parsing it may take some time. Continue?", "Large Result Warning", "YesNo")
            if ($result -ne "Yes") {
                Add-LogEntry "Inspector aborted by user for large stored result."
                return
            }
        }
        $sourceText = Get-Content -Path $script:LastResponseFile -Raw
    }

    if (-not $sourceText) {
        Add-LogEntry "Inspector: no data to show."
        return
    }

    try {
        $parsed = $sourceText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        [System.Windows.MessageBox]::Show("Unable to parse current response for inspection.`n$($_.Exception.Message)", "Data Inspector")
        return
    }

    $inspectorXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Data Inspector" Height="600" Width="700" WindowStartupLocation="CenterOwner">
  <DockPanel Margin="10">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0 0 0 8">
      <Button Name="CopyJsonButton" Width="110" Height="28" Content="Copy JSON" Margin="0 0 10 0"/>
      <Button Name="ExportJsonButton" Width="130" Height="28" Content="Export JSON"/>
    </StackPanel>
    <TabControl>
      <TabItem Header="Structured">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <TreeView Name="InspectorTree"/>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="Raw">
        <TextBox Name="InspectorRaw" TextWrapping="Wrap" AcceptsReturn="True"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" IsReadOnly="True"/>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
"@

    $inspectorWindow = [System.Windows.Markup.XamlReader]::Parse($inspectorXaml)
    if (-not $inspectorWindow) {
        Add-LogEntry "Data Inspector UI failed to load."
        return
    }

    $treeView = $inspectorWindow.FindName("InspectorTree")
    $rawBox = $inspectorWindow.FindName("InspectorRaw")
    $copyButton = $inspectorWindow.FindName("CopyJsonButton")
    $exportButton = $inspectorWindow.FindName("ExportJsonButton")

    if ($rawBox) {
        $rawBox.Text = $sourceText
    }

    if ($treeView) {
        $treeView.Items.Clear()
        # Reset the node counter before populating
        $script:InspectorNodeCount = 0
        Add-LogEntry "Inspector: Building tree view for data (max $($script:InspectorMaxNodes) nodes, max depth $($script:InspectorMaxDepth))..."
        Populate-InspectorTree -Tree $treeView -Data $parsed -Label "root"
        Add-LogEntry "Inspector: Tree view populated with $($script:InspectorNodeCount) nodes."
    }

    if ($copyButton) {
        $copyButton.Add_Click({
                if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
                    Set-Clipboard -Value $sourceText
                    Add-LogEntry "Raw JSON copied to clipboard via inspector."
                }
                else {
                    [System.Windows.MessageBox]::Show("Clipboard access is not available in this host.", "Clipboard")
                    Add-LogEntry "Clipboard copy skipped (command missing)."
                }
            })
    }

    if ($exportButton) {
        $exportButton.Add_Click({
                $dialog = New-Object Microsoft.Win32.SaveFileDialog
                $dialog.Filter = "JSON Files (*.json)|*.json|All Files (*.*)|*.*"
                $dialog.FileName = "GenesysData.json"
                $dialog.Title = "Export Inspector JSON"
                if ($dialog.ShowDialog() -eq $true) {
                    $JsonText | Out-File -FilePath $dialog.FileName -Encoding utf8
                    Add-LogEntry "Inspector JSON exported to $($dialog.FileName)"
                }
            })
    }

    if ($Window) {
        $inspectorWindow.Owner = $Window
    }
    $inspectorWindow.ShowDialog() | Out-Null
}

<#
.SYNOPSIS
    Displays a formatted conversation timeline report in a popup window.
.DESCRIPTION
    Shows the chronological timeline report with all events from the conversation,
    including timing, errors, MOS scores, hold times, queue wait times, and flow path.
.PARAMETER Report
    The conversation report object containing all data from 6 API endpoints
#>
function Show-ConversationTimelineReport {
    param (
        [Parameter(Mandatory = $true)]
        $Report
    )

    if (-not $Report) {
        Add-LogEntry "No conversation report data to display."
        return
    }

    # Generate the formatted timeline report text
    $reportText = Format-ConversationReportText -Report $Report

    # Sanitize ConversationId for safe use in XAML Title (prevent XML injection)
    $safeConvId = if ($Report.ConversationId) {
        [System.Security.SecurityElement]::Escape($Report.ConversationId)
    }
    else {
        "Unknown"
    }

    $timelineXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Conversation Timeline Report - $safeConvId" Height="700" Width="1000" WindowStartupLocation="CenterOwner">
  <DockPanel Margin="10">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0 0 0 8">
      <Button Name="CopyReportButton" Width="110" Height="28" Content="Copy Report" Margin="0 0 10 0"/>
      <Button Name="ExportReportButton" Width="130" Height="28" Content="Export Report"/>
    </StackPanel>
    <TextBox Name="TimelineReportText" TextWrapping="Wrap" AcceptsReturn="True"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" IsReadOnly="True"
             FontFamily="Consolas" FontSize="11"/>
  </DockPanel>
</Window>
"@

    try {
        $timelineWindow = [System.Windows.Markup.XamlReader]::Parse($timelineXaml)
    }
    catch {
        Add-LogEntry "Failed to create timeline window: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show("Failed to create timeline window: $($_.Exception.Message)", "Error")
        return
    }

    if (-not $timelineWindow) {
        Add-LogEntry "Timeline report window failed to load."
        return
    }

    $timelineTextBox = $timelineWindow.FindName("TimelineReportText")
    $copyButton = $timelineWindow.FindName("CopyReportButton")
    $exportButton = $timelineWindow.FindName("ExportReportButton")

    if ($timelineTextBox) {
        $timelineTextBox.Text = $reportText
    }

    if ($copyButton) {
        $copyButton.Add_Click({
                try {
                    if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
                        Set-Clipboard -Value $reportText
                        Add-LogEntry "Timeline report copied to clipboard."
                    }
                    else {
                        [System.Windows.Clipboard]::SetText($reportText)
                        Add-LogEntry "Timeline report copied to clipboard."
                    }
                }
                catch {
                    Add-LogEntry "Failed to copy timeline report: $($_.Exception.Message)"
                }
            })
    }

    if ($exportButton) {
        $exportButton.Add_Click({
                # Sanitize ConversationId for safe use in filename (remove invalid filename characters)
                $safeFilenameConvId = if ($Report.ConversationId) {
                    $Report.ConversationId -replace '[\\/:*?"<>|]', '_'
                }
                else {
                    "Unknown"
                }

                $dialog = New-Object Microsoft.Win32.SaveFileDialog
                $dialog.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
                $dialog.Title = "Export Conversation Timeline Report"
                $dialog.FileName = "ConversationTimeline_$safeFilenameConvId.txt"
                if ($dialog.ShowDialog() -eq $true) {
                    try {
                        $reportText | Out-File -FilePath $dialog.FileName -Encoding utf8
                        Add-LogEntry "Timeline report exported to $($dialog.FileName)"
                    }
                    catch {
                        Add-LogEntry "Failed to export timeline report: $($_.Exception.Message)"
                        [System.Windows.MessageBox]::Show("Failed to export timeline report: $($_.Exception.Message)", "Export Error")
                    }
                }
            })
    }

    if ($Window) {
        $timelineWindow.Owner = $Window
    }
    $timelineWindow.ShowDialog() | Out-Null
}

function Job-StatusIsPending {
    param ([string]$Status)

    if (-not $Status) { return $false }
    return $Status -match '^(pending|running|in[-]?progress|processing|created)$'
}

<#
.SYNOPSIS
    Updates or adds a query parameter in a URL.
.DESCRIPTION
    Safely updates an existing query parameter or adds a new one to a URL path.
    Handles URLs with or without existing query strings.
.PARAMETER Path
    The URL path (may include existing query string)
.PARAMETER ParameterName
    The query parameter name to update or add
.PARAMETER ParameterValue
    The value to set for the parameter
.OUTPUTS
    Updated URL path with query parameter
#>
function Update-UrlParameter {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ParameterName,
        [Parameter(Mandatory = $true)]
        [string]$ParameterValue
    )

    # Parse URL into path and query parts
    if ($Path -match '^([^\?]+)(\?.*)$') {
        $pathPart = $matches[1]
        $queryPart = $matches[2]
        # Check if parameter already exists in query (match any value, not just digits)
        $paramPattern = "[&\?]$ParameterName=[^&]*"
        if ($queryPart -match $paramPattern) {
            $queryPart = $queryPart -replace "([&\?])$ParameterName=[^&]*", "`${1}$ParameterName=$ParameterValue"
            return $pathPart + $queryPart
        }
        else {
            return "$Path&$ParameterName=$ParameterValue"
        }
    }
    else {
        # No query string yet
        return "$Path?$ParameterName=$ParameterValue"
    }
}

<#
.SYNOPSIS
    Fetches all pages from a paginated API endpoint.
.DESCRIPTION
    Handles three types of pagination:
    1. Cursor-based: Response contains 'cursor' field
    2. URI-based: Response contains 'nextUri' field
    3. Page number based: Response contains 'pageCount' and 'pageNumber' fields
    Continues fetching pages until no more pagination info is found.
.PARAMETER BaseUrl
    Base URL for the API
.PARAMETER InitialPath
    Initial endpoint path
.PARAMETER Headers
    HTTP headers including authorization
.PARAMETER Method
    HTTP method (GET or POST)
.PARAMETER Body
    Request body for POST requests
.PARAMETER ProgressCallback
    Optional callback for progress reporting
#>
function Get-PaginatedResults {
    param (
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$InitialPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,
        [Parameter(Mandatory = $false)]
        [string]$Method = "GET",
        [Parameter(Mandatory = $false)]
        [string]$Body = $null,
        [scriptblock]$ProgressCallback = $null
    )

    $allResults = [System.Collections.ArrayList]::new()
    $currentPath = $InitialPath
    $pageNumber = 1
    $continueLoop = $true

    while ($continueLoop) {
        if ($ProgressCallback) {
            & $ProgressCallback -PageNumber $pageNumber -Status "Fetching page $pageNumber..."
        }

        try {
            $url = if ($currentPath -match '^https?://') { $currentPath } else { "$BaseUrl$currentPath" }
            $response = Invoke-GCRequest -Method $Method -Uri $url -Headers $Headers -Body $Body -AsResponse
            $data = $response.Content | ConvertFrom-Json

            # Add results from this page
            if ($data.entities) {
                foreach ($entity in $data.entities) {
                    [void]$allResults.Add($entity)
                }
            }
            elseif ($data.conversations) {
                foreach ($conv in $data.conversations) {
                    [void]$allResults.Add($conv)
                }
            }
            elseif ($data -is [array]) {
                foreach ($item in $data) {
                    [void]$allResults.Add($item)
                }
            }
            else {
                # Single result or unknown structure
                [void]$allResults.Add($data)
            }

            # Check for cursor-based pagination
            if ($data.cursor) {
                # URL-encode the cursor value to handle special characters
                $encodedCursor = [uri]::EscapeDataString($data.cursor)
                $currentPath = $InitialPath
                if ($currentPath -match '\?') {
                    $currentPath += "&cursor=$encodedCursor"
                }
                else {
                    $currentPath += "?cursor=$encodedCursor"
                }
                $pageNumber++
            }
            elseif ($data.nextUri) {
                $currentPath = $data.nextUri
                $pageNumber++
            }
            # Check for page number based pagination
            elseif ($data.pageCount -and $data.pageNumber) {
                if ($data.pageNumber -lt $data.pageCount) {
                    $nextPage = $data.pageNumber + 1
                    # Use helper function to safely update pageNumber parameter
                    $currentPath = Update-UrlParameter -Path $InitialPath -ParameterName "pageNumber" -ParameterValue $nextPage
                    $pageNumber++
                }
                else {
                    $continueLoop = $false
                }
            }
            else {
                # No pagination info found, this is the last page
                $continueLoop = $false
            }
        }
        catch {
            if ($ProgressCallback) {
                & $ProgressCallback -PageNumber $pageNumber -Status "Error on page $pageNumber : $($_.Exception.Message)" -IsError $true
            }
            throw
        }
    }

    if ($ProgressCallback) {
        & $ProgressCallback -PageNumber $pageNumber -Status "Completed - Retrieved $($allResults.Count) total results" -IsComplete $true
    }

    return $allResults
}

<#
.SYNOPSIS
    Generates a comprehensive conversation report by querying multiple API endpoints.
.DESCRIPTION
    Queries 6 different Genesys Cloud API endpoints to gather comprehensive conversation data:
    - Conversation Details (required)
    - Analytics Details (required)
    - Speech & Text Analytics (optional)
    - Recording Metadata (optional)
    - Sentiments (optional)
    - SIP Messages (optional)

    Reports progress via optional callback for real-time UI updates.
.PARAMETER ConversationId
    The conversation ID to retrieve data for
.PARAMETER Headers
    HTTP headers including authorization (Authorization: Bearer token)
.PARAMETER BaseUrl
    Base API URL for the region (e.g., https://api.usw2.pure.cloud)
.PARAMETER ProgressCallback
    Optional scriptblock called for each endpoint with parameters:
    -PercentComplete (int), -Status (string), -EndpointName (string),
    -IsStarting (bool), -IsSuccess (bool), -IsOptional (bool)
.OUTPUTS
    PSCustomObject with ConversationId, endpoint data properties, RetrievedAt, Errors array, and EndpointLog
#>
function Get-ConversationReport {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ConversationId,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,
        [string]$BaseUrl = "https://api.mypurecloud.com",
        [scriptblock]$ProgressCallback = $null
    )

    # Define all endpoints to query
    $endpoints = @(
        @{ Name = "Conversation Details"; Path = "/api/v2/conversations/$ConversationId"; PropertyName = "ConversationDetails" }
        @{ Name = "Analytics Details"; Path = "/api/v2/analytics/conversations/$ConversationId/details"; PropertyName = "AnalyticsDetails" }
        @{ Name = "Speech & Text Analytics"; Path = "/api/v2/speechandtextanalytics/conversations/$ConversationId"; PropertyName = "SpeechTextAnalytics"; Optional = $true }
        @{ Name = "Recording Metadata"; Path = "/api/v2/conversations/$ConversationId/recordingmetadata"; PropertyName = "RecordingMetadata"; Optional = $true }
        @{ Name = "Sentiments"; Path = "/api/v2/speechandtextanalytics/conversations/$ConversationId/sentiments"; PropertyName = "Sentiments"; Optional = $true }
        @{ Name = "SIP Messages"; Path = "/api/v2/telephony/sipmessages/conversations/$ConversationId"; PropertyName = "SipMessages"; Optional = $true }
    )

    $result = [PSCustomObject]@{
        ConversationId      = $ConversationId
        ConversationDetails = $null
        AnalyticsDetails    = $null
        SpeechTextAnalytics = $null
        RecordingMetadata   = $null
        Sentiments          = $null
        SipMessages         = $null
        RetrievedAt         = (Get-Date).ToString("o")
        Errors              = @()
        EndpointLog         = [System.Collections.ArrayList]::new()
    }

    $totalEndpoints = $endpoints.Count
    $currentEndpoint = 0

    foreach ($endpoint in $endpoints) {
        $currentEndpoint++
        $percentComplete = [int](($currentEndpoint / $totalEndpoints) * 100)

        # Report progress if callback provided
        if ($ProgressCallback) {
            & $ProgressCallback -PercentComplete $percentComplete -Status "Querying: $($endpoint.Name)" -EndpointName $endpoint.Name -IsStarting $true
        }

        $url = "$BaseUrl$($endpoint.Path)"
        $logEntry = [PSCustomObject]@{
            Timestamp = (Get-Date).ToString("HH:mm:ss.fff")
            Endpoint  = $endpoint.Name
            Path      = $endpoint.Path
            Status    = "Pending"
            Message   = ""
        }

        try {
            $response = Invoke-GCRequest -Method GET -Uri $url -Headers $Headers -AsResponse
            $data = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            $result.($endpoint.PropertyName) = $data

            $logEntry.Status = "Success"
            $logEntry.Message = "Retrieved successfully"

            if ($ProgressCallback) {
                & $ProgressCallback -PercentComplete $percentComplete -Status "✓ $($endpoint.Name)" -EndpointName $endpoint.Name -IsSuccess $true
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            if ($endpoint.Optional) {
                $logEntry.Status = "Optional - Not Available"
                $logEntry.Message = $errorMessage
            }
            else {
                $result.Errors += "$($endpoint.Name): $errorMessage"
                $logEntry.Status = "Failed"
                $logEntry.Message = $errorMessage
            }

            if ($ProgressCallback) {
                & $ProgressCallback -PercentComplete $percentComplete -Status "✗ $($endpoint.Name)" -EndpointName $endpoint.Name -IsSuccess $false -IsOptional $endpoint.Optional
            }
        }

        [void]$result.EndpointLog.Add($logEntry)
    }

    return $result
}

<#
.SYNOPSIS
    Extracts timeline events from analytics and conversation details.
.DESCRIPTION
    Parses both API responses and creates a unified list of events with timestamps,
    participant info, segment IDs, MOS scores, error codes, and event types.
#>
function Get-GCConversationDetailsTimeline {
    param (
        [Parameter(Mandatory = $true)]
        $Report
    )

    # Use ArrayList for efficient appending instead of array += which creates new arrays
    $events = [System.Collections.ArrayList]::new()
    $segmentCounter = 0

    # Extract events from analytics details (segments with MOS, errorCodes, etc.)
    if ($Report.AnalyticsDetails -and $Report.AnalyticsDetails.participants) {
        foreach ($participant in $Report.AnalyticsDetails.participants) {
            $participantName = if ($participant.participantName) { $participant.participantName } else { $participant.purpose }
            $participantId = $participant.participantId

            if ($participant.sessions) {
                foreach ($session in $participant.sessions) {
                    $mediaType = $session.mediaType
                    $direction = $session.direction
                    $ani = $session.ani
                    $dnis = $session.dnis
                    $sessionId = $session.sessionId

                    # Extract MOS from session-level mediaEndpointStats
                    # MOS is at the session level, not segment level
                    $sessionMos = $null
                    if ($session.mediaEndpointStats) {
                        foreach ($stat in $session.mediaEndpointStats) {
                            if ($stat.minMos) {
                                $sessionMos = $stat.minMos
                                break  # Use first available MOS value
                            }
                        }
                    }

                    if ($session.segments) {
                        foreach ($segment in $session.segments) {
                            $segmentCounter++
                            $segmentId = $segmentCounter
                            $segmentType = $segment.segmentType
                            $queueId = $segment.queueId
                            $flowId = $segment.flowId
                            $flowName = $segment.flowName
                            $queueName = $segment.queueName
                            $wrapUpCode = $segment.wrapUpCode
                            $wrapUpNote = $segment.wrapUpNote

                            # Extract error codes from segment
                            $errorCode = $null
                            if ($segment.errorCode) {
                                $errorCode = $segment.errorCode
                            }
                            # Also check for sipResponseCode as an error indicator
                            if ($segment.sipResponseCode -and -not $errorCode) {
                                $errorCode = "sip:$($segment.sipResponseCode)"
                            }

                            # Segment start event - parse with InvariantCulture for reliable ISO 8601 parsing
                            if ($segment.segmentStart) {
                                [void]$events.Add([PSCustomObject]@{
                                        Timestamp      = [DateTime]::Parse($segment.segmentStart, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                        Source         = "AnalyticsDetails"
                                        Participant    = $participantName
                                        ParticipantId  = $participantId
                                        SegmentId      = $segmentId
                                        EventType      = "SegmentStart"
                                        SegmentType    = $segmentType
                                        MediaType      = $mediaType
                                        Direction      = $direction
                                        QueueName      = $queueName
                                        FlowName       = $flowName
                                        Mos            = $sessionMos
                                        ErrorCode      = $errorCode
                                        Context        = "ANI: $ani, DNIS: $dnis"
                                        DisconnectType = $null
                                    })
                            }

                            # Segment end event - parse with InvariantCulture
                            if ($segment.segmentEnd) {
                                $disconnectType = $segment.disconnectType
                                [void]$events.Add([PSCustomObject]@{
                                        Timestamp      = [DateTime]::Parse($segment.segmentEnd, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                        Source         = "AnalyticsDetails"
                                        Participant    = $participantName
                                        ParticipantId  = $participantId
                                        SegmentId      = $segmentId
                                        EventType      = if ($disconnectType) { "Disconnect" } else { "SegmentEnd" }
                                        SegmentType    = $segmentType
                                        MediaType      = $mediaType
                                        Direction      = $direction
                                        QueueName      = $queueName
                                        FlowName       = $flowName
                                        Mos            = $sessionMos
                                        ErrorCode      = $errorCode
                                        Context        = if ($disconnectType) { "DisconnectType: $disconnectType" } else { $null }
                                        DisconnectType = $disconnectType
                                    })
                            }
                        }
                    }
                }
            }
        }
    }

    # Extract events from conversation details (state transitions, etc.)
    if ($Report.ConversationDetails -and $Report.ConversationDetails.participants) {
        foreach ($participant in $Report.ConversationDetails.participants) {
            $participantName = if ($participant.name) { $participant.name } else { $participant.purpose }
            $participantId = $participant.id

            # Start time event - parse with InvariantCulture
            if ($participant.startTime) {
                [void]$events.Add([PSCustomObject]@{
                        Timestamp      = [DateTime]::Parse($participant.startTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        Source         = "Conversations"
                        Participant    = $participantName
                        ParticipantId  = $participantId
                        SegmentId      = $null
                        EventType      = "ParticipantJoined"
                        SegmentType    = $null
                        MediaType      = $null
                        Direction      = $null
                        QueueName      = $null
                        FlowName       = $null
                        Mos            = $null
                        ErrorCode      = $null
                        Context        = "Purpose: $($participant.purpose)"
                        DisconnectType = $null
                    })
            }

            # End time / disconnect event - parse with InvariantCulture
            if ($participant.endTime) {
                $disconnectType = $participant.disconnectType
                [void]$events.Add([PSCustomObject]@{
                        Timestamp      = [DateTime]::Parse($participant.endTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        Source         = "Conversations"
                        Participant    = $participantName
                        ParticipantId  = $participantId
                        SegmentId      = $null
                        EventType      = if ($disconnectType) { "Disconnect" } else { "ParticipantLeft" }
                        SegmentType    = $null
                        MediaType      = $null
                        Direction      = $null
                        QueueName      = $null
                        FlowName       = $null
                        Mos            = $null
                        ErrorCode      = $null
                        Context        = if ($disconnectType) { "DisconnectType: $disconnectType" } else { $null }
                        DisconnectType = $disconnectType
                    })
            }

            # Process calls/chats for state changes
            if ($participant.calls) {
                foreach ($call in $participant.calls) {
                    if ($call.state -and $call.connectedTime) {
                        [void]$events.Add([PSCustomObject]@{
                                Timestamp      = [DateTime]::Parse($call.connectedTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                Source         = "Conversations"
                                Participant    = $participantName
                                ParticipantId  = $participantId
                                SegmentId      = $null
                                EventType      = "StateChange"
                                SegmentType    = $null
                                MediaType      = "voice"
                                Direction      = $call.direction
                                QueueName      = $null
                                FlowName       = $null
                                Mos            = $null
                                ErrorCode      = $null
                                Context        = "State: connected"
                                DisconnectType = $null
                            })
                    }
                    if ($call.disconnectedTime) {
                        [void]$events.Add([PSCustomObject]@{
                                Timestamp      = [DateTime]::Parse($call.disconnectedTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                Source         = "Conversations"
                                Participant    = $participantName
                                ParticipantId  = $participantId
                                SegmentId      = $null
                                EventType      = "Disconnect"
                                SegmentType    = $null
                                MediaType      = "voice"
                                Direction      = $call.direction
                                QueueName      = $null
                                FlowName       = $null
                                Mos            = $null
                                ErrorCode      = $null
                                Context        = "State: disconnected"
                                DisconnectType = $call.disconnectType
                            })
                    }
                }
            }

            # Process chats
            if ($participant.chats) {
                foreach ($chat in $participant.chats) {
                    if ($chat.state -and $chat.connectedTime) {
                        [void]$events.Add([PSCustomObject]@{
                                Timestamp      = [DateTime]::Parse($chat.connectedTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                Source         = "Conversations"
                                Participant    = $participantName
                                ParticipantId  = $participantId
                                SegmentId      = $null
                                EventType      = "StateChange"
                                SegmentType    = $null
                                MediaType      = "chat"
                                Direction      = $chat.direction
                                QueueName      = $null
                                FlowName       = $null
                                Mos            = $null
                                ErrorCode      = $null
                                Context        = "State: connected"
                                DisconnectType = $null
                            })
                    }
                    if ($chat.disconnectedTime) {
                        [void]$events.Add([PSCustomObject]@{
                                Timestamp      = [DateTime]::Parse($chat.disconnectedTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                Source         = "Conversations"
                                Participant    = $participantName
                                ParticipantId  = $participantId
                                SegmentId      = $null
                                EventType      = "Disconnect"
                                SegmentType    = $null
                                MediaType      = "chat"
                                Direction      = $chat.direction
                                QueueName      = $null
                                FlowName       = $null
                                Mos            = $null
                                ErrorCode      = $null
                                Context        = "State: disconnected"
                                DisconnectType = $chat.disconnectType
                            })
                    }
                }
            }
        }
    }

    # Extract events from SIP messages if available
    if ($Report.SipMessages) {
        foreach ($msg in $Report.SipMessages) {
            if ($msg.timestamp) {
                # Build error information from SIP status codes and reason phrases
                # Only include status codes that indicate errors (4xx, 5xx, 6xx)
                $sipErrorInfo = $null
                if ($msg.statusCode -and $msg.statusCode -ge 400) {
                    $sipErrorInfo = "SIP $($msg.statusCode)"
                    if ($msg.reasonPhrase -and -not [string]::IsNullOrWhiteSpace($msg.reasonPhrase)) {
                        $sipErrorInfo += ": $($msg.reasonPhrase)"
                    }
                }

                [void]$events.Add([PSCustomObject]@{
                        Timestamp      = [DateTime]::Parse($msg.timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        Source         = "SIP"
                        Participant    = $msg.participantId
                        ParticipantId  = $msg.participantId
                        SegmentId      = $null
                        EventType      = "SIP_$($msg.method)"
                        SegmentType    = $null
                        MediaType      = "voice"
                        Direction      = $msg.direction
                        QueueName      = $null
                        FlowName       = $null
                        Mos            = $null
                        ErrorCode      = $sipErrorInfo
                        Context        = $msg.method
                        DisconnectType = $null
                    })
            }
        }
    }

    # Extract events from speech & text analytics if available
    if ($Report.SpeechTextAnalytics -and $Report.SpeechTextAnalytics.conversation) {
        $convStart = $null
        if ($Report.SpeechTextAnalytics.conversation.startTime) {
            $convStart = [DateTime]::Parse($Report.SpeechTextAnalytics.conversation.startTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }

        if ($Report.SpeechTextAnalytics.conversation.topics) {
            foreach ($topic in $Report.SpeechTextAnalytics.conversation.topics) {
                [void]$events.Add([PSCustomObject]@{
                        Timestamp      = $convStart
                        Source         = "SpeechText"
                        Participant    = $null
                        ParticipantId  = $null
                        SegmentId      = $null
                        EventType      = "Topic"
                        SegmentType    = $null
                        MediaType      = $null
                        Direction      = $null
                        QueueName      = $null
                        FlowName       = $null
                        Mos            = $null
                        ErrorCode      = $null
                        Context        = "Topic: $($topic.name)"
                        DisconnectType = $null
                    })
            }
        }
    }

    # Extract events from sentiment analysis if available
    if ($Report.Sentiments -and $Report.Sentiments.sentiment) {
        foreach ($sentiment in $Report.Sentiments.sentiment) {
            if ($sentiment.time) {
                [void]$events.Add([PSCustomObject]@{
                        Timestamp      = [DateTime]::Parse($sentiment.time, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        Source         = "Sentiment"
                        Participant    = $sentiment.participantId
                        ParticipantId  = $sentiment.participantId
                        SegmentId      = $null
                        EventType      = "SentimentSample"
                        SegmentType    = $null
                        MediaType      = $null
                        Direction      = $null
                        QueueName      = $null
                        FlowName       = $null
                        Mos            = $null
                        ErrorCode      = $null
                        Context        = "Sentiment: $($sentiment.label) ($($sentiment.score))"
                        DisconnectType = $null
                    })
            }
        }
    }

    # Extract events from recording metadata if available
    if ($Report.RecordingMetadata) {
        foreach ($rec in $Report.RecordingMetadata) {
            if ($rec.startTime) {
                [void]$events.Add([PSCustomObject]@{
                        Timestamp      = [DateTime]::Parse($rec.startTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        Source         = "Recording"
                        Participant    = $rec.participantId
                        ParticipantId  = $rec.participantId
                        SegmentId      = $null
                        EventType      = "RecordingStart"
                        SegmentType    = $null
                        MediaType      = $null
                        Direction      = $null
                        QueueName      = $null
                        FlowName       = $null
                        Mos            = $null
                        ErrorCode      = $null
                        Context        = "Recording ID: $($rec.id)"
                        DisconnectType = $null
                    })
            }
            if ($rec.endTime) {
                [void]$events.Add([PSCustomObject]@{
                        Timestamp      = [DateTime]::Parse($rec.endTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                        Source         = "Recording"
                        Participant    = $rec.participantId
                        ParticipantId  = $rec.participantId
                        SegmentId      = $null
                        EventType      = "RecordingEnd"
                        SegmentType    = $null
                        MediaType      = $null
                        Direction      = $null
                        QueueName      = $null
                        FlowName       = $null
                        Mos            = $null
                        ErrorCode      = $null
                        Context        = "Recording ID: $($rec.id)"
                        DisconnectType = $null
                    })
            }
        }
    }

    return $events
}

<#
.SYNOPSIS
    Merges and sorts conversation events chronologically.
.DESCRIPTION
    Takes events from Get-GCConversationDetailsTimeline and sorts them by timestamp
    to create a unified, chronological view of the conversation.
#>
function Merge-GCConversationEvents {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Events
    )

    # Sort events by timestamp ascending
    $sortedEvents = $Events | Sort-Object -Property Timestamp

    return $sortedEvents
}

<#
.SYNOPSIS
    Formats the chronological timeline as text output.
.DESCRIPTION
    Creates a text-based timeline with each event on a line showing timestamp,
    event type, participant, segment ID, MOS score, and error code.
#>

function Format-GCConversationTimelineText {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Events
    )

    $sb = [System.Text.StringBuilder]::new()

    foreach ($timelineEvent in $Events) {
        $timestamp = $timelineEvent.Timestamp.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssK')
        $eventType = $timelineEvent.EventType.PadRight(18)

        $participantStr = ''
        if ($timelineEvent.FlowName) {
            $participantStr = 'Flow: ' + $timelineEvent.FlowName
        }
        elseif ($timelineEvent.QueueName) {
            $participantStr = 'Queue: ' + $timelineEvent.QueueName
        }
        elseif ($timelineEvent.Participant) {
            $participantStr = $timelineEvent.Participant
        }
        else {
            $participantStr = '(unknown)'
        }

        $segmentStr = if ($timelineEvent.SegmentId) { 'seg=' + $timelineEvent.SegmentId } else { '' }

        $mediaStr = ''
        if ($timelineEvent.MediaType -or $timelineEvent.Direction) {
            $parts = @()
            if ($timelineEvent.MediaType) { $parts += 'media=' + $timelineEvent.MediaType }
            if ($timelineEvent.Direction) { $parts += 'dir=' + $timelineEvent.Direction }
            $mediaStr = $parts -join ' | '
        }

        $mosStr = ''
        if ($null -ne $timelineEvent.Mos) {
            $mosValue = 0.0
            if ([double]::TryParse($timelineEvent.Mos.ToString(), [ref]$mosValue)) {
                if ($mosValue -lt 3.5) {
                    $mosStr = 'MOS=' + $mosValue.ToString('0.00') + ' (DEGRADED)'
                }
                else {
                    $mosStr = 'MOS=' + $mosValue.ToString('0.00')
                }
            }
        }

        $errorStr = if ($timelineEvent.ErrorCode) { 'errorCode=' + $timelineEvent.ErrorCode } else { '' }

        $disconnectStr = ''
        if ($timelineEvent.EventType -eq 'Disconnect' -and $timelineEvent.DisconnectType) {
            $disconnectStr = $timelineEvent.Participant + ' disconnected (' + $timelineEvent.DisconnectType + ')'
        }

        $lineParts = @($timestamp, '|', $eventType, '|', $participantStr)
        if ($segmentStr) { $lineParts += '| ' + $segmentStr }
        if ($mediaStr) { $lineParts += '| ' + $mediaStr }
        if ($mosStr) { $lineParts += '| ' + $mosStr }
        if ($errorStr) { $lineParts += '| ' + $errorStr }
        if ($disconnectStr) { $lineParts += '| ' + $disconnectStr }

        $line = $lineParts -join ' '
        [void]$sb.AppendLine($line.Trim())
    }

    return $sb.ToString()
}

<#
.SYNOPSIS
    Generates a summary of degraded segments and disconnects.
.DESCRIPTION
    Analyzes the timeline events to produce summary statistics including
    total segments, segments with MOS values, degraded segments (MOS < 3.5),
    and all disconnect events.
#>
function Get-GCConversationSummary {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ConversationId,
        [Parameter(Mandatory = $true)]
        [array]$Events
    )

    # Count segments (SegmentEnd events contain the final MOS)
    $segmentEndEvents = $Events | Where-Object { $_.EventType -eq "SegmentEnd" -or ($_.EventType -eq "Disconnect" -and $_.SegmentId) }
    $segmentStartEvents = $Events | Where-Object { $_.EventType -eq "SegmentStart" }

    $totalSegments = ($segmentStartEvents | Measure-Object).Count

    # Get segments with MOS values
    $segmentsWithMos = $segmentEndEvents | Where-Object { $null -ne $_.Mos }
    $segmentsWithMosCount = ($segmentsWithMos | Measure-Object).Count

    # Get degraded segments (MOS < 3.5) - use TryParse for safe conversion
    $degradedSegments = $segmentsWithMos | Where-Object {
        $mosValue = 0.0
        if ([double]::TryParse($_.Mos.ToString(), [ref]$mosValue)) {
            return $mosValue -lt 3.5
        }
        return $false
    }
    $degradedCount = ($degradedSegments | Measure-Object).Count

    # Get all disconnect events
    $disconnectEvents = $Events | Where-Object { $_.EventType -eq "Disconnect" }

    # Build segment details lookup (start times)
    $segmentDetails = @{}
    foreach ($startEvent in $segmentStartEvents) {
        if ($startEvent.SegmentId) {
            $segmentDetails[$startEvent.SegmentId] = $startEvent
        }
    }

    return [PSCustomObject]@{
        ConversationId       = $ConversationId
        TotalSegments        = $totalSegments
        SegmentsWithMos      = $segmentsWithMosCount
        DegradedSegmentCount = $degradedCount
        DegradedSegments     = $degradedSegments
        DisconnectEvents     = $disconnectEvents
        SegmentDetails       = $segmentDetails
    }
}

<#
.SYNOPSIS
    Formats the conversation summary as text output.
.DESCRIPTION
    Creates a text block with summary statistics and lists of degraded
    segments and disconnect events.
#>
function Format-GCConversationSummaryText {
    param (
        [Parameter(Mandatory = $true)]
        $Summary
    )

    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("=" * 50 + " Summary " + "=" * 50)
    [void]$sb.AppendLine("ConversationId: $($Summary.ConversationId)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Segments:          $($Summary.TotalSegments)")
    [void]$sb.AppendLine("Segments with MOS: $($Summary.SegmentsWithMos)")
    [void]$sb.AppendLine("Degraded segments (MOS less than 3.5): $($Summary.DegradedSegmentCount)")
    [void]$sb.AppendLine("")

    # List degraded segments
    if ($Summary.DegradedSegments -and ($Summary.DegradedSegments | Measure-Object).Count -gt 0) {
        [void]$sb.AppendLine("Degraded segments:")
        foreach ($seg in $Summary.DegradedSegments) {
            $startInfo = $Summary.SegmentDetails[$seg.SegmentId]
            $startTime = if ($startInfo) { $startInfo.Timestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssK") } else { "(unknown)" }
            $endTime = $seg.Timestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssK")

            $participantStr = if ($seg.QueueName) { "Queue: $($seg.QueueName)" } `
                elseif ($seg.FlowName) { "Flow: $($seg.FlowName)" } `
                elseif ($seg.Participant) { $seg.Participant } `
                else { "(unknown)" }

            # Use TryParse for safe MOS value conversion
            $mosValue = 0.0
            [void][double]::TryParse($seg.Mos.ToString(), [ref]$mosValue)
            $errorStr = if ($seg.ErrorCode) { "errorCode=$($seg.ErrorCode)" } else { "errorCode=" }

            [void]$sb.AppendLine("  - seg=$($seg.SegmentId) | $participantStr | MOS=$($mosValue.ToString('0.00')) | $startTime-$endTime | $errorStr")
        }
        [void]$sb.AppendLine("")
    }

    # List disconnect events
    if ($Summary.DisconnectEvents -and ($Summary.DisconnectEvents | Measure-Object).Count -gt 0) {
        [void]$sb.AppendLine("Disconnects:")
        foreach ($disc in $Summary.DisconnectEvents) {
            $timestamp = $disc.Timestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssK")
            $segStr = if ($disc.SegmentId) { "seg=$($disc.SegmentId)" } else { "(no segment)" }
            $disconnector = if ($disc.DisconnectType) { "$($disc.Participant) disconnected ($($disc.DisconnectType))" } else { "$($disc.Participant) disconnected" }
            $errorStr = if ($disc.ErrorCode) { "errorCode=$($disc.ErrorCode)" } else { "errorCode=" }

            [void]$sb.AppendLine("  - $timestamp | $segStr | $disconnector | $errorStr")
        }
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("=" * 109)

    return $sb.ToString()
}

<#
.SYNOPSIS
    Calculates duration statistics from conversation events and analytics data.
.DESCRIPTION
    Computes total duration, IVR time, queue wait time, agent talk time, hold time,
    wrap-up time, and other timing metrics from the conversation data.
#>
function Get-GCConversationDurationAnalysis {
    param (
        [Parameter(Mandatory = $true)]
        $Report,
        [Parameter(Mandatory = $true)]
        [array]$Events
    )

    $analysis = [PSCustomObject]@{
        TotalDurationSeconds = 0
        IvrTimeSeconds       = 0
        QueueWaitSeconds     = 0
        AgentTalkSeconds     = 0
        HoldTimeSeconds      = 0
        WrapUpSeconds        = 0
        ConferenceSeconds    = 0
        SystemTimeSeconds    = 0
        InteractTimeSeconds  = 0
        AlertTimeSeconds     = 0
        ConversationStart    = $null
        ConversationEnd      = $null
        SegmentBreakdown     = @{}
    }

    # Get conversation start/end times from analytics or conversation details
    if ($Report.AnalyticsDetails) {
        if ($Report.AnalyticsDetails.conversationStart) {
            $analysis.ConversationStart = [DateTime]::Parse($Report.AnalyticsDetails.conversationStart, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        if ($Report.AnalyticsDetails.conversationEnd) {
            $analysis.ConversationEnd = [DateTime]::Parse($Report.AnalyticsDetails.conversationEnd, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
    }

    # Calculate total duration
    if ($analysis.ConversationStart -and $analysis.ConversationEnd) {
        $analysis.TotalDurationSeconds = ($analysis.ConversationEnd - $analysis.ConversationStart).TotalSeconds
    }

    # Process segments from analytics to extract timing metrics
    if ($Report.AnalyticsDetails -and $Report.AnalyticsDetails.participants) {
        foreach ($participant in $Report.AnalyticsDetails.participants) {
            if ($participant.sessions) {
                foreach ($session in $participant.sessions) {
                    # Extract metrics from session if available
                    if ($session.metrics) {
                        foreach ($metric in $session.metrics) {
                            # Metrics are typically in milliseconds
                            $valueSeconds = if ($metric.value) { $metric.value / 1000.0 } else { 0 }
                            # Note: "Complete" metrics are cumulative totals; regular metrics may be emitted multiple times
                            # For talk/held, we use the "Complete" values when available as they represent totals
                            switch ($metric.name) {
                                "tIvr" { $analysis.IvrTimeSeconds += $valueSeconds }
                                "tAcd" { $analysis.QueueWaitSeconds += $valueSeconds }
                                "tTalk" {
                                    # Regular tTalk may be emitted multiple times; track the max as a fallback
                                    $analysis.AgentTalkSeconds = [Math]::Max($analysis.AgentTalkSeconds, $valueSeconds)
                                }
                                "tTalkComplete" {
                                    # Complete value is the authoritative total
                                    $analysis.AgentTalkSeconds = [Math]::Max($analysis.AgentTalkSeconds, $valueSeconds)
                                }
                                "tHeld" {
                                    # Regular tHeld may be emitted multiple times; track the max as a fallback
                                    $analysis.HoldTimeSeconds = [Math]::Max($analysis.HoldTimeSeconds, $valueSeconds)
                                }
                                "tHeldComplete" {
                                    # Complete value is the authoritative total
                                    $analysis.HoldTimeSeconds = [Math]::Max($analysis.HoldTimeSeconds, $valueSeconds)
                                }
                                "tAcw" { $analysis.WrapUpSeconds += $valueSeconds }
                                "tAlert" { $analysis.AlertTimeSeconds += $valueSeconds }
                            }
                        }
                    }

                    # Calculate segment-based timing
                    if ($session.segments) {
                        foreach ($segment in $session.segments) {
                            if ($segment.segmentStart -and $segment.segmentEnd) {
                                $start = [DateTime]::Parse($segment.segmentStart, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                $end = [DateTime]::Parse($segment.segmentEnd, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                $durationSec = ($end - $start).TotalSeconds

                                $segType = if ($segment.segmentType) { $segment.segmentType } else { "unknown" }
                                if (-not $analysis.SegmentBreakdown.ContainsKey($segType)) {
                                    $analysis.SegmentBreakdown[$segType] = 0
                                }
                                $analysis.SegmentBreakdown[$segType] += $durationSec

                                switch ($segType) {
                                    "interact" { $analysis.InteractTimeSeconds += $durationSec }
                                    "hold" { $analysis.HoldTimeSeconds += $durationSec }
                                    "system" { $analysis.SystemTimeSeconds += $durationSec }
                                    "ivr" { $analysis.IvrTimeSeconds += $durationSec }
                                    "wrapup" { $analysis.WrapUpSeconds += $durationSec }
                                    "alert" { $analysis.AlertTimeSeconds += $durationSec }
                                }

                                if ($segment.conference -eq $true) {
                                    $analysis.ConferenceSeconds += $durationSec
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return $analysis
}

<#
.SYNOPSIS
    Generates participant statistics from conversation data.
.DESCRIPTION
    Calculates per-participant metrics including time in conversation,
    segment counts, and role-specific information.
#>
function Get-GCParticipantStatistics {
    param (
        [Parameter(Mandatory = $true)]
        $Report
    )

    $stats = [System.Collections.ArrayList]::new()

    if ($Report.AnalyticsDetails -and $Report.AnalyticsDetails.participants) {
        foreach ($participant in $Report.AnalyticsDetails.participants) {
            $participantName = if ($participant.participantName) { $participant.participantName } else { $participant.purpose }
            $purpose = $participant.purpose

            $participantStat = [PSCustomObject]@{
                Name                 = $participantName
                ParticipantId        = $participant.participantId
                Purpose              = $purpose
                SessionCount         = 0
                SegmentCount         = 0
                TotalDurationSeconds = 0
                MediaTypes           = [System.Collections.ArrayList]::new()
                DisconnectType       = $null
                HasErrors            = $false
                ErrorCodes           = [System.Collections.ArrayList]::new()
                MosScores            = [System.Collections.ArrayList]::new()
                FlowNames            = [System.Collections.ArrayList]::new()
                QueueNames           = [System.Collections.ArrayList]::new()
                HasRecording         = $false
                Providers            = [System.Collections.ArrayList]::new()
                RemoteName           = $null
                ANI                  = $null
                DNIS                 = $null
            }

            if ($participant.sessions) {
                $participantStat.SessionCount = $participant.sessions.Count

                foreach ($session in $participant.sessions) {
                    if ($session.mediaType -and $participantStat.MediaTypes -notcontains $session.mediaType) {
                        [void]$participantStat.MediaTypes.Add($session.mediaType)
                    }

                    # Extract recording info
                    if ($session.recording -eq $true) {
                        $participantStat.HasRecording = $true
                    }

                    # Extract provider info
                    if ($session.provider -and $participantStat.Providers -notcontains $session.provider) {
                        [void]$participantStat.Providers.Add($session.provider)
                    }

                    # Extract remote party name
                    if ($session.remoteNameDisplayable -and -not $participantStat.RemoteName) {
                        $participantStat.RemoteName = $session.remoteNameDisplayable
                    }

                    # Extract ANI/DNIS
                    if ($session.ani -and -not $participantStat.ANI) {
                        $participantStat.ANI = $session.ani
                    }
                    if ($session.dnis -and -not $participantStat.DNIS) {
                        $participantStat.DNIS = $session.dnis
                    }

                    # Extract flow info
                    if ($session.flow -and $session.flow.flowName) {
                        if ($participantStat.FlowNames -notcontains $session.flow.flowName) {
                            [void]$participantStat.FlowNames.Add($session.flow.flowName)
                        }
                    }

                    if ($session.segments) {
                        $participantStat.SegmentCount += $session.segments.Count

                        foreach ($segment in $session.segments) {
                            # Calculate segment duration
                            if ($segment.segmentStart -and $segment.segmentEnd) {
                                $start = [DateTime]::Parse($segment.segmentStart, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                $end = [DateTime]::Parse($segment.segmentEnd, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                $participantStat.TotalDurationSeconds += ($end - $start).TotalSeconds
                            }

                            # Track disconnect type
                            if ($segment.disconnectType -and -not $participantStat.DisconnectType) {
                                $participantStat.DisconnectType = $segment.disconnectType
                            }

                            # Track errors
                            if ($segment.errorCode) {
                                $participantStat.HasErrors = $true
                                if ($participantStat.ErrorCodes -notcontains $segment.errorCode) {
                                    [void]$participantStat.ErrorCodes.Add($segment.errorCode)
                                }
                            }

                            # Track queue names
                            if ($segment.queueId) {
                                # Note: queueId would need lookup for actual name
                                if ($participantStat.QueueNames -notcontains $segment.queueId) {
                                    [void]$participantStat.QueueNames.Add($segment.queueId)
                                }
                            }
                        }
                    }

                    # Track MOS from media endpoint stats
                    if ($session.mediaEndpointStats) {
                        foreach ($stat in $session.mediaEndpointStats) {
                            if ($stat.minMos) {
                                [void]$participantStat.MosScores.Add($stat.minMos)
                            }
                        }
                    }
                }
            }

            [void]$stats.Add($participantStat)
        }
    }

    return $stats
}

<#
.SYNOPSIS
    Analyzes the conversation flow and path.
.DESCRIPTION
    Creates a visual representation of the conversation path showing
    how the call moved between IVR, queues, agents, and external parties.
#>
function Get-GCConversationFlowPath {
    param (
        [Parameter(Mandatory = $true)]
        $Report
    )

    $flowPath = [System.Collections.ArrayList]::new()

    if ($Report.AnalyticsDetails -and $Report.AnalyticsDetails.participants) {
        # Sort participants by their first segment start time
        $participantOrder = @()
        foreach ($participant in $Report.AnalyticsDetails.participants) {
            $earliestTime = $null
            if ($participant.sessions) {
                foreach ($session in $participant.sessions) {
                    if ($session.segments) {
                        foreach ($segment in $session.segments) {
                            if ($segment.segmentStart) {
                                $segTime = [DateTime]::Parse($segment.segmentStart, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                                if (-not $earliestTime -or $segTime -lt $earliestTime) {
                                    $earliestTime = $segTime
                                }
                            }
                        }
                    }
                }
            }
            $participantOrder += [PSCustomObject]@{
                Participant = $participant
                StartTime   = $earliestTime
            }
        }

        $sortedParticipants = $participantOrder | Sort-Object -Property StartTime

        foreach ($entry in $sortedParticipants) {
            $participant = $entry.Participant
            $participantName = if ($participant.participantName) { $participant.participantName } else { $participant.purpose }
            $purpose = $participant.purpose

            $flowStep = [PSCustomObject]@{
                Order        = $flowPath.Count + 1
                Name         = $participantName
                Purpose      = $purpose
                StartTime    = $entry.StartTime
                FlowName     = $null
                TransferType = $null
                TransferTo   = $null
            }

            # Get flow info and transfer details
            if ($participant.sessions) {
                foreach ($session in $participant.sessions) {
                    if ($session.flow) {
                        $flowStep.FlowName = $session.flow.flowName
                        $flowStep.TransferType = $session.flow.transferType
                        $flowStep.TransferTo = $session.flow.transferTargetName
                    }
                }
            }

            [void]$flowPath.Add($flowStep)
        }
    }

    return $flowPath
}

<#
.SYNOPSIS
    Generates key insights from the conversation analysis.
.DESCRIPTION
    Analyzes all conversation data to produce actionable insights and
    highlights about quality issues, timing anomalies, and patterns.
#>
function Get-GCConversationKeyInsights {
    param (
        [Parameter(Mandatory = $true)]
        $Report,
        [Parameter(Mandatory = $true)]
        $DurationAnalysis,
        [Parameter(Mandatory = $true)]
        $ParticipantStats,
        [Parameter(Mandatory = $true)]
        $Summary
    )

    $insights = [System.Collections.ArrayList]::new()

    # Insight: Overall quality assessment
    $minMos = $null
    if ($Report.AnalyticsDetails -and $Report.AnalyticsDetails.mediaStatsMinConversationMos) {
        $minMos = $Report.AnalyticsDetails.mediaStatsMinConversationMos
        if ($minMos -lt 3.0) {
            [void]$insights.Add([PSCustomObject]@{
                    Category = "CRITICAL"
                    Type     = "Quality"
                    Message  = "Very poor voice quality detected (MOS: $([Math]::Round($minMos, 2))). Call likely had significant audio issues."
                })
        }
        elseif ($minMos -lt 3.5) {
            [void]$insights.Add([PSCustomObject]@{
                    Category = "WARNING"
                    Type     = "Quality"
                    Message  = "Below-average voice quality detected (MOS: $([Math]::Round($minMos, 2))). Some audio degradation may have occurred."
                })
        }
        elseif ($minMos -ge 4.0) {
            [void]$insights.Add([PSCustomObject]@{
                    Category = "OK"
                    Type     = "Quality"
                    Message  = "Good voice quality maintained throughout (MOS: $([Math]::Round($minMos, 2)))."
                })
        }
    }

    # Insight: Long hold times
    if ($DurationAnalysis.HoldTimeSeconds -gt 300) {
        [void]$insights.Add([PSCustomObject]@{
                Category = "WARNING"
                Type     = "Experience"
                Message  = "Extended hold time detected ($([Math]::Round($DurationAnalysis.HoldTimeSeconds / 60, 1)) minutes). Customer may have experienced frustration."
            })
    }

    # Insight: Long IVR time
    if ($DurationAnalysis.IvrTimeSeconds -gt 180) {
        [void]$insights.Add([PSCustomObject]@{
                Category = "INFO"
                Type     = "Flow"
                Message  = "Extended IVR navigation ($([Math]::Round($DurationAnalysis.IvrTimeSeconds / 60, 1)) minutes). Consider reviewing IVR flow complexity."
            })
    }

    # Insight: Multiple transfers
    $transferCount = 0
    foreach ($stat in $ParticipantStats) {
        if ($stat.Purpose -eq "agent" -or $stat.Purpose -eq "acd") {
            $transferCount++
        }
    }
    if ($transferCount -gt 2) {
        [void]$insights.Add([PSCustomObject]@{
                Category = "WARNING"
                Type     = "Flow"
                Message  = "Multiple transfers occurred ($transferCount agent/queue handoffs). Customer experience may be affected."
            })
    }

    # Insight: Error conditions
    $hasErrors = $false
    $errorTypes = [System.Collections.ArrayList]::new()
    foreach ($stat in $ParticipantStats) {
        if ($stat.HasErrors) {
            $hasErrors = $true
            foreach ($err in $stat.ErrorCodes) {
                if ($errorTypes -notcontains $err) {
                    [void]$errorTypes.Add($err)
                }
            }
        }
    }
    if ($hasErrors) {
        [void]$insights.Add([PSCustomObject]@{
                Category = "WARNING"
                Type     = "Error"
                Message  = "Technical errors occurred during the conversation: $($errorTypes -join ', ')"
            })
    }

    # Insight: Abnormal disconnect
    $abnormalDisconnects = @("error", "system", "timeout")
    foreach ($stat in $ParticipantStats) {
        if ($null -ne $stat.DisconnectType -and $stat.DisconnectType -ne "" -and $abnormalDisconnects -contains $stat.DisconnectType.ToLower()) {
            [void]$insights.Add([PSCustomObject]@{
                    Category = "WARNING"
                    Type     = "Disconnect"
                    Message  = "$($stat.Name) disconnected abnormally ($($stat.DisconnectType)). May indicate technical issue."
                })
        }
    }

    # Insight: Conference call
    if ($DurationAnalysis.ConferenceSeconds -gt 0) {
        [void]$insights.Add([PSCustomObject]@{
                Category = "INFO"
                Type     = "Flow"
                Message  = "Conference call included ($([Math]::Round($DurationAnalysis.ConferenceSeconds / 60, 1)) minutes with multiple parties)."
            })
    }

    # Insight: Long total duration
    if ($DurationAnalysis.TotalDurationSeconds -gt 3600) {
        [void]$insights.Add([PSCustomObject]@{
                Category = "INFO"
                Type     = "Duration"
                Message  = "Extended conversation duration ($([Math]::Round($DurationAnalysis.TotalDurationSeconds / 60, 0)) minutes). May require follow-up review."
            })
    }

    # Insight: Short conversation (might be abandoned)
    if ($DurationAnalysis.TotalDurationSeconds -gt 0 -and $DurationAnalysis.TotalDurationSeconds -lt 30) {
        [void]$insights.Add([PSCustomObject]@{
                Category = "INFO"
                Type     = "Duration"
                Message  = "Very short conversation ($([Math]::Round($DurationAnalysis.TotalDurationSeconds, 0)) seconds). May indicate abandoned call or quick resolution."
            })
    }

    # Add a general quality rating
    $qualityRating = "Unknown"
    $ratingScore = 0

    # Score calculation based on various factors
    if ($minMos) {
        if ($minMos -ge 4.0) { $ratingScore += 3 }
        elseif ($minMos -ge 3.5) { $ratingScore += 2 }
        elseif ($minMos -ge 3.0) { $ratingScore += 1 }
    }
    if ($DurationAnalysis.HoldTimeSeconds -lt 60) { $ratingScore += 1 }
    if ($transferCount -le 1) { $ratingScore += 1 }
    if (-not $hasErrors) { $ratingScore += 2 }

    if ($ratingScore -ge 6) { $qualityRating = "Excellent" }
    elseif ($ratingScore -ge 4) { $qualityRating = "Good" }
    elseif ($ratingScore -ge 2) { $qualityRating = "Fair" }
    else { $qualityRating = "Needs Review" }

    [void]$insights.Insert(0, [PSCustomObject]@{
            Category = "OVERALL"
            Type     = "Rating"
            Message  = "Overall Quality: $qualityRating (Score: $ratingScore/8)"
        })

    return $insights
}

<#
.SYNOPSIS
    Provides human-readable explanations for common error codes.
.DESCRIPTION
    Maps Genesys Cloud error codes to user-friendly descriptions
    and potential resolution steps.
#>
function Get-GCErrorExplanation {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ErrorCode
    )

    $explanations = @{
        "error.ininedgecontrol.session.inactive"               = "Session became inactive, possibly due to network issues or timeout."
        "error.ininedgecontrol.connection.media.endpoint.idle" = "Media endpoint went idle, often due to prolonged silence or network dropout."
        "sip:400"                                              = "Bad Request - The SIP request was malformed or invalid."
        "sip:403"                                              = "Forbidden - The request was understood but refused."
        "sip:404"                                              = "Not Found - The requested resource could not be found."
        "sip:408"                                              = "Request Timeout - The server timed out waiting for the request."
        "sip:410"                                              = "Gone - The resource is no longer available (often indicates transfer completion)."
        "sip:480"                                              = "Temporarily Unavailable - The callee is currently unavailable."
        "sip:486"                                              = "Busy Here - The callee is busy."
        "sip:487"                                              = "Request Terminated - The request was terminated by a BYE or CANCEL."
        "sip:500"                                              = "Server Internal Error - An internal server error occurred."
        "sip:502"                                              = "Bad Gateway - The gateway received an invalid response."
        "sip:503"                                              = "Service Unavailable - The service is temporarily unavailable."
        "sip:504"                                              = "Gateway Timeout - The gateway timed out."
        "network.packetloss"                                   = "Network packet loss detected, causing audio quality degradation."
        "network.jitter"                                       = "Network jitter detected, causing inconsistent audio delivery."
    }

    if ($explanations.ContainsKey($ErrorCode)) {
        return $explanations[$ErrorCode]
    }

    # Try partial match for error codes
    foreach ($key in $explanations.Keys) {
        if ($ErrorCode -like "*$key*") {
            return $explanations[$key]
        }
    }

    return "Unknown error condition. Review system logs for details."
}

<#
.SYNOPSIS
    Formats the key insights section for the report.
.DESCRIPTION
    Creates a formatted text block with categorized insights
    that appears at the top of the report for quick review.
#>
function Format-GCKeyInsightsText {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Insights
    )

    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("*" * 60)
    [void]$sb.AppendLine("KEY INSIGHTS")
    [void]$sb.AppendLine("*" * 60)
    [void]$sb.AppendLine("")

    foreach ($insight in $Insights) {
        $icon = switch ($insight.Category) {
            "CRITICAL" { "[!!!]" }
            "WARNING" { "[!]  " }
            "INFO" { "[i]  " }
            "OK" { "[OK] " }
            "OVERALL" { "[*]  " }
            default { "     " }
        }
        [void]$sb.AppendLine("$icon $($insight.Message)")
    }

    [void]$sb.AppendLine("")

    return $sb.ToString()
}

<#
.SYNOPSIS
    Formats the duration analysis section for the report.
.DESCRIPTION
    Creates a formatted text block showing timing breakdown
    with easy-to-read duration values.
#>
function Format-GCDurationAnalysisText {
    param (
        [Parameter(Mandatory = $true)]
        $Analysis
    )

    $sb = [System.Text.StringBuilder]::new()

    # Helper function to format seconds as human-readable duration
    function Format-Duration {
        param ([double]$Seconds)
        if ($Seconds -lt 60) {
            return "$([Math]::Round($Seconds, 0))s"
        }
        elseif ($Seconds -lt 3600) {
            $mins = [Math]::Floor($Seconds / 60)
            $secs = [Math]::Round($Seconds % 60, 0)
            return "${mins}m ${secs}s"
        }
        else {
            $hours = [Math]::Floor($Seconds / 3600)
            $mins = [Math]::Floor(($Seconds % 3600) / 60)
            return "${hours}h ${mins}m"
        }
    }

    [void]$sb.AppendLine("-" * 40)
    [void]$sb.AppendLine("DURATION ANALYSIS")
    [void]$sb.AppendLine("-" * 40)
    [void]$sb.AppendLine("")

    if ($Analysis.ConversationStart -and $Analysis.ConversationEnd) {
        [void]$sb.AppendLine("Start: $($Analysis.ConversationStart.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC")
        [void]$sb.AppendLine("End:   $($Analysis.ConversationEnd.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC")
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("Timing Breakdown:")
    [void]$sb.AppendLine("  Total Duration:   $(Format-Duration $Analysis.TotalDurationSeconds)")

    if ($Analysis.IvrTimeSeconds -gt 0) {
        [void]$sb.AppendLine("  IVR Time:         $(Format-Duration $Analysis.IvrTimeSeconds)")
    }
    if ($Analysis.QueueWaitSeconds -gt 0) {
        [void]$sb.AppendLine("  Queue Wait:       $(Format-Duration $Analysis.QueueWaitSeconds)")
    }
    if ($Analysis.AlertTimeSeconds -gt 0) {
        [void]$sb.AppendLine("  Alert/Ring Time:  $(Format-Duration $Analysis.AlertTimeSeconds)")
    }
    if ($Analysis.InteractTimeSeconds -gt 0) {
        [void]$sb.AppendLine("  Interaction Time: $(Format-Duration $Analysis.InteractTimeSeconds)")
    }
    if ($Analysis.AgentTalkSeconds -gt 0) {
        [void]$sb.AppendLine("  Agent Talk Time:  $(Format-Duration $Analysis.AgentTalkSeconds)")
    }
    if ($Analysis.HoldTimeSeconds -gt 0) {
        [void]$sb.AppendLine("  Hold Time:        $(Format-Duration $Analysis.HoldTimeSeconds)")
    }
    if ($Analysis.ConferenceSeconds -gt 0) {
        [void]$sb.AppendLine("  Conference Time:  $(Format-Duration $Analysis.ConferenceSeconds)")
    }
    if ($Analysis.WrapUpSeconds -gt 0) {
        [void]$sb.AppendLine("  Wrap-up Time:     $(Format-Duration $Analysis.WrapUpSeconds)")
    }
    if ($Analysis.SystemTimeSeconds -gt 0) {
        [void]$sb.AppendLine("  System Time:      $(Format-Duration $Analysis.SystemTimeSeconds)")
    }

    # Segment type breakdown if available
    if ($Analysis.SegmentBreakdown.Count -gt 0) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Segment Type Distribution:")
        foreach ($segType in $Analysis.SegmentBreakdown.Keys | Sort-Object) {
            $duration = $Analysis.SegmentBreakdown[$segType]
            $pct = if ($Analysis.TotalDurationSeconds -gt 0) { [Math]::Round(($duration / $Analysis.TotalDurationSeconds) * 100, 1) } else { 0 }
            [void]$sb.AppendLine("  $($segType.PadRight(15)): $(Format-Duration $duration) ($pct%)")
        }
    }

    [void]$sb.AppendLine("")

    return $sb.ToString()
}

<#
.SYNOPSIS
    Formats the participant statistics section for the report.
.DESCRIPTION
    Creates a formatted text block with per-participant details
    including timing, quality metrics, and flow information.
#>
function Format-GCParticipantStatisticsText {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Stats
    )

    $sb = [System.Text.StringBuilder]::new()

    # Helper function to format seconds as human-readable duration
    function Format-Duration {
        param ([double]$Seconds)
        if ($Seconds -lt 60) {
            return "$([Math]::Round($Seconds, 0))s"
        }
        elseif ($Seconds -lt 3600) {
            $mins = [Math]::Floor($Seconds / 60)
            $secs = [Math]::Round($Seconds % 60, 0)
            return "${mins}m ${secs}s"
        }
        else {
            $hours = [Math]::Floor($Seconds / 3600)
            $mins = [Math]::Floor(($Seconds % 3600) / 60)
            return "${hours}h ${mins}m"
        }
    }

    [void]$sb.AppendLine("-" * 40)
    [void]$sb.AppendLine("PARTICIPANT STATISTICS")
    [void]$sb.AppendLine("-" * 40)
    [void]$sb.AppendLine("")

    foreach ($stat in $Stats) {
        $roleIcon = switch ($stat.Purpose) {
            "customer" { "[C]" }
            "external" { "[E]" }
            "agent" { "[A]" }
            "acd" { "[Q]" }
            "ivr" { "[I]" }
            "voicemail" { "[V]" }
            default { "[?]" }
        }

        [void]$sb.AppendLine("$roleIcon $($stat.Name)")
        [void]$sb.AppendLine("    Role: $($stat.Purpose)")
        [void]$sb.AppendLine("    Duration: $(Format-Duration $stat.TotalDurationSeconds)")
        [void]$sb.AppendLine("    Sessions: $($stat.SessionCount) | Segments: $($stat.SegmentCount)")

        if ($stat.MediaTypes.Count -gt 0) {
            [void]$sb.AppendLine("    Media: $($stat.MediaTypes -join ', ')")
        }

        # Display ANI/DNIS for customer/external participants
        if ($stat.ANI -or $stat.DNIS) {
            $contactInfo = @()
            if ($stat.ANI) { $contactInfo += "ANI: $($stat.ANI)" }
            if ($stat.DNIS) { $contactInfo += "DNIS: $($stat.DNIS)" }
            [void]$sb.AppendLine("    Contact: $($contactInfo -join ' | ')")
        }

        # Display remote party name if available
        if ($stat.RemoteName) {
            [void]$sb.AppendLine("    Remote: $($stat.RemoteName)")
        }

        if ($stat.FlowNames.Count -gt 0) {
            [void]$sb.AppendLine("    Flows: $($stat.FlowNames -join ', ')")
        }

        # Display provider info
        if ($stat.Providers.Count -gt 0) {
            [void]$sb.AppendLine("    Provider: $($stat.Providers -join ', ')")
        }

        if ($stat.MosScores.Count -gt 0) {
            $avgMos = ($stat.MosScores | Measure-Object -Average).Average
            $minMos = ($stat.MosScores | Measure-Object -Minimum).Minimum
            [void]$sb.AppendLine("    MOS: avg=$([Math]::Round($avgMos, 2)) min=$([Math]::Round($minMos, 2))")
        }

        # Display recording indicator
        if ($stat.HasRecording) {
            [void]$sb.AppendLine("    Recording: Yes")
        }

        if ($stat.DisconnectType) {
            [void]$sb.AppendLine("    Disconnect: $($stat.DisconnectType)")
        }

        if ($stat.HasErrors) {
            [void]$sb.AppendLine("    Errors: $($stat.ErrorCodes -join ', ')")
        }

        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("Legend: [C]=Customer [E]=External [A]=Agent [Q]=Queue/ACD [I]=IVR [V]=Voicemail")
    [void]$sb.AppendLine("")

    return $sb.ToString()
}

<#
.SYNOPSIS
    Formats the conversation flow path for the report.
.DESCRIPTION
    Creates a visual ASCII representation of the call flow
    showing the path through IVR, queues, and agents.
#>
function Format-GCConversationFlowText {
    param (
        [Parameter(Mandatory = $true)]
        [array]$FlowPath
    )

    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("-" * 40)
    [void]$sb.AppendLine("CONVERSATION FLOW PATH")
    [void]$sb.AppendLine("-" * 40)
    [void]$sb.AppendLine("")

    if ($FlowPath.Count -eq 0) {
        [void]$sb.AppendLine("No flow path data available.")
        [void]$sb.AppendLine("")
        return $sb.ToString()
    }

    $lastPurpose = ""
    foreach ($step in $FlowPath) {
        $roleIcon = switch ($step.Purpose) {
            "customer" { "[CUSTOMER]" }
            "external" { "[EXTERNAL]" }
            "agent" { "[AGENT]   " }
            "acd" { "[QUEUE]   " }
            "ivr" { "[IVR]     " }
            "voicemail" { "[VM]      " }
            default { "[OTHER]   " }
        }

        $connector = if ($lastPurpose) { "     |" } else { "" }
        if ($connector) {
            [void]$sb.AppendLine($connector)
            [void]$sb.AppendLine("     v")
        }

        [void]$sb.AppendLine("$($step.Order). $roleIcon $($step.Name)")

        if ($step.FlowName) {
            [void]$sb.AppendLine("              Flow: $($step.FlowName)")
        }

        if ($step.TransferTo) {
            [void]$sb.AppendLine("              -> Transfer to: $($step.TransferTo) ($($step.TransferType))")
        }

        $lastPurpose = $step.Purpose
    }

    [void]$sb.AppendLine("")

    return $sb.ToString()
}

function Format-ConversationReportText {
    param (
        [Parameter(Mandatory = $true)]
        $Report
    )

    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("=" * 60)
    [void]$sb.AppendLine("CONVERSATION REPORT")
    [void]$sb.AppendLine("=" * 60)
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Conversation ID: $($Report.ConversationId)")
    [void]$sb.AppendLine("Retrieved At: $($Report.RetrievedAt)")
    [void]$sb.AppendLine("")

    if ($Report.Errors -and $Report.Errors.Count -gt 0) {
        [void]$sb.AppendLine("-" * 40)
        [void]$sb.AppendLine("ERRORS")
        [void]$sb.AppendLine("-" * 40)
        foreach ($err in $Report.Errors) {
            [void]$sb.AppendLine("  - $err")
        }
        [void]$sb.AppendLine("")
    }

    # Generate insight data early so we can display key insights at the top
    $events = $null
    $sortedEvents = $null
    $durationAnalysis = $null
    $participantStats = $null
    $summary = $null
    $keyInsights = $null
    $flowPath = $null
    $analysisError = $null

    try {
        # Extract events from both API responses
        $events = Get-GCConversationDetailsTimeline -Report $Report

        if ($events -and $events.Count -gt 0) {
            # Merge and sort events chronologically
            $sortedEvents = Merge-GCConversationEvents -Events $events

            # Generate analysis data
            $durationAnalysis = Get-GCConversationDurationAnalysis -Report $Report -Events $sortedEvents
            $participantStats = Get-GCParticipantStatistics -Report $Report
            $summary = Get-GCConversationSummary -ConversationId $Report.ConversationId -Events $sortedEvents
            $flowPath = Get-GCConversationFlowPath -Report $Report

            # Generate key insights (requires all other analyses)
            $keyInsights = Get-GCConversationKeyInsights -Report $Report -DurationAnalysis $durationAnalysis -ParticipantStats $participantStats -Summary $summary
        }
    }
    catch {
        # Store error but continue with report using available data
        $analysisError = $_.Exception.Message
    }

    # Display analysis error if one occurred
    if ($analysisError) {
        [void]$sb.AppendLine("-" * 40)
        [void]$sb.AppendLine("ANALYSIS NOTE")
        [void]$sb.AppendLine("-" * 40)
        [void]$sb.AppendLine("Some analysis sections may be incomplete due to: $analysisError")
        [void]$sb.AppendLine("")
    }

    # Display Key Insights at the top (most valuable information first)
    if ($keyInsights -and $keyInsights.Count -gt 0) {
        $insightsText = Format-GCKeyInsightsText -Insights $keyInsights
        [void]$sb.Append($insightsText)
    }

    # Display Duration Analysis
    if ($durationAnalysis) {
        $durationText = Format-GCDurationAnalysisText -Analysis $durationAnalysis
        [void]$sb.Append($durationText)
    }

    # Display Conversation Flow Path
    if ($flowPath -and $flowPath.Count -gt 0) {
        $flowText = Format-GCConversationFlowText -FlowPath $flowPath
        [void]$sb.Append($flowText)
    }

    # Display Participant Statistics
    if ($participantStats -and $participantStats.Count -gt 0) {
        $participantText = Format-GCParticipantStatisticsText -Stats $participantStats
        [void]$sb.Append($participantText)
    }

    # Conversation Details Section
    if ($Report.ConversationDetails) {
        $conv = $Report.ConversationDetails
        [void]$sb.AppendLine("-" * 40)
        [void]$sb.AppendLine("CONVERSATION DETAILS")
        [void]$sb.AppendLine("-" * 40)

        if ($conv.startTime) {
            [void]$sb.AppendLine("Start Time: $($conv.startTime)")
        }
        if ($conv.endTime) {
            [void]$sb.AppendLine("End Time: $($conv.endTime)")
        }
        if ($conv.conversationStart) {
            [void]$sb.AppendLine("Conversation Start: $($conv.conversationStart)")
        }
        if ($conv.conversationEnd) {
            [void]$sb.AppendLine("Conversation End: $($conv.conversationEnd)")
        }
        if ($conv.state) {
            [void]$sb.AppendLine("State: $($conv.state)")
        }
        if ($conv.externalTag) {
            [void]$sb.AppendLine("External Tag: $($conv.externalTag)")
        }
        if ($conv.utilizationLabelId) {
            [void]$sb.AppendLine("Utilization Label ID: $($conv.utilizationLabelId)")
        }

        # Participants
        if ($conv.participants -and $conv.participants.Count -gt 0) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("Participants ($($conv.participants.Count)):")
            foreach ($participant in $conv.participants) {
                [void]$sb.AppendLine("  - Purpose: $($participant.purpose)")
                if ($participant.userId) {
                    [void]$sb.AppendLine("    User ID: $($participant.userId)")
                }
                if ($participant.name) {
                    [void]$sb.AppendLine("    Name: $($participant.name)")
                }
                if ($participant.queueId) {
                    [void]$sb.AppendLine("    Queue ID: $($participant.queueId)")
                }
                if ($participant.address) {
                    [void]$sb.AppendLine("    Address: $($participant.address)")
                }
                if ($participant.startTime) {
                    [void]$sb.AppendLine("    Start Time: $($participant.startTime)")
                }
                if ($participant.endTime) {
                    [void]$sb.AppendLine("    End Time: $($participant.endTime)")
                }
                if ($null -ne $participant.wrapupRequired) {
                    [void]$sb.AppendLine("    Wrapup Required: $($participant.wrapupRequired)")
                }
            }
        }
        [void]$sb.AppendLine("")
    }
    else {
        [void]$sb.AppendLine("-" * 40)
        [void]$sb.AppendLine("CONVERSATION DETAILS: Not available")
        [void]$sb.AppendLine("-" * 40)
        [void]$sb.AppendLine("")
    }

    # Analytics Details Section
    if ($Report.AnalyticsDetails) {
        $analytics = $Report.AnalyticsDetails
        [void]$sb.AppendLine("-" * 40)
        [void]$sb.AppendLine("ANALYTICS DETAILS")
        [void]$sb.AppendLine("-" * 40)

        if ($analytics.conversationStart) {
            [void]$sb.AppendLine("Conversation Start: $($analytics.conversationStart)")
        }
        if ($analytics.conversationEnd) {
            [void]$sb.AppendLine("Conversation End: $($analytics.conversationEnd)")
        }
        if ($analytics.originatingDirection) {
            [void]$sb.AppendLine("Originating Direction: $($analytics.originatingDirection)")
        }
        if ($analytics.divisionIds -and $analytics.divisionIds.Count -gt 0) {
            [void]$sb.AppendLine("Division IDs: $($analytics.divisionIds -join ', ')")
        }
        if ($analytics.mediaStatsMinConversationMos) {
            [void]$sb.AppendLine("Min MOS: $($analytics.mediaStatsMinConversationMos)")
        }
        if ($analytics.mediaStatsMinConversationRFactor) {
            [void]$sb.AppendLine("Min R-Factor: $($analytics.mediaStatsMinConversationRFactor)")
        }

        # Participant Sessions
        if ($analytics.participants -and $analytics.participants.Count -gt 0) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("Analytics Participants ($($analytics.participants.Count)):")
            foreach ($participant in $analytics.participants) {
                [void]$sb.AppendLine("  - Participant ID: $($participant.participantId)")
                if ($participant.participantName) {
                    [void]$sb.AppendLine("    Name: $($participant.participantName)")
                }
                if ($participant.purpose) {
                    [void]$sb.AppendLine("    Purpose: $($participant.purpose)")
                }
                if ($participant.sessions -and $participant.sessions.Count -gt 0) {
                    [void]$sb.AppendLine("    Sessions: $($participant.sessions.Count)")
                    foreach ($session in $participant.sessions) {
                        if ($session.mediaType) {
                            [void]$sb.AppendLine("      Media Type: $($session.mediaType)")
                        }
                        if ($session.direction) {
                            [void]$sb.AppendLine("      Direction: $($session.direction)")
                        }
                        if ($session.ani) {
                            [void]$sb.AppendLine("      ANI: $($session.ani)")
                        }
                        if ($session.dnis) {
                            [void]$sb.AppendLine("      DNIS: $($session.dnis)")
                        }
                    }
                }
            }
        }
        [void]$sb.AppendLine("")
    }
    else {
        [void]$sb.AppendLine("-" * 40)
        [void]$sb.AppendLine("ANALYTICS DETAILS: Not available")
        [void]$sb.AppendLine("-" * 40)
        [void]$sb.AppendLine("")
    }

    # Generate chronological timeline by extracting events from both endpoints
    # and interlacing them in time order
    [void]$sb.AppendLine("-" * 40)
    [void]$sb.AppendLine("CHRONOLOGICAL TIMELINE")
    [void]$sb.AppendLine("-" * 40)
    [void]$sb.AppendLine("")

    # Use previously computed events if available
    if ($sortedEvents -and $sortedEvents.Count -gt 0) {
        # Format timeline text
        $timelineText = Format-GCConversationTimelineText -Events $sortedEvents
        [void]$sb.AppendLine($timelineText)

        # Generate and append summary (use pre-computed if available)
        if ($summary) {
            $summaryText = Format-GCConversationSummaryText -Summary $summary
            [void]$sb.AppendLine($summaryText)
        }
    }
    else {
        [void]$sb.AppendLine("No timeline events could be extracted from the available data.")
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("=" * 60)
    [void]$sb.AppendLine("END OF REPORT")
    [void]$sb.AppendLine("=" * 60)

    return $sb.ToString()
}

$ApiBaseUrl = "https://api.$($script:Region)"
$JobTracker = [PSCustomObject]@{
    Timer      = $null
    JobId      = $null
    Path       = $null
    Headers    = @{}
    Status     = ""
    ResultFile = ""
    LastUpdate = ""
}
$script:LastResponseFile = ""

function Stop-JobPolling {
    if ($JobTracker.Timer) {
        $JobTracker.Timer.Stop()
        $JobTracker.Timer = $null
    }
}

function Update-JobPanel {
    param (
        [string]$JobId,
        [string]$Status,
        [string]$Updated
    )

    if ($jobIdText) {
        $jobIdText.Text = if ($JobTracker.JobId) { $JobTracker.JobId } else { "No active job" }
    }

    if ($jobStatusText) {
        $jobStatusText.Text = if ($Status) { "Status: $Status" } else { "Status: (none)" }
    }

    if ($jobUpdatedText) {
        $jobUpdatedText.Text = if ($Updated) { "Last checked: $Updated" } else { "Last checked: --" }
    }

    if ($jobResultsPath) {
        $jobResultsPath.Text = if ($JobTracker.ResultFile) { "Results file: $($JobTracker.ResultFile)" } else { "Results file: (not available yet)" }
    }

    if ($fetchJobResultsButton) {
        $fetchJobResultsButton.IsEnabled = [bool]$JobTracker.JobId
    }

    if ($exportJobResultsButton) {
        $exportJobResultsButton.IsEnabled = (($JobTracker.ResultFile) -and (Test-Path $JobTracker.ResultFile))
    }
}

function Start-JobPolling {
    param (
        [string]$Path,
        [string]$JobId,
        [hashtable]$Headers
    )

    if (-not $Path -or -not $JobId) {
        return
    }

    Stop-JobPolling
    $JobTracker.Path = $Path.TrimEnd('/')
    $JobTracker.JobId = $JobId
    $JobTracker.Headers = $Headers
    $JobTracker.Status = "Pending"
    $JobTracker.ResultFile = ""
    Update-JobPanel -Status $JobTracker.Status -Updated (Get-Date).ToString("HH:mm:ss")

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [System.TimeSpan]::FromSeconds(6)
    $timer.Add_Tick({
            Get-JobStatus
        })
    $JobTracker.Timer = $timer
    $timer.Start()
    Get-JobStatus
}

function Get-JobStatus {
    if (-not $JobTracker.JobId -or -not $JobTracker.Path) {
        return
    }

    $statusUrl = "$ApiBaseUrl$($JobTracker.Path)/$($JobTracker.JobId)"
    try {
        $statusResponse = Invoke-GCRequest -Method GET -Uri $statusUrl -Headers $JobTracker.Headers -AsResponse
        $statusJson = $statusResponse.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        $statusValue = if ($statusJson.status) { $statusJson.status } elseif ($statusJson.state) { $statusJson.state } else { $null }
        $JobTracker.Status = $statusValue
        $JobTracker.LastUpdate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Update-JobPanel -Status $statusValue -Updated $JobTracker.LastUpdate
        Add-LogEntry "Job $($JobTracker.JobId) status checked: $statusValue"

        if (-not (Job-StatusIsPending -Status $statusValue)) {
            Stop-JobPolling
            Fetch-JobResults
        }
    }
    catch {
        Add-LogEntry "Job status poll failed: $($_.Exception.Message)"
    }
}

function Fetch-JobResults {
    param ([switch]$Force)

    if (-not $JobTracker.JobId -or -not $JobTracker.Path) {
        return
    }

    $resultsPath = "$($JobTracker.Path)/$($JobTracker.JobId)/results"
    $tempFile = Join-Path -Path $env:TEMP -ChildPath "GenesysJobResults_$([guid]::NewGuid()).json"
    $errorMessage = $null

    try {
        # Update status to show we're fetching
        $statusText.Text = "Fetching job results (may be paginated)..."
        Add-LogEntry "Fetching job results from $resultsPath"

        # Define progress callback for pagination
        $paginationCallback = {
            param($PageNumber, $Status, $IsError, $IsComplete)

            if ($IsError) {
                $statusText.Text = "Error: $Status"
            }
            elseif ($IsComplete) {
                $statusText.Text = $Status
            }
            else {
                $statusText.Text = "Fetching results - $Status"
            }
            Add-LogEntry $Status
            [System.Windows.Forms.Application]::DoEvents()
        }

        # Use pagination helper to fetch all results
        $allResults = Get-PaginatedResults `
            -BaseUrl $ApiBaseUrl `
            -InitialPath $resultsPath `
            -Headers $JobTracker.Headers `
            -Method "GET" `
            -ProgressCallback $paginationCallback

        # Save all results to temp file
        $allResults | ConvertTo-Json -Depth 20 | Set-Content -Path $tempFile -Encoding UTF8

        $JobTracker.ResultFile = $tempFile
        if ($jobResultsPath) {
            $jobResultsPath.Text = "Results file: $tempFile"
        }
        $snippet = Get-Content -Path $tempFile -TotalCount 200 | Out-String
        $script:LastResponseText = "Job results saved to temp file (Total: $($allResults.Count) items).`r`n$tempFile`r`n`r`n${snippet}"
        $script:LastResponseRaw = $snippet.Trim()
        $script:LastResponseFile = $tempFile
        $responseBox.Text = "Job $($JobTracker.JobId) completed; $($allResults.Count) results saved to temp file."
        Add-LogEntry "Job results downloaded: $($allResults.Count) total items saved to $tempFile"
        Update-JobPanel -Status $JobTracker.Status -Updated (Get-Date).ToString("HH:mm:ss")
    }
    catch {
        $errorMessage = $_.Exception.Message
        Add-LogEntry "Fetching job results failed: $errorMessage"
        $responseBox.Text = "Failed to download job results: $errorMessage"
        $statusText.Text = "Job results fetch failed"
    }
}

function Get-FavoritesFromDisk {
    param ([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        return @()
    }

    try {
        $content = Get-Content -Path $Path -Raw
        if (-not $content) {
            return @()
        }

        return $content | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "Unable to load favorites: $($_.Exception.Message)"
        return @()
    }
}

function Save-FavoritesToDisk {
    param (
        [string]$Path,
        [Parameter(Mandatory)][System.Collections.IEnumerable]$Favorites
    )

    try {
        $Favorites | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding utf8
    }
    catch {
        Write-Warning "Unable to save favorites: $($_.Exception.Message)"
    }
}

function Build-FavoritesCollection {
    param ($Source)

    $list = [System.Collections.ArrayList]::new()
    if (-not $Source) {
        return $list
    }

    $isEnumerable = ($Source -is [System.Collections.IEnumerable]) -and -not ($Source -is [string])
    if ($isEnumerable) {
        foreach ($item in $Source) {
            $list.Add($item) | Out-Null
        }
    }
    else {
        $list.Add($Source) | Out-Null
    }

    return $list
}

function Load-TemplatesFromDisk {
    param ([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        return @()
    }

    try {
        $content = Get-Content -Path $Path -Raw
        if (-not $content) {
            return @()
        }

        return $content | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "Unable to load templates: $($_.Exception.Message)"
        return @()
    }
}

function Save-TemplatesToDisk {
    param (
        [string]$Path,
        [Parameter(Mandatory)][System.Collections.IEnumerable]$Templates
    )

    try {
        $normalized = @($Templates | Where-Object { $_ } | ForEach-Object { $_ })
        $normalized | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding utf8
    }
    catch {
        Write-Warning "Unable to save templates: $($_.Exception.Message)"
    }
}

$script:BlockedTemplateMethods = @('DELETE', 'PATCH', 'PUT')

function Test-TemplateMethodAllowed {
    param([string]$Method)

    if ([string]::IsNullOrWhiteSpace($Method)) { return $true }
    return (-not ($script:BlockedTemplateMethods -contains $Method.Trim().ToUpperInvariant()))
}

function Normalize-TemplateObject {
    param(
        [Parameter(Mandatory)]
        $Template,
        [string]$DefaultLastModified
    )

    if (-not $Template) { return $null }

    $method = ''
    try { $method = [string]$Template.Method } catch { $method = '' }
    if (-not (Test-TemplateMethodAllowed -Method $method)) { return $null }

    $created = ''
    $lastModified = ''
    try { $created = [string]$Template.Created } catch { $created = '' }
    try { $lastModified = [string]$Template.LastModified } catch { $lastModified = '' }

    if ([string]::IsNullOrWhiteSpace($created)) {
        $created = if ($DefaultLastModified) { $DefaultLastModified } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    }
    if ([string]::IsNullOrWhiteSpace($lastModified)) {
        $lastModified = $created
    }

    $templateOut = [pscustomobject]@{
        Name         = [string]$Template.Name
        Method       = [string]$Template.Method
        Path         = [string]$Template.Path
        Group        = [string]$Template.Group
        Parameters   = $Template.Parameters
        Created      = $created
        LastModified = $lastModified
    }

    return $templateOut
}

function Normalize-Templates {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IEnumerable]$Templates,
        [string]$DefaultLastModified
    )

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($Templates)) {
        $norm = Normalize-TemplateObject -Template $t -DefaultLastModified $DefaultLastModified
        if ($norm) { $out.Add($norm) | Out-Null }
    }
    # Avoid PowerShell host differences when expanding generic lists.
    return $out.ToArray()
}

function Enable-GridViewColumnSorting {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Controls.ListView]$ListView,
        [hashtable]$State
    )

    if (-not $State) { $State = @{} }
    if (-not $State.ContainsKey('Property')) { $State['Property'] = $null }
    if (-not $State.ContainsKey('Direction')) { $State['Direction'] = [System.ComponentModel.ListSortDirection]::Ascending }

    $ListView.Resources['ColumnSortState'] = $State

    $ListView.AddHandler(
        [System.Windows.Controls.GridViewColumnHeader]::ClickEvent,
        [System.Windows.RoutedEventHandler] {
            param($sender, $e)

            $header = $e.OriginalSource
            if (-not ($header -is [System.Windows.Controls.GridViewColumnHeader])) { return }
            if (-not $header.Tag) { return }

            $sortBy = [string]$header.Tag
            if ([string]::IsNullOrWhiteSpace($sortBy)) { return }

            $State = $null
            try { $State = $sender.Resources['ColumnSortState'] } catch { }
            if (-not ($State -is [hashtable])) {
                $State = @{}
                $State['Property'] = $null
                $State['Direction'] = [System.ComponentModel.ListSortDirection]::Ascending
                try { $sender.Resources['ColumnSortState'] = $State } catch { }
            }

            $direction = [System.ComponentModel.ListSortDirection]::Ascending
            if ($State['Property'] -eq $sortBy) {
                $direction = if ($State['Direction'] -eq [System.ComponentModel.ListSortDirection]::Ascending) {
                    [System.ComponentModel.ListSortDirection]::Descending
                }
                else {
                    [System.ComponentModel.ListSortDirection]::Ascending
                }
            }

            $State['Property'] = $sortBy
            $State['Direction'] = $direction

            $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($sender.ItemsSource)
            if (-not $view) { return }

            $view.SortDescriptions.Clear()
            $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription($sortBy, $direction)))
            $view.Refresh()
        }
    )
}

$script:LastResponseText = ""
$script:LastResponseRaw = ""
$paramInputs = @{}
$pendingFavoriteParameters = $null
$script:FilterBuilderData = @{
    ConversationFilters = New-Object System.Collections.ArrayList
    SegmentFilters      = New-Object System.Collections.ArrayList
    Interval            = "2025-12-01T00:00:00.000Z/2025-12-07T23:59:59.999Z"
}
$script:FilterBuilderEnums = @{
    Conversation = @{
        Dimensions = @()
        Metrics    = @()
    }
    Segment      = @{
        Dimensions = @()
        Metrics    = @()
    }
    Operators    = @("matches", "exists", "notExists")
}

function Join-FromScriptRoot {
    param (
        [int]$Levels,
        [string]$Child
    )

    $base = $ScriptRoot
    for ($i = 1; $i -le $Levels; $i++) {
        $base = Split-Path -Parent $base
    }

    return Join-Path -Path $base -ChildPath $Child
}

function Resolve-WorkspaceRoot {
    param(
        [string[]]$StartDirectories
    )

    Write-TraceLog "Resolve-WorkspaceRoot: startDirs=$(@($StartDirectories) -join ' | ')"
    foreach ($start in @($StartDirectories)) {
        if ([string]::IsNullOrWhiteSpace($start)) { continue }
        try {
            $item = Get-Item -LiteralPath $start -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            $current = if ($item.PSIsContainer) { $item.FullName } else { Split-Path -Parent $item.FullName }
            for ($i = 0; $i -lt 10; $i++) {
                $packs = Join-Path -Path (Join-Path -Path $current -ChildPath 'insights') -ChildPath 'packs'
                $legacyPacks = Join-Path -Path $current -ChildPath 'insightpacks'
                if (Test-Path -LiteralPath $packs) { return $current }
                if (Test-Path -LiteralPath $legacyPacks) { return $current }

                $parent = Split-Path -Parent $current
                if (-not $parent -or ($parent -eq $current)) { break }
                $current = $parent
            }
        }
        catch { }
    }

    return $null
}

$candidateRoots = @(
    $env:GENESYS_API_EXPLORER_ROOT,
    $ScriptRoot,
    (Get-Location).Path,
    $PSCommandPath,
    $MyInvocation.MyCommand.Path,
    [AppDomain]::CurrentDomain.BaseDirectory
)

$workspaceRoot = Resolve-WorkspaceRoot -StartDirectories $candidateRoots
if (-not $workspaceRoot) {
    # Fallback to the original assumption (script lives under apps/OpsConsole/Resources)
    $workspaceRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptRoot))
}

# Allow overriding pack discovery when running from an installed module/EXE.
# - `GENESYS_API_EXPLORER_PACKS_DIR` may point directly to the packs folder, or to the repo root.
$insightPackRoot = Join-Path -Path (Join-Path -Path $workspaceRoot -ChildPath 'insights') -ChildPath 'packs'
$packOverride = [string]$env:GENESYS_API_EXPLORER_PACKS_DIR
if (-not [string]::IsNullOrWhiteSpace($packOverride)) {
    try {
        if (Test-Path -LiteralPath $packOverride) {
            $overrideItem = Get-Item -LiteralPath $packOverride -ErrorAction SilentlyContinue
            if ($overrideItem -and $overrideItem.PSIsContainer) {
                $overrideDirect = Join-Path -Path (Join-Path -Path $overrideItem.FullName -ChildPath 'insights') -ChildPath 'packs'
                if (Test-Path -LiteralPath $overrideDirect) {
                    $insightPackRoot = $overrideDirect
                }
                else {
                    $insightPackRoot = $overrideItem.FullName
                }
            }
        }
    }
    catch { }
}
$legacyInsightPackRoot = Join-Path -Path $workspaceRoot -ChildPath 'insightpacks'
$insightBriefingRoot = Join-Path -Path (Join-Path -Path $workspaceRoot -ChildPath 'insights') -ChildPath 'briefings'
$legacyInsightBriefingRoot = Join-Path -Path $workspaceRoot -ChildPath 'InsightBriefings'
$script:OpsInsightsManifest = Join-Path -Path $workspaceRoot -ChildPath 'src/GenesysCloud.OpsInsights/GenesysCloud.OpsInsights.psd1'
$script:OpsInsightsModuleRoot = Split-Path -Parent $script:OpsInsightsManifest
$script:OpsInsightsCoreManifest = Join-Path -Path $script:OpsInsightsModuleRoot -ChildPath '..\GenesysCloud.OpsInsights.Core\GenesysCloud.OpsInsights.Core.psd1'

Write-TraceLog "Workspace/Pack roots: workspaceRoot='$workspaceRoot' scriptRoot='$ScriptRoot' insightPackRoot='$insightPackRoot' legacyInsightPackRoot='$legacyInsightPackRoot' override='$packOverride'"

function Load-OpsInsightsScripts {
    if ($script:OpsInsightsScriptsLoaded) { return }

    $directories = @(
        Join-Path -Path $script:OpsInsightsModuleRoot -ChildPath 'Private',
        Join-Path -Path $script:OpsInsightsModuleRoot -ChildPath 'Public'
    )

    foreach ($dir in $directories) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -Path $dir -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object {
            try {
                . $_.FullName
            }
            catch {
                Write-Warning "Failed to load OpsInsights script '$($_.FullName)': $($_.Exception.Message)"
            }
        }
    }

    $script:OpsInsightsScriptsLoaded = $true
}

function Ensure-OpsInsightsModuleLoaded {
    param(
        [switch]$Force
    )

    if (-not $script:OpsInsightsManifest) {
        throw "OpsInsights module manifest path is unavailable."
    }
    if (-not (Test-Path -LiteralPath $script:OpsInsightsManifest)) {
        throw "OpsInsights module manifest not found at '$script:OpsInsightsManifest'."
    }

    if ($Force -or (-not (Get-Module -Name 'GenesysCloud.OpsInsights'))) {
        Import-Module -Name $script:OpsInsightsManifest -Force -ErrorAction Stop
    }

    if ($Force -or (-not (Get-Module -Name 'GenesysCloud.OpsInsights.Core'))) {
        if ($script:OpsInsightsCoreManifest -and (Test-Path -LiteralPath $script:OpsInsightsCoreManifest)) {
            Import-Module -Name $script:OpsInsightsCoreManifest -Force -ErrorAction Stop
        }
        else {
            Write-Verbose "OpsInsights core manifest missing or unavailable at '$script:OpsInsightsCoreManifest'."
        }
    }

    if (-not (Get-Command -Name 'Invoke-GCInsightPack' -ErrorAction SilentlyContinue)) {
        Load-OpsInsightsScripts
    }
}

function Ensure-OpsInsightsContext {
    $token = Get-ExplorerAccessToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Please provide an OAuth token before running Insight Packs."
    }

    try {
        Set-GCContext -ApiBaseUri $ApiBaseUrl -AccessToken ($token.Trim()) | Out-Null
    }
    catch {
        # Fallback to global token for older module behaviors
        $global:AccessToken = $token.Trim()
    }
}

$UserProfileBase = if ($env:USERPROFILE) { $env:USERPROFILE } else { $ScriptRoot }
$FavoritesFile = Join-Path -Path $UserProfileBase -ChildPath "GenesysApiExplorerFavorites.json"

$JsonPath = Join-Path -Path $ScriptRoot -ChildPath "GenesysCloudAPIEndpoints.json"
if (-not (Test-Path -Path $JsonPath)) {
    Write-Error "Required endpoint catalog not found at '$JsonPath'."
    return
}

$script:CurrentJsonPath = $JsonPath
$ApiCatalog = Load-PathsFromJson -JsonPath $JsonPath
$script:ApiPaths = $ApiCatalog.Paths
$script:Definitions = if ($ApiCatalog.Definitions) { $ApiCatalog.Definitions } else { @{} }
Initialize-FilterBuilderEnum
$script:GroupMap = Build-GroupMap -Paths $script:ApiPaths
$FavoritesData = Get-FavoritesFromDisk -Path $FavoritesFile
$Favorites = Build-FavoritesCollection -Source $FavoritesData

# Load templates at startup
$TemplatesFilePath = Join-Path -Path $UserProfileBase -ChildPath "GenesysApiExplorerTemplates.json"
$TemplatesData = Load-TemplatesFromDisk -Path $TemplatesFilePath

# If no user templates exist, load default templates
if (-not $TemplatesData -or $TemplatesData.Count -eq 0) {
    $DefaultTemplatesPath = Join-Path -Path $ScriptRoot -ChildPath "DefaultTemplates.json"
    if (Test-Path -Path $DefaultTemplatesPath) {
        try {
            $TemplatesData = Load-TemplatesFromDisk -Path $DefaultTemplatesPath
            if ($TemplatesData -and $TemplatesData.Count -gt 0) {
                # Save default templates to user's template file
                Save-TemplatesToDisk -Path $TemplatesFilePath -Templates $TemplatesData
                Write-Host "Initialized with $($TemplatesData.Count) default conversation templates."
            }
        }
        catch {
            Write-Warning "Could not load default templates from '$DefaultTemplatesPath': $($_.Exception.Message)"
        }
    }
}

# Load example POST bodies for conversations endpoints
$ExamplePostBodiesPath = Join-Path -Path $ScriptRoot -ChildPath "ExamplePostBodies.json"
$script:ExamplePostBodies = @{}
if (Test-Path -Path $ExamplePostBodiesPath) {
    try {
        $script:ExamplePostBodies = Get-Content -Path $ExamplePostBodiesPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not load example POST bodies from '$ExamplePostBodiesPath': $($_.Exception.Message)"
    }
}

function Get-ExamplePostBody {
    param (
        [string]$Path,
        [string]$Method
    )

    if (-not $script:ExamplePostBodies) { return $null }

    $methodLower = $Method.ToLower()

    # Check if this path and method has an example
    $pathData = $script:ExamplePostBodies.PSObject.Properties | Where-Object { $_.Name -eq $Path }
    if ($pathData -and $pathData.Value.$methodLower -and $pathData.Value.$methodLower.example) {
        return ($pathData.Value.$methodLower.example | ConvertTo-Json -Depth 10)
    }

    return $null
}

$Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Genesys Cloud API Explorer" Height="860" Width="1000"
        MinHeight="600" MinWidth="800"
        WindowStartupLocation="CenterScreen">
  <DockPanel LastChildFill="True">
	    <Menu DockPanel.Dock="Top">
	      <MenuItem Header="_Settings">
	        <MenuItem Name="AppSettingsMenuItem" Header="App Settings..."/>
	        <Separator/>
	        <MenuItem Name="TraceMenuItem" Header="Enable Tracing" IsCheckable="True"
	                  ToolTip="Write verbose diagnostics to a temp log file (can include local file paths)."/>
	        <Separator/>
	        <MenuItem Name="SettingsMenuItem" Header="Endpoints Configuration"/>
	        <Separator/>
	        <MenuItem Name="ResetEndpointsMenuItem" Header="Reset to Default"/>
	      </MenuItem>
      <MenuItem Header="_Help">
        <MenuItem Name="HelpMenuItem" Header="Show Help"/>
        <Separator/>
        <MenuItem Name="HelpDevLink" Header="Developer Portal"/>
        <MenuItem Name="HelpSupportLink" Header="Genesys Support"/>
      </MenuItem>
    </Menu>
		    <Grid Margin="10">
		    <Grid.RowDefinitions>
		      <RowDefinition Height="Auto"/>
		      <RowDefinition Height="Auto"/>
		      <RowDefinition Height="Auto"/>
	      <RowDefinition Height="Auto"/>
	      <RowDefinition Height="Auto"/>
	      <RowDefinition Height="Auto"/>
	      <RowDefinition Height="Auto"/>
	      <RowDefinition Height="*"/>
	    </Grid.RowDefinitions>

	    <Grid Grid.Row="0" Margin="0 0 0 10">
	      <Grid.ColumnDefinitions>
	        <ColumnDefinition Width="*"/>
	        <ColumnDefinition Width="Auto"/>
	      </Grid.ColumnDefinitions>
	      <TextBlock Grid.Column="0" Text="Genesys Cloud API Explorer" FontSize="20" FontWeight="Bold" VerticalAlignment="Center"/>
	      <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
	        <TextBlock Name="RegionStatusText" VerticalAlignment="Center" Foreground="SlateGray" Margin="0 0 10 0" Text="Region: (unset)"/>
	        <TextBlock Name="OauthTypeText" VerticalAlignment="Center" Foreground="SlateGray" Margin="0 0 10 0" Text="OAuth: (none)"/>
	        <Button Name="LoginButton" Width="90" Height="28" Content="Login..." Margin="0 0 10 0" Background="#E0E0FF"/>
	        <Button Name="TestTokenButton" Width="95" Height="28" Content="Test Token" Margin="0 0 10 0" ToolTip="Verify token validity"/>
	        <TextBlock Name="TokenReadyIndicator" VerticalAlignment="Center" Foreground="Gray" FontSize="16" Margin="0 0 10 0" Text="●"/>
	        <TextBlock Name="TokenStatusText" VerticalAlignment="Center" Foreground="Gray" Text="No token"/>
	      </StackPanel>
	    </Grid>

		    <Grid Grid.Row="2" Name="RequestSelectorGrid" Margin="0 0 0 10">
	      <Grid.ColumnDefinitions>
	        <ColumnDefinition Width="*"/>
	        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <StackPanel Grid.Column="0">
        <TextBlock Text="Group" FontWeight="Bold"/>
        <ComboBox Name="GroupCombo" MinWidth="200"/>
      </StackPanel>

      <StackPanel Grid.Column="1">
        <TextBlock Text="Endpoint Path" FontWeight="Bold"/>
        <ComboBox Name="PathCombo" MinWidth="200"/>
      </StackPanel>

      <StackPanel Grid.Column="2">
        <TextBlock Text="HTTP Method" FontWeight="Bold"/>
        <ComboBox Name="MethodCombo" MinWidth="200"/>
      </StackPanel>
    </Grid>

    <Expander Grid.Row="3" Name="ParametersExpander" Header="Parameters" IsExpanded="True" Margin="0 0 0 10">
      <Border BorderBrush="LightGray" BorderThickness="1" Padding="10">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Name="ParameterPanel"/>
        </ScrollViewer>
      </Border>
    </Expander>

    <Expander Grid.Row="4" Name="FilterBuilderExpander" Header="{Binding RelativeSource={RelativeSource Self}, Path=Tag}" IsExpanded="True" Visibility="Collapsed" Margin="0 0 0 10">
      <Expander.Tag>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="Conversation Filter Builder" FontWeight="Bold"/>
          <TextBlock Name="FilterBuilderHintText" FontSize="11" Foreground="Gray" VerticalAlignment="Center" Margin="10 0 0 0" TextWrapping="Wrap"/>
        </StackPanel>
      </Expander.Tag>
      <Border Name="FilterBuilderBorder" BorderBrush="LightGray" BorderThickness="1" Padding="10">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="0 0 0 10">
            <TextBlock Text="Interval" VerticalAlignment="Center" Margin="0 0 8 0"/>
            <TextBox Name="FilterIntervalInput" Width="320" Height="26"/>
          </StackPanel>
          <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Left" Margin="0 0 0 12">
            <Button Name="RefreshFiltersButton" Content="Apply to Body" Width="150" Height="28" Margin="0 0 8 0"/>
            <Button Name="ResetFiltersButton" Content="Reset Filters" Width="130" Height="28"/>
          </StackPanel>
          <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="1*"/>
              <ColumnDefinition Width="1*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" BorderBrush="LightGray" BorderThickness="1" Padding="6" Margin="0 0 8 0" CornerRadius="4">
              <StackPanel>
                <TextBlock Text="Conversation Filters" FontWeight="Bold" Margin="0 0 0 6"/>
                <ListBox Name="ConversationFiltersList" Height="140"
                         VirtualizingStackPanel.IsVirtualizing="True"
                         VirtualizingStackPanel.VirtualizationMode="Recycling"
                         ScrollViewer.CanContentScroll="True"/>
                <StackPanel Orientation="Horizontal" Margin="0 6 0 0">
                  <ComboBox Name="ConversationFilterTypeCombo" Width="120" Margin="0 0 8 0"/>
                  <ComboBox Name="ConversationPredicateTypeCombo" Width="120"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0 4 0 0">
                  <ComboBox Name="ConversationFieldCombo" Width="180" Margin="0 0 8 0"/>
                  <ComboBox Name="ConversationOperatorCombo" Width="120" Margin="0 0 8 0"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0 4 0 0">
                  <TextBox Name="ConversationValueInput" Width="220" Margin="0 0 8 0" ToolTip="Enter a value or JSON range object (e.g. {'min':1,'max':5})."/>
                  <Button Name="AddConversationPredicateButton" Content="Add" Width="90" Margin="0 0 4 0"/>
                  <Button Name="RemoveConversationPredicateButton" Content="Remove" Width="90"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Grid.Column="1" BorderBrush="LightGray" BorderThickness="1" Padding="6" CornerRadius="4">
              <StackPanel>
                <TextBlock Text="Segment Filters" FontWeight="Bold" Margin="0 0 0 6"/>
                <ListBox Name="SegmentFiltersList" Height="140"
                         VirtualizingStackPanel.IsVirtualizing="True"
                         VirtualizingStackPanel.VirtualizationMode="Recycling"
                         ScrollViewer.CanContentScroll="True"/>
                <StackPanel Orientation="Horizontal" Margin="0 6 0 0">
                  <ComboBox Name="SegmentFilterTypeCombo" Width="120" Margin="0 0 8 0"/>
                  <ComboBox Name="SegmentPredicateTypeCombo" Width="120"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0 4 0 0">
                  <ComboBox Name="SegmentFieldCombo" Width="180" Margin="0 0 8 0"/>
                  <ComboBox Name="SegmentOperatorCombo" Width="120" Margin="0 0 8 0"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0 4 0 0">
                  <TextBox Name="SegmentPropertyInput" Width="120" Margin="0 0 8 0" ToolTip="Property name (for property type predicates)"/>
                  <ComboBox Name="SegmentPropertyTypeCombo" Width="120" Margin="0 0 8 0" ToolTip="Property type (for property type predicates)"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0 4 0 0">
                  <TextBox Name="SegmentValueInput" Width="220" Margin="0 0 8 0" ToolTip="Enter a value or JSON range object (e.g. {'min':1,'max':5})."/>
                  <Button Name="AddSegmentPredicateButton" Content="Add" Width="90" Margin="0 0 4 0"/>
                  <Button Name="RemoveSegmentPredicateButton" Content="Remove" Width="90"/>
                </StackPanel>
              </StackPanel>
            </Border>
          </Grid>
        </Grid>
      </Border>
    </Expander>

	    <Border Grid.Row="5" Name="FavoritesBorder" BorderBrush="LightGray" BorderThickness="1" Padding="10" Margin="0 0 0 10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="2*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Text="Favorites" FontWeight="Bold" Margin="0 0 0 6"/>
          <ListBox Name="FavoritesList" DisplayMemberPath="Name" Height="120"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Margin="10 0 0 0">
          <TextBlock Text="Favorite name" FontWeight="Bold" Margin="0 0 0 6"/>
          <TextBox Name="FavoriteNameInput" Width="220" Margin="0 0 0 6"
                   ToolTip="Give the favorite a friendly label for reference."/>
          <Button Name="SaveFavoriteButton" Width="120" Height="32" Content="Save Favorite"/>
        </StackPanel>
      </Grid>
    </Border>

		    <StackPanel Grid.Row="6" Name="ActionButtonsPanel" Orientation="Horizontal" VerticalAlignment="Center" Margin="0 0 0 10">
	      <Button Name="SubmitButton" Width="150" Height="34" Content="Submit API Call" Margin="0 0 10 0"/>
	      <Button Name="SaveButton" Width="150" Height="34" Content="Save Response" IsEnabled="False" Margin="0 0 10 0"/>
	      <Button Name="ExportPowerShellButton" Width="150" Height="34" Content="Export PowerShell" Margin="0 0 10 0" ToolTip="Generate PowerShell script for this request"/>
	      <ComboBox Name="PowerShellExportModeCombo" Width="240" Height="34" Margin="0 0 10 0" SelectedIndex="0"
	                ToolTip="Choose export style. Portable uses Invoke-WebRequest only. OpsInsights-native requires the module and uses Invoke-GCRequest. Auto prefers OpsInsights when available.">
	        <ComboBoxItem Content="Auto (prefer OpsInsights)"/>
	        <ComboBoxItem Content="Portable (Invoke-WebRequest)"/>
	        <ComboBoxItem Content="OpsInsights-native (Invoke-GCRequest)"/>
	      </ComboBox>
	      <Button Name="ExportCurlButton" Width="120" Height="34" Content="Export cURL" ToolTip="Generate cURL command for this request"/>
	      <TextBlock Name="ProgressIndicator" VerticalAlignment="Center" Foreground="Blue" Margin="10 0 5 0" Visibility="Collapsed">⏳</TextBlock>
	      <TextBlock Name="StatusText" VerticalAlignment="Center" Foreground="SlateGray" Margin="5 0 0 0"/>
	    </StackPanel>

	    <TabControl Grid.Row="7" Name="MainTabControl" VerticalAlignment="Stretch">
      <TabItem Header="Response">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0 0 0 6">
            <Button Name="ToggleResponseViewButton" Width="140" Height="30" Content="Toggle Raw/Formatted" Margin="0 0 10 0" IsEnabled="False"/>
            <Button Name="InspectResponseButton" Width="140" Height="30" Content="Inspect Result"/>
          </StackPanel>
          <TextBox Grid.Row="1" Name="ResponseText" TextWrapping="Wrap" AcceptsReturn="True"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" IsReadOnly="True"
                   VerticalAlignment="Stretch" MinHeight="250"/>
        </Grid>
      </TabItem>
      <TabItem Header="Transparency Log">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0 0 0 8">
            <Button Name="ExportLogButton" Width="120" Height="30" Content="Export Log" ToolTip="Export transparency log to a text file"/>
            <Button Name="ClearLogButton" Width="120" Height="30" Content="Clear Log" Margin="10 0 0 0" ToolTip="Clear all log entries"/>
          </StackPanel>
          <TextBox Grid.Row="1" Name="LogText" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                   HorizontalScrollBarVisibility="Auto" IsReadOnly="True"
                   VerticalAlignment="Stretch" MinHeight="220"/>
        </Grid>
      </TabItem>
      <TabItem Header="Schema">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="Expected response structure" FontWeight="Bold" Margin="0 0 0 6"/>
          <ListView Grid.Row="1" Name="SchemaList"
                    VirtualizingStackPanel.IsVirtualizing="True"
                    VirtualizingStackPanel.VirtualizationMode="Recycling"
                    MinHeight="200">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="Field" DisplayMemberBinding="{Binding Field}" Width="260"/>
                <GridViewColumn Header="Type" DisplayMemberBinding="{Binding Type}" Width="140"/>
                <GridViewColumn Header="Required" DisplayMemberBinding="{Binding Required}" Width="80"/>
                <GridViewColumn Header="Description" DisplayMemberBinding="{Binding Description}" Width="320"/>
              </GridView>
            </ListView.View>
          </ListView>
        </Grid>
      </TabItem>
      <TabItem Header="Job Watch">
        <StackPanel Margin="10">
          <TextBlock Text="Job manager" FontWeight="Bold" Margin="0 0 0 10"/>
          <TextBlock Name="JobIdText" Text="Job ID: (not set)" Margin="0 0 0 4"/>
          <TextBlock Name="JobStatusText" Text="Status: (none)" Margin="0 0 0 4"/>
          <TextBlock Name="JobUpdatedText" Text="Last checked: --" Margin="0 0 0 8"/>
          <StackPanel Orientation="Horizontal" Margin="0 0 0 6">
            <Button Name="FetchJobResultsButton" Width="150" Height="30" Content="Fetch Results"/>
            <Button Name="ExportJobResultsButton" Width="150" Height="30" Content="Export Results" Margin="10 0 0 0"/>
          </StackPanel>
          <TextBlock Name="JobResultsPath" Text="Results file: (not available yet)" TextWrapping="Wrap"/>
        </StackPanel>
      </TabItem>
      <TabItem Header="Request History">
        <Grid Margin="10">
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <ListView Grid.Row="0" Name="RequestHistoryList" Height="200"
                    VirtualizingStackPanel.IsVirtualizing="True"
                    VirtualizingStackPanel.VirtualizationMode="Recycling">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="Time" DisplayMemberBinding="{Binding Timestamp}" Width="140"/>
                <GridViewColumn Header="Method" DisplayMemberBinding="{Binding Method}" Width="70"/>
                <GridViewColumn Header="Path" DisplayMemberBinding="{Binding Path}" Width="280"/>
                <GridViewColumn Header="Status" DisplayMemberBinding="{Binding Status}" Width="70"/>
                <GridViewColumn Header="Duration" DisplayMemberBinding="{Binding Duration}" Width="90"/>
              </GridView>
            </ListView.View>
          </ListView>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0 10 0 0">
            <Button Name="ReplayRequestButton" Width="140" Height="30" Content="Replay Request" IsEnabled="False" ToolTip="Load the selected request into the main form"/>
            <Button Name="ClearHistoryButton" Width="140" Height="30" Content="Clear History" Margin="10 0 0 0" ToolTip="Clear all request history"/>
          </StackPanel>
        </Grid>
      </TabItem>
      <TabItem Header="Ops Insights">
      <Grid Margin="10">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Margin="0 0 0 8">
            <GroupBox Header="Pack Runner" Margin="0 0 0 8">
              <Grid Margin="10">
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="2*"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Row="0" Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="Pack:" VerticalAlignment="Center" FontWeight="Bold" Margin="0 0 8 0"/>
                  <ComboBox Name="InsightPackCombo" MinWidth="420" IsEditable="True" IsTextSearchEnabled="True"
                            ToolTip="Select an Insight Pack from insights/packs"/>
                  <Button Name="RefreshInsightPacksButton" Width="80" Height="26" Margin="10 2 0 0" Content="Reload"
                          ToolTip="Reload packs from disk (uses GENESYS_API_EXPLORER_PACKS_DIR when set)"/>
                </StackPanel>

                <WrapPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
                  <Button Name="RunSelectedInsightPackButton" Width="120" Height="30" Content="Run"/>
                  <Button Name="CompareSelectedInsightPackButton" Width="140" Height="30" Content="Compare" Margin="10 0 0 0"/>
                  <ComboBox Name="InsightBaselineModeCombo" Width="150" Height="26" Margin="8 2 0 0"
                            ToolTip="Baseline selection for Compare runs"/>
                  <Button Name="DryRunSelectedInsightPackButton" Width="110" Height="30" Content="Dry Run" Margin="10 0 0 0"/>
                  <CheckBox Name="UseInsightCacheCheckbox" Content="Cache" VerticalAlignment="Center" Margin="14 0 0 0" IsChecked="True"
                            ToolTip="Cache gcRequest steps to disk (file+TTL)"/>
                  <CheckBox Name="StrictInsightValidationCheckbox" Content="Strict validate" VerticalAlignment="Center" Margin="12 0 0 0" IsChecked="False"
                            ToolTip="Enable stricter pack validation before running (schema-ish checks)."/>
                  <TextBlock Text="TTL (min)" VerticalAlignment="Center" Margin="10 0 6 0" Foreground="SlateGray"/>
                  <TextBox Name="InsightCacheTtlInput" Width="60" Height="26" VerticalContentAlignment="Center" Text="60"
                           ToolTip="Cache time-to-live in minutes"/>
                  <Button Name="ExportInsightBriefingButton" Width="130" Height="30" Content="Export Briefing" Margin="10 0 0 0" IsEnabled="False"/>
                </WrapPanel>

                <Grid Grid.Row="1" Grid.ColumnSpan="2" Margin="0 8 0 8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0" Orientation="Vertical">
                    <TextBlock Name="InsightPackDescriptionText"
                               Text="Select a pack to view parameters." TextWrapping="Wrap" Foreground="Gray" />
                    <StackPanel Orientation="Horizontal" Margin="0 6 0 0">
                      <TextBlock Text="Window" VerticalAlignment="Center" Foreground="SlateGray" Margin="0 0 8 0"/>
                      <ComboBox Name="InsightTimePresetCombo" Width="260" Height="26" VerticalContentAlignment="Center"
                                ToolTip="Quick time window presets (UTC)"/>
                      <Button Name="ApplyInsightTimePresetButton" Width="110" Height="26" Content="Apply" Margin="10 0 0 0"/>
                      <TextBlock Text="Example" VerticalAlignment="Center" Foreground="SlateGray" Margin="16 0 8 0"/>
                      <ComboBox Name="InsightPackExampleCombo" Width="260" Height="26" VerticalContentAlignment="Center"
                                ToolTip="Pack-provided example parameter presets"/>
                      <Button Name="LoadInsightPackExampleButton" Width="110" Height="26" Content="Load" Margin="10 0 0 0"/>
                    </StackPanel>
                  </StackPanel>
                  <TextBlock Grid.Column="1" Text="Start (UTC)" VerticalAlignment="Center" Margin="12 0 8 0" Foreground="SlateGray"/>
                  <TextBox Grid.Column="2" Name="InsightGlobalStartInput" Width="220" Height="26" VerticalContentAlignment="Center"
                           ToolTip="Default startDate for packs that define startDate (ISO-8601 UTC)"/>
                  <TextBlock Grid.Column="3" Text="End (UTC)" VerticalAlignment="Center" Margin="12 0 8 0" Foreground="SlateGray"/>
                  <TextBox Grid.Column="4" Name="InsightGlobalEndInput" Width="220" Height="26" VerticalContentAlignment="Center"
                           ToolTip="Default endDate for packs that define endDate (ISO-8601 UTC)"/>
                </Grid>
                <Expander Grid.Row="2" Grid.ColumnSpan="2" Header="Pack Metadata" IsExpanded="False" Margin="0 0 0 8">
                  <Border BorderBrush="#D0D7E2" BorderThickness="1" CornerRadius="6" Padding="10" Background="White">
                    <TextBox Name="InsightPackMetaText" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                             FontFamily="Consolas" FontSize="10" Background="#F5F5F5" MinHeight="90"/>
                  </Border>
                </Expander>
                <Border Grid.Row="3" Grid.ColumnSpan="2" Background="#FFF8E1" BorderBrush="#F3D17A" BorderThickness="1" CornerRadius="6" Padding="8" Margin="0 0 0 8">
                  <TextBlock Name="InsightPackWarningsText" Text=" " TextWrapping="Wrap" Foreground="#6B4E00"/>
                </Border>

                <ScrollViewer Grid.Row="4" Grid.ColumnSpan="2" VerticalScrollBarVisibility="Auto">
                  <StackPanel Name="InsightPackParametersPanel"/>
                </ScrollViewer>
              </Grid>
            </GroupBox>

	            <Expander Header="Quick Packs" IsExpanded="False">
	              <StackPanel Orientation="Horizontal" Margin="10 6 0 0">
	                <Button Name="RunQueueSmokePackButton" Width="200" Height="30" Content="Queue Smoke Detector" Margin="0 0 10 0"/>
	                <Button Name="RunDataActionsPackButton" Width="200" Height="30" Content="Data Action Failures" Margin="0 0 10 0"/>
	                <Button Name="RunDataActionsEnrichedPackButton" Width="220" Height="30" Content="Data Actions (Enriched)" Margin="0 0 10 0"/>
	                <Button Name="RunPeakConcurrencyPackButton" Width="220" Height="30" Content="Peak Concurrency (Voice)" Margin="0 0 10 0"/>
	                <Button Name="RunMosMonthlyPackButton" Width="260" Height="30" Content="Monthly MOS (By Division)"/>
	              </StackPanel>
	            </Expander>
          </StackPanel>
	          <!-- Use Grid instead of StackPanel so TextWrapping/Trimming measure against available width. -->
	          <Grid Grid.Row="1" Margin="0 0 0 8">
	            <Grid.RowDefinitions>
	              <RowDefinition Height="Auto"/>
	              <RowDefinition Height="Auto"/>
	            </Grid.RowDefinitions>
	            <TextBlock Grid.Row="0" Name="InsightEvidenceSummary" Text="Run an insight pack to surface the evidence narrative." TextWrapping="Wrap" Foreground="DarkSlateGray"/>
	            <TextBlock Grid.Row="1" Name="InsightBriefingPathText" Text="Briefings folder will appear here after the first export."
	                       TextWrapping="Wrap" TextTrimming="CharacterEllipsis" Foreground="Gray" FontSize="11" Margin="0 4 0 0"/>
	          </Grid>
          <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="2*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <GroupBox Header="Metrics" Grid.Column="0" Margin="0 0 10 0">
              <ListView Name="InsightMetricsList">
                <ListView.View>
                  <GridView>
                    <GridViewColumn Header="Title" DisplayMemberBinding="{Binding Title}" Width="220"/>
                    <GridViewColumn Header="Value" DisplayMemberBinding="{Binding Value}" Width="120"/>
                    <GridViewColumn Header="Items" DisplayMemberBinding="{Binding Items}" Width="80"/>
                  </GridView>
                </ListView.View>
              </ListView>
            </GroupBox>
            <GroupBox Header="Drilldowns" Grid.Column="1">
              <ListView Name="InsightDrilldownsList">
                <ListView.View>
                  <GridView>
                    <GridViewColumn Header="Title" DisplayMemberBinding="{Binding Title}" Width="160"/>
                    <GridViewColumn Header="Rows" DisplayMemberBinding="{Binding RowCount}" Width="80"/>
                    <GridViewColumn Header="Summary" DisplayMemberBinding="{Binding Summary}" Width="200"/>
                  </GridView>
                </ListView.View>
              </ListView>
            </GroupBox>
        </Grid>
        <GroupBox Header="Briefing History" Grid.Row="3" Margin="0 10 0 0">
          <Grid Margin="10">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0 0 0 8">
              <Button Name="RefreshInsightBriefingsButton" Width="90" Height="28" Content="Refresh"/>
              <Button Name="OpenBriefingsFolderButton" Width="110" Height="28" Content="Open Folder" Margin="10 0 0 0"/>
              <Button Name="OpenBriefingHtmlButton" Width="110" Height="28" Content="Open HTML" Margin="10 0 0 0" IsEnabled="False"/>
              <Button Name="OpenBriefingSnapshotButton" Width="140" Height="28" Content="Open Snapshot" Margin="10 0 0 0" IsEnabled="False"/>
            </StackPanel>
            <ListView Grid.Row="1" Name="InsightBriefingsList">
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="Time (UTC)" DisplayMemberBinding="{Binding Timestamp}" Width="160"/>
                  <GridViewColumn Header="Pack" DisplayMemberBinding="{Binding Pack}" Width="220"/>
                  <GridViewColumn Header="Snapshot" DisplayMemberBinding="{Binding Snapshot}" Width="220"/>
                  <GridViewColumn Header="HTML" DisplayMemberBinding="{Binding Html}" Width="220"/>
                </GridView>
              </ListView.View>
            </ListView>
          </Grid>
        </GroupBox>
      </Grid>
      </TabItem>
      <TabItem Header="Templates">
        <Grid Margin="10">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <TextBlock Grid.Row="0" Text="Request Templates - Save and reuse API request configurations" FontWeight="Bold" Margin="0 0 0 10"/>
          <ListView Grid.Row="1" Name="TemplatesList" Height="180"
                    VirtualizingStackPanel.IsVirtualizing="True"
                    VirtualizingStackPanel.VirtualizationMode="Recycling">
            <ListView.View>
              <GridView>
                <GridViewColumn DisplayMemberBinding="{Binding Name}" Width="200">
                  <GridViewColumn.Header>
                    <GridViewColumnHeader Content="Name" Tag="Name"/>
                  </GridViewColumn.Header>
                </GridViewColumn>
                <GridViewColumn DisplayMemberBinding="{Binding Method}" Width="80">
                  <GridViewColumn.Header>
                    <GridViewColumnHeader Content="Method" Tag="Method"/>
                  </GridViewColumn.Header>
                </GridViewColumn>
                <GridViewColumn DisplayMemberBinding="{Binding Path}" Width="280">
                  <GridViewColumn.Header>
                    <GridViewColumnHeader Content="Path" Tag="Path"/>
                  </GridViewColumn.Header>
                </GridViewColumn>
                <GridViewColumn DisplayMemberBinding="{Binding Created}" Width="150">
                  <GridViewColumn.Header>
                    <GridViewColumnHeader Content="Created" Tag="Created"/>
                  </GridViewColumn.Header>
                </GridViewColumn>
                <GridViewColumn DisplayMemberBinding="{Binding LastModified}" Width="160">
                  <GridViewColumn.Header>
                    <GridViewColumnHeader Content="Last Modified" Tag="LastModified"/>
                  </GridViewColumn.Header>
                </GridViewColumn>
              </GridView>
            </ListView.View>
          </ListView>
          <Grid Grid.Row="2" Margin="0 10 0 0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal">
              <Button Name="SaveTemplateButton" Width="120" Height="30" Content="Save Template" ToolTip="Save current request as a template"/>
              <Button Name="LoadTemplateButton" Width="120" Height="30" Content="Load Template" Margin="10 0 0 0" IsEnabled="False" ToolTip="Load selected template into the main form"/>
              <Button Name="DeleteTemplateButton" Width="120" Height="30" Content="Delete Template" Margin="10 0 0 0" IsEnabled="False" ToolTip="Delete selected template"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right">
              <Button Name="ExportTemplatesButton" Width="140" Height="30" Content="Export Templates" ToolTip="Export all templates to JSON file"/>
              <Button Name="ImportTemplatesButton" Width="140" Height="30" Content="Import Templates" Margin="10 0 0 0" ToolTip="Import templates from JSON file"/>
            </StackPanel>
          </Grid>
        </Grid>
      </TabItem>
      <TabItem Header="Conversation Report">
        <Grid Margin="10">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0 0 0 10">
            <TextBlock Text="Conversation ID:" VerticalAlignment="Center" FontWeight="Bold" Margin="0 0 8 0"/>
            <TextBox Name="ConversationReportIdInput" Width="350" Height="28" VerticalContentAlignment="Center"
                     ToolTip="Enter the conversation ID to generate a report"/>
            <Button Name="RunConversationReportButton" Width="120" Height="30" Content="Run Report" Margin="10 0 0 0"/>
          </StackPanel>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0 0 0 10">
            <Button Name="InspectConversationReportButton" Width="140" Height="30" Content="Inspect Result" IsEnabled="False"/>
            <Button Name="ExportConversationReportJsonButton" Width="140" Height="30" Content="Export JSON" Margin="10 0 0 0" IsEnabled="False"/>
            <Button Name="ExportConversationReportTextButton" Width="140" Height="30" Content="Export Text" Margin="10 0 0 0" IsEnabled="False"/>
            <TextBlock Name="ConversationReportStatus" VerticalAlignment="Center" Foreground="SlateGray" Margin="10 0 0 0"/>
          </StackPanel>
          <StackPanel Grid.Row="2" Orientation="Vertical" Margin="0 0 0 10">
            <TextBlock Text="Progress:" FontWeight="Bold" Margin="0 0 0 5"/>
            <ProgressBar Name="ConversationReportProgressBar" Height="20" Minimum="0" Maximum="100" Value="0"/>
            <TextBlock Name="ConversationReportProgressText" Margin="0 5 0 0" Foreground="DarkBlue" FontSize="10"/>
          </StackPanel>
          <StackPanel Grid.Row="3" Orientation="Vertical" Margin="0 0 0 10">
            <TextBlock Text="Endpoint Query Log:" FontWeight="Bold" Margin="0 0 0 5"/>
            <TextBox Name="ConversationReportEndpointLog" Height="100" TextWrapping="Wrap" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" IsReadOnly="True"
                     FontFamily="Consolas" FontSize="10" Background="#F5F5F5"/>
          </StackPanel>
          <TextBox Grid.Row="4" Name="ConversationReportText" TextWrapping="Wrap" AcceptsReturn="True"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" IsReadOnly="True"
                   FontFamily="Consolas" FontSize="11"
                   VerticalAlignment="Stretch" MinHeight="200"/>
        </Grid>
      </TabItem>
    </TabControl>
  </Grid>
</DockPanel>
</Window>
"@

$Window = [System.Windows.Markup.XamlReader]::Parse($Xaml)
if (-not $Window) {
    Write-Error "Failed to create the WPF UI."
    return
}

$groupCombo = $Window.FindName("GroupCombo")
$pathCombo = $Window.FindName("PathCombo")
$methodCombo = $Window.FindName("MethodCombo")
$parameterPanel = $Window.FindName("ParameterPanel")
$btnSubmit = $Window.FindName("SubmitButton")
$btnSave = $Window.FindName("SaveButton")
$responseBox = $Window.FindName("ResponseText")
$logBox = $Window.FindName("LogText")
$loginButton = $Window.FindName("LoginButton")
$testTokenButton = $Window.FindName("TestTokenButton")
$tokenStatusText = $Window.FindName("TokenStatusText")
$tokenReadyIndicator = $Window.FindName("TokenReadyIndicator")
$regionStatusText = $Window.FindName("RegionStatusText")
$oauthTypeText = $Window.FindName("OauthTypeText")
$progressIndicator = $Window.FindName("ProgressIndicator")
$statusText = $Window.FindName("StatusText")
$favoritesList = $Window.FindName("FavoritesList")

Update-AuthUiState
$favoriteNameInput = $Window.FindName("FavoriteNameInput")
$saveFavoriteButton = $Window.FindName("SaveFavoriteButton")
$schemaList = $Window.FindName("SchemaList")
$inspectResponseButton = $Window.FindName("InspectResponseButton")
$toggleResponseViewButton = $Window.FindName("ToggleResponseViewButton")
$jobIdText = $Window.FindName("JobIdText")
$jobStatusText = $Window.FindName("JobStatusText")
$jobUpdatedText = $Window.FindName("JobUpdatedText")
$jobResultsPath = $Window.FindName("JobResultsPath")
$fetchJobResultsButton = $Window.FindName("FetchJobResultsButton")
$exportJobResultsButton = $Window.FindName("ExportJobResultsButton")
$helpMenuItem = $Window.FindName("HelpMenuItem")
$helpDevLink = $Window.FindName("HelpDevLink")
$helpSupportLink = $Window.FindName("HelpSupportLink")
$conversationReportIdInput = $Window.FindName("ConversationReportIdInput")
$runConversationReportButton = $Window.FindName("RunConversationReportButton")
$inspectConversationReportButton = $Window.FindName("InspectConversationReportButton")
$exportConversationReportJsonButton = $Window.FindName("ExportConversationReportJsonButton")
$exportConversationReportTextButton = $Window.FindName("ExportConversationReportTextButton")
$conversationReportText = $Window.FindName("ConversationReportText")
$conversationReportStatus = $Window.FindName("ConversationReportStatus")
$conversationReportProgressBar = $Window.FindName("ConversationReportProgressBar")
$conversationReportProgressText = $Window.FindName("ConversationReportProgressText")
	$conversationReportEndpointLog = $Window.FindName("ConversationReportEndpointLog")
	$appSettingsMenuItem = $Window.FindName("AppSettingsMenuItem")
	$traceMenuItem = $Window.FindName("TraceMenuItem")
	$settingsMenuItem = $Window.FindName("SettingsMenuItem")
	$exportLogButton = $Window.FindName("ExportLogButton")
	$clearLogButton = $Window.FindName("ClearLogButton")
	$resetEndpointsMenuItem = $Window.FindName("ResetEndpointsMenuItem")
$requestHistoryList = $Window.FindName("RequestHistoryList")
$replayRequestButton = $Window.FindName("ReplayRequestButton")
$clearHistoryButton = $Window.FindName("ClearHistoryButton")
$mainTabControl = $Window.FindName("MainTabControl")
$requestSelectorGrid = $Window.FindName("RequestSelectorGrid")
$favoritesBorder = $Window.FindName("FavoritesBorder")
$actionButtonsPanel = $Window.FindName("ActionButtonsPanel")
$runQueueSmokePackButton = $Window.FindName("RunQueueSmokePackButton")
$runDataActionsPackButton = $Window.FindName("RunDataActionsPackButton")
$runDataActionsEnrichedPackButton = $Window.FindName("RunDataActionsEnrichedPackButton")
$runPeakConcurrencyPackButton = $Window.FindName("RunPeakConcurrencyPackButton")
$runMosMonthlyPackButton = $Window.FindName("RunMosMonthlyPackButton")
$runSelectedInsightPackButton = $Window.FindName("RunSelectedInsightPackButton")
$compareSelectedInsightPackButton = $Window.FindName("CompareSelectedInsightPackButton")
	$insightBaselineModeCombo = $Window.FindName("InsightBaselineModeCombo")
	$dryRunSelectedInsightPackButton = $Window.FindName("DryRunSelectedInsightPackButton")
	$useInsightCacheCheckbox = $Window.FindName("UseInsightCacheCheckbox")
	$strictInsightValidationCheckbox = $Window.FindName("StrictInsightValidationCheckbox")
	$insightCacheTtlInput = $Window.FindName("InsightCacheTtlInput")
	$insightPackCombo = $Window.FindName("InsightPackCombo")
	$refreshInsightPacksButton = $Window.FindName("RefreshInsightPacksButton")
	$insightPackDescriptionText = $Window.FindName("InsightPackDescriptionText")
	$insightPackMetaText = $Window.FindName("InsightPackMetaText")
	$insightPackWarningsText = $Window.FindName("InsightPackWarningsText")
	$insightPackParametersPanel = $Window.FindName("InsightPackParametersPanel")
	$insightTimePresetCombo = $Window.FindName("InsightTimePresetCombo")
$applyInsightTimePresetButton = $Window.FindName("ApplyInsightTimePresetButton")
$insightPackExampleCombo = $Window.FindName("InsightPackExampleCombo")
$loadInsightPackExampleButton = $Window.FindName("LoadInsightPackExampleButton")
$insightGlobalStartInput = $Window.FindName("InsightGlobalStartInput")
$insightGlobalEndInput = $Window.FindName("InsightGlobalEndInput")
$exportInsightBriefingButton = $Window.FindName("ExportInsightBriefingButton")
$insightEvidenceSummary = $Window.FindName("InsightEvidenceSummary")
$insightMetricsList = $Window.FindName("InsightMetricsList")
$insightDrilldownsList = $Window.FindName("InsightDrilldownsList")
$insightBriefingPathText = $Window.FindName("InsightBriefingPathText")
$insightBriefingsList = $Window.FindName("InsightBriefingsList")
$refreshInsightBriefingsButton = $Window.FindName("RefreshInsightBriefingsButton")
$openBriefingsFolderButton = $Window.FindName("OpenBriefingsFolderButton")
$openBriefingHtmlButton = $Window.FindName("OpenBriefingHtmlButton")
$openBriefingSnapshotButton = $Window.FindName("OpenBriefingSnapshotButton")
$exportPowerShellButton = $Window.FindName("ExportPowerShellButton")
$powerShellExportModeCombo = $Window.FindName("PowerShellExportModeCombo")
$exportCurlButton = $Window.FindName("ExportCurlButton")
$templatesList = $Window.FindName("TemplatesList")
$saveTemplateButton = $Window.FindName("SaveTemplateButton")
$loadTemplateButton = $Window.FindName("LoadTemplateButton")
$deleteTemplateButton = $Window.FindName("DeleteTemplateButton")
$exportTemplatesButton = $Window.FindName("ExportTemplatesButton")
$importTemplatesButton = $Window.FindName("ImportTemplatesButton")
$filterBuilderBorder = $Window.FindName("FilterBuilderBorder")
$filterBuilderHintText = $Window.FindName("FilterBuilderHintText")
$filterBuilderExpander = $Window.FindName("FilterBuilderExpander")
$parametersExpander = $Window.FindName("ParametersExpander")
$filterIntervalInput = $Window.FindName("FilterIntervalInput")
$refreshFiltersButton = $Window.FindName("RefreshFiltersButton")
$resetFiltersButton = $Window.FindName("ResetFiltersButton")
$conversationFiltersList = $Window.FindName("ConversationFiltersList")
$conversationFilterTypeCombo = $Window.FindName("ConversationFilterTypeCombo")
$conversationPredicateTypeCombo = $Window.FindName("ConversationPredicateTypeCombo")
$conversationFieldCombo = $Window.FindName("ConversationFieldCombo")
$conversationOperatorCombo = $Window.FindName("ConversationOperatorCombo")
$conversationValueInput = $Window.FindName("ConversationValueInput")
$addConversationPredicateButton = $Window.FindName("AddConversationPredicateButton")
$removeConversationPredicateButton = $Window.FindName("RemoveConversationPredicateButton")
$segmentFiltersList = $Window.FindName("SegmentFiltersList")
$segmentFilterTypeCombo = $Window.FindName("SegmentFilterTypeCombo")
$segmentPredicateTypeCombo = $Window.FindName("SegmentPredicateTypeCombo")
$segmentFieldCombo = $Window.FindName("SegmentFieldCombo")
$segmentOperatorCombo = $Window.FindName("SegmentOperatorCombo")
$segmentPropertyInput = $Window.FindName("SegmentPropertyInput")
$segmentPropertyTypeCombo = $Window.FindName("SegmentPropertyTypeCombo")
$segmentValueInput = $Window.FindName("SegmentValueInput")
$addSegmentPredicateButton = $Window.FindName("AddSegmentPredicateButton")
$removeSegmentPredicateButton = $Window.FindName("RemoveSegmentPredicateButton")

if ($filterBuilderBorder) {
    Initialize-FilterBuilderControl
    Reset-FilterBuilderData
    Set-FilterBuilderVisibility -Visible $false
    Update-FilterBuilderHint

    if ($conversationPredicateTypeCombo) {
        $conversationPredicateTypeCombo.Add_SelectionChanged({
                Update-FilterFieldOptions -Scope "Conversation" -PredicateType $conversationPredicateTypeCombo.SelectedItem -ComboBox $conversationFieldCombo
            })
    }
    if ($segmentPredicateTypeCombo) {
        $segmentPredicateTypeCombo.Add_SelectionChanged({
                Update-FilterFieldOptions -Scope "Segment" -PredicateType $segmentPredicateTypeCombo.SelectedItem -ComboBox $segmentFieldCombo
            })
    }

    if ($addConversationPredicateButton) {
        $addConversationPredicateButton.Add_Click({
                $filter = Build-FilterFromInput -Scope "Conversation" -FilterTypeCombo $conversationFilterTypeCombo -PredicateTypeCombo $conversationPredicateTypeCombo -FieldCombo $conversationFieldCombo -OperatorCombo $conversationOperatorCombo -ValueInput $conversationValueInput
                if ($filter) {
                    Add-FilterEntry -Scope "Conversation" -FilterObject $filter
                    if ($conversationValueInput) { $conversationValueInput.Clear() }
                }
            })
    }

    if ($addSegmentPredicateButton) {
        $addSegmentPredicateButton.Add_Click({
                $filter = Build-FilterFromInput -Scope "Segment" -FilterTypeCombo $segmentFilterTypeCombo -PredicateTypeCombo $segmentPredicateTypeCombo -FieldCombo $segmentFieldCombo -OperatorCombo $segmentOperatorCombo -ValueInput $segmentValueInput -PropertyTypeCombo $segmentPropertyTypeCombo
                if ($filter) {
                    Add-FilterEntry -Scope "Segment" -FilterObject $filter
                    if ($segmentValueInput) { $segmentValueInput.Clear() }
                }
            })
    }

    if ($conversationFiltersList -and $removeConversationPredicateButton) {
        $conversationFiltersList.Add_SelectionChanged({
                $removeConversationPredicateButton.IsEnabled = ($conversationFiltersList.SelectedIndex -ge 0)
            })
        $removeConversationPredicateButton.Add_Click({
                $index = $conversationFiltersList.SelectedIndex
                if ($index -ge 0) {
                    $script:FilterBuilderData.ConversationFilters.RemoveAt($index)
                    Refresh-FilterList -Scope "Conversation"
                    $removeConversationPredicateButton.IsEnabled = $false
                }
            })
    }

    if ($segmentFiltersList -and $removeSegmentPredicateButton) {
        $segmentFiltersList.Add_SelectionChanged({
                $removeSegmentPredicateButton.IsEnabled = ($segmentFiltersList.SelectedIndex -ge 0)
            })
        $removeSegmentPredicateButton.Add_Click({
                $index = $segmentFiltersList.SelectedIndex
                if ($index -ge 0) {
                    $script:FilterBuilderData.SegmentFilters.RemoveAt($index)
                    Refresh-FilterList -Scope "Segment"
                    $removeSegmentPredicateButton.IsEnabled = $false
                }
            })
    }

    if ($refreshFiltersButton) {
        $refreshFiltersButton.Add_Click({
                Invoke-FilterBuilderBody
            })
    }
    if ($resetFiltersButton) {
        $resetFiltersButton.Add_Click({
                Reset-FilterBuilderData
                Refresh-FilterList -Scope "Conversation"
                Refresh-FilterList -Scope "Segment"
            })
    }
}

if (-not $script:LayoutDefaultsCaptured) {
    $script:LayoutDefaultsCaptured = $true
    $script:LayoutDefaults = [pscustomobject]@{
        RequestSelectorVisibility = if ($requestSelectorGrid) { $requestSelectorGrid.Visibility } else { $null }
        FavoritesVisibility       = if ($favoritesBorder) { $favoritesBorder.Visibility } else { $null }
        ActionButtonsVisibility   = if ($actionButtonsPanel) { $actionButtonsPanel.Visibility } else { $null }
        ParametersVisibility      = if ($parametersExpander) { $parametersExpander.Visibility } else { $null }
        ParametersExpanded        = if ($parametersExpander) { [bool]$parametersExpander.IsExpanded } else { $false }
        FilterBuilderVisibility   = if ($filterBuilderExpander) { $filterBuilderExpander.Visibility } else { $null }
        FilterBuilderExpanded     = if ($filterBuilderExpander) { [bool]$filterBuilderExpander.IsExpanded } else { $false }
    }
}

function Set-FocusLayoutForMainTab {
    param(
        [Parameter(Mandatory)]
        [string]$Header
    )

    $isOpsInsights = ($Header -eq 'Ops Insights')
    if ($isOpsInsights) {
        if ($requestSelectorGrid) { $requestSelectorGrid.Visibility = 'Collapsed' }
        if ($favoritesBorder) { $favoritesBorder.Visibility = 'Collapsed' }
        if ($actionButtonsPanel) { $actionButtonsPanel.Visibility = 'Collapsed' }
        if ($parametersExpander) {
            $parametersExpander.IsExpanded = $false
            $parametersExpander.Visibility = 'Collapsed'
        }
        if ($filterBuilderExpander) {
            $filterBuilderExpander.IsExpanded = $false
            $filterBuilderExpander.Visibility = 'Collapsed'
        }
        return
    }

    # Restore defaults for non-Ops Insights tabs
    if ($script:LayoutDefaults) {
        if ($requestSelectorGrid -and $null -ne $script:LayoutDefaults.RequestSelectorVisibility) { $requestSelectorGrid.Visibility = $script:LayoutDefaults.RequestSelectorVisibility }
        if ($favoritesBorder -and $null -ne $script:LayoutDefaults.FavoritesVisibility) { $favoritesBorder.Visibility = $script:LayoutDefaults.FavoritesVisibility }
        if ($actionButtonsPanel -and $null -ne $script:LayoutDefaults.ActionButtonsVisibility) { $actionButtonsPanel.Visibility = $script:LayoutDefaults.ActionButtonsVisibility }

        if ($parametersExpander -and $null -ne $script:LayoutDefaults.ParametersVisibility) {
            $parametersExpander.Visibility = $script:LayoutDefaults.ParametersVisibility
            $parametersExpander.IsExpanded = [bool]$script:LayoutDefaults.ParametersExpanded
        }

        if ($filterBuilderExpander -and $null -ne $script:LayoutDefaults.FilterBuilderVisibility) {
            $filterBuilderExpander.Visibility = $script:LayoutDefaults.FilterBuilderVisibility
            $filterBuilderExpander.IsExpanded = [bool]$script:LayoutDefaults.FilterBuilderExpanded
        }
    }
}

if ($mainTabControl) {
    $mainTabControl.Add_SelectionChanged({
            param($sender, $e)
            try {
                if ($e.OriginalSource -ne $sender) { return }
                $selected = $sender.SelectedItem
                if (-not $selected) { return }
                $header = [string]$selected.Header
                if ([string]::IsNullOrWhiteSpace($header)) { return }
                Set-FocusLayoutForMainTab -Header $header
            }
            catch {
                # Don't break the UI for layout issues
            }
        })

    try {
        $initial = $mainTabControl.SelectedItem
        if ($initial) { Set-FocusLayoutForMainTab -Header ([string]$initial.Header) }
    }
    catch { }
}
$script:LastConversationReport = $null
$script:LastConversationReportJson = ""
$script:RequestHistory = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$script:ResponseViewMode = "Formatted"  # Can be "Formatted" or "Raw"
$script:Templates = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$script:TemplatesFilePath = Join-Path -Path $env:USERPROFILE -ChildPath "GenesysApiExplorerTemplates.json"
$script:CurrentBodyControl = $null
$script:CurrentBodySchema = $null
$script:InsightMetrics = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$script:InsightDrilldowns = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$script:LastInsightResult = $null
$script:InsightBriefingsHistory = New-Object System.Collections.ObjectModel.ObservableCollection[Object]

function Invoke-ReloadEndpoints {
    param (
        [string]$JsonPath
    )

    try {
        if (-not (Test-Path -Path $JsonPath)) {
            [System.Windows.MessageBox]::Show("The endpoints file does not exist at: $JsonPath", "File Not Found", "OK", "Error")
            return $false
        }

        $newCatalog = Load-PathsFromJson -JsonPath $JsonPath

        if (-not $newCatalog) {
            [System.Windows.MessageBox]::Show("Failed to load endpoints from the selected file.", "Load Error", "OK", "Error")
            return $false
        }

        # Update global variables
        $script:ApiCatalog = $newCatalog
        $script:ApiPaths = $newCatalog.Paths
        $script:Definitions = if ($newCatalog.Definitions) { $newCatalog.Definitions } else { @{} }
        $script:GroupMap = Build-GroupMap -Paths $script:ApiPaths
        $script:CurrentJsonPath = $JsonPath

        Initialize-FilterBuilderEnum
        Reset-FilterBuilderData
        Update-FilterBuilderHint
        Set-FilterBuilderVisibility -Visible $false

        # Refresh UI
        $groupCombo.Items.Clear()
        $pathCombo.Items.Clear()
        $methodCombo.Items.Clear()
        $parameterPanel.Children.Clear()
        $paramInputs.Clear()
        $responseBox.Text = ""
        $btnSave.IsEnabled = $false

        foreach ($group in ($script:GroupMap.Keys | Sort-Object)) {
            $groupCombo.Items.Add($group) | Out-Null
        }

        $statusText.Text = "Endpoints reloaded successfully from: $(Split-Path -Leaf $JsonPath)"
        Add-LogEntry "Endpoints reloaded from: $JsonPath"

        return $true
    }
    catch {
        [System.Windows.MessageBox]::Show("Error loading endpoints: $($_.Exception.Message)", "Load Error", "OK", "Error")
        Add-LogEntry "Error reloading endpoints: $($_.Exception.Message)"
        return $false
    }
}

function Add-LogEntry {
    param ([string]$Message)

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    if ($logBox) {
        $logBox.AppendText("[$timestamp] $Message`r`n")
        $logBox.ScrollToEnd()
    }
}

function Refresh-FavoritesList {
    if (-not $favoritesList) { return }
    $favoritesList.Items.Clear()

    foreach ($favorite in $Favorites) {
        $favoritesList.Items.Add($favorite) | Out-Null
    }

    $favoritesList.SelectedIndex = -1
}

function Get-InsightPackPath {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        $FileName
    )

    if (-not $insightPackRoot) {
        throw "Insight pack root path is not configured."
    }

    $packName = $FileName
    if ($packName -is [System.Collections.IEnumerable] -and -not ($packName -is [string])) {
        $packName = $packName | Select-Object -First 1
    }

    $packName = [string]$packName
    if ([string]::IsNullOrWhiteSpace($packName)) {
        throw "Insight pack file name is required."
    }

    $candidate = Join-Path -Path $insightPackRoot -ChildPath $packName
    if (Test-Path -LiteralPath $candidate) { return $candidate }

    if ($legacyInsightPackRoot) {
        $legacyCandidate = Join-Path -Path $legacyInsightPackRoot -ChildPath $packName
        if (Test-Path -LiteralPath $legacyCandidate) { return $legacyCandidate }
    }

    return $candidate
}

function Get-InsightBriefingDirectory {
    $targetDir = $insightBriefingRoot

    if (-not $targetDir) {
        throw "Insight briefing root path is not configured."
    }

    # If primary directory doesn't exist, try legacy location
    if (-not (Test-Path -LiteralPath $targetDir) -and $legacyInsightBriefingRoot) {
        if (Test-Path -LiteralPath $legacyInsightBriefingRoot) {
            $targetDir = $legacyInsightBriefingRoot
        }
    }

    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    return $targetDir
}

function Update-InsightPackUi {
    param(
        [Parameter(Mandatory)]
        $Result
    )

    $script:InsightMetrics.Clear()
    $script:InsightDrilldowns.Clear()

    $metrics = @($Result.Metrics)
    $drilldowns = @($Result.Drilldowns)

    $index = 0
    foreach ($metric in $metrics) {
        $index++
        $title = if ($metric.PSObject.Properties.Name -contains 'title') { $metric.title } else { "Metric $index" }
        $value = if ($metric.PSObject.Properties.Name -contains 'value') { $metric.value } else { $null }
        $itemsCount = if ($metric.PSObject.Properties.Name -contains 'items') { (@($metric.items)).Count } else { 0 }
        $script:InsightMetrics.Add([pscustomobject]@{
                Title   = $title
                Value   = $value
                Items   = $itemsCount
                Details = if ($metric.PSObject.Properties.Name -contains 'items') { ($metric.items | ConvertTo-Json -Depth 4) } else { $null }
            }) | Out-Null
    }

    foreach ($drilldown in $drilldowns) {
        $title = if ($drilldown.PSObject.Properties.Name -contains 'title') { $drilldown.title } elseif (($drilldown.PSObject.Properties.Name -contains 'Id') -and $drilldown.Id) { $drilldown.Id } else { 'drilldown' }
        $rowCount = if ($drilldown.PSObject.Properties.Name -contains 'items') { (@($drilldown.items)).Count } else { 0 }
        $summary = if ($rowCount -gt 0) { "$rowCount rows" } else { '' }
        $script:InsightDrilldowns.Add([pscustomobject]@{
                Title    = $title
                RowCount = $rowCount
                Summary  = $summary
            }) | Out-Null
    }

    if ($insightEvidenceSummary) {
        $evidence = $Result.Evidence
        $severity = if ($evidence -and ($evidence.PSObject.Properties.Name -contains 'Severity')) { $evidence.Severity } else { 'Info' }
        $impact = if ($evidence -and ($evidence.PSObject.Properties.Name -contains 'Impact')) { $evidence.Impact } else { '' }
        $narrative = if ($evidence) { $evidence.Narrative } else { '(No narrative available)' }
        $drillNotes = if ($evidence) { $evidence.DrilldownNotes } else { '' }
        $insightEvidenceSummary.Text = "Severity: $severity`nImpact: $impact`nNarrative: $narrative`nDrilldowns: $drillNotes"
    }
}

function Run-InsightPackWorkflow {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter()]
        [string]$TimePresetKey
    )

    try {
        # Prefer selecting the pack in the UI so parameter controls exist and start/end can be applied.
        if ($insightPackCombo -and $script:InsightPackCatalog -and $script:InsightPackCatalog.Count -gt 0) {
            $target = @($script:InsightPackCatalog | Where-Object { $_.FileName -eq $FileName } | Select-Object -First 1)
            if ($target) {
                $insightPackCombo.SelectedItem = $target
            }
        }

        if ($TimePresetKey) {
            try { Apply-InsightTimePresetToUi -PresetKey $TimePresetKey } catch { }
        }

        if ($runQueueSmokePackButton) { $runQueueSmokePackButton.IsEnabled = $false }
        if ($runDataActionsPackButton) { $runDataActionsPackButton.IsEnabled = $false }
        if ($runDataActionsEnrichedPackButton) { $runDataActionsEnrichedPackButton.IsEnabled = $false }
        if ($runPeakConcurrencyPackButton) { $runPeakConcurrencyPackButton.IsEnabled = $false }
        if ($runMosMonthlyPackButton) { $runMosMonthlyPackButton.IsEnabled = $false }

        $statusText.Text = "Running insight pack: $Label..."

        Run-SelectedInsightPack -Compare:$false -DryRun:$false | Out-Null
        $statusText.Text = "Insight pack '$Label' completed."
    }
    catch {
        $statusText.Text = "Insight pack '$Label' failed."
        Add-LogEntry "Insight pack '$Label' failed: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show("Insight pack '$Label' failed: $($_.Exception.Message)", "Insight Pack Error", "OK", "Error")
    }
    finally {
        if ($runQueueSmokePackButton) { $runQueueSmokePackButton.IsEnabled = $true }
        if ($runDataActionsPackButton) { $runDataActionsPackButton.IsEnabled = $true }
        if ($runDataActionsEnrichedPackButton) { $runDataActionsEnrichedPackButton.IsEnabled = $true }
        if ($runPeakConcurrencyPackButton) { $runPeakConcurrencyPackButton.IsEnabled = $true }
        if ($runMosMonthlyPackButton) { $runMosMonthlyPackButton.IsEnabled = $true }
    }
}

function Export-InsightBriefingWorkflow {
    if (-not $script:LastInsightResult) {
        [System.Windows.MessageBox]::Show("Run an insight pack before exporting a briefing.", "Insight Briefing", "OK", "Information")
        return
    }

    $outputDir = Get-InsightBriefingDirectory
    $exportResult = Export-GCInsightBriefing -Result $script:LastInsightResult -Directory $outputDir -Force:$true

    $statusText.Text = "Insight briefing exported: $($exportResult.HtmlPath)"
    Add-LogEntry "Insight briefing exported: $($exportResult.HtmlPath)"

    if ($insightBriefingPathText) {
        $insightBriefingPathText.Text = "Briefings folder: $outputDir`nLast export: $($exportResult.HtmlPath)"
    }

    Refresh-InsightBriefingHistory

    if ($insightBriefingsList -and $script:InsightBriefingsHistory.Count -gt 0) {
        $insightBriefingsList.SelectedIndex = $script:InsightBriefingsHistory.Count - 1
        $insightBriefingsList.ScrollIntoView($insightBriefingsList.SelectedItem)
    }

    [System.Windows.MessageBox]::Show("Briefing exported to:`n$($exportResult.HtmlPath)", "Insight Briefing", "OK", "Information")
}

foreach ($group in ($script:GroupMap.Keys | Sort-Object)) {
    $groupCombo.Items.Add($group)
}

$statusText.Text = "Select a group to begin."
Refresh-FavoritesList

Update-JobPanel -Status "" -Updated ""

if ($Favorites.Count -gt 0) {
    Add-LogEntry "Loaded $($Favorites.Count) favorites from $FavoritesFile."
}
else {
    Add-LogEntry "No favorites saved yet; create one from your current request."
}

Show-SplashScreen

$groupCombo.Add_SelectionChanged({
        $parameterPanel.Children.Clear()
        $paramInputs.Clear()
        $pathCombo.Items.Clear()
        $methodCombo.Items.Clear()
        $responseBox.Text = ""
        $btnSave.IsEnabled = $false

        $selectedGroup = $groupCombo.SelectedItem
        if (-not $selectedGroup) {
            return
        }

        $paths = $script:GroupMap[$selectedGroup]
        if (-not $paths) { return }
        foreach ($path in ($paths | Sort-Object)) {
            $pathCombo.Items.Add($path) | Out-Null
        }

        $statusText.Text = "Group '$selectedGroup' selected. Choose a path."
    })

$pathCombo.Add_SelectionChanged({
        $methodCombo.Items.Clear()
        $parameterPanel.Children.Clear()
        $paramInputs.Clear()
        $responseBox.Text = ""
        $btnSave.IsEnabled = $false

        $selectedPath = $pathCombo.SelectedItem
        if (-not $selectedPath) { return }

        $pathObject = Get-PathObject -ApiPaths $script:ApiPaths -Path $selectedPath
        if (-not $pathObject) { return }

        # Filter methods to only include GET and POST (read-only mode)
        $allowedMethods = @('get', 'post')
        foreach ($method in $pathObject.PSObject.Properties | Select-Object -ExpandProperty Name) {
            if ($allowedMethods -contains $method.ToLower()) {
                $methodCombo.Items.Add($method) | Out-Null
            }
        }

        $statusText.Text = "Path '$selectedPath' loaded. Select a method."
    })

$methodCombo.Add_SelectionChanged({
        $parameterPanel.Children.Clear()
        $paramInputs.Clear()
        $responseBox.Text = ""
        $btnSave.IsEnabled = $false

        $selectedPath = $pathCombo.SelectedItem
        $selectedMethod = $methodCombo.SelectedItem
        if (-not $selectedPath -or -not $selectedMethod) {
            return
        }

        $script:CurrentBodyControl = $null
        $script:CurrentBodySchema = $null
        Reset-FilterBuilderData
        Set-FilterBuilderVisibility -Visible $false

        $pathObject = Get-PathObject -ApiPaths $script:ApiPaths -Path $selectedPath
        $methodObject = Get-MethodObject -PathObject $pathObject -MethodName $selectedMethod
        if (-not $methodObject) {
            return
        }

        $params = $methodObject.parameters
        if (-not $params) { return }

        foreach ($param in $params) {
            $row = New-Object System.Windows.Controls.Grid
            $row.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8

            $col0 = New-Object System.Windows.Controls.ColumnDefinition
            $col0.Width = New-Object System.Windows.GridLength 240
            $row.ColumnDefinitions.Add($col0)

            $col1 = New-Object System.Windows.Controls.ColumnDefinition
            $col1.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
            $row.ColumnDefinitions.Add($col1)

            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = "$($param.name) ($($param.in))"
            if ($param.required) {
                $label.Text += " (required)"
            }
            $label.VerticalAlignment = "Center"
            $label.ToolTip = $param.description
            $label.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0
            [System.Windows.Controls.Grid]::SetColumn($label, 0)

            # Check if parameter has enum values (dropdown)
            if ($param.enum -and $param.enum.Count -gt 0) {
                $comboBox = New-Object System.Windows.Controls.ComboBox
                $comboBox.MinWidth = 360
                $comboBox.HorizontalAlignment = "Stretch"
                $comboBox.Height = 28
                if ($param.required) {
                    $comboBox.Background = [System.Windows.Media.Brushes]::LightYellow
                }
                $comboBox.ToolTip = $param.description

                # Add empty option for optional parameters
                if (-not $param.required) {
                    $comboBox.Items.Add("") | Out-Null
                }

                # Add enum values
                foreach ($enumValue in $param.enum) {
                    $comboBox.Items.Add($enumValue) | Out-Null
                }

                # Set default value if exists
                if ($param.default) {
                    $comboBox.SelectedItem = $param.default
                }

                [System.Windows.Controls.Grid]::SetColumn($comboBox, 1)
                $inputControl = $comboBox
            }
            # Check if parameter is boolean type (checkbox)
            elseif ($param.type -eq "boolean") {
                $checkBoxPanel = New-Object System.Windows.Controls.StackPanel
                $checkBoxPanel.Orientation = "Horizontal"

                $checkBox = New-Object System.Windows.Controls.CheckBox
                $checkBox.VerticalAlignment = "Center"
                $checkBox.ToolTip = $param.description
                $checkBox.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0

                # Set default value if exists
                if ($param.default -ne $null) {
                    if ($param.default -eq $true -or $param.default -eq "true") {
                        $checkBox.IsChecked = $true
                    }
                }

                $checkBoxLabel = New-Object System.Windows.Controls.TextBlock
                $checkBoxLabel.Text = if ($param.default -ne $null) { "(default: $($param.default))" } else { "" }
                $checkBoxLabel.VerticalAlignment = "Center"
                $checkBoxLabel.Foreground = [System.Windows.Media.Brushes]::Gray
                $checkBoxLabel.FontSize = 11

                $checkBoxPanel.Children.Add($checkBox) | Out-Null
                $checkBoxPanel.Children.Add($checkBoxLabel) | Out-Null

                [System.Windows.Controls.Grid]::SetColumn($checkBoxPanel, 1)
                $inputControl = $checkBoxPanel
                # Store reference to the checkbox itself for value retrieval
                $inputControl | Add-Member -NotePropertyName "ValueControl" -NotePropertyValue $checkBox
            }
            # Check if parameter is array type
            elseif ($param.type -eq "array") {
                # Create a container for textbox and hint
                $arrayPanel = New-Object System.Windows.Controls.StackPanel
                $arrayPanel.Orientation = "Vertical"

                $textbox = New-Object System.Windows.Controls.TextBox
                $textbox.MinWidth = 360
                $textbox.HorizontalAlignment = "Stretch"
                $textbox.Height = 28
                if ($param.required) {
                    $textbox.Background = [System.Windows.Media.Brushes]::LightYellow
                }
                $textbox.ToolTip = $param.description

                # Store array metadata for validation
                $textbox | Add-Member -NotePropertyName "IsArrayType" -NotePropertyValue $true
                $textbox | Add-Member -NotePropertyName "ArrayItems" -NotePropertyValue $param.items

                # Add hint text
                $hintText = New-Object System.Windows.Controls.TextBlock
                $itemTypeStr = if ($param.items -and $param.items.type) { $param.items.type } else { "string" }
                $hintText.Text = "Enter comma-separated values (type: $itemTypeStr)"
                $hintText.FontSize = 10
                $hintText.Foreground = [System.Windows.Media.Brushes]::Gray
                $hintText.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0

                # Add validation indicator
                $validationText = New-Object System.Windows.Controls.TextBlock
                $validationText.FontSize = 10
                $validationText.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
                $validationText.Visibility = "Collapsed"

                # Store reference to validation text for later updates
                $textbox | Add-Member -NotePropertyName "ValidationText" -NotePropertyValue $validationText

                # Add real-time validation for array parameters
                $textbox.Add_TextChanged({
                        param($sender, $e)
                        $text = $sender.Text.Trim()
                        $validationTextBlock = $sender.ValidationText

                        if ([string]::IsNullOrWhiteSpace($text)) {
                            $sender.BorderBrush = $null
                            $sender.BorderThickness = New-Object System.Windows.Thickness 1
                            $validationTextBlock.Visibility = "Collapsed"
                        }
                        else {
                            $testResult = Test-ArrayValue -Value $text -ItemType $sender.ArrayItems
                            if ($testResult.IsValid) {
                                $sender.BorderBrush = [System.Windows.Media.Brushes]::Green
                                $sender.BorderThickness = New-Object System.Windows.Thickness 2
                                $validationTextBlock.Visibility = "Collapsed"
                            }
                            else {
                                $sender.BorderBrush = [System.Windows.Media.Brushes]::Red
                                $sender.BorderThickness = New-Object System.Windows.Thickness 2
                                $validationTextBlock.Text = "✗ " + $testResult.ErrorMessage
                                $validationTextBlock.Foreground = [System.Windows.Media.Brushes]::Red
                                $validationTextBlock.Visibility = "Visible"
                            }
                        }
                    })

                $arrayPanel.Children.Add($textbox) | Out-Null
                $arrayPanel.Children.Add($hintText) | Out-Null
                $arrayPanel.Children.Add($validationText) | Out-Null

                [System.Windows.Controls.Grid]::SetColumn($arrayPanel, 1)
                $inputControl = $arrayPanel
                # Store reference to the textbox itself for value retrieval
                $inputControl | Add-Member -NotePropertyName "ValueControl" -NotePropertyValue $textbox
            }
            # Default: use textbox
            else {
                $textbox = New-Object System.Windows.Controls.TextBox
                $textbox.MinWidth = 360
                $textbox.HorizontalAlignment = "Stretch"
                $textbox.TextWrapping = "Wrap"
                $textbox.AcceptsReturn = ($param.in -eq "body")
                $textbox.Height = if ($param.in -eq "body") { 80 } else { 28 }
                if ($param.required) {
                    $textbox.Background = [System.Windows.Media.Brushes]::LightYellow
                }

                # Build enhanced tooltip with validation constraints
                $enhancedTooltip = $param.description
                if ($param.type -eq "integer" -or $param.type -eq "number") {
                    if ($param.minimum -ne $null) {
                        $enhancedTooltip += "`n`nMinimum: $($param.minimum)"
                    }
                    if ($param.maximum -ne $null) {
                        $enhancedTooltip += "`n`nMaximum: $($param.maximum)"
                    }
                    if ($param.format) {
                        $enhancedTooltip += "`n`nFormat: $($param.format)"
                    }
                }
                if ($param.default -ne $null) {
                    $enhancedTooltip += "`n`nDefault: $($param.default)"
                }
                $textbox.ToolTip = $enhancedTooltip

                # Store parameter metadata for validation
                if ($param.in -eq "body") {
                    $textbox.Tag = "body"
                }
                else {
                    # Store type and validation constraints
                    $textbox.Tag = @{
                        Type    = $param.type
                        Format  = $param.format
                        Minimum = $param.minimum
                        Maximum = $param.maximum
                    }
                }

                # Add real-time JSON validation for body parameters
                if ($param.in -eq "body") {
                    $textbox.Tag = "body"

                    # Create container for body textbox with character count
                    $bodyPanel = New-Object System.Windows.Controls.StackPanel
                    $bodyPanel.Orientation = "Vertical"

                    # Add line number and character count info
                    $infoText = New-Object System.Windows.Controls.TextBlock
                    $infoText.FontSize = 10
                    $infoText.Foreground = [System.Windows.Media.Brushes]::Gray
                    $infoText.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
                    $infoText.Text = "Lines: 0 | Characters: 0"

                    # Store reference for updates
                    $textbox | Add-Member -NotePropertyName "InfoText" -NotePropertyValue $infoText

                    $textbox.Add_TextChanged({
                            param($sender, $e)
                            $text = $sender.Text.Trim()
                            $infoTextBlock = $sender.InfoText

                            # Update character count and line count
                            $charCount = $sender.Text.Length
                            $lineCount = ($sender.Text -split "`n").Count
                            $infoTextBlock.Text = "Lines: $lineCount | Characters: $charCount"

                            if ([string]::IsNullOrWhiteSpace($text)) {
                                # Empty is OK - will be checked as required field
                                $sender.BorderBrush = $null
                                $sender.BorderThickness = New-Object System.Windows.Thickness 1
                                $infoTextBlock.Foreground = [System.Windows.Media.Brushes]::Gray
                            }
                            elseif (Test-JsonString -JsonString $text) {
                                # Valid JSON - green border and checkmark
                                $sender.BorderBrush = [System.Windows.Media.Brushes]::Green
                                $sender.BorderThickness = New-Object System.Windows.Thickness 2
                                $infoTextBlock.Foreground = [System.Windows.Media.Brushes]::Green
                            }
                            else {
                                # Invalid JSON - red border and X
                                $sender.BorderBrush = [System.Windows.Media.Brushes]::Red
                                $sender.BorderThickness = New-Object System.Windows.Thickness 2
                                $infoTextBlock.Foreground = [System.Windows.Media.Brushes]::Red
                            }
                        })

                    # Replace the textbox with the panel containing textbox and info
                    $bodyPanel.Children.Add($textbox) | Out-Null
                    $bodyPanel.Children.Add($infoText) | Out-Null
                    [System.Windows.Controls.Grid]::SetColumn($bodyPanel, 1)
                    $inputControl = $bodyPanel
                    # Store reference to the textbox for value retrieval
                    $inputControl | Add-Member -NotePropertyName "ValueControl" -NotePropertyValue $textbox
                }
                # Add real-time validation for numeric and format parameters
                elseif ($param.type -in @("integer", "number") -or $param.format -or $param.pattern) {
                    # Create container for textbox and validation message
                    $validatedPanel = New-Object System.Windows.Controls.StackPanel
                    $validatedPanel.Orientation = "Vertical"

                    $validationText = New-Object System.Windows.Controls.TextBlock
                    $validationText.FontSize = 10
                    $validationText.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
                    $validationText.Visibility = "Collapsed"

                    # Store reference to validation text
                    $textbox | Add-Member -NotePropertyName "ValidationText" -NotePropertyValue $validationText

                    $textbox.Add_TextChanged({
                            param($zsender, $e)
                            $text = $zsender.Text.Trim()
                            $validationTextBlock = $zsender.ValidationText

                            if ([string]::IsNullOrWhiteSpace($text)) {
                                $zsender.BorderBrush = $null
                                $zsender.BorderThickness = New-Object System.Windows.Thickness 1
                                $validationTextBlock.Visibility = "Collapsed"
                            }
                            else {
                                $isValid = $true
                                $errorMsg = ""

                                # Validate numeric types
                                if ($zsender.ParamType -in @("integer", "number")) {
                                    $testResult = Test-NumericValue -Value $text -Type $zsender.ParamType -Minimum $zsender.ParamMinimum -Maximum $zsender.ParamMaximum
                                    $isValid = $testResult.IsValid
                                    $errorMsg = $testResult.ErrorMessage
                                }
                                # Validate string formats
                                elseif ($zsender.ParamFormat -or $zsender.ParamPattern) {
                                    $testResult = Test-StringFormat -Value $text -Format $zsender.ParamFormat -Pattern $zsender.ParamPattern
                                    $isValid = $testResult.IsValid
                                    $errorMsg = $testResult.ErrorMessage
                                }

                                if ($isValid) {
                                    $zsender.BorderBrush = [System.Windows.Media.Brushes]::Green
                                    $zsender.BorderThickness = New-Object System.Windows.Thickness 2
                                    $validationTextBlock.Visibility = "Collapsed"
                                }
                                else {
                                    $zsender.BorderBrush = [System.Windows.Media.Brushes]::Red
                                    $zsender.BorderThickness = New-Object System.Windows.Thickness 2
                                    $validationTextBlock.Text = "✗ " + $errorMsg
                                    $validationTextBlock.Foreground = [System.Windows.Media.Brushes]::Red
                                    $validationTextBlock.Visibility = "Visible"
                                }
                            }
                        })

                    $validatedPanel.Children.Add($textbox) | Out-Null
                    $validatedPanel.Children.Add($validationText) | Out-Null
                    [System.Windows.Controls.Grid]::SetColumn($validatedPanel, 1)
                    $inputControl = $validatedPanel
                    # Store reference to the textbox for value retrieval
                    $inputControl | Add-Member -NotePropertyName "ValueControl" -NotePropertyValue $textbox
                }
                else {
                    [System.Windows.Controls.Grid]::SetColumn($textbox, 1)
                    $inputControl = $textbox
                }
            }

            $row.Children.Add($label) | Out-Null
            $row.Children.Add($inputControl) | Out-Null

            $parameterPanel.Children.Add($row) | Out-Null
            $paramInputs[$param.name] = $inputControl
            if ($param.in -eq "body") {
                $script:CurrentBodyControl = $inputControl
                $script:CurrentBodySchema = $param.schema
            }

            # Add event handlers for conditional parameter visibility updates
            # This infrastructure is ready for future use when API schema includes parameter dependencies
            try {
                $actualControl = $inputControl

                # Get the actual input control (unwrap if in panel)
                if ($inputControl.ValueControl) {
                    $actualControl = $inputControl.ValueControl
                }

                # Add change handler to trigger visibility updates
                if ($actualControl -is [System.Windows.Controls.ComboBox]) {
                    $actualControl.Add_SelectionChanged({
                            # Update-ParameterVisibility would be called here when dependencies exist
                            # Currently a no-op as API schema doesn't define conditional parameters
                        })
                }
                elseif ($actualControl -is [System.Windows.Controls.CheckBox]) {
                    $actualControl.Add_Checked({
                            # Update-ParameterVisibility would be called here when dependencies exist
                        })
                    $actualControl.Add_Unchecked({
                            # Update-ParameterVisibility would be called here when dependencies exist
                        })
                }
                elseif ($actualControl -is [System.Windows.Controls.TextBox]) {
                    # TextChanged would be too frequent; use LostFocus instead
                    $actualControl.Add_LostFocus({
                            # Update-ParameterVisibility would be called here when dependencies exist
                        })
                }
            }
            catch {
                # Silently continue if event handler setup fails
            }
        }

        $bodySchemaResolved = Resolve-SchemaReference -Schema $script:CurrentBodySchema -Definitions $script:Definitions
        $builderActive = $bodySchemaResolved -and $bodySchemaResolved.properties `
            -and ($bodySchemaResolved.properties.conversationFilters -or $bodySchemaResolved.properties.segmentFilters)

        if ($builderActive) {
            Set-FilterBuilderVisibility -Visible $true
            Update-FilterBuilderHint
        }
        else {
            Set-FilterBuilderVisibility -Visible $false
            if ($filterBuilderHintText) {
                $filterBuilderHintText.Text = ""
            }
        }

        $statusText.Text = "Provide values for the parameters and submit."
        if ($pendingFavoriteParameters) {
            Populate-ParameterValues -ParameterSet $pendingFavoriteParameters
            $pendingFavoriteParameters = $null
        }
        else {
            # Try to populate body parameter with example template if available
            $exampleBody = Get-ExamplePostBody -Path $selectedPath -Method $selectedMethod
            if ($exampleBody) {
                # Find the body parameter input and populate it
                foreach ($param in $params) {
                    if ($param.in -eq "body") {
                        $bodyInput = $paramInputs[$param.name]
                        if ($bodyInput) {
                            $bodyTextControl = if ($bodyInput.ValueControl) { $bodyInput.ValueControl } else { $bodyInput }
                            if ($bodyTextControl -is [System.Windows.Controls.TextBox]) {
                                $bodyTextControl.Text = $exampleBody
                            }
                            $statusText.Text = "Example body template loaded. Modify as needed and submit."
                        }
                        break
                    }
                }
            }
        }
        $responseSchema = Get-ResponseSchema -MethodObject $methodObject
        Update-SchemaList -Schema $responseSchema
    })

if ($favoritesList) {
    $favoritesList.Add_SelectionChanged({
            $favorite = $favoritesList.SelectedItem
            if (-not $favorite) { return }

            $favoritePath = $favorite.Path
            $favoriteMethod = $favorite.Method
            $favoriteGroup = if ($favorite.Group) { $favorite.Group } else { Get-GroupForPath -Path $favoritePath }

            if ($favoriteGroup -and $GroupMap.ContainsKey($favoriteGroup)) {
                $groupCombo.SelectedItem = $favoriteGroup
            }

            if ($favoritePath) {
                $pathCombo.SelectedItem = $favoritePath
            }

            if ($favoriteMethod) {
                $pendingFavoriteParameters = $favorite.Parameters
                $methodCombo.SelectedItem = $favoriteMethod
            }

            $statusText.Text = "Favorite '$($favorite.Name)' loaded."
            Add-LogEntry "Favorite applied: $($favorite.Name)"
        })
}

if ($saveFavoriteButton) {
    $saveFavoriteButton.Add_Click({
            $favoriteName = if ($favoriteNameInput) { $favoriteNameInput.Text.Trim() } else { "" }

            if (-not $favoriteName) {
                $statusText.Text = "Enter a name before saving a favorite."
                return
            }

            $selectedPath = $pathCombo.SelectedItem
            $selectedMethod = $methodCombo.SelectedItem
            if (-not $selectedPath -or -not $selectedMethod) {
                $statusText.Text = "Pick an endpoint and method before saving."
                return
            }

            $pathObject = Get-PathObject -ApiPaths $ApiPaths -Path $selectedPath
            $methodObject = Get-MethodObject -PathObject $pathObject -MethodName $selectedMethod
            if (-not $methodObject) {
                $statusText.Text = "Unable to read the selected method metadata."
                return
            }

            $params = $methodObject.parameters
            $paramData = @()
            foreach ($param in $params) {
                $value = ""
                $input = $paramInputs[$param.name]
                if ($input) {
                    $value = $input.Text
                }

                $paramData += [PSCustomObject]@{
                    name  = $param.name
                    in    = $param.in
                    value = $value
                }
            }

            $favoriteRecord = [PSCustomObject]@{
                Name       = $favoriteName
                Path       = $selectedPath
                Method     = $selectedMethod
                Group      = Get-GroupForPath -Path $selectedPath
                Parameters = $paramData
                Timestamp  = (Get-Date).ToString("o")
            }

            $filteredFavorites = [System.Collections.ArrayList]::new()
            foreach ($fav in $Favorites) {
                if ($fav.Name -ne $favoriteRecord.Name) {
                    $filteredFavorites.Add($fav) | Out-Null
                }
            }

            $filteredFavorites.Add($favoriteRecord) | Out-Null
            $Favorites = $filteredFavorites

            Save-FavoritesToDisk -Path $FavoritesFile -Favorites $Favorites
            Refresh-FavoritesList

            if ($favoriteNameInput) {
                $favoriteNameInput.Text = ""
            }

            $statusText.Text = "Favorite '$favoriteName' saved."
            Add-LogEntry "Saved favorite '$favoriteName'."
        })
}

if ($toggleResponseViewButton) {
    $toggleResponseViewButton.Add_Click({
            if ($script:ResponseViewMode -eq "Formatted") {
                # Switch to raw
                $script:ResponseViewMode = "Raw"
                if ($script:LastResponseRaw) {
                    $statusCode = if ($responseBox.Text -match "Status\s+(\d+)") { $matches[1] } else { "" }
                    if ($statusCode) {
                        $newLine = [System.Environment]::NewLine
                        $responseBox.Text = "Status $statusCode (Raw):$newLine$($script:LastResponseRaw)"
                    }
                    else {
                        $responseBox.Text = $script:LastResponseRaw
                    }
                }
                Add-LogEntry "Response view switched to Raw."
            }
            else {
                # Switch to formatted
                $script:ResponseViewMode = "Formatted"
                if ($script:LastResponseText) {
                    $statusCode = if ($responseBox.Text -match "Status\s+(\d+)") { $matches[1] } else { "" }
                    if ($statusCode) {
                        $newLine = [System.Environment]::NewLine
                        $responseBox.Text = "Status ${statusCode}:$newLine$($script:LastResponseText)"
                    }
                    else {
                        $responseBox.Text = $script:LastResponseText
                    }
                }
                Add-LogEntry "Response view switched to Formatted."
            }
        })
}

if ($inspectResponseButton) {
    $inspectResponseButton.Add_Click({
            Show-DataInspector -JsonText $script:LastResponseRaw
        })
}

if ($settingsMenuItem) {
    $settingsMenuItem.Add_Click({
            $selectedFile = Show-SettingsDialog -CurrentJsonPath $script:CurrentJsonPath
            if ($selectedFile) {
                Invoke-ReloadEndpoints -JsonPath $selectedFile
            }
        })
}

if ($appSettingsMenuItem) {
    $appSettingsMenuItem.Add_Click({
            $result = Show-AppSettingsDialog -CurrentRegion $script:Region -CurrentOAuthType $script:OAuthType -CurrentToken (Get-ExplorerAccessToken)
            if (-not $result) { return }

            Set-ExplorerRegion -Region ([string]$result.Region)
            $saved = Load-ExplorerSettings
            $saved.Region = $script:Region
            Save-ExplorerSettings -Settings $saved

            $tokenValue = if ($result.Token) { [string]$result.Token } else { '' }
            if ([string]::IsNullOrWhiteSpace($tokenValue)) {
                Set-ExplorerAccessToken -Token '' -OAuthType '(none)'
            }
            else {
                $type = if ($result.OAuthType) { [string]$result.OAuthType } else { 'Manual' }
                Set-ExplorerAccessToken -Token $tokenValue -OAuthType $type
            }

            Update-AuthUiState
            Add-LogEntry "App settings updated (region=$($script:Region), oauth=$($script:OAuthType))."
        })
}

if ($traceMenuItem) {
    try { $traceMenuItem.IsChecked = [bool]$script:TraceEnabled } catch { }
    $traceMenuItem.Add_Click({
            try {
                $enabled = [bool]$traceMenuItem.IsChecked
                if ($enabled) {
                    $script:TraceEnabled = $true
                    $env:GENESYS_API_EXPLORER_TRACE = '1'
                    if ([string]::IsNullOrWhiteSpace($script:TraceLogPath)) {
                        $script:TraceLogPath = Get-TraceLogPath
                    }
                    Write-TraceLog "Tracing enabled from Settings menu."
                    Add-LogEntry "Tracing enabled. Log: $script:TraceLogPath"
                    try { $traceMenuItem.ToolTip = "Tracing enabled. Log: $script:TraceLogPath" } catch { }
                }
                else {
                    Write-TraceLog "Tracing disabled from Settings menu."
                    $script:TraceEnabled = $false
                    $env:GENESYS_API_EXPLORER_TRACE = '0'
                    Add-LogEntry "Tracing disabled."
                    try { $traceMenuItem.ToolTip = "Tracing disabled. Toggle to write a temp log file." } catch { }
                }
            }
            catch {
                Add-LogEntry "Failed to toggle tracing: $($_.Exception.Message)"
            }
        })
}

if ($resetEndpointsMenuItem) {
    $resetEndpointsMenuItem.Add_Click({
            $defaultPath = Join-Path -Path $ScriptRoot -ChildPath "GenesysCloudAPIEndpoints.json"
            if (Test-Path -Path $defaultPath) {
                if (Invoke-ReloadEndpoints -JsonPath $defaultPath) {
                    [System.Windows.MessageBox]::Show("Endpoints reset to default configuration.", "Reset Complete", "OK", "Information")
                }
            }
            else {
                [System.Windows.MessageBox]::Show("Default endpoints file not found at: $defaultPath", "File Not Found", "OK", "Error")
            }
        })
}

if ($loginButton) {
    $loginButton.Add_Click({
            $newToken = Show-LoginWindow
            if ($newToken) {
                if ($script:LastLoginRegion) {
                    Set-ExplorerRegion -Region ([string]$script:LastLoginRegion)
                    $saved = Load-ExplorerSettings
                    $saved.Region = $script:Region
                    Save-ExplorerSettings -Settings $saved
                }

                $oauthType = if ($script:LastLoginOAuthType) { [string]$script:LastLoginOAuthType } else { 'Login' }
                Set-ExplorerAccessToken -Token ([string]$newToken) -OAuthType $oauthType
                Update-AuthUiState
                Add-LogEntry "Token updated via Login ($oauthType)."
            }
        })
}

if ($testTokenButton) {
    $testTokenButton.Add_Click({
            $token = Get-ExplorerAccessToken
            if (-not $token) {
                $script:TokenValidated = $false
                Update-AuthUiState
                Add-LogEntry "Token test failed: No token provided."
                return
            }

            $testTokenButton.IsEnabled = $false
            if ($tokenStatusText) {
                $tokenStatusText.Text = "Testing..."
                $tokenStatusText.Foreground = "Gray"
            }
            Add-LogEntry "Testing OAuth token validity..."

            try {
                # Test token with a simple API call to /api/v2/users/me
                $headers = @{
                    "Authorization" = "Bearer $token"
                    "Content-Type"  = "application/json"
                }
                $testUrl = "$ApiBaseUrl/api/v2/users/me"

                $response = Invoke-GCRequest -Method GET -Uri $testUrl -Headers $headers -AsResponse

                if ($response.StatusCode -eq 200) {
                    $script:TokenValidated = $true
                    Update-AuthUiState
                    Add-LogEntry "Token test successful: Token is valid."
                }
                else {
                    $script:TokenValidated = $false
                    Update-AuthUiState
                    Add-LogEntry "Token test returned unexpected status: $($response.StatusCode)"
                }
            }
            catch {
                $script:TokenValidated = $false
                Update-AuthUiState
                $errorMsg = $_.Exception.Message
                Add-LogEntry "Token test failed: $errorMsg"
            }
            finally {
                $testTokenButton.IsEnabled = $true
            }
        })
}

if ($helpMenuItem) {
    $helpMenuItem.Add_Click({
            Show-HelpWindow
        })
}

if ($helpDevLink) {
    $helpDevLink.Add_Click({
            Launch-Url -Url $DeveloperDocsUrl
        })
}

if ($helpSupportLink) {
    $helpSupportLink.Add_Click({
            Launch-Url -Url $SupportDocsUrl
        })
}

if ($fetchJobResultsButton) {
    $fetchJobResultsButton.Add_Click({
            Fetch-JobResults -Force
        })
}

if ($exportJobResultsButton) {
    $exportJobResultsButton.Add_Click({
            if (-not $JobTracker.ResultFile -or -not (Test-Path -Path $JobTracker.ResultFile)) {
                $statusText.Text = "No job result file to export."
                return
            }

            $dialog = New-Object Microsoft.Win32.SaveFileDialog
            $dialog.Filter = "JSON Files (*.json)|*.json|All Files (*.*)|*.*"
            $dialog.Title = "Export Job Results"
            $dialog.FileName = [System.IO.Path]::GetFileName($JobTracker.ResultFile)
            if ($dialog.ShowDialog() -eq $true) {
                Copy-Item -Path $JobTracker.ResultFile -Destination $dialog.FileName -Force
                $statusText.Text = "Job results exported to $($dialog.FileName)"
                Add-LogEntry "Job results exported to $($dialog.FileName)"
            }
        })
}

if ($runConversationReportButton) {
    $runConversationReportButton.Add_Click({
            $convId = if ($conversationReportIdInput) { $conversationReportIdInput.Text.Trim() } else { "" }

            if (-not $convId) {
                if ($conversationReportStatus) {
                    $conversationReportStatus.Text = "Please enter a conversation ID."
                }
                Add-LogEntry "Conversation report blocked: no conversation ID."
                return
            }

            $token = Get-ExplorerAccessToken
            if (-not $token) {
                if ($conversationReportStatus) {
                    $conversationReportStatus.Text = "Please provide an OAuth token."
                }
                Add-LogEntry "Conversation report blocked: no OAuth token."
                return
            }

            $headers = @{
                "Content-Type"  = "application/json"
                "Authorization" = "Bearer $token"
            }

            # Reset progress UI
            if ($conversationReportProgressBar) {
                $conversationReportProgressBar.Value = 0
            }
            if ($conversationReportProgressText) {
                $conversationReportProgressText.Text = "Initializing..."
            }
            if ($conversationReportEndpointLog) {
                $conversationReportEndpointLog.Text = ""
            }
            if ($conversationReportStatus) {
                $conversationReportStatus.Text = "Fetching report..."
            }
            Add-LogEntry "Generating conversation report for: $convId"

            try {
                # Define progress callback to update UI
                $progressCallback = {
                    param($PercentComplete, $Status, $EndpointName, $IsStarting, $IsSuccess, $IsOptional)

                    if ($conversationReportProgressBar) {
                        $conversationReportProgressBar.Value = $PercentComplete
                    }
                    if ($conversationReportProgressText) {
                        $conversationReportProgressText.Text = $Status
                    }
                    if ($conversationReportEndpointLog) {
                        $timestamp = (Get-Date).ToString("HH:mm:ss")
                        if ($IsStarting) {
                            $logLine = "[$timestamp] Querying: $EndpointName..."
                        }
                        elseif ($IsSuccess) {
                            $logLine = "[$timestamp] ✓ $EndpointName - Retrieved successfully"
                        }
                        elseif ($IsOptional) {
                            $logLine = "[$timestamp] ⚠ $EndpointName - Optional, not available"
                        }
                        else {
                            $logLine = "[$timestamp] ✗ $EndpointName - Failed"
                        }
                        $conversationReportEndpointLog.AppendText("$logLine`r`n")
                        $conversationReportEndpointLog.ScrollToEnd()
                    }
                    # Force UI update
                    [System.Windows.Forms.Application]::DoEvents()
                }

                $script:LastConversationReport = Get-ConversationReport -ConversationId $convId -Headers $headers -BaseUrl $ApiBaseUrl -ProgressCallback $progressCallback
                $script:LastConversationReportJson = $script:LastConversationReport | ConvertTo-Json -Depth 20

                $reportText = Format-ConversationReportText -Report $script:LastConversationReport

                if ($conversationReportText) {
                    $conversationReportText.Text = $reportText
                }

                if ($inspectConversationReportButton) {
                    $inspectConversationReportButton.IsEnabled = $true
                }
                if ($exportConversationReportJsonButton) {
                    $exportConversationReportJsonButton.IsEnabled = $true
                }
                if ($exportConversationReportTextButton) {
                    $exportConversationReportTextButton.IsEnabled = $true
                }

                # Complete progress bar
                if ($conversationReportProgressBar) {
                    $conversationReportProgressBar.Value = 100
                }
                if ($conversationReportProgressText) {
                    $conversationReportProgressText.Text = "Complete"
                }

                $errorCount = if ($script:LastConversationReport.Errors) { $script:LastConversationReport.Errors.Count } else { 0 }
                if ($errorCount -gt 0) {
                    if ($conversationReportStatus) {
                        $conversationReportStatus.Text = "Report generated with $errorCount error(s)."
                    }
                    Add-LogEntry "Conversation report completed with $errorCount error(s)."
                }
                else {
                    if ($conversationReportStatus) {
                        $conversationReportStatus.Text = "Report generated successfully."
                    }
                    Add-LogEntry "Conversation report generated successfully."
                }
            }
            catch {
                if ($conversationReportStatus) {
                    $conversationReportStatus.Text = "Report failed: $($_.Exception.Message)"
                }
                Add-LogEntry "Conversation report failed: $($_.Exception.Message)"
            }
        })
}

if ($inspectConversationReportButton) {
    $inspectConversationReportButton.Add_Click({
            if ($script:LastConversationReport) {
                Show-ConversationTimelineReport -Report $script:LastConversationReport
            }
            else {
                Add-LogEntry "No conversation report data to inspect."
            }
        })
}

if ($exportConversationReportJsonButton) {
    $exportConversationReportJsonButton.Add_Click({
            if (-not $script:LastConversationReportJson) {
                if ($conversationReportStatus) {
                    $conversationReportStatus.Text = "No report data to export."
                }
                return
            }

            $dialog = New-Object Microsoft.Win32.SaveFileDialog
            $dialog.Filter = "JSON Files (*.json)|*.json|All Files (*.*)|*.*"
            $dialog.Title = "Export Conversation Report JSON"
            $dialog.FileName = "ConversationReport_$($script:LastConversationReport.ConversationId).json"
            if ($dialog.ShowDialog() -eq $true) {
                $script:LastConversationReportJson | Out-File -FilePath $dialog.FileName -Encoding utf8
                if ($conversationReportStatus) {
                    $conversationReportStatus.Text = "JSON exported to $($dialog.FileName)"
                }
                Add-LogEntry "Conversation report JSON exported to $($dialog.FileName)"
            }
        })
}

if ($exportConversationReportTextButton) {
    $exportConversationReportTextButton.Add_Click({
            if (-not $script:LastConversationReport) {
                if ($conversationReportStatus) {
                    $conversationReportStatus.Text = "No report data to export."
                }
                return
            }

            $dialog = New-Object Microsoft.Win32.SaveFileDialog
            $dialog.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
            $dialog.Title = "Export Conversation Report Text"
            $dialog.FileName = "ConversationReport_$($script:LastConversationReport.ConversationId).txt"
            if ($dialog.ShowDialog() -eq $true) {
                $reportText = Format-ConversationReportText -Report $script:LastConversationReport
                $reportText | Out-File -FilePath $dialog.FileName -Encoding utf8
                if ($conversationReportStatus) {
                    $conversationReportStatus.Text = "Text exported to $($dialog.FileName)"
                }
                Add-LogEntry "Conversation report text exported to $($dialog.FileName)"
            }
        })
}

if ($requestHistoryList) {
    $requestHistoryList.ItemsSource = $script:RequestHistory

    $requestHistoryList.Add_SelectionChanged({
            if ($requestHistoryList.SelectedItem) {
                $replayRequestButton.IsEnabled = $true
            }
            else {
                $replayRequestButton.IsEnabled = $false
            }
        })
}

if ($replayRequestButton) {
    $replayRequestButton.Add_Click({
            $selectedHistory = $requestHistoryList.SelectedItem
            if (-not $selectedHistory) {
                Add-LogEntry "No request selected to replay."
                return
            }

            # Set the group, path, and method
            $groupCombo.SelectedItem = $selectedHistory.Group
            $pathCombo.SelectedItem = $selectedHistory.Path
            $methodCombo.SelectedItem = $selectedHistory.Method

            # Restore parameters
            if ($selectedHistory.Parameters) {
                # Use Dispatcher.Invoke to ensure UI is updated before setting parameters
                $Window.Dispatcher.Invoke([Action] {
                        foreach ($paramName in $selectedHistory.Parameters.Keys) {
                            if ($paramInputs.ContainsKey($paramName)) {
                                Set-ParameterControlValue -Control $paramInputs[$paramName] -Value $selectedHistory.Parameters[$paramName]
                            }
                        }
                    }, [System.Windows.Threading.DispatcherPriority]::Background)
            }

            Add-LogEntry "Request loaded from history: $($selectedHistory.Method) $($selectedHistory.Path)"
            $statusText.Text = "Request loaded from history."
        })
}

if ($clearHistoryButton) {
    $clearHistoryButton.Add_Click({
            $result = [System.Windows.MessageBox]::Show(
                "Are you sure you want to clear all request history?",
                "Clear History",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question
            )

            if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
                $script:RequestHistory.Clear()
                Add-LogEntry "Request history cleared."
                $statusText.Text = "History cleared."
            }
        })
}

if ($insightMetricsList) {
    $insightMetricsList.ItemsSource = $script:InsightMetrics
}
if ($insightDrilldownsList) {
    $insightDrilldownsList.ItemsSource = $script:InsightDrilldowns
}
if ($insightBriefingsList) {
    $insightBriefingsList.ItemsSource = $script:InsightBriefingsHistory
}
if ($insightBriefingPathText -and $insightBriefingRoot) {
    $insightBriefingPathText.Text = "Briefings folder: $insightBriefingRoot"
}

function Refresh-InsightBriefingHistory {
    $outputDir = Get-InsightBriefingDirectory
    $indexPath = Join-Path -Path $outputDir -ChildPath 'index.json'

    $script:InsightBriefingsHistory.Clear()

    if (-not (Test-Path -LiteralPath $indexPath)) { return }

    try {
        $raw = Get-Content -LiteralPath $indexPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return }

        $entries = @($raw | ConvertFrom-Json)
        foreach ($entry in $entries) {
            $timestamp = if ($entry.TimestampUtc) { [string]$entry.TimestampUtc } else { '' }
            $packLabel = if ($entry.PackName) { "$($entry.PackName)" } elseif ($entry.PackId) { "$($entry.PackId)" } else { '' }

            $snapshotLeaf = [string]$entry.Snapshot
            $htmlLeaf = [string]$entry.Html

            $historyEntry = [pscustomobject]@{
                Timestamp    = $timestamp
                Pack         = $packLabel
                Snapshot     = $snapshotLeaf
                Html         = $htmlLeaf
                SnapshotPath = if ($snapshotLeaf) { Join-Path -Path $outputDir -ChildPath $snapshotLeaf } else { $null }
                HtmlPath     = if ($htmlLeaf) { Join-Path -Path $outputDir -ChildPath $htmlLeaf } else { $null }
            }
            $script:InsightBriefingsHistory.Add($historyEntry) | Out-Null
        }
    }
    catch {
        Add-LogEntry "Failed to load insight briefing index: $($_.Exception.Message)"
    }
}

if ($refreshInsightBriefingsButton) {
    $refreshInsightBriefingsButton.Add_Click({
            Refresh-InsightBriefingHistory
        })
}

if ($openBriefingsFolderButton) {
    $openBriefingsFolderButton.Add_Click({
            try {
                $dir = Get-InsightBriefingDirectory
                if ($dir) { Start-Process -FilePath $dir }
            }
            catch {}
        })
}

if ($insightBriefingsList) {
    $insightBriefingsList.Add_SelectionChanged({
            $selected = $insightBriefingsList.SelectedItem
            $has = ($null -ne $selected)
            if ($openBriefingHtmlButton) { $openBriefingHtmlButton.IsEnabled = $has -and $selected.HtmlPath }
            if ($openBriefingSnapshotButton) { $openBriefingSnapshotButton.IsEnabled = $has -and $selected.SnapshotPath }
        })
}

if ($openBriefingHtmlButton) {
    $openBriefingHtmlButton.Add_Click({
            $selected = if ($insightBriefingsList) { $insightBriefingsList.SelectedItem } else { $null }
            if ($selected -and $selected.HtmlPath -and (Test-Path -LiteralPath $selected.HtmlPath)) {
                Start-Process -FilePath $selected.HtmlPath
            }
        })
}

if ($openBriefingSnapshotButton) {
    $openBriefingSnapshotButton.Add_Click({
            $selected = if ($insightBriefingsList) { $insightBriefingsList.SelectedItem } else { $null }
            if ($selected -and $selected.SnapshotPath -and (Test-Path -LiteralPath $selected.SnapshotPath)) {
                Start-Process -FilePath $selected.SnapshotPath
            }
        })
}

	Refresh-InsightBriefingHistory
	
	if (-not $script:InsightParamInputs) { $script:InsightParamInputs = @{} }
	$script:InsightPackCatalog = @()

	function Refresh-InsightPackCatalogUi {
	    if (-not $insightPackCombo) { return }
	    $script:InsightPackCatalog = @(Get-InsightPackCatalog -PackDirectory $insightPackRoot -LegacyPackDirectory $legacyInsightPackRoot)
	    $insightPackCombo.ItemsSource = $script:InsightPackCatalog
	    $insightPackCombo.DisplayMemberPath = 'Display'

	    $packExists = Test-Path -LiteralPath $insightPackRoot
	    $legacyExists = Test-Path -LiteralPath $legacyInsightPackRoot
	    $count = if ($script:InsightPackCatalog) { $script:InsightPackCatalog.Count } else { 0 }

	    if ($count -le 0) {
	        $msg = "No insight packs found. Checked:`n- $insightPackRoot (exists=$packExists)`n- $legacyInsightPackRoot (exists=$legacyExists)"
	        if ($insightPackDescriptionText) { $insightPackDescriptionText.Text = $msg }
	        Add-LogEntry $msg
	        Add-LogEntry "Insight pack discovery context: workspaceRoot=$workspaceRoot; scriptRoot=$ScriptRoot; override=$([string]$env:GENESYS_API_EXPLORER_PACKS_DIR)"

	        if ($script:InsightPackCatalogErrors -and $script:InsightPackCatalogErrors.Count -gt 0) {
	            Add-LogEntry "Insight pack parse errors (first 3):"
	            foreach ($line in @($script:InsightPackCatalogErrors | Select-Object -First 3)) {
	                Add-LogEntry "  $line"
	            }
	        }
	    }
	    else {
	        if ($insightPackDescriptionText) {
	            $insightPackDescriptionText.Text = "Loaded $count pack(s) from:`n- $insightPackRoot`n- $legacyInsightPackRoot"
	        }
	    }
	}

	if ($insightPackCombo) {
	    Refresh-InsightPackCatalogUi

	    $insightPackCombo.Add_SelectionChanged({
	            $selected = $insightPackCombo.SelectedItem
	            if (-not $selected) { return }

            if ($insightPackDescriptionText) {
                $insightPackDescriptionText.Text = if ($selected.Description) { $selected.Description } else { $selected.Id }
            }
            if ($insightPackMetaText) {
                $tags = if ($selected.Tags -and $selected.Tags.Count -gt 0) { ($selected.Tags -join ', ') } else { '' }
                $scopes = if ($selected.Scopes -and $selected.Scopes.Count -gt 0) { ($selected.Scopes -join ', ') } else { '' }
                $endpoints = if ($selected.Endpoints -and $selected.Endpoints.Count -gt 0) { ($selected.Endpoints -join "`n") } else { '' }

                $lines = New-Object System.Collections.Generic.List[string]
                if ($selected.Version) { $lines.Add("Version: $($selected.Version)") | Out-Null }
                if ($selected.Maturity) { $lines.Add("Maturity: $($selected.Maturity)") | Out-Null }
                if ($selected.Owner) { $lines.Add("Owner: $($selected.Owner)") | Out-Null }
                if ($null -ne $selected.ExpectedRuntimeSec) { $lines.Add("Expected runtime: $($selected.ExpectedRuntimeSec)s") | Out-Null }
                if ($tags) { $lines.Add("Tags: $tags") | Out-Null }
                if ($scopes) { $lines.Add("Scopes: $scopes") | Out-Null }
                if ($selected.FullPath) { $lines.Add("Path: $($selected.FullPath)") | Out-Null }
                if ($endpoints) {
                    $lines.Add("Endpoints:") | Out-Null
                    $lines.Add($endpoints) | Out-Null
                }
                if ($selected.Examples -and $selected.Examples.Count -gt 0) {
                    $lines.Add("Examples:") | Out-Null
                    foreach ($ex in @($selected.Examples)) {
                        if (-not $ex) { continue }
                        $note = if ($ex.Notes) { " — $($ex.Notes)" } else { '' }
                        $lines.Add("  - $($ex.Title)$note") | Out-Null
                    }
                }
                $insightPackMetaText.Text = ($lines -join "`n")
            }
            if ($insightPackParametersPanel) {
                Render-InsightPackParameters -Pack $selected.Pack -Panel $insightPackParametersPanel
            }

            if ($insightPackWarningsText) {
                $warnings = New-Object System.Collections.Generic.List[string]
                if ($selected.Scopes -and $selected.Scopes.Count -gt 0) {
                    $warnings.Add("Requires OAuth scopes: $($selected.Scopes -join ', ')") | Out-Null
                }
                if ($warnings.Count -eq 0) {
                    $warnings.Add("No required scopes declared by this pack.") | Out-Null
                }

                # Optional strict validation (surface issues early without blocking selection)
                try {
                    Ensure-OpsInsightsModuleLoaded
                    $strict = $false
                    if ($strictInsightValidationCheckbox) { $strict = [bool]$strictInsightValidationCheckbox.IsChecked }
                    $validation = Test-GCInsightPack -PackPath $selected.FullPath -Strict:$strict
                    if ($validation -and -not $validation.IsValid -and $validation.Errors -and $validation.Errors.Count -gt 0) {
                        $warnings.Add("Validation: $($validation.Errors[0])") | Out-Null
                    }
                }
                catch {
                    $warnings.Add("Validation: $($_.Exception.Message)") | Out-Null
                }
                $insightPackWarningsText.Text = ($warnings -join "`n")
            }

            if ($insightPackExampleCombo) {
                $insightPackExampleCombo.ItemsSource = @($selected.Examples)
                $insightPackExampleCombo.DisplayMemberPath = 'Title'
                $insightPackExampleCombo.IsEnabled = ($selected.Examples -and $selected.Examples.Count -gt 0)
                if ($insightPackExampleCombo.IsEnabled) { $insightPackExampleCombo.SelectedIndex = 0 }
            }
            if ($loadInsightPackExampleButton) {
                $loadInsightPackExampleButton.IsEnabled = ($selected.Examples -and $selected.Examples.Count -gt 0)
            }

            # Apply global defaults (only if the pack defines these params and the controls are empty)
            if ($script:InsightParamInputs.ContainsKey('startDate') -and $insightGlobalStartInput -and -not [string]::IsNullOrWhiteSpace($insightGlobalStartInput.Text)) {
                $ctrl = $script:InsightParamInputs['startDate']
                if ($ctrl -is [System.Windows.Controls.TextBox] -and [string]::IsNullOrWhiteSpace($ctrl.Text)) {
                    $ctrl.Text = $insightGlobalStartInput.Text.Trim()
                }
            }
            if ($script:InsightParamInputs.ContainsKey('endDate') -and $insightGlobalEndInput -and -not [string]::IsNullOrWhiteSpace($insightGlobalEndInput.Text)) {
                $ctrl = $script:InsightParamInputs['endDate']
                if ($ctrl -is [System.Windows.Controls.TextBox] -and [string]::IsNullOrWhiteSpace($ctrl.Text)) {
                    $ctrl.Text = $insightGlobalEndInput.Text.Trim()
                }
            }
        })

    if ($script:InsightPackCatalog.Count -gt 0) {
        $insightPackCombo.SelectedIndex = 0
    }
}

if ($insightTimePresetCombo) {
    $insightTimePresetCombo.ItemsSource = @(Get-InsightTimePresets)
    $insightTimePresetCombo.DisplayMemberPath = 'Name'
    $insightTimePresetCombo.SelectedValuePath = 'Key'
    $insightTimePresetCombo.SelectedValue = 'last7'
}

if ($insightBaselineModeCombo) {
    $insightBaselineModeCombo.ItemsSource = @(
        [pscustomobject]@{ Key = 'PreviousWindow'; Name = 'Prev window' },
        [pscustomobject]@{ Key = 'ShiftDays7'; Name = 'Shift -7 days' },
        [pscustomobject]@{ Key = 'ShiftDays30'; Name = 'Shift -30 days' }
    )
    $insightBaselineModeCombo.DisplayMemberPath = 'Name'
    $insightBaselineModeCombo.SelectedValuePath = 'Key'
    $insightBaselineModeCombo.SelectedValue = 'PreviousWindow'
}

function Apply-InsightTimePresetToUi {
    param(
        [Parameter(Mandatory)]
        [string]$PresetKey
    )

    $window = Resolve-InsightUtcWindowFromPreset -PresetKey $PresetKey
    $startIso = $window.StartUtc.ToString('o')
    $endIso = $window.EndUtc.ToString('o')

    if ($insightGlobalStartInput) { $insightGlobalStartInput.Text = $startIso }
    if ($insightGlobalEndInput) { $insightGlobalEndInput.Text = $endIso }

    if ($script:InsightParamInputs.ContainsKey('startDate')) {
        $ctrl = $script:InsightParamInputs['startDate']
        if ($ctrl -is [System.Windows.Controls.TextBox]) { $ctrl.Text = $startIso }
    }
    if ($script:InsightParamInputs.ContainsKey('endDate')) {
        $ctrl = $script:InsightParamInputs['endDate']
        if ($ctrl -is [System.Windows.Controls.TextBox]) { $ctrl.Text = $endIso }
    }
}

if ($insightTimePresetCombo -and $insightGlobalStartInput -and $insightGlobalEndInput) {
    if ([string]::IsNullOrWhiteSpace($insightGlobalStartInput.Text) -and [string]::IsNullOrWhiteSpace($insightGlobalEndInput.Text)) {
        try {
            $key = [string]$insightTimePresetCombo.SelectedValue
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                Apply-InsightTimePresetToUi -PresetKey $key
            }
        }
        catch {
            # ignore default preset failures
        }
    }
}

if ($applyInsightTimePresetButton) {
    $applyInsightTimePresetButton.Add_Click({
            try {
                $key = if ($insightTimePresetCombo) { [string]$insightTimePresetCombo.SelectedValue } else { '' }
                if ([string]::IsNullOrWhiteSpace($key)) { return }
                Apply-InsightTimePresetToUi -PresetKey $key
            }
            catch {
                Add-LogEntry "Failed to apply time preset: $($_.Exception.Message)"
            }
	        })
	}

	if ($refreshInsightPacksButton) {
	    $refreshInsightPacksButton.Add_Click({
	            Refresh-InsightPackCatalogUi
	        })
	}

if ($loadInsightPackExampleButton) {
    $loadInsightPackExampleButton.Add_Click({
            try {
                if (-not $insightPackExampleCombo -or -not $insightPackExampleCombo.SelectedItem) { return }
                $example = $insightPackExampleCombo.SelectedItem
                if (-not $example -or -not $example.Parameters) { return }

                $paramObject = $example.Parameters
                foreach ($prop in @($paramObject.PSObject.Properties)) {
                    $name = $prop.Name
                    $value = $prop.Value
                    if (-not $script:InsightParamInputs.ContainsKey($name)) { continue }
                    $ctrl = $script:InsightParamInputs[$name]

                    if ($ctrl -is [System.Windows.Controls.CheckBox]) {
                        $ctrl.IsChecked = [bool]$value
                        continue
                    }
                    if ($ctrl -is [System.Windows.Controls.TextBox]) {
                        if ($null -eq $value) { $ctrl.Text = '' }
                        else { $ctrl.Text = [string]$value }
                    }
                }
            }
            catch {
                Add-LogEntry "Failed to load pack example: $($_.Exception.Message)"
            }
        })
}

function Run-SelectedInsightPack {
    param(
        [Parameter(Mandatory)]
        [bool]$Compare,

        [Parameter()]
        [bool]$DryRun = $false
    )

    if (-not $insightPackCombo -or -not $insightPackCombo.SelectedItem) {
        throw "Select an Insight Pack first."
    }

    $selected = $insightPackCombo.SelectedItem
    $packPath = $selected.FullPath
    if (-not (Test-Path -LiteralPath $packPath)) {
        $packPath = Get-InsightPackPath -FileName $selected.FileName
    }

    Ensure-OpsInsightsModuleLoaded
    Ensure-OpsInsightsContext
    $packParams = Get-InsightPackParameterValues

    $useCache = $false
    if ($useInsightCacheCheckbox) { $useCache = [bool]$useInsightCacheCheckbox.IsChecked }
    $strictValidate = $false
    if ($strictInsightValidationCheckbox) { $strictValidate = [bool]$strictInsightValidationCheckbox.IsChecked }
    $cacheTtl = 60
    if ($insightCacheTtlInput -and -not [string]::IsNullOrWhiteSpace($insightCacheTtlInput.Text)) {
        try { $cacheTtl = [int]$insightCacheTtlInput.Text.Trim() } catch { $cacheTtl = 60 }
    }
    if ($cacheTtl -lt 1) { $cacheTtl = 1 }

    $cacheDir = Join-Path -Path $UserProfileBase -ChildPath "GenesysApiExplorerCache\\OpsInsights"
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    if ($Compare) {
        $baselineKey = if ($insightBaselineModeCombo) { [string]$insightBaselineModeCombo.SelectedValue } else { 'PreviousWindow' }
        if ($baselineKey -eq 'ShiftDays7') {
            $result = Invoke-GCInsightPackCompare -PackPath $packPath -Parameters $packParams -BaselineMode ShiftDays -BaselineShiftDays 7 -StrictValidation:$strictValidate
        }
        elseif ($baselineKey -eq 'ShiftDays30') {
            $result = Invoke-GCInsightPackCompare -PackPath $packPath -Parameters $packParams -BaselineMode ShiftDays -BaselineShiftDays 30 -StrictValidation:$strictValidate
        }
        else {
            $result = Invoke-GCInsightPackCompare -PackPath $packPath -Parameters $packParams -BaselineMode PreviousWindow -StrictValidation:$strictValidate
        }
    }
    else {
        if ($DryRun) {
            $result = Invoke-GCInsightPack -PackPath $packPath -Parameters $packParams -DryRun -StrictValidation:$strictValidate
        }
        else {
            if ($useCache) {
                $result = Invoke-GCInsightPack -PackPath $packPath -Parameters $packParams -UseCache -CacheTtlMinutes $cacheTtl -CacheDirectory $cacheDir -StrictValidation:$strictValidate
            }
            else {
                $result = Invoke-GCInsightPack -PackPath $packPath -Parameters $packParams -StrictValidation:$strictValidate
            }
        }
    }

    $script:LastInsightResult = $result
    Update-InsightPackUi -Result $result
    if ($exportInsightBriefingButton) { $exportInsightBriefingButton.IsEnabled = $true }
    return $result
}

if ($runSelectedInsightPackButton) {
    $runSelectedInsightPackButton.Add_Click({
            try {
                $statusText.Text = "Running insight pack..."
                Run-SelectedInsightPack -Compare:$false -DryRun:$false | Out-Null
                $statusText.Text = "Insight pack completed."
            }
            catch {
                $statusText.Text = "Insight pack failed."
                Add-LogEntry "Insight pack failed: $($_.Exception.Message)"
                [System.Windows.MessageBox]::Show("Insight pack failed: $($_.Exception.Message)", "Insight Pack Error", "OK", "Error")
            }
        })
}

if ($compareSelectedInsightPackButton) {
    $compareSelectedInsightPackButton.Add_Click({
            try {
                $statusText.Text = "Running insight pack (compare)..."
                Run-SelectedInsightPack -Compare:$true -DryRun:$false | Out-Null
                $statusText.Text = "Insight pack comparison completed."
            }
            catch {
                $statusText.Text = "Insight pack comparison failed."
                Add-LogEntry "Insight pack compare failed: $($_.Exception.Message)"
                [System.Windows.MessageBox]::Show("Insight pack compare failed: $($_.Exception.Message)", "Insight Pack Error", "OK", "Error")
            }
        })
}

if ($dryRunSelectedInsightPackButton) {
    $dryRunSelectedInsightPackButton.Add_Click({
            try {
                $statusText.Text = "Running insight pack (dry run)..."
                Run-SelectedInsightPack -Compare:$false -DryRun:$true | Out-Null
                $statusText.Text = "Insight pack dry run completed."
            }
            catch {
                $statusText.Text = "Insight pack dry run failed."
                Add-LogEntry "Insight pack dry run failed: $($_.Exception.Message)"
                [System.Windows.MessageBox]::Show("Insight pack dry run failed: $($_.Exception.Message)", "Insight Pack Error", "OK", "Error")
            }
        })
}

if ($runQueueSmokePackButton) {
    $runQueueSmokePackButton.Add_Click({
            Run-InsightPackWorkflow -Label "Queue Smoke Detector" -FileName "gc.queues.smoke.v1.json"
        })
}

if ($runDataActionsPackButton) {
    $runDataActionsPackButton.Add_Click({
            Run-InsightPackWorkflow -Label "Data Action Failures" -FileName "gc.dataActions.failures.v1.json"
        })
}

if ($runDataActionsEnrichedPackButton) {
    $runDataActionsEnrichedPackButton.Add_Click({
            Run-InsightPackWorkflow -Label "Data Actions (Enriched)" -FileName "gc.dataActions.failures.enriched.v1.json"
        })
}

if ($runPeakConcurrencyPackButton) {
    $runPeakConcurrencyPackButton.Add_Click({
            Run-InsightPackWorkflow -Label "Peak Concurrency (Voice)" -FileName "gc.calls.peakConcurrency.monthly.v1.json"
        })
}

if ($runMosMonthlyPackButton) {
    $runMosMonthlyPackButton.Add_Click({
            # End-of-month reporting is typically "last full month"
            Run-InsightPackWorkflow -Label "Monthly MOS (By Division)" -FileName "gc.mos.monthly.byDivision.v1.json" -TimePresetKey 'lastMonth'
        })
}

if ($exportInsightBriefingButton) {
    $exportInsightBriefingButton.Add_Click({
            Export-InsightBriefingWorkflow
        })
}

# Export PowerShell Script button
if ($exportPowerShellButton) {
    $exportPowerShellButton.Add_Click({
            $selectedPath = $pathCombo.SelectedItem
            $selectedMethod = $methodCombo.SelectedItem
            $token = Get-ExplorerAccessToken

            if (-not $selectedPath -or -not $selectedMethod) {
                $statusText.Text = "Select a path and method first."
                return
            }

            # Collect current parameters
            $requestParams = @{}
            $pathObject = Get-PathObject -ApiPaths $ApiPaths -Path $selectedPath
            $methodObject = Get-MethodObject -PathObject $pathObject -MethodName $selectedMethod
            if ($methodObject -and $methodObject.parameters) {
                foreach ($param in $methodObject.parameters) {
                    $yinput = $paramInputs[$param.name]
                    if ($yinput) {
                        $value = Get-ParameterControlValue -Control $yinput
                        if (-not [string]::IsNullOrWhiteSpace($value)) {
                            $requestParams[$param.name] = $value
                        }
                    }
                }
            }

            $mode = 'Auto'
            try {
                if ($powerShellExportModeCombo -and $powerShellExportModeCombo.SelectedIndex -ge 0) {
                    switch ([int]$powerShellExportModeCombo.SelectedIndex) {
                        1 { $mode = 'Portable' }
                        2 { $mode = 'OpsInsights' }
                        default { $mode = 'Auto' }
                    }
                }
            }
            catch { $mode = 'Auto' }

            # Generate PowerShell script
            $script = Export-PowerShellScript -Method $selectedMethod -Path $selectedPath -Parameters $requestParams -Token $token -Region $script:Region -Mode $mode

            # Show in dialog with copy/save options
            $dialog = New-Object Microsoft.Win32.SaveFileDialog
            $dialog.Filter = "PowerShell Scripts (*.ps1)|*.ps1|All Files (*.*)|*.*"
            $dialog.Title = "Save PowerShell Script"
            $dialog.FileName = "GenesysAPI_$($selectedMethod)_Script.ps1"

            if ($dialog.ShowDialog() -eq $true) {
                $script | Out-File -FilePath $dialog.FileName -Encoding utf8
                $statusText.Text = "PowerShell script exported to $($dialog.FileName)"
                Add-LogEntry "PowerShell script exported to $($dialog.FileName)"

                # Copy to clipboard as well
                [System.Windows.Clipboard]::SetText($script)
                [System.Windows.MessageBox]::Show(
                    "PowerShell script saved to $($dialog.FileName) and copied to clipboard.",
                    "Script Exported",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information
                )
            }
        })
}

# Export cURL Command button
if ($exportCurlButton) {
    $exportCurlButton.Add_Click({
            $selectedPath = $pathCombo.SelectedItem
            $selectedMethod = $methodCombo.SelectedItem
            $token = Get-ExplorerAccessToken

            if (-not $selectedPath -or -not $selectedMethod) {
                $statusText.Text = "Select a path and method first."
                return
            }

            # Collect current parameters
            $requestParams = @{}
            $pathObject = Get-PathObject -ApiPaths $ApiPaths -Path $selectedPath
            $methodObject = Get-MethodObject -PathObject $pathObject -MethodName $selectedMethod
            if ($methodObject -and $methodObject.parameters) {
                foreach ($param in $methodObject.parameters) {
                    $xinput = $paramInputs[$param.name]
                    if ($xinput) {
                        $value = Get-ParameterControlValue -Control $xinput
                        if (-not [string]::IsNullOrWhiteSpace($value)) {
                            $requestParams[$param.name] = $value
                        }
                    }
                }
            }

            # Generate cURL command
            $curlCommand = Export-CurlCommand -Method $selectedMethod -Path $selectedPath -Parameters $requestParams -Token $token -Region $script:Region

            # Copy to clipboard and show confirmation
            [System.Windows.Clipboard]::SetText($curlCommand)
            [System.Windows.MessageBox]::Show(
                "cURL command copied to clipboard:`r`n`r`n$curlCommand",
                "cURL Exported",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
            $statusText.Text = "cURL command copied to clipboard."
            Add-LogEntry "cURL command generated and copied to clipboard"
        })
}

# Templates list selection changed
if ($templatesList) {
    $templatesList.ItemsSource = $script:Templates
    if (-not $script:TemplateSortState) { $script:TemplateSortState = @{} }
    Enable-GridViewColumnSorting -ListView $templatesList -State $script:TemplateSortState

    # Load templates from disk into the collection
    if ($TemplatesData) {
        $defaultLastModified = $null
        try {
            if ($TemplatesFilePath -and (Test-Path -LiteralPath $TemplatesFilePath)) {
                $defaultLastModified = (Get-Item -LiteralPath $TemplatesFilePath).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            }
        }
        catch { }

        $normalizedTemplates = Normalize-Templates -Templates $TemplatesData -DefaultLastModified $defaultLastModified
        foreach ($template in $normalizedTemplates) {
            $script:Templates.Add($template)
        }

        # Persist normalized templates back to disk (removes blocked methods + adds LastModified)
        try {
            if ($TemplatesFilePath -and (Test-Path -LiteralPath $TemplatesFilePath)) {
                Save-TemplatesToDisk -Path $TemplatesFilePath -Templates $script:Templates
            }
        }
        catch { }
    }

    $templatesList.Add_SelectionChanged({
            if ($templatesList.SelectedItem) {
                $loadTemplateButton.IsEnabled = $true
                $deleteTemplateButton.IsEnabled = $true
            }
            else {
                $loadTemplateButton.IsEnabled = $false
                $deleteTemplateButton.IsEnabled = $false
            }
        })
}

# Save Template button
if ($saveTemplateButton) {
    $saveTemplateButton.Add_Click({
            $selectedPath = $pathCombo.SelectedItem
            $selectedMethod = $methodCombo.SelectedItem

            if (-not $selectedPath -or -not $selectedMethod) {
                [System.Windows.MessageBox]::Show(
                    "Please select a path and method before saving a template.",
                    "Missing Information",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                )
                return
            }

            if (-not (Test-TemplateMethodAllowed -Method $selectedMethod)) {
                [System.Windows.MessageBox]::Show(
                    "Templates for HTTP methods PATCH and DELETE are disabled.",
                    "Template Not Allowed",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information
                )
                return
            }

            # Prompt for template name
            Add-Type -AssemblyName Microsoft.VisualBasic
            $templateName = [Microsoft.VisualBasic.Interaction]::InputBox(
                "Enter a name for this template:",
                "Save Template",
                "$selectedMethod $selectedPath"
            )

            if ([string]::IsNullOrWhiteSpace($templateName)) {
                return
            }

            # Collect current parameters
            $requestParams = @{}
            $pathObject = Get-PathObject -ApiPaths $ApiPaths -Path $selectedPath
            $methodObject = Get-MethodObject -PathObject $pathObject -MethodName $selectedMethod
            if ($methodObject -and $methodObject.parameters) {
                foreach ($param in $methodObject.parameters) {
                    $einput = $paramInputs[$param.name]
                    if ($einput) {
                        $value = Get-ParameterControlValue -Control $einput
                        if (-not [string]::IsNullOrWhiteSpace($value)) {
                            $requestParams[$param.name] = $value
                        }
                    }
                }
            }

            # Create template object
            $template = [PSCustomObject]@{
                Name         = $templateName
                Method       = $selectedMethod
                Path         = $selectedPath
                Group        = $groupCombo.SelectedItem
                Parameters   = $requestParams
                Created      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                LastModified = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }

            # Add to collection and save
            $script:Templates.Add($template)
            Save-TemplatesToDisk -Path $script:TemplatesFilePath -Templates $script:Templates

            Add-LogEntry "Template saved: $templateName"
            $statusText.Text = "Template '$templateName' saved successfully."
        })
}

# Load Template button
if ($loadTemplateButton) {
    $loadTemplateButton.Add_Click({
            $selectedTemplate = $templatesList.SelectedItem
            if (-not $selectedTemplate) {
                return
            }

            # Set the group, path, and method
            Select-ComboBoxItemByText -ComboBox $groupCombo -Text $selectedTemplate.Group
            Select-ComboBoxItemByText -ComboBox $pathCombo -Text $selectedTemplate.Path
            Select-ComboBoxItemByText -ComboBox $methodCombo -Text $selectedTemplate.Method

            # Restore parameters using Dispatcher
            if ($selectedTemplate.Parameters) {
                $Window.Dispatcher.Invoke([Action] {
                        foreach ($paramName in $selectedTemplate.Parameters.PSObject.Properties.Name) {
                            if ($paramInputs.ContainsKey($paramName)) {
                                Set-ParameterControlValue -Control $paramInputs[$paramName] -Value $selectedTemplate.Parameters.$paramName
                            }
                        }
                    }, [System.Windows.Threading.DispatcherPriority]::Background)
            }

            Add-LogEntry "Template loaded: $($selectedTemplate.Name)"
            $statusText.Text = "Template loaded: $($selectedTemplate.Name)"
        })
}

# Delete Template button
if ($deleteTemplateButton) {
    $deleteTemplateButton.Add_Click({
            $selectedTemplate = $templatesList.SelectedItem
            if (-not $selectedTemplate) {
                return
            }

            $result = [System.Windows.MessageBox]::Show(
                "Are you sure you want to delete the template '$($selectedTemplate.Name)'?",
                "Delete Template",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question
            )

            if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
                $script:Templates.Remove($selectedTemplate)
                Save-TemplatesToDisk -Path $script:TemplatesFilePath -Templates $script:Templates
                Add-LogEntry "Template deleted: $($selectedTemplate.Name)"
                $statusText.Text = "Template deleted."
            }
        })
}

# Export Templates button
if ($exportTemplatesButton) {
    $exportTemplatesButton.Add_Click({
            if ($script:Templates.Count -eq 0) {
                [System.Windows.MessageBox]::Show(
                    "No templates to export.",
                    "Export Templates",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information
                )
                return
            }

            $dialog = New-Object Microsoft.Win32.SaveFileDialog
            $dialog.Filter = "JSON Files (*.json)|*.json|All Files (*.*)|*.*"
            $dialog.Title = "Export Templates"
            $dialog.FileName = "GenesysAPIExplorerTemplates.json"

            if ($dialog.ShowDialog() -eq $true) {
                Save-TemplatesToDisk -Path $dialog.FileName -Templates $script:Templates
                $statusText.Text = "Templates exported to $($dialog.FileName)"
                Add-LogEntry "Templates exported to $($dialog.FileName)"
                [System.Windows.MessageBox]::Show(
                    "Templates exported successfully to $($dialog.FileName)",
                    "Export Complete",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information
                )
            }
        })
}

# Import Templates button
if ($importTemplatesButton) {
    $importTemplatesButton.Add_Click({
            $dialog = New-Object Microsoft.Win32.OpenFileDialog
            $dialog.Filter = "JSON Files (*.json)|*.json|All Files (*.*)|*.*"
            $dialog.Title = "Import Templates"

            if ($dialog.ShowDialog() -eq $true) {
                $importedRaw = Load-TemplatesFromDisk -Path $dialog.FileName
                $importedTemplates = if ($importedRaw) { Normalize-Templates -Templates $importedRaw -DefaultLastModified (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } else { @() }
                if ($importedTemplates -and $importedTemplates.Count -gt 0) {
                    $importCount = 0
                    foreach ($template in $importedTemplates) {
                        # Check if template already exists by name
                        $exists = $false
                        foreach ($existingTemplate in $script:Templates) {
                            if ($existingTemplate.Name -eq $template.Name) {
                                $exists = $true
                                break
                            }
                        }

                        if (-not $exists) {
                            $script:Templates.Add($template)
                            $importCount++
                        }
                    }

                    if ($importCount -gt 0) {
                        Save-TemplatesToDisk -Path $script:TemplatesFilePath -Templates $script:Templates
                        $statusText.Text = "Imported $importCount template(s)."
                        Add-LogEntry "Imported $importCount template(s) from $($dialog.FileName)"
                        [System.Windows.MessageBox]::Show(
                            "Successfully imported $importCount template(s). Duplicates were skipped.",
                            "Import Complete",
                            [System.Windows.MessageBoxButton]::OK,
                            [System.Windows.MessageBoxImage]::Information
                        )
                    }
                    else {
                        [System.Windows.MessageBox]::Show(
                            "No new templates imported. All templates already exist.",
                            "Import Complete",
                            [System.Windows.MessageBoxButton]::OK,
                            [System.Windows.MessageBoxImage]::Information
                        )
                    }
                }
                else {
                    [System.Windows.MessageBox]::Show(
                        "No templates found in the selected file.",
                        "Import Failed",
                        [System.Windows.MessageBoxButton]::OK,
                        [System.Windows.MessageBoxImage]::Warning
                    )
                }
            }
        })
}

$btnSubmit.Add_Click({
        $selectedPath = $pathCombo.SelectedItem
        $selectedMethod = $methodCombo.SelectedItem

        if (-not $selectedPath -or -not $selectedMethod) {
            $statusText.Text = "Select a path and method first."
            Add-LogEntry "Submit blocked: method or path missing."
            return
        }

        $pathObject = Get-PathObject -ApiPaths $ApiPaths -Path $selectedPath
        $methodObject = Get-MethodObject -PathObject $pathObject -MethodName $selectedMethod
        if (-not $methodObject) {
            Add-LogEntry "Submit blocked: method metadata missing."
            $statusText.Text = "Method metadata missing."
            return
        }

        $params = $methodObject.parameters

        # Validate required parameters and JSON body parameters
        $validationErrors = @()
        foreach ($param in $params) {
            $ainput = $paramInputs[$param.name]
            if ($ainput) {
                $value = Get-ParameterControlValue -Control $ainput
                if ($value -and $value.GetType().Name -eq "String") {
                    $value = $value.Trim()
                }

                # Check required fields
                if ($param.required -and -not $value) {
                    $validationErrors += "$($param.name) is required"
                }

                # Validate JSON format for body parameters
                if ($param.in -eq "body" -and $value) {
                    if (-not (Test-JsonString -JsonString $value)) {
                        $validationErrors += "$($param.name) contains invalid JSON"
                    }
                }

                # Validate type and constraints for non-body parameters
                if ($param.in -ne "body" -and $value -and $input.Tag -is [hashtable]) {
                    $validationResult = Test-ParameterValue -Value $value -ValidationMetadata $input.Tag
                    if (-not $validationResult.Valid) {
                        foreach ($validationError in $validationResult.Errors) {
                            $validationErrors += "$($param.name): $validationError"
                        }
                    }
                }

                # Validate array parameters
                if ($param.type -eq "array" -and $value) {
                    $testResult = Test-ArrayValue -Value $value -ItemType $param.items
                    if (-not $testResult.IsValid) {
                        $validationErrors += "$($param.name): " + $testResult.ErrorMessage
                    }
                }

                # Validate numeric parameters
                if ($param.type -in @("integer", "number") -and $value) {
                    $testResult = Test-NumericValue -Value $value -Type $param.type -Minimum $param.minimum -Maximum $param.maximum
                    if (-not $testResult.IsValid) {
                        $validationErrors += "$($param.name): " + $testResult.ErrorMessage
                    }
                }

                # Validate string format/pattern parameters
                if ($param.type -eq "string" -and $value -and ($param.format -or $param.pattern)) {
                    $testResult = Test-StringFormat -Value $value -Format $param.format -Pattern $param.pattern
                    if (-not $testResult.IsValid) {
                        $validationErrors += "$($param.name): " + $testResult.ErrorMessage
                    }
                }
            }
            elseif ($param.required) {
                $validationErrors += "$($param.name) is required but control not found"
            }
        }

        if ($validationErrors.Count -gt 0) {
            $errorMessage = "Validation errors:`n" + ($validationErrors -join "`n")
            $statusText.Text = "Validation failed: " + ($validationErrors -join ", ")
            Add-LogEntry "Submit blocked: $errorMessage"
            [System.Windows.MessageBox]::Show($errorMessage, "Validation Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }

        $queryParams = @{}
        $pathParams = @{}
        $bodyParams = @{}
        $headers = @{
            "Content-Type" = "application/json"
        }

        $token = Get-ExplorerAccessToken
        if ($token) {
            $headers["Authorization"] = "Bearer $token"
        }
        else {
            Add-LogEntry "Warning: Authorization token is empty."
        }

        foreach ($param in $params) {
            $rinput = $paramInputs[$param.name]
            if (-not $rinput) { continue }

            $value = Get-ParameterControlValue -Control $rinput
            if ($value -and $value.GetType().Name -eq "String") {
                $value = $value.Trim()
            }
            if (-not $value) { continue }

            switch ($param.in) {
                "query" { $queryParams[$param.name] = $value }
                "path" { $pathParams[$param.name] = $value }
                "body" { $bodyParams[$param.name] = $value }
                "header" { $headers[$param.name] = $value }
            }
        }

        $baseUrl = $ApiBaseUrl
        $pathWithReplacements = $selectedPath
        foreach ($key in $pathParams.Keys) {
            $escaped = [uri]::EscapeDataString($pathParams[$key])
            $pathWithReplacements = $pathWithReplacements -replace "\{$key\}", $escaped
        }

        $queryString = if ($queryParams.Count -gt 0) {
            "?" + ($queryParams.GetEnumerator() | ForEach-Object {
                    [uri]::EscapeDataString($_.Key) + "=" + [uri]::EscapeDataString($_.Value)
                } -join "&")
        }
        else {
            ""
        }

        $fullUrl = $baseUrl + $pathWithReplacements + $queryString
        $body = if ($bodyParams.Count -gt 0) { $bodyParams | ConvertTo-Json -Depth 10 } else { $null }

        Add-LogEntry "Request $($selectedMethod.ToUpper()) $fullUrl"
        $statusText.Text = "Sending request..."
        $btnSubmit.IsEnabled = $false
        if ($progressIndicator) {
            $progressIndicator.Visibility = "Visible"
        }

        # Track request start time
        $requestStartTime = Get-Date

        # Store parameters for history
        $requestParams = @{}
        foreach ($param in $params) {
            $rinput = $paramInputs[$param.name]
            if ($rinput) {
                $value = Get-ParameterControlValue -Control $rinput
                if ($value -and $value.GetType().Name -eq "String") {
                    $value = $value.Trim()
                }
                if ($value) {
                    $requestParams[$param.name] = $value
                }
            }
        }

        try {
            $response = Invoke-GCRequest -Method $selectedMethod.ToUpper() -Uri $fullUrl -Headers $headers -Body $body -AsResponse
            $rawContent = $response.Content
            $formattedContent = $rawContent
            try {
                $json = $rawContent | ConvertFrom-Json -ErrorAction Stop
                $formattedContent = $json | ConvertTo-Json -Depth 10
            }
            catch {
                # Keep raw text if JSON parsing fails
            }

            $script:LastResponseText = $formattedContent
            $script:LastResponseRaw = $rawContent
            $script:LastResponseFile = ""
            $script:ResponseViewMode = "Formatted"
            $responseBox.Text = "Status $($response.StatusCode):`r`n$formattedContent"
            $btnSave.IsEnabled = $true
            $btnSubmit.IsEnabled = $true
            if ($toggleResponseViewButton) {
                $toggleResponseViewButton.IsEnabled = $true
            }
            if ($progressIndicator) {
                $progressIndicator.Visibility = "Collapsed"
            }

            # Calculate duration and update status
            $requestDuration = ((Get-Date) - $requestStartTime).TotalMilliseconds

            # Detect pagination in response
            $hasPagination = $false
            $paginationInfo = ""
            if ($json) {
                if ($json.cursor) {
                    $hasPagination = $true
                    $paginationInfo = " (Cursor-based pagination detected)"
                }
                elseif ($json.nextUri) {
                    $hasPagination = $true
                    $paginationInfo = " (Next page available via nextUri)"
                }
                elseif ($json.pageCount -and $json.pageNumber) {
                    $hasPagination = $true
                    $paginationInfo = " (Page $($json.pageNumber) of $($json.pageCount))"
                }
            }

            $statusText.Text = "Last call succeeded ($($response.StatusCode)) - {0:N0} ms$paginationInfo" -f $requestDuration
            Add-LogEntry ("Response: {0} returned {1} chars in {2:N0} ms.$paginationInfo" -f $response.StatusCode, $formattedContent.Length, $requestDuration)

            # If pagination detected, log a note
            if ($hasPagination) {
                Add-LogEntry "Note: Response contains pagination. To fetch all pages, use Get-PaginatedResults function or the Jobs results fetcher for job endpoints."
            }

            # Add to request history
            $historyEntry = [PSCustomObject]@{
                Timestamp  = $requestStartTime.ToString("yyyy-MM-dd HH:mm:ss")
                Method     = $selectedMethod.ToUpper()
                Path       = $selectedPath
                Group      = $groupCombo.SelectedItem
                Status     = $response.StatusCode
                Duration   = "{0:N0} ms" -f $requestDuration
                Parameters = $requestParams
            }
            $script:RequestHistory.Insert(0, $historyEntry)
            # Keep only last 50 requests
            while ($script:RequestHistory.Count -gt 50) {
                $script:RequestHistory.RemoveAt(50)
            }

            if ($selectedMethod -eq "post" -and $selectedPath -match "/jobs/?$" -and $json) {
                $jobId = if ($json.id) { $json.id } elseif ($json.jobId) { $json.jobId } else { $null }
                if ($jobId) {
                    Start-JobPolling -Path $selectedPath -JobId $jobId -Headers $headers
                }
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            $statusCode = ""
            $errorResponseBody = ""

            # Try to extract detailed error information from the HTTP response
            if ($_.Exception.Response) {
                $response = $_.Exception.Response
                if ($response -is [System.Net.HttpWebResponse]) {
                    $statusCode = "Status $($response.StatusCode) ($([int]$response.StatusCode)) - "
                    try {
                        $responseStream = $response.GetResponseStream()
                        $reader = New-Object System.IO.StreamReader($responseStream)
                        $errorResponseBody = $reader.ReadToEnd()
                        $reader.Close()
                        $responseStream.Close()
                    }
                    catch {
                        # Could not read response body
                    }
                }
            }

            # Build the display message
            $displayMessage = "Error:`r`n$statusCode$errorMessage"
            if ($errorResponseBody) {
                # Try to format as JSON if possible
                try {
                    $errorJson = $errorResponseBody | ConvertFrom-Json -ErrorAction Stop
                    $formattedError = $errorJson | ConvertTo-Json -Depth 5
                    $displayMessage += "`r`n`r`nResponse Body:`r`n$formattedError"
                }
                catch {
                    $displayMessage += "`r`n`r`nResponse Body:`r`n$errorResponseBody"
                }
            }

            $responseBox.Text = $displayMessage
            $btnSave.IsEnabled = $false
            $btnSubmit.IsEnabled = $true
            if ($toggleResponseViewButton) {
                $toggleResponseViewButton.IsEnabled = $false
            }
            if ($progressIndicator) {
                $progressIndicator.Visibility = "Collapsed"
            }
            $statusText.Text = "Request failed - see log."
            $script:LastResponseRaw = ""
            $script:LastResponseFile = ""

            # Add to request history
            $requestDuration = ((Get-Date) - $requestStartTime).TotalMilliseconds
            $statusForHistory = if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                [int]$_.Exception.Response.StatusCode
            }
            else {
                "Error"
            }
            $historyEntry = [PSCustomObject]@{
                Timestamp  = $requestStartTime.ToString("yyyy-MM-dd HH:mm:ss")
                Method     = $selectedMethod.ToUpper()
                Path       = $selectedPath
                Group      = $groupCombo.SelectedItem
                Status     = $statusForHistory
                Duration   = "{0:N0} ms" -f $requestDuration
                Parameters = $requestParams
            }
            $script:RequestHistory.Insert(0, $historyEntry)
            # Keep only last 50 requests
            while ($script:RequestHistory.Count -gt 50) {
                $script:RequestHistory.RemoveAt(50)
            }

            # Log detailed error information to the transparency log
            Add-LogEntry "Response error: $statusCode$errorMessage"
            if ($errorResponseBody) {
                # Truncate very long error responses for the log
                $logBody = if ($errorResponseBody.Length -gt $script:LogMaxMessageLength) {
                    $errorResponseBody.Substring(0, $script:LogMaxMessageLength) + "... (truncated)"
                }
                else {
                    $errorResponseBody
                }
                Add-LogEntry "Error response body: $logBody"
            }
        }
    })

$btnSave.Add_Click({
        if (-not $script:LastResponseText) {
            return
        }

        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Filter = "JSON Files (*.json)|*.json|All Files (*.*)|*.*"
        $dialog.Title = "Save API Response"
        $dialog.FileName = "GenesysResponse.json"

        if ($dialog.ShowDialog() -eq $true) {
            $script:LastResponseText | Out-File -FilePath $dialog.FileName -Encoding utf8
            $statusText.Text = "Saved response to $($dialog.FileName)"
            Add-LogEntry "Saved response to $($dialog.FileName)"
        }
    })

if ($exportLogButton) {
    $exportLogButton.Add_Click({
            if ([string]::IsNullOrWhiteSpace($logBox.Text)) {
                $statusText.Text = "No log entries to export."
                return
            }

            $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
            $dialog = New-Object Microsoft.Win32.SaveFileDialog
            $dialog.Filter = "Text Files (*.txt)|*.txt|Log Files (*.log)|*.log|All Files (*.*)|*.*"
            $dialog.Title = "Export Transparency Log"
            $dialog.FileName = "GenesysAPIExplorer_Log_$timestamp.txt"

            if ($dialog.ShowDialog() -eq $true) {
                $logBox.Text | Out-File -FilePath $dialog.FileName -Encoding utf8
                $statusText.Text = "Log exported to $($dialog.FileName)"
                Add-LogEntry "Transparency log exported to $($dialog.FileName)"
            }
        })
}

if ($clearLogButton) {
    $clearLogButton.Add_Click({
            $result = [System.Windows.MessageBox]::Show(
                "Are you sure you want to clear all log entries? This action cannot be undone.",
                "Clear Log",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question
            )

            if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
                $logBox.Clear()
                $statusText.Text = "Log cleared."
                Add-LogEntry "Log was cleared by user."
            }
        })
}

Add-LogEntry "Loaded $($GroupMap.Keys.Count) groups from the API catalog."
$Window.ShowDialog() | Out-Null
