<#
.SYNOPSIS
    Intune Remediation Script - Trigger Windows Store Apps Update Scan

.DESCRIPTION
    This remediation script triggers a Windows Store Apps (UWP) update scan on the device
    by invoking the UpdateScanMethod on the MDM_EnterpriseModernAppManagement_AppManagement01
    WMI class.
    
    The script runs when the detection script identifies that Store Apps have not been
    recently scanned for updates. It forces an immediate update check to ensure all
    Store Apps are current.
    
    This is part of a proactive remediation workflow to maintain Windows Store Apps in
    an up-to-date state across all managed devices.
    
    All execution details are logged to: C:\ProgramData\IntuneRemediations\StoreApps

.NOTES
    Author:         First American
    Company:        First American
    Purpose:        Intune Proactive Remediation - Remediation
    Log Location:   C:\ProgramData\IntuneRemediations\StoreApps
    
.EXIT CODES
    0       Remediation succeeded - update scan triggered
    2000    Remediation failed - unable to trigger scan

.REQUIREMENTS
    - Device must be enrolled in Microsoft Intune/MDM
    - Requires access to Root\cimv2\mdm\dmmap WMI namespace
    - PowerShell execution policy must allow script execution
    - Sufficient permissions to invoke WMI methods
#>

# =========================
# Remediation Script - Trigger Store Apps Update Scan
# Logs to: C:\ProgramData\IntuneRemediations\StoreApps
# Exit 0  = Remediation succeeded
# Exit 2000 = Remediation failed
# =========================

$LogRoot = "C:\ProgramData\IntuneRemediations\StoreApps"
if (-not (Test-Path $LogRoot)) {
    New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
}

$LogFile = Join-Path $LogRoot ("Remediation-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [Parameter(Mandatory=$false)][ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    # Write to file
    $line | Out-File -FilePath $LogFile -Encoding UTF8 -Append
    # Also write to standard output (shows in Intune logs)
    Write-Output $line
}

function Write-LogHeader {
    $separator = "=" * 80
    Write-Log $separator
    Write-Log "REMEDIATION SCRIPT STARTED"
    Write-Log "Computer Name: $env:COMPUTERNAME"
    Write-Log "User: $env:USERNAME"
    Write-Log "OS: $((Get-CimInstance Win32_OperatingSystem).Caption)"
    Write-Log "PowerShell Version: $($PSVersionTable.PSVersion.ToString())"
    Write-Log "Log File: $LogFile"
    Write-Log $separator
}

try {
    Write-LogHeader
    
    Write-Log "Initiating Store Apps update scan remediation"
    Write-Log "Querying WMI namespace: Root\cimv2\mdm\dmmap"
    Write-Log "Querying class: MDM_EnterpriseModernAppManagement_AppManagement01"
    
    $wmiObj = Get-CimInstance -Namespace "Root\cimv2\mdm\dmmap" -ClassName "MDM_EnterpriseModernAppManagement_AppManagement01" -ErrorAction Stop

    if (-not $wmiObj) {
        Write-Log "WMI object returned null. MDM classes may not be available on this system." -Level ERROR
        Write-Log "This typically indicates the device is not properly enrolled in MDM/Intune." -Level WARN
        Write-Log "Cannot invoke UpdateScanMethod without valid WMI object." -Level ERROR
        Write-Log "REMEDIATION FAILED - Exit Code: 2000" -Level ERROR
        Exit 2000
    }

    Write-Log "Successfully retrieved WMI object"
    Write-Log "Invoking UpdateScanMethod on MDM_EnterpriseModernAppManagement_AppManagement01..."
    
    $result = $wmiObj | Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop

    Write-Log "UpdateScanMethod invoked successfully"
    
    if ($result) {
        Write-Log "Method return value:"
        Write-Log "  ReturnValue: $($result.ReturnValue)"
        if ($result.PSObject.Properties.Count -gt 1) {
            $result.PSObject.Properties | ForEach-Object {
                if ($_.Name -ne 'PSComputerName' -and $_.Name -ne 'PSShowComputerName') {
                    Write-Log "  $($_.Name): $($_.Value)"
                }
            }
        }
    } else {
        Write-Log "Method returned null result" -Level WARN
    }

    Write-Log "Store Apps update scan triggered successfully"
    Write-Log "REMEDIATION COMPLETED - Exit Code: 0" -Level INFO
    Exit 0
}
catch {
    Write-Log "Exception during remediation: $($_.Exception.Message)" -Level ERROR
    Write-Log "Exception Type: $($_.Exception.GetType().FullName)" -Level ERROR
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level ERROR
    }
    Write-Log "REMEDIATION FAILED - Exit Code: 2000" -Level ERROR
    Exit 2000
}

