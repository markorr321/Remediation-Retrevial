$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFolder = "C:\Temp\PAR-CompanyPortal_$timestamp"
New-Item -Path $logFolder -ItemType Directory -Force | Out-Null
$logFile = Join-Path $logFolder "CompanyPortal.log"

function Write-Log {
    param([string]$Message)
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Add-Content -Path $logFile -Value $entry
    Write-Output $Message
}

$app = Get-AppxPackage -Name "Microsoft.CompanyPortal" -ErrorAction SilentlyContinue
if ($app) {
    Write-Log "Company Portal is installed."
    exit 0
} else {
    Write-Log "Company Portal not found. Installing..."
    Invoke-WebRequest -Uri "https://get.microsoft.com/installer/download/9WZDNCRFJ3PZ?hl=en-us&gl=us&referrer=storeforweb" -OutFile "$env:TEMP\CompanyPortalInstaller.exe"
    Write-Log "Download complete. Starting installation..."
    Start-Process "$env:TEMP\CompanyPortalInstaller.exe" -Wait
    Write-Log "Installation process completed."
    exit 1
}


