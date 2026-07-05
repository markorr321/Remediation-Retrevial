<#
.SYNOPSIS
    Pushes remediation scripts to Intune as Device Health Scripts

.DESCRIPTION
    Scans the current directory for remediation script folders (containing detection.ps1,
    optional remediation.ps1, and metadata.json), then uploads them to Intune via Microsoft Graph API.

    Can create new remediation scripts or update existing ones based on the Id in metadata.json.

.PARAMETER Path
    Root path containing remediation script folders. Defaults to current directory.

.PARAMETER BrowseFolder
    Opens a graphical folder-picker dialog to choose the folder to import. You can pick a
    parent folder containing multiple remediation folders, or a single remediation folder
    (one that contains detection.ps1 and metadata.json).

.PARAMETER FolderName
    Specific folder name to push. If not specified, processes all folders.

.PARAMETER Create
    Explicitly create new remediation scripts. This is the default action when
    -UpdateExisting is not used. When a folder's metadata.json already contains an Id,
    -Create still creates a brand-new (duplicate) remediation in Intune and writes the
    new Id back to metadata.json - useful for cloning an existing remediation.

.PARAMETER UpdateExisting
    If specified, updates existing remediation scripts (matched by the Id in
    metadata.json). Otherwise, creates new ones. Takes precedence over -Create.

.PARAMETER ApprovalJustification
    Justification text for the approval request. If not provided, you'll be prompted with common options.

.PARAMETER WhatIf
    Shows what would be uploaded without actually pushing to Intune.

.PARAMETER Interactive
    Prompts for settings before pushing.
    - With -UpdateExisting: fetches the CURRENT live settings from Intune, displays them,
      and lets you keep them as-is or modify each one before the update is applied.
    - With -Create: prompts for all settings (name, description, publisher, run-as account,
      32-bit, signature check, scope tags) plus an optional assignment (All devices / All
      users / a group) and run schedule (Daily / Hourly / Once), then assigns on create.

.PARAMETER Menu
    Opens the interactive text-based menu (TUI) for choosing the action and options,
    instead of running with switches. Requires Start-RemediationToolkit.ps1 alongside
    this script.

.EXAMPLE
    .\Push-RemediationsToIntune.ps1

.EXAMPLE
    .\Push-RemediationsToIntune.ps1 -Menu

.EXAMPLE
    .\Push-RemediationsToIntune.ps1 -BrowseFolder

.EXAMPLE
    .\Push-RemediationsToIntune.ps1 -Create

.EXAMPLE
    .\Push-RemediationsToIntune.ps1 -BrowseFolder -Create

.EXAMPLE
    .\Push-RemediationsToIntune.ps1 -BrowseFolder -UpdateExisting

.EXAMPLE
    .\Push-RemediationsToIntune.ps1 -UpdateExisting -WhatIf

.EXAMPLE
    .\Push-RemediationsToIntune.ps1 -FolderName "DEV_-_GP_-_CC" -UpdateExisting

.EXAMPLE
    .\Push-RemediationsToIntune.ps1 -FolderName "DEV_-_GP_-_CC" -UpdateExisting -ApprovalJustification "Testing CIS registry compliance updates"

.NOTES
    Author: Mark Orr
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$Path = $PSScriptRoot,

    [Parameter()]
    [switch]$BrowseFolder,

    [Parameter()]
    [string]$FolderName,

    [Parameter()]
    [string[]]$FolderNames,

    [Parameter()]
    [switch]$Create,

    [Parameter()]
    [switch]$UpdateExisting,

    [Parameter()]
    [string]$ApprovalJustification,

    [Parameter()]
    [switch]$Interactive,

    [Parameter()]
    [switch]$Menu
)

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement

# ============================================================================
#  HELPER FUNCTIONS
#  Graph connection, UI folder picker, encoding, and folder discovery.
# ============================================================================

# Connect to Microsoft Graph
function Connect-ToGraph {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan

    $requiredScopes = @(
        'DeviceManagementConfiguration.ReadWrite.All'
    )

    try {
        # -ErrorAction Stop so a cancelled/failed sign-in throws into the catch below
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome -ErrorAction Stop

        # Even when Connect-MgGraph doesn't throw, verify we actually have an account.
        # (A cancelled interactive sign-in can leave an empty context.)
        $context = Get-MgContext
        if (-not $context -or [string]::IsNullOrWhiteSpace($context.Account)) {
            Write-Error "Microsoft Graph sign-in did not complete (no active account). Aborting."
            exit 1
        }

        Write-Host "Connected as: $($context.Account)" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $_"
        exit 1
    }
}

