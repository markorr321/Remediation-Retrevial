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
    Write-Log "Starting remediation: triggering Store apps update scan..."

    $wmiObj = Get-CimInstance -Namespace "Root\cimv2\mdm\dmmap" -ClassName "MDM_EnterpriseModernAppManagement_AppManagement01"

    if (-not $wmiObj) {
        Write-Log "WMI object is null. Cannot invoke UpdateScanMethod."
        Exit 2000
    }

    $result = $wmiObj | Invoke-CimMethod -MethodName UpdateScanMethod

    Write-Log "Invoke-CimMethod UpdateScanMethod returned: $($result | Out-String)"

    Write-Log "Windows Store Apps update scan triggered successfully."
    Exit 0
}
catch {
    Write-Log "Exception during remediation: $($_.Exception.Message)"
    Exit 2000
}


