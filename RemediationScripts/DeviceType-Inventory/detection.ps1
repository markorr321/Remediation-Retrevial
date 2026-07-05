<#
.SYNOPSIS
    Device Type Inventory Script - Detects Physical/Virtual and reports to Entra ID + Log Analytics.

.DESCRIPTION
    Single script that:
    1. Detects if device is Physical or Virtual
    2. Writes result to local registry (cache)
    3. Calls Azure Function to update Entra ID extensionAttribute1
    4. Sends device inventory to Log Analytics workspace

.NOTES
    Run As: SYSTEM
    Deploy via: Intune Proactive Remediation (Detection only, no Remediation script needed)
    Always returns exit 0 after successful execution
#>

$PackageName = "DeviceTypeInventory"
$LogFolder = "$env:ProgramData\IntuneRemediations\$PackageName"
if (-not (Test-Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}
Start-Transcript -Path "$LogFolder\$PackageName.log" -Force -Append

#region Check Registry Flag
$RegistryPath = "HKLM:\SOFTWARE\Intune\DeviceType"
$RequiredVersion = 1

if (Test-Path $RegistryPath) {
    $CurrentVersion = (Get-ItemProperty -Path $RegistryPath -Name "Version" -ErrorAction SilentlyContinue).Version
    $DeviceType = (Get-ItemProperty -Path $RegistryPath -Name "DeviceType" -ErrorAction SilentlyContinue).DeviceType
    
    if ($DeviceType -and $CurrentVersion -ge $RequiredVersion) {
        Write-Output "Device already tagged as: $DeviceType (Version: $CurrentVersion) - skipping"
        Stop-Transcript
        exit 0
    }
}

Write-Output "Device not tagged or outdated - running inventory collection"
#endregion

#region Configuration
# Azure Function URL (includes function key)
$AzureFunctionUrl = "https://func-devicetype-prod.azurewebsites.net/api/UpdateDeviceType?code=<AZURE_FUNCTION_KEY>"

# Log Analytics Configuration
$LogAnalyticsWorkspaceId = "<LOG_ANALYTICS_WORKSPACE_ID>"
$LogAnalyticsPrimaryKey = "<LOG_ANALYTICS_PRIMARY_KEY>"
$LogType = "DeviceTypeInventory"

# Local registry path for caching
$RegistryPath = "HKLM:\SOFTWARE\Intune\DeviceType"
$Version = 1
#endregion

#region Log Analytics Functions
function Build-Signature {
    param(
        [string]$CustomerId,
        [string]$SharedKey,
        [string]$Date,
        [int]$ContentLength,
        [string]$Method,
        [string]$ContentType,
        [string]$Resource
    )
    $xHeaders = "x-ms-date:" + $Date
    $stringToHash = $Method + "`n" + $ContentLength + "`n" + $ContentType + "`n" + $xHeaders + "`n" + $Resource
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($SharedKey)
    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $CustomerId, $encodedHash
    return $authorization
}

function Send-LogAnalyticsData {
    param(
        [string]$CustomerId,
        [string]$SharedKey,
        [string]$Body,
        [string]$LogType
    )
    
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $Body.Length
    
    $signature = Build-Signature `
        -CustomerId $CustomerId `
        -SharedKey $SharedKey `
        -Date $rfc1123date `
        -ContentLength $contentLength `
        -Method $method `
        -ContentType $contentType `
        -Resource $resource
    
    $uri = "https://" + $CustomerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
    
    $headers = @{
        "Authorization"        = $signature
        "Log-Type"             = $LogType
        "x-ms-date"            = $rfc1123date
        "time-generated-field" = ""
    }
    
    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $Body -UseBasicParsing
    return $response.StatusCode
}
#endregion

#region VM Detection
Write-Output "Detecting if device is a virtual machine..."

$IsVirtual = $false

# Check Win32_ComputerSystem for VM indicators
$CS = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$Model = $CS.Model
$Manufacturer = $CS.Manufacturer

# Common VM signatures
$VMSignatures = @("Virtual Machine", "VMware", "VirtualBox", "QEMU", "KVM", "Xen", "Parallels")

foreach ($sig in $VMSignatures) {
    if ($Model -like "*$sig*" -or $Manufacturer -like "*$sig*") {
        $IsVirtual = $true
        break
    }
}

# Check Hyper-V registry (catches Windows 365)
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters") {
    $IsVirtual = $true
}

$DeviceType = if ($IsVirtual) { "Virtual" } else { "Physical" }
Write-Output "Device Type: $DeviceType (Model: $Model, Manufacturer: $Manufacturer)"
#endregion

#region Write to Local Registry
Write-Output "Writing to local registry..."

if (-not (Test-Path $RegistryPath)) {
    New-Item -Path $RegistryPath -Force | Out-Null
}

Set-ItemProperty -Path $RegistryPath -Name "DeviceType" -Value $DeviceType -Type String -Force
Set-ItemProperty -Path $RegistryPath -Name "Model" -Value $Model -Type String -Force
Set-ItemProperty -Path $RegistryPath -Name "Manufacturer" -Value $Manufacturer -Type String -Force
Set-ItemProperty -Path $RegistryPath -Name "DetectionDate" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Type String -Force
Set-ItemProperty -Path $RegistryPath -Name "Version" -Value $Version -Type DWord -Force

Write-Output "Registry updated successfully"
#endregion

#region Get Entra Device ID
$DSRegStatus = dsregcmd /status
$DeviceIdMatch = $DSRegStatus | Select-String -Pattern "DeviceId\s*:\s*(\S+)"

if ($DeviceIdMatch) {
    $EntraDeviceId = $DeviceIdMatch.Matches[0].Groups[1].Value
    Write-Output "Entra Device ID: $EntraDeviceId"
} else {
    Write-Error "Could not retrieve Entra Device ID"
    Stop-Transcript
    exit 1
}
#endregion

#region Call Azure Function
Write-Output "Calling Azure Function to update Entra ID..."

$Body = @{
    DeviceId   = $EntraDeviceId
    DeviceType = $DeviceType
} | ConvertTo-Json

try {
    $Response = Invoke-RestMethod -Uri $AzureFunctionUrl -Method POST -Body $Body -ContentType "application/json" -TimeoutSec 30
    Write-Output "Azure Function response: $Response"
    Write-Output "Successfully updated device type in Entra ID"
} catch {
    Write-Error "Failed to call Azure Function: $_"
    Stop-Transcript
    exit 1
}
#endregion

#region Send to Log Analytics
Write-Output "Sending device inventory to Log Analytics..."

$ComputerName = $env:COMPUTERNAME
$OSInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue

$DeviceInventory = @{
    DeviceName       = $ComputerName
    DeviceType       = $DeviceType
    Model            = $Model
    Manufacturer     = $Manufacturer
    EntraDeviceId    = $EntraDeviceId
    OSVersion        = $OSInfo.Version
    OSBuild          = $OSInfo.BuildNumber
    OSCaption        = $OSInfo.Caption
    CollectionDate   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    ScriptVersion    = $Version
}

$JsonPayload = ConvertTo-Json @($DeviceInventory)

try {
    $StatusCode = Send-LogAnalyticsData -CustomerId $LogAnalyticsWorkspaceId -SharedKey $LogAnalyticsPrimaryKey -Body $JsonPayload -LogType $LogType
    if ($StatusCode -eq 200) {
        Write-Output "Successfully sent data to Log Analytics (Status: $StatusCode)"
    } else {
        Write-Warning "Log Analytics returned status code: $StatusCode"
    }
} catch {
    Write-Warning "Failed to send data to Log Analytics: $_"
}
#endregion

Write-Output "Device type inventory completed successfully"
Stop-Transcript
exit 0