# Show a graphical folder-picker dialog and return the selected path (or $null if cancelled)
function Show-FolderPicker {
    param(
        [string]$InitialPath,
        [string]$Description = "Select the folder to import remediation scripts from"
    )

    Add-Type -AssemblyName System.Windows.Forms

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $false
    if ($InitialPath -and (Test-Path $InitialPath)) {
        $dialog.SelectedPath = $InitialPath
    }

    # Ensure the dialog appears in the foreground
    $topmost = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    $result = $dialog.ShowDialog($topmost)
    $topmost.Dispose()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }

    return $null
}

# Convert script content to base64
function ConvertTo-Base64 {
    param([string]$Content)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    return [Convert]::ToBase64String($bytes)
}

# Build the deviceHealthScript request body used by both create and update.
# IMPORTANT: never emit JSON null - the Intune approval "completion" step re-validates
# the stored payload against the schema, and null publisher/description (or a missing
# roleScopeTagIds) fails that validation ("completion action fails"). So string fields
# are coerced to strings, booleans to real booleans, and scope tags default to '0'.
function New-RemediationRequestBody {
    param(
        [PSCustomObject]$Metadata,
        [string]$DetectionScriptContent,
        [string]$RemediationScriptContent
    )

    # Scope tags: split the comma-separated string; default to '0' (Default) if empty
    $scopeTags = @(
        "$($Metadata.RoleScopeTagIds)" -split ',\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    )
    if ($scopeTags.Count -eq 0) { $scopeTags = @('0') }

    # Run-as account must be a non-empty string; default to 'system'
    $runAs = if ([string]::IsNullOrWhiteSpace($Metadata.RunAsAccount)) { 'system' } else { "$($Metadata.RunAsAccount)".Trim() }

    $body = @{
        '@odata.type'          = '#microsoft.graph.deviceHealthScript'
        displayName            = "$($Metadata.DisplayName)"
        description            = "$($Metadata.Description)"
        publisher              = "$($Metadata.Publisher)"
        runAsAccount           = $runAs
        enforceSignatureCheck  = [bool]$Metadata.EnforceSignatureCheck
        runAs32Bit             = [bool]$Metadata.RunAs32Bit
        roleScopeTagIds        = $scopeTags
        detectionScriptContent = ConvertTo-Base64 -Content $DetectionScriptContent
    }

    if ($RemediationScriptContent) {
        $body.remediationScriptContent = ConvertTo-Base64 -Content $RemediationScriptContent
    }

    return $body
}

# --- Interactive prompt helpers (used by -Interactive create/update) ------------

# Free-text prompt that keeps the current value when the user just presses Enter
function Read-TextSetting {
    param([string]$Label, [string]$Current)
    $shown = if ([string]::IsNullOrWhiteSpace($Current)) { "(empty)" } else { $Current }
    $value = Read-Host "    $Label [$shown] (Enter = keep)"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Current }
    return $value
}

# Yes/No prompt that keeps the current boolean when the user just presses Enter
function Read-BoolSetting {
    param([string]$Label, [bool]$Current)
    $shown = if ($Current) { "Yes" } else { "No" }
    while ($true) {
        $value = Read-Host "    $Label [$shown] (Y/N, Enter = keep)"
        if ([string]::IsNullOrWhiteSpace($value)) { return $Current }
        switch -Regex ($value.Trim()) {
            '^(y|yes|true|1)$' { return $true }
            '^(n|no|false|0)$' { return $false }
            default { Write-Host "    Please enter Y or N." -ForegroundColor Yellow }
        }
    }
}

# Choice prompt from a fixed set that keeps the current value on empty input
function Read-ChoiceSetting {
    param([string]$Label, [string]$Current, [string[]]$Choices)
    $list = $Choices -join ' / '
    while ($true) {
        $value = Read-Host "    $Label [$Current] ($list, Enter = keep)"
        if ([string]::IsNullOrWhiteSpace($value)) { return $Current }
        $match = $Choices | Where-Object { $_ -ieq $value.Trim() } | Select-Object -First 1
        if ($match) { return $match }
        Write-Host "    Please enter one of: $list" -ForegroundColor Yellow
    }
}

# Fetch the current (live) settings for a remediation script from Intune
function Get-LiveRemediationScript {
    param([string]$Id)
    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts/$Id"
        return Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    }
    catch {
        Write-Warning "  Could not read current settings for ID $Id : $($_.Exception.Message)"
        return $null
    }
}

