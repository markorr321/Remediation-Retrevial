<#
    Remediation - Test Remediation Marker
    Creates the benign registry marker that detection.ps1 looks for:
        HKLM:\SOFTWARE\OrrTest\RemediationTest = "Compliant"

    To undo/reset after testing:
        Remove-Item 'HKLM:\SOFTWARE\OrrTest' -Recurse -Force

    Exit 0 = remediation succeeded
    Exit 1 = remediation failed
#>

$Path  = 'HKLM:\SOFTWARE\OrrTest'
$Name  = 'RemediationTest'
$Value = 'Compliant'

try {
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
    Write-Output "Remediated: set $Name = $Value"
    exit 0
}
catch {
    Write-Output "Remediation failed: $($_.Exception.Message)"
    exit 1
}

