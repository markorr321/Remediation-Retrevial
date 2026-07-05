<#
    Detection - Test Remediation Marker
    Safe, reversible test remediation for validating the toolkit end to end.

    Checks for a benign registry marker:
        HKLM:\SOFTWARE\OrrTest\RemediationTest = "Compliant"

    Exit 0 = compliant (marker present)   -> no remediation runs
    Exit 1 = non-compliant (marker missing) -> remediation runs
#>

$Path  = 'HKLM:\SOFTWARE\OrrTest'
$Name  = 'RemediationTest'
$Value = 'Compliant'

try {
    $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
    if ($current -eq $Value) {
        Write-Output "Compliant: $Name = $current"
        exit 0
    }
    else {
        Write-Output "Non-compliant: $Name = '$current' (expected '$Value')"
        exit 1
    }
}
catch {
    Write-Output "Non-compliant: marker not found"
    exit 1
}