# Print the current live settings so the user can see them before changing anything.
# Shown in red to make the existing/current values stand out before any change.
function Show-RemediationSettings {
    param([object]$Live)
    Write-Host "`n  ---- Current settings in Intune ----" -ForegroundColor Red
    Write-Host ("    {0,-24}: {1}" -f 'Display Name',          $Live.displayName)          -ForegroundColor Red
    Write-Host ("    {0,-24}: {1}" -f 'Description',           $Live.description)           -ForegroundColor Red
    Write-Host ("    {0,-24}: {1}" -f 'Publisher',             $Live.publisher)             -ForegroundColor Red
    Write-Host ("    {0,-24}: {1}" -f 'Run As Account',        $Live.runAsAccount)          -ForegroundColor Red
    Write-Host ("    {0,-24}: {1}" -f 'Run As 32-bit',         $Live.runAs32Bit)            -ForegroundColor Red
    Write-Host ("    {0,-24}: {1}" -f 'Enforce Signature',     $Live.enforceSignatureCheck) -ForegroundColor Red
    Write-Host ("    {0,-24}: {1}" -f 'Scope Tag Ids',         ($Live.roleScopeTagIds -join ', ')) -ForegroundColor Red
    Write-Host ("    {0,-24}: {1}" -f 'Version',               $Live.version)               -ForegroundColor Red
    Write-Host ("    {0,-24}: {1}" -f 'Last Modified',         $Live.lastModifiedDateTime)  -ForegroundColor Red
    Write-Host "  ------------------------------------" -ForegroundColor Red
}

# Scan for remediation script folders
function Get-RemediationFolders {
    param(
        [string]$RootPath,
        [string]$SpecificFolder,
        [string[]]$SpecificFolders
    )

    Write-Host "`nScanning for remediation scripts in: $RootPath" -ForegroundColor Cyan

    # If the selected folder is itself a remediation folder, import just that one
    if ((Test-Path (Join-Path $RootPath "detection.ps1")) -and (Test-Path (Join-Path $RootPath "metadata.json"))) {
        Write-Host "Selected folder is a single remediation script" -ForegroundColor Yellow
        $single = Get-Item -Path $RootPath
        Write-Host "Found 1 remediation script folder" -ForegroundColor Green
        return @($single)
    }

    if ($SpecificFolders -and $SpecificFolders.Count -gt 0) {
        Write-Host "Filtering for $($SpecificFolders.Count) specific folders" -ForegroundColor Yellow
        $folders = Get-ChildItem -Path $RootPath -Directory | Where-Object {
            $detectionScript = Join-Path $_.FullName "detection.ps1"
            $metadataFile = Join-Path $_.FullName "metadata.json"

            ($SpecificFolders -contains $_.Name) -and (Test-Path $detectionScript) -and (Test-Path $metadataFile)
        }
    }
    elseif ($SpecificFolder) {
        Write-Host "Filtering for folder: $SpecificFolder" -ForegroundColor Yellow
        $folders = Get-ChildItem -Path $RootPath -Directory | Where-Object {
            $detectionScript = Join-Path $_.FullName "detection.ps1"
            $metadataFile = Join-Path $_.FullName "metadata.json"

            $_.Name -eq $SpecificFolder -and (Test-Path $detectionScript) -and (Test-Path $metadataFile)
        }
    }
    else {
        $folders = Get-ChildItem -Path $RootPath -Directory | Where-Object {
            $detectionScript = Join-Path $_.FullName "detection.ps1"
            $metadataFile = Join-Path $_.FullName "metadata.json"

            (Test-Path $detectionScript) -and (Test-Path $metadataFile)
        }
    }

    Write-Host "Found $($folders.Count) remediation script folders" -ForegroundColor Green
    return $folders
}

# ============================================================================
#  INTUNE GRAPH API OPERATIONS
#  Create / update deviceHealthScripts. Both handle the approval workflow:
#  a 412/409 response means the change was accepted but needs portal approval,
#  which is surfaced (not treated as a hard failure) to the caller.
# ============================================================================

