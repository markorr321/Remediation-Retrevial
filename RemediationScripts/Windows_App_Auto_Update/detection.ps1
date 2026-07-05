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
        [Parameter(Mandatory=$true)][string]$Message
    )
    $timestamp = Get-Date -Format "s"
    $line = "$timestamp`t$Message"
    # Write to file
    $line | Out-File -FilePath $LogFile -Encoding UTF8 -Append
    # Also write to standard output (shows in Intune logs)
    Write-Output $line
}

try {
    Write-Log "Starting detection: querying MDM_EnterpriseModernAppManagement_AppManagement01..."
    $wmiObj = Get-CimInstance -Namespace "Root\cimv2\mdm\dmmap" -ClassName "MDM_EnterpriseModernAppManagement_AppManagement01"

    if (-not $wmiObj) {
        Write-Log "WMI object is null. Unable to determine Store app update status."
        Exit 2000
    }

    Write-Log "LastScanError value: $($wmiObj.LastScanError)"

    if ($wmiObj.LastScanError -ne '0') {
        Write-Log "Windows Store Apps not updated (LastScanError != 0)."
        Exit 1   # Non-zero so remediation runs
    }
    else {
        Write-Log "Windows Store Apps updated (LastScanError = 0)."
        Exit 0
    }
}
catch {
    Write-Log "Exception during detection: $($_.Exception.Message)"
    Exit 2000
}


