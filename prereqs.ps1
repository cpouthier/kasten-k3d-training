<#
.SYNOPSIS
    Prepares a Windows machine to run the Veeam Kasten k3d training lab
    (deploy.sh) inside WSL2.

.DESCRIPTION
    deploy.sh is a bash script and assumes a Linux environment, so on
    Windows it runs inside WSL2 rather than natively — this is the same
    approach the lab's README already recommends, just automated. This
    script only handles the Windows-side setup:

      1. Checks the Windows build supports the modern `wsl --install`
         one-liner, and runs it if WSL2 / a Linux distro isn't installed
         yet (this also enables the required Windows features).
      2. Checks for Docker Desktop and installs it via winget if missing.
      3. Prints the exact commands to finish setup: enabling Docker
         Desktop's WSL integration (a one-time checkbox — there's no
         stable scriptable API for it across Docker Desktop versions, so
         this is a manual step) and fetching + running deploy.sh inside
         your WSL2 distro.

    Safe to re-run: every step checks current state first and skips
    anything already done.

.NOTES
    Run this from an elevated PowerShell (Run as Administrator) — enabling
    WSL and installing software both need it.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$DeployScriptUrl = 'https://raw.githubusercontent.com/cpouthier/kasten-k3d-training/main/deploy.sh'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# --- 0. Windows version check ------------------------------------------------
Write-Step "Checking Windows version..."
$build = [System.Environment]::OSVersion.Version.Build
if ($build -lt 19041) {
    Write-Warn2 "Windows build $build detected — `wsl --install` needs build 19041+ (Windows 10 version 2004) or Windows 11."
    Write-Warn2 "Update Windows first (Settings > Windows Update), then re-run this script."
    Write-Warn2 "Alternatively, follow the manual WSL2 install guide: https://learn.microsoft.com/windows/wsl/install-manual"
    exit 1
}
Write-Host "    OK (build $build)"

# --- 1. WSL2 + a Linux distro -------------------------------------------------
Write-Step "Checking for WSL2..."
$wslInstalled = $false
try {
    $wslStatus = wsl --status 2>&1
    if ($LASTEXITCODE -eq 0) { $wslInstalled = $true }
} catch {
    $wslInstalled = $false
}

if ($wslInstalled) {
    Write-Host "    WSL is already installed."
    $distros = (wsl -l -q 2>&1) -join "`n"
    if ([string]::IsNullOrWhiteSpace($distros)) {
        Write-Warn2 "No Linux distro installed under WSL yet — installing the default (Ubuntu)..."
        wsl --install -d Ubuntu
        Write-Warn2 "A reboot may be required. After rebooting, launch 'Ubuntu' from the Start Menu once to finish its first-run setup (creating a username/password), then re-run this script."
        exit 0
    } else {
        Write-Host "    Distro(s) found:"
        $distros -split "`n" | ForEach-Object { Write-Host "      $_" }
    }
} else {
    Write-Warn2 "WSL not found — installing WSL2 + Ubuntu (this enables required Windows features too)..."
    wsl --install
    Write-Warn2 "A REBOOT IS REQUIRED to finish this. After rebooting:"
    Write-Warn2 "  1. Launch 'Ubuntu' from the Start Menu once to finish its first-run setup (username/password)."
    Write-Warn2 "  2. Re-run this script to continue with Docker Desktop."
    exit 0
}

# --- 2. Docker Desktop --------------------------------------------------------
Write-Step "Checking for Docker Desktop..."
$dockerInstalled = (Get-Command docker -ErrorAction SilentlyContinue) -or (Test-Path "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe")

if ($dockerInstalled) {
    Write-Host "    Docker Desktop is already installed."
} else {
    Write-Warn2 "Docker Desktop not found."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Step "Installing Docker Desktop via winget..."
        winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    } else {
        Write-Warn2 "winget isn't available on this machine."
        Write-Warn2 "Download and install Docker Desktop manually: https://www.docker.com/products/docker-desktop/"
        Write-Warn2 "Then re-run this script."
        exit 1
    }
}

# --- 3. What's left (manual, one-time) ---------------------------------------
Write-Step "Almost done — two manual steps left:"
Write-Host @"

1. Launch Docker Desktop. On first launch it may ask you to sign in/accept
   its terms — click through that, then go to:
       Settings > Resources > WSL Integration
   and enable integration for your Ubuntu distro (recent Docker Desktop
   versions do this by default, but double-check it's toggled on).

2. Open 'Ubuntu' from the Start Menu (or run 'wsl' from any terminal), then
   inside that Linux shell run:

       curl -fsSL $DeployScriptUrl -o deploy.sh
       chmod +x deploy.sh
       ./deploy.sh

   That single script does everything else (k3d cluster, Veeam Kasten, MinIO,
   the sample app) — no git clone, no other files needed. To tear the lab
   down later, run './deploy.sh destroy' the same way.

"@