# Create remediation script in Intune
function New-IntuneRemediationScript {
    param(
        [PSCustomObject]$Metadata,
        [string]$DetectionScriptContent,
        [string]$RemediationScriptContent,
        [string]$Justification = "Automated remediation script deployment via Push-RemediationsToIntune.ps1"
    )

    $body = New-RemediationRequestBody -Metadata $Metadata -DetectionScriptContent $DetectionScriptContent -RemediationScriptContent $RemediationScriptContent

    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts"
        $justificationBase64 = ConvertTo-Base64 -Content $Justification
        $headers = @{
            'x-msft-approval-justification' = $justificationBase64
        }
        $response = Invoke-MgGraphRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json -Depth 10) -Headers $headers
        return $response
    }
    catch {
        # Get full error details
        $errorDetails = $_.Exception.Message
        $fullError = $_ | Out-String

        # Check if approval is required (multiple patterns)
        $isApprovalRequired = (
            $errorDetails -match '412 Precondition Failed' -or
            $errorDetails -match 'PreconditionFailed' -or
            $errorDetails -match 'Precondition Failed' -or
            $errorDetails -match 'x-msft-approval-code' -or
            $fullError -match 'x-msft-approval-code' -or
            $fullError -match 'Approval Required'
        )

        if ($isApprovalRequired) {
            # Try to extract approval code from error details or full error
            if ($errorDetails -match 'x-msft-approval-code[:\s\\"]+([a-f0-9-]+)') {
                $approvalCode = $matches[1]
            }
            elseif ($fullError -match 'x-msft-approval-code[:\s\\"]+([a-f0-9-]+)') {
                $approvalCode = $matches[1]
            }
            else {
                $approvalCode = 'CHECK_PORTAL'
            }

            # Return a special object to indicate approval is pending
            return @{
                approvalRequired = $true
                approvalCode = $approvalCode
            }
        }

        # For other errors, return error details
        return @{
            error = $true
            message = $errorDetails
        }
    }
}

# Update existing remediation script in Intune
function Update-IntuneRemediationScript {
    param(
        [string]$Id,
        [PSCustomObject]$Metadata,
        [string]$DetectionScriptContent,
        [string]$RemediationScriptContent,
        [string]$Justification = "Automated remediation script update via Push-RemediationsToIntune.ps1"
    )

    $body = New-RemediationRequestBody -Metadata $Metadata -DetectionScriptContent $DetectionScriptContent -RemediationScriptContent $RemediationScriptContent

    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts/$Id"
        $justificationBase64 = ConvertTo-Base64 -Content $Justification
        $headers = @{
            'x-msft-approval-justification' = $justificationBase64
        }
        $response = Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body ($body | ConvertTo-Json -Depth 10) -Headers $headers -ErrorAction Stop
        return $response
    }
    catch {
        # Get full error details
        $errorDetails = $_.Exception.Message
        $fullError = $_ | Out-String

        # Check if approval is required (multiple patterns)
        $isApprovalRequired = (
            $errorDetails -match '412 Precondition Failed' -or
            $errorDetails -match 'PreconditionFailed' -or
            $errorDetails -match 'Precondition Failed' -or
            $errorDetails -match 'x-msft-approval-code' -or
            $fullError -match 'x-msft-approval-code' -or
            $fullError -match 'Approval Required'
        )

        if ($isApprovalRequired) {
            # Try to extract approval code from error details or full error
            if ($errorDetails -match 'x-msft-approval-code[:\s\\"]+([a-f0-9-]+)') {
                $approvalCode = $matches[1]
            }
            elseif ($fullError -match 'x-msft-approval-code[:\s\\"]+([a-f0-9-]+)') {
                $approvalCode = $matches[1]
            }
            else {
                $approvalCode = 'CHECK_PORTAL'
            }

            # Return a special object to indicate approval is pending (don't write error)
            return @{
                approvalRequired = $true
                approvalCode = $approvalCode
                id = $Id
            }
        }

        # Check if an approval request already exists (409 Conflict)
        if ($errorDetails -match '409 Conflict' -and $errorDetails -match 'An active Approval Request already exists') {
            # Return a special object to indicate approval is already pending (don't write error)
            return @{
                approvalRequired = $true
                approvalCode = 'PENDING'
                id = $Id
            }
        }

        # For other errors, return error details
        return @{
            error = $true
            message = $errorDetails
        }
    }
}

