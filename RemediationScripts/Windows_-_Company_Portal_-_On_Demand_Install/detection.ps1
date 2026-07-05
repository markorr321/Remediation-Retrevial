<#
.SYNOPSIS
    Install Company Portal On-Demand Script

.DESCRIPTION
    This PowerShell script automatically detects and installs the Microsoft Company Portal
    application if it's not already present on a Windows device.

.HOW IT WORKS
    1. Logging Setup
       - Creates a timestamped log folder: C:\Temp\PAR-CompanyPortal_yyyyMMdd_HHmmss\
       - Generates a log file to track the installation process
       - All actions are logged with timestamps

    2. Detection Phase
       - Uses Get-AppxPackage to check if Microsoft Company Portal is already installed
       - Searches for the package name: Microsoft.CompanyPortal

    3. Installation Logic
       - If Company Portal is found:
         * Logs "Company Portal is installed"
         * Exits with code 0 (success, no action needed)

       - If Company Portal is NOT found:
         * Logs "Company Portal not found. Installing..."
         * Downloads the installer from Microsoft's official URL
         * Saves installer to: $env:TEMP\CompanyPortalInstaller.exe
         * Runs the installer and waits for completion (INTERACTIVE - user will see installation UI)
         * Logs completion message
         * Exits with code 1 (action taken - installation performed)

.KEY FEATURES
    - Idempotent: Won't reinstall if already present
    - Logged: Full audit trail of actions
    - Interactive Installation: User will see and interact with the Microsoft installer UI
    - Exit Codes: 0 = already installed, 1 = installation performed

.USE CASE
    Typically deployed via Intune, SCCM, or other management tools to ensure Company Portal
    (required for corporate app deployment and device management) is available on managed
    Windows devices.

.NOTES
    Author: Mark Orr
    Exit Code 0: Company Portal already installed
    Exit Code 1: Company Portal was installed during execution
#>

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
}
else {
    Write-Log "Company Portal not found. Installing..."
    Invoke-WebRequest -Uri "https://get.microsoft.com/installer/download/9WZDNCRFJ3PZ?hl=en-us&gl=us&referrer=storeforweb" -OutFile "$env:TEMP\CompanyPortalInstaller.exe"
    Write-Log "Download complete. Starting installation..."
    Start-Process "$env:TEMP\CompanyPortalInstaller.exe" -Wait
    Write-Log "Installation process completed."
    exit 1
}

