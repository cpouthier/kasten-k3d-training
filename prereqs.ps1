<#
.SYNOPSIS
    Prepares a Windows machine to run the Veeam Kasten k3d training lab
    (deploy.sh) inside WSL2, with Docker Engine installed natively inside
    the Ubuntu distro (no Docker Desktop on Windows).

.DESCRIPTION
    deploy.sh is a bash script and assumes a Linux environment, so on
    Windows it runs inside WSL2 rather than natively - this is the same
    approach the lab's README already recommends, just automated. This
    script only handles the Windows-side setup:

      1. Checks the Windows build supports the modern "wsl --install"
         one-liner, and runs it if WSL2 / a Linux distro isn't installed
         yet (this also enables the required Windows features).
      2. Installs Docker Engine directly inside the Ubuntu distro (the
         official convenience script, get.docker.com), configures it to
         start automatically on every WSL launch, and adds the distro's
         default user to the "docker" group.
      3. Prints the exact command to fetch + run deploy.sh inside WSL2.

    Docker never touches Windows itself here - no Docker Desktop, no
    WSL integration setting to toggle. Safe to re-run: every step checks
    current state first and skips anything already done.

.NOTES
    Run this from an elevated PowerShell (Run as Administrator) - enabling
    WSL and installing software both need it.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$DeployScriptUrl = 'https://raw.githubusercontent.com/cpouthier/kasten-k3d-training/main/deploy.sh'
$Distro = 'Ubuntu'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# --- 0. Windows version check ------------------------------------------------
Write-Step "Checking Windows version..."
$build = [System.Environment]::OSVersion.Version.Build
if ($build -lt 19041) {
    Write-Warn2 "Windows build $build detected - the 'wsl --install' command needs build 19041+ (Windows 10 version 2004) or Windows 11."
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
        Write-Warn2 "No Linux distro installed under WSL yet - installing the default ($Distro)..."
        wsl --install -d $Distro
        Write-Warn2 "A reboot may be required. After rebooting, launch '$Distro' from the Start Menu once to finish its first-run setup (creating a username/password), then re-run this script."
        exit 0
    } else {
        Write-Host "    Distro(s) found:"
        $distros -split "`n" | ForEach-Object { Write-Host "      $_" }
    }
} else {
    Write-Warn2 "WSL not found - installing WSL2 + $Distro (this enables required Windows features too)..."
    wsl --install -d $Distro
    Write-Warn2 "A REBOOT IS REQUIRED to finish this. After rebooting:"
    Write-Warn2 "  1. Launch '$Distro' from the Start Menu once to finish its first-run setup (username/password)."
    Write-Warn2 "  2. Re-run this script to continue with Docker."
    exit 0
}

# --- 2. Docker Engine inside the distro ---------------------------------------
Write-Step "Setting up Docker Engine inside $Distro..."

# Runs as root inside the distro (wsl -u root) so nothing here needs an
# interactive sudo password. Idempotent: every check looks at current state
# first. WSL images from Microsoft don't run systemd out of the box, so
# instead of a systemd unit, this uses the older (but universally supported)
# /etc/wsl.conf "boot.command" hook, which runs once, automatically, every
# time this distro starts.
$setupScript = @'
#!/bin/sh
set -e

CONF_CHANGED=0
if ! grep -q "service docker start" /etc/wsl.conf 2>/dev/null; then
  { echo ""; echo "[boot]"; echo "command = \"service docker start\""; } >> /etc/wsl.conf
  CONF_CHANGED=1
fi

INSTALLED=0
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  INSTALLED=1
fi

service docker start >/dev/null 2>&1 || true

DEFAULT_USER=$(getent passwd 1000 | cut -d: -f1)
GROUP_CHANGED=0
if [ -n "$DEFAULT_USER" ] && ! id -nG "$DEFAULT_USER" | grep -qw docker; then
  usermod -aG docker "$DEFAULT_USER"
  GROUP_CHANGED=1
fi

echo "CONF_CHANGED=$CONF_CHANGED"
echo "INSTALLED=$INSTALLED"
echo "GROUP_CHANGED=$GROUP_CHANGED"
echo "DEFAULT_USER=$DEFAULT_USER"
'@

$result = $setupScript | wsl -d $Distro -u root -- sh
$result | ForEach-Object { Write-Host "    $_" }

$confChanged = ($result -match '^CONF_CHANGED=1$').Count -gt 0
$groupChanged = ($result -match '^GROUP_CHANGED=1$').Count -gt 0

if ($confChanged) {
    Write-Warn2 "Docker's auto-start hook was just added to /etc/wsl.conf - this only takes effect on a fresh WSL boot."
    Write-Warn2 "Restarting WSL now..."
    wsl --shutdown
    Write-Warn2 "Re-run this script to finish setup - it picks up right where it left off."
    exit 0
}

Write-Step "Verifying Docker is reachable inside $Distro..."
wsl -d $Distro -u root -- docker info | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "    Docker Engine is up and running."
} else {
    Write-Warn2 "Docker doesn't look reachable yet, even as root. Something above may have failed - check the output."
    exit 1
}

if ($groupChanged) {
    Write-Warn2 "Your $Distro user was just added to the 'docker' group. This needs a brand-new WSL session to take effect (existing terminals won't pick it up)."
}

# --- 3. What's left -------------------------------------------------------------
Write-Step "Almost done:"
Write-Host @"

Open a NEW '$Distro' terminal (from the Start Menu, or run 'wsl' - close
any $Distro terminal you already had open first if this is the first time
this script added you to the docker group), then inside it run:

    curl -fsSL $DeployScriptUrl -o deploy.sh
    chmod +x deploy.sh
    ./deploy.sh

That single script does everything else (k3d cluster, Veeam Kasten, MinIO,
the sample app) - no git clone, no other files needed. To tear the lab
down later, run './deploy.sh destroy' the same way.

"@