# Build the Graph "assign" body from an Assignment object (stored in metadata.json).
# Supports All Devices / All Users / a specific group, plus Daily/Hourly/Once schedules.
function Get-RemediationAssignmentBody {
    param([object]$Assignment)

    # Assignment target
    switch ($Assignment.Target) {
        'AllDevices' { $target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }
        'AllUsers'   { $target = @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } }
        'Group'      { $target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $Assignment.GroupId } }
        default      { throw "Unknown assignment target '$($Assignment.Target)'" }
    }

    $entry = @{
        target               = $target
        runRemediationScript = [bool]$Assignment.RunRemediation
    }

    # Run schedule (normalize HH:mm -> HH:mm:ss for Graph)
    if ($Assignment.ScheduleType) {
        $time = $Assignment.StartTime
        if ($time -and $time -notmatch ':\d{2}:\d{2}$') { $time = "$time`:00" }
        $useUtc = [bool]$Assignment.UseUtc

        switch ($Assignment.ScheduleType) {
            'Daily' {
                $entry.runSchedule = @{
                    '@odata.type' = '#microsoft.graph.deviceHealthScriptDailySchedule'
                    interval = [int]$Assignment.Interval
                    time     = $time
                    useUtc   = $useUtc
                }
            }
            'Hourly' {
                $entry.runSchedule = @{
                    '@odata.type' = '#microsoft.graph.deviceHealthScriptHourlySchedule'
                    interval = [int]$Assignment.Interval
                }
            }
            'Once' {
                $entry.runSchedule = @{
                    '@odata.type' = '#microsoft.graph.deviceHealthScriptRunOnceSchedule'
                    interval = 1
                    date     = $Assignment.StartDate
                    time     = $time
                    useUtc   = $useUtc
                }
            }
        }
    }

    return @{ deviceHealthScriptAssignments = @($entry) }
}

# POST the assignment for a newly-created remediation script
function Set-IntuneRemediationAssignment {
    param([string]$Id, [object]$Assignment)
    try {
        $uri = "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts/$Id/assign"
        $body = Get-RemediationAssignmentBody -Assignment $Assignment
        Invoke-MgGraphRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null
        return @{ success = $true }
    }
    catch {
        return @{ error = $true; message = $_.Exception.Message }
    }
}

# Interactively prompt for the create settings + assignment/schedule, writing the
# choices onto the metadata object (defaults come from the folder's metadata.json).
function Read-CreateSettings {
    param([object]$Metadata, [string]$FolderName)

    Write-Host "`n  ---- New remediation settings ----" -ForegroundColor Cyan
    Write-Host "  Enter values (press Enter to accept the [default]):" -ForegroundColor Gray

    # Precompute defaults (an 'if' expression is only valid in statement position,
    # not inline as a command argument).
    $defaultName  = if ($Metadata.DisplayName)     { $Metadata.DisplayName }     else { $FolderName }
    $defaultRunAs = if ($Metadata.RunAsAccount)    { $Metadata.RunAsAccount }    else { 'system' }
    $defaultScope = if ($Metadata.RoleScopeTagIds) { $Metadata.RoleScopeTagIds } else { '0' }

    $Metadata.DisplayName           = Read-TextSetting   -Label 'Display Name'      -Current $defaultName
    $Metadata.Description            = Read-TextSetting   -Label 'Description'       -Current $Metadata.Description
    $Metadata.Publisher             = Read-TextSetting   -Label 'Publisher'         -Current $Metadata.Publisher
    $Metadata.RunAsAccount          = Read-ChoiceSetting -Label 'Run As Account'    -Current $defaultRunAs -Choices @('system','user')
    $Metadata.RunAs32Bit            = Read-BoolSetting   -Label 'Run As 32-bit'     -Current ([bool]$Metadata.RunAs32Bit)
    $Metadata.EnforceSignatureCheck = Read-BoolSetting   -Label 'Enforce Signature' -Current ([bool]$Metadata.EnforceSignatureCheck)
    $Metadata.RoleScopeTagIds       = Read-TextSetting   -Label 'Scope Tag Ids'     -Current $defaultScope

    # --- Assignment ---
    Write-Host "`n  ---- Assignment ----" -ForegroundColor Cyan
    $assignTarget = Read-ChoiceSetting -Label 'Assign to' -Current 'None' -Choices @('None','AllDevices','AllUsers','Group')

    if ($assignTarget -eq 'None') {
        # Remove any assignment block so no assignment is created
        if ($Metadata.PSObject.Properties['Assignment']) { $Metadata.PSObject.Properties.Remove('Assignment') }
        Write-Host "  No assignment will be created." -ForegroundColor Gray
        return
    }

    $assignment = [ordered]@{ Target = $assignTarget }

    if ($assignTarget -eq 'Group') {
        while ($true) {
            $gid = Read-Host "    Group Object Id (GUID)"
            if ($gid -match '^[0-9a-fA-F-]{36}$') { $assignment.GroupId = $gid.Trim(); break }
            Write-Host "    Please enter a valid group object Id (GUID)." -ForegroundColor Yellow
        }
        $assignment.GroupName = Read-Host "    Group name (optional, for reference)"
    }

    # --- Schedule ---
    $scheduleType = Read-ChoiceSetting -Label 'Schedule' -Current 'Daily' -Choices @('Daily','Hourly','Once')
    $assignment.ScheduleType = $scheduleType

    switch ($scheduleType) {
        'Daily' {
            $assignment.Interval  = [int](Read-TextSetting -Label 'Every N day(s)' -Current '1')
            $assignment.StartTime = Read-TextSetting -Label 'Start time (HH:mm)' -Current '01:00'
        }
        'Hourly' {
            $assignment.Interval  = [int](Read-TextSetting -Label 'Every N hour(s)' -Current '1')
        }
        'Once' {
            $assignment.StartDate = Read-TextSetting -Label 'Run date (YYYY-MM-DD)' -Current (Get-Date).AddDays(1).ToString('yyyy-MM-dd')
            $assignment.StartTime = Read-TextSetting -Label 'Run time (HH:mm)' -Current '01:00'
        }
    }

    $assignment.RunRemediation = Read-BoolSetting -Label 'Run remediation script' -Current $true
    $assignment.UseUtc         = $false

    # Attach the assignment to the metadata object (add or replace)
    if ($Metadata.PSObject.Properties['Assignment']) {
        $Metadata.Assignment = [pscustomobject]$assignment
    }
    else {
        $Metadata | Add-Member -NotePropertyName 'Assignment' -NotePropertyValue ([pscustomobject]$assignment)
    }
}

