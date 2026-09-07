<#
.SYNOPSIS
    Removes WSL2 and any Linux distros installed for it, undoing what
    prereqs.ps1 set up.

.DESCRIPTION
    This is destructive: unregistering a WSL distro permanently deletes its
    entire filesystem, including anything you deployed inside it (a running
    Veeam Kasten lab, deploy.sh, etc.). This script lists everything it
    found and asks for confirmation before removing anything, unless
    -Force is passed.

    Steps:
      1. Lists installed WSL distros and unregisters each one (deletes its
         virtual disk).
      2. Disables the "Windows Subsystem for Linux" and "Virtual Machine
         Platform" Windows features.
      3. Removes the WSL app package if it was installed via the Microsoft
         Store (how newer Windows versions distribute it).

    A reboot is required afterward to finish removing the Windows features.

    WARNING: prereqs.ps1 installs Docker Engine directly inside the Ubuntu
    distro, so unregistering it here deletes Docker along with everything
    else in that distro. Separately, if you also have Docker Desktop
    installed and it's using the WSL2 backend (its default), disabling the
    WSL2 Windows features will break it too, until you either reinstall
    WSL2 or switch Docker Desktop to the Hyper-V backend.

.PARAMETER Force
    Skip the confirmation prompt and remove everything found.

.NOTES
    Run this from an elevated PowerShell (Run as Administrator).
#>

#Requires -RunAsAdministrator

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# --- 1. Find what's installed -------------------------------------------------
Write-Step "Checking what's installed..."

# Docker Desktop's WSL2 backend registers its own hidden distros
# (docker-desktop runs the engine, docker-desktop-data holds all
# image/container/volume data) alongside whatever distro you actually use.
# Those belong to Docker Desktop, not to this lab's setup, so they're
# excluded here, removing them would delete Docker Desktop's engine and
# all of its data, not just undo prereqs.ps1.
$dockerDesktopDistros = @('docker-desktop', 'docker-desktop-data')

$distros = @()
try {
    $distros = (wsl -l -q 2>&1) | Where-Object { $_ -and ($_.Trim() -ne '') -and ($dockerDesktopDistros -notcontains $_.Trim()) }
} catch {
    $distros = @()
}

if ($distros.Count -eq 0) {
    Write-Host "    No WSL distros found (other than Docker Desktop's own, which this script leaves alone)."
} else {
    Write-Warn2 "The following distro(s) will be PERMANENTLY DELETED, including all files inside them:"
    $distros | ForEach-Object { Write-Host "      - $_" }
}

$wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
$vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
$wslFeatureOn = $wslFeature -and ($wslFeature.State -eq 'Enabled')
$vmpFeatureOn = $vmpFeature -and ($vmpFeature.State -eq 'Enabled')

if ($wslFeatureOn) {
    Write-Host "    Windows feature 'Windows Subsystem for Linux' is enabled and will be disabled."
}
if ($vmpFeatureOn) {
    Write-Host "    Windows feature 'Virtual Machine Platform' is enabled and will be disabled."
}

if (($distros.Count -eq 0) -and (-not $wslFeatureOn) -and (-not $vmpFeatureOn)) {
    Write-Host "`nNothing to remove, WSL isn't installed."
    exit 0
}

Write-Warn2 "Docker Engine lives inside these distro(s) (installed there by prereqs.ps1), so removing them deletes Docker along with everything else."
Write-Warn2 "If you separately have Docker Desktop installed and it's using the WSL2 backend, disabling the WSL2 features will also break it until WSL2 is reinstalled or it's switched to the Hyper-V backend."

# --- 2. Confirm -----------------------------------------------------------------
if (-not $Force) {
    Write-Host ""
    $answer = Read-Host "Type 'yes' to permanently remove all of the above (anything else cancels)"
    if ($answer -ne 'yes') {
        Write-Host "Cancelled, nothing was removed."
        exit 0
    }
}

# --- 3. Unregister distros --------------------------------------------------------
foreach ($distro in $distros) {
    Write-Step "Removing distro '$distro'..."
    wsl --unregister $distro
}

# --- 4. Disable the Windows features -----------------------------------------------
if ($wslFeatureOn) {
    Write-Step "Disabling 'Windows Subsystem for Linux'..."
    Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -ErrorAction SilentlyContinue | Out-Null
}
if ($vmpFeatureOn) {
    Write-Step "Disabling 'Virtual Machine Platform'..."
    Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -ErrorAction SilentlyContinue | Out-Null
}

# --- 5. Remove the WSL app package, if installed that way --------------------------
Write-Step "Checking for the WSL app package (Microsoft Store install)..."
$wslPackage = Get-AppxPackage -AllUsers -Name "MicrosoftCorporationII.WindowsSubsystemForLinux" -ErrorAction SilentlyContinue
if ($wslPackage) {
    Write-Step "Removing the WSL app package..."
    Remove-AppxPackage -Package $wslPackage.PackageFullName -AllUsers -ErrorAction SilentlyContinue
} else {
    Write-Host "    Not installed as a Store app, nothing to remove there."
}

Write-Step "Done. A REBOOT is required to finish removing the Windows features."
