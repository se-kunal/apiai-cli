#Requires -Version 5.1
# ================================================================
#  API.AI  |  Uninstaller
#  Removes the `api` command and all CLI files.
#
#  Usage:
#    irm https://your-domain.com/uninstall.ps1 | iex
# ================================================================

$INSTALL_DIR = Join-Path $env:LOCALAPPDATA "apiai-cli"
$BIN_DIR     = Join-Path $INSTALL_DIR "bin"

$ESC     = [char]27
$SUCCESS = "$ESC[38;2;72;199;142m"
$WARN    = "$ESC[38;2;251;189;35m"
$INFO    = "$ESC[38;2;148;163;184m"
$MUTED   = "$ESC[38;2;71;85;105m"
$CYAN    = "$ESC[38;2;34;211;238m"
$RESET   = "$ESC[0m"

Write-Host ""
Write-Host "  API.AI Uninstaller"
Write-Host ""

if (-not (Test-Path $INSTALL_DIR)) {
    Write-Host "  $INFO`u{25CF}$RESET API.AI CLI is not installed. Nothing to remove."
    Write-Host ""
    exit 0
}

$answer = Read-Host "  Remove API.AI CLI from $INSTALL_DIR? [y/N]"
if ($answer.ToLower() -ne "y") {
    Write-Host ""
    Write-Host "  $WARN`u{26A0}$RESET Cancelled. Nothing was removed."
    Write-Host ""
    exit 0
}

Write-Host ""

# Remove files
Write-Host "  Removing CLI files..." -NoNewline
try {
    Remove-Item -Path $INSTALL_DIR -Recurse -Force -ErrorAction Stop
    Write-Host " $SUCCESS`u{2714}$RESET"
} catch {
    Write-Host " $WARN`u{26A0}$RESET"
    Write-Host "  Could not fully remove $INSTALL_DIR"
    Write-Host "  Delete it manually if needed."
}

# Remove from PATH
Write-Host "  Removing from PATH..." -NoNewline
try {
    $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $newPath  = ($userPath -split ";" | Where-Object { $_ -ne $BIN_DIR }) -join ";"
    [System.Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    Write-Host " $SUCCESS`u{2714}$RESET"
} catch {
    Write-Host " $WARN`u{26A0}$RESET"
    Write-Host "  Could not update PATH. Remove $BIN_DIR manually."
}

Write-Host ""
Write-Host "  $SUCCESS`u{2714}$RESET Uninstalled. Open a new CMD window to apply changes."
Write-Host ""