# ============================================================================
#  MAIN EXECUTION
# ============================================================================

# --- Interactive menu: hand off to the TUI launcher and exit when -Menu is used ---
if ($Menu) {
    $launcher = Join-Path $PSScriptRoot 'Start-RemediationToolkit.ps1'
    if (-not (Test-Path $launcher)) {
        Write-Error "Menu launcher not found: $launcher"
        exit 1
    }
    & $launcher -StartAt Push -Path $Path
    exit $LASTEXITCODE
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Push Remediation Scripts to Intune" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# --- Step 0: Validate switch combination ---
# -Create and -UpdateExisting are opposing intents. If both are set, -UpdateExisting
# wins for any folder that already has an Id (matches the create/update logic below).
if ($Create -and $UpdateExisting) {
    Write-Warning "Both -Create and -UpdateExisting were specified. -UpdateExisting takes precedence for folders whose metadata.json already has an Id; folders without an Id are created."
}

# --- Step 1: Resolve the source path (optional graphical folder picker) ---
# Prompt for a folder via the graphical picker if requested
if ($BrowseFolder) {
    $selectedPath = Show-FolderPicker -InitialPath $Path
    if (-not $selectedPath) {
        Write-Warning "No folder selected. Exiting."
        exit 0
    }
    $Path = $selectedPath
    Write-Host "Selected folder: $Path" -ForegroundColor Green
}

# --- Step 2: Connect to Graph (skipped in -WhatIf mode) ---
# Connect to Graph
if (-not $WhatIfPreference) {
    Connect-ToGraph
}

# --- Step 3: Discover the remediation folders to process ---
# Get all remediation folders
$remediationFolders = Get-RemediationFolders -RootPath $Path -SpecificFolder $FolderName -SpecificFolders $FolderNames

if ($remediationFolders.Count -eq 0) {
    Write-Warning "No remediation script folders found."
    exit 0
}

# --- Step 4: Process each folder (read files -> justify -> create/update) ---
# Process each folder
$successCount = 0
$failCount = 0
$skippedCount = 0

foreach ($folder in $remediationFolders) {
    Write-Host "`n----------------------------------------" -ForegroundColor Yellow
    Write-Host "Processing: $($folder.Name)" -ForegroundColor Yellow
    Write-Host "----------------------------------------" -ForegroundColor Yellow

    # Read metadata
    $metadataPath = Join-Path $folder.FullName "metadata.json"
    $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json

    # Read detection script
    $detectionPath = Join-Path $folder.FullName "detection.ps1"
    $detectionContent = Get-Content $detectionPath -Raw

    # Read remediation script (if exists)
    $remediationPath = Join-Path $folder.FullName "remediation.ps1"
    $remediationContent = $null
    if (Test-Path $remediationPath) {
        $remediationContent = Get-Content $remediationPath -Raw
        Write-Host "  ✓ Detection and Remediation scripts found" -ForegroundColor Green
    }
    else {
        Write-Host "  ✓ Detection script found (no remediation)" -ForegroundColor Green
    }

    # Display metadata
    Write-Host "  Display Name: $($metadata.DisplayName)" -ForegroundColor White
    Write-Host "  Description: $($metadata.Description)" -ForegroundColor Gray
    Write-Host "  Publisher: $($metadata.Publisher)" -ForegroundColor Gray
    Write-Host "  Run As: $($metadata.RunAsAccount)" -ForegroundColor Gray
    Write-Host "  Run As 32-bit: $($metadata.RunAs32Bit)" -ForegroundColor Gray

    if ($WhatIfPreference) {
        Write-Host "  [WHATIF] Would upload to Intune" -ForegroundColor Magenta
        $skippedCount++
        continue
    }

    # --- Approval justification: prompt once, then reuse for the whole batch ---
    # Determine justification (only prompt once for batch processing)
    if (-not $script:batchJustification) {
        $justification = $ApprovalJustification

        if (-not $justification) {
            Write-Host "`n  Common justifications:" -ForegroundColor Cyan
            Write-Host "  1. Updating for Signature Enforcement" -ForegroundColor Gray
            Write-Host "  2. Security compliance update" -ForegroundColor Gray
            Write-Host "  3. Bug fix deployment" -ForegroundColor Gray
            Write-Host "  4. Custom (enter your own)" -ForegroundColor Gray
            Write-Host ""

            $choice = Read-Host "  Select option (1-4) or press Enter for default"

            switch ($choice) {
                "1" { $justification = "Updating for Signature Enforcement" }
                "2" { $justification = "Security compliance update" }
                "3" { $justification = "Bug fix deployment" }
                "4" {
                    $justification = Read-Host "  Enter custom justification"
                    if ([string]::IsNullOrWhiteSpace($justification)) {
                        if ($UpdateExisting) {
                            $justification = "Automated remediation script update via Push-RemediationsToIntune.ps1"
                        } else {
                            $justification = "Automated remediation script deployment via Push-RemediationsToIntune.ps1"
                        }
                    }
                }
                default {
                    if ($UpdateExisting) {
                        $justification = "Automated remediation script update via Push-RemediationsToIntune.ps1"
                    } else {
                        $justification = "Automated remediation script deployment via Push-RemediationsToIntune.ps1"
                    }
                }
            }
        }

        # Store for batch processing
        $script:batchJustification = $justification
    }
    else {
        $justification = $script:batchJustification
    }

    Write-Host "  Justification: $justification" -ForegroundColor Gray

    # --- Push to Intune: -UpdateExisting (with Id) patches; -Create always makes a new one; default creates ---
    # Create or update
    if ($UpdateExisting -and $metadata.Id) {

        # Interactive update: show the current LIVE settings from Intune, then let the
        # user keep them as-is or modify each one before the script content is patched.
        if ($Interactive) {
            $live = Get-LiveRemediationScript -Id $metadata.Id
            if ($live) {
                Show-RemediationSettings -Live $live

                # Start from the live values so "keep" truly preserves what's in Intune
                $metadata.DisplayName           = $live.displayName
                $metadata.Description            = $live.description
                $metadata.Publisher             = $live.publisher
                $metadata.RunAsAccount          = $live.runAsAccount
                $metadata.RunAs32Bit            = [bool]$live.runAs32Bit
                $metadata.EnforceSignatureCheck = [bool]$live.enforceSignatureCheck
                $metadata.RoleScopeTagIds       = ($live.roleScopeTagIds -join ', ')

                $modify = Read-BoolSetting -Label "Modify these settings before updating?" -Current $false
                if ($modify) {
                    Write-Host "`n  Enter new values (press Enter to keep the current value):" -ForegroundColor Cyan
                    $metadata.DisplayName           = Read-TextSetting   -Label 'Display Name'      -Current $metadata.DisplayName
                    $metadata.Description            = Read-TextSetting   -Label 'Description'       -Current $metadata.Description
                    $metadata.Publisher             = Read-TextSetting   -Label 'Publisher'         -Current $metadata.Publisher
                    $metadata.RunAsAccount          = Read-ChoiceSetting -Label 'Run As Account'    -Current $metadata.RunAsAccount -Choices @('system','user')
                    $metadata.RunAs32Bit            = Read-BoolSetting   -Label 'Run As 32-bit'     -Current ([bool]$metadata.RunAs32Bit)
                    $metadata.EnforceSignatureCheck = Read-BoolSetting   -Label 'Enforce Signature' -Current ([bool]$metadata.EnforceSignatureCheck)
                    $metadata.RoleScopeTagIds       = Read-TextSetting   -Label 'Scope Tag Ids'     -Current $metadata.RoleScopeTagIds
                }
                else {
                    Write-Host "  Keeping current settings; only the detection/remediation script content will be updated." -ForegroundColor Gray
                }
            }
            else {
                Write-Host "  Falling back to local metadata.json settings (could not read live settings)." -ForegroundColor Yellow
            }
        }

        Write-Host "  Updating existing remediation (ID: $($metadata.Id))..." -ForegroundColor Cyan
        $result = Update-IntuneRemediationScript -Id $metadata.Id -Metadata $metadata -DetectionScriptContent $detectionContent -RemediationScriptContent $remediationContent -Justification $justification -ErrorAction SilentlyContinue
    }
    else {
        # Creating a new remediation. Warn if this folder already maps to an Intune object,
        # since creating will produce a duplicate rather than updating the existing one.
        if ($metadata.Id) {
            if ($Create) {
                Write-Host "  -Create specified: creating a NEW remediation even though metadata.json already has an Id ($($metadata.Id)). A duplicate will be created in Intune." -ForegroundColor Yellow
            }
            else {
                Write-Host "  Note: metadata.json already has an Id ($($metadata.Id)); creating a duplicate. Use -UpdateExisting to update it instead." -ForegroundColor Yellow
            }
        }

        # Interactive create: prompt for settings + assignment/schedule (defaults from metadata.json)
        if ($Interactive) {
            Read-CreateSettings -Metadata $metadata -FolderName $folder.Name
        }

        Write-Host "  Creating new remediation script..." -ForegroundColor Cyan
        $result = New-IntuneRemediationScript -Metadata $metadata -DetectionScriptContent $detectionContent -RemediationScriptContent $remediationContent -Justification $justification -ErrorAction SilentlyContinue
    }

    # --- Interpret the API result: approval-pending / error / success, and tally counts ---
    if ($result) {
        # Check if approval is required
        if ($result.approvalRequired) {
            Write-Host "  ⚠ APPROVAL REQUIRED" -ForegroundColor Yellow
            Write-Host "  Approval Code: $($result.approvalCode)" -ForegroundColor Yellow
            Write-Host "  Go to Intune Portal > Endpoint Security > Remediations > Approvals to approve this change" -ForegroundColor Cyan
            $successCount++
        }
        elseif ($result.error) {
            Write-Host "  ✗ FAILED" -ForegroundColor Red
            Write-Host "  Error: $($result.message)" -ForegroundColor Red
            $failCount++
        }
        else {
            Write-Host "  ✓ SUCCESS" -ForegroundColor Green
            if ($result.id -and -not $UpdateExisting) {
                Write-Host "  New ID: $($result.id)" -ForegroundColor Green

                # Update metadata.json with new ID (Depth 10 so any Assignment block persists)
                $metadata.Id = $result.id
                $metadata.LastModifiedDateTime = Get-Date -Format "o"
                $metadata | ConvertTo-Json -Depth 10 | Set-Content $metadataPath
                Write-Host "  Updated metadata.json with new ID" -ForegroundColor Green

                # Create the assignment if one was configured (interactive create or metadata.json)
                if ($metadata.Assignment -and $metadata.Assignment.Target) {
                    $tgt = switch ($metadata.Assignment.Target) {
                        'Group' { "group '$($metadata.Assignment.GroupName)' ($($metadata.Assignment.GroupId))" }
                        default { $metadata.Assignment.Target }
                    }
                    Write-Host "  Creating assignment: $tgt ..." -ForegroundColor Cyan
                    $assignResult = Set-IntuneRemediationAssignment -Id $result.id -Assignment $metadata.Assignment
                    if ($assignResult.success) {
                        Write-Host "  ✓ Assignment created" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  ⚠ Assignment failed: $($assignResult.message)" -ForegroundColor Yellow
                        Write-Host "    (The script was created; you can assign it manually in Intune.)" -ForegroundColor Gray
                    }
                }
            }
            $successCount++
        }
    }
    else {
        Write-Host "  ✗ FAILED - No response from API" -ForegroundColor Red
        $failCount++
    }
}

# --- Step 5: Report results and disconnect ---
# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Total: $($remediationFolders.Count)" -ForegroundColor White
Write-Host "  Uploaded/Pending Approval: $successCount" -ForegroundColor Green
Write-Host "  Failed: $failCount" -ForegroundColor Red

# Disconnect (only if we actually have an active session)
if (-not $WhatIfPreference -and (Get-MgContext)) {
    Write-Host "`nDisconnecting from Microsoft Graph..." -ForegroundColor Cyan
    Disconnect-MgGraph | Out-Null
}

Write-Host "`nDone!" -ForegroundColor Green
