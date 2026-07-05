<#
.SYNOPSIS
    Intune Remediation Detection Script - Windows Store Apps Update Status

.DESCRIPTION
    This detection script checks the update status of Windows Store Apps (UWP applications)
    by querying the MDM_EnterpriseModernAppManagement_AppManagement01 WMI class.
    
    The script evaluates the LastScanError property to determine if Store Apps have been
    successfully scanned for updates. A value of '0' indicates apps are current, while
    any other value suggests an update check is needed.
    
    This is part of a proactive remediation workflow to ensure Windows Store Apps remain
    up-to-date on managed devices.
    
    All execution details are logged to: C:\ProgramData\IntuneRemediations\StoreApps

.NOTES
    Author:         First American
    Company:        First American
    Purpose:        Intune Proactive Remediation - Detection
    Log Location:   C:\ProgramData\IntuneRemediations\StoreApps
    
.EXIT CODES
    0       Store apps are updated (compliant)
    1       Store apps not updated - remediation required
    2000    Unable to query WMI - script failed

.REQUIREMENTS
    - Device must be enrolled in Microsoft Intune/MDM
    - Requires access to Root\cimv2\mdm\dmmap WMI namespace
    - PowerShell execution policy must allow script execution
#>

# =========================
# Detection Script - Store Apps Update Status
# Logs to: C:\ProgramData\IntuneRemediations\StoreApps
# Exit 0  = Store apps updated
# Exit 1  = Not updated (remediation should run)
# Exit 2000 = Unable to query
# =========================

$LogRoot = "C:\ProgramData\IntuneRemediations\StoreApps"
if (-not (Test-Path $LogRoot)) {
    New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
}

$LogFile = Join-Path $LogRoot ("Detection-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

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
    Write-Log "DETECTION SCRIPT STARTED"
    Write-Log "Computer Name: $env:COMPUTERNAME"
    Write-Log "User: $env:USERNAME"
    Write-Log "OS: $((Get-CimInstance Win32_OperatingSystem).Caption)"
    Write-Log "PowerShell Version: $($PSVersionTable.PSVersion.ToString())"
    Write-Log "Log File: $LogFile"
    Write-Log $separator
}

try {
    Write-LogHeader
    
    Write-Log "Querying WMI namespace: Root\cimv2\mdm\dmmap"
    Write-Log "Querying class: MDM_EnterpriseModernAppManagement_AppManagement01"
    
    $wmiObj = Get-CimInstance -Namespace "Root\cimv2\mdm\dmmap" -ClassName "MDM_EnterpriseModernAppManagement_AppManagement01" -ErrorAction Stop

    if (-not $wmiObj) {
        Write-Log "WMI object returned null. MDM classes may not be available on this system." -Level ERROR
        Write-Log "This typically indicates the device is not properly enrolled in MDM/Intune." -Level WARN
        Write-Log "DETECTION FAILED - Exit Code: 2000" -Level ERROR
        Exit 2000
    }

    Write-Log "Successfully retrieved WMI object"
    Write-Log "Checking LastScanError property..."
    
    $lastScanError = $wmiObj.LastScanError
    Write-Log "LastScanError value: '$lastScanError'"

    if ($lastScanError -ne '0') {
        Write-Log "Store Apps update check needed (LastScanError = '$lastScanError', expected '0')" -Level WARN
        Write-Log "REMEDIATION REQUIRED - Exit Code: 1" -Level INFO
        Exit 1   # Non-zero so remediation runs
    }
    else {
        Write-Log "Store Apps are up to date (LastScanError = '0')"
        Write-Log "DETECTION PASSED - Exit Code: 0" -Level INFO
        Exit 0
    }
}
catch {
    Write-Log "Exception during detection: $($_.Exception.Message)" -Level ERROR
    Write-Log "Exception Type: $($_.Exception.GetType().FullName)" -Level ERROR
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level ERROR
    }
    Write-Log "DETECTION FAILED - Exit Code: 2000" -Level ERROR
    Exit 2000
}

