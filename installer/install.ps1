#Requires -Version 5.1
# ================================================================
#  API.AI  |  Global Installer
#  Run once. Installs the `api` command system-wide.
#
#  Usage (paste into any PowerShell window):
#    irm https://your-domain.com/install.ps1 | iex
# ================================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ESC         = [char]27
$BRAND       = "$ESC[38;2;99;179;237m"
$SUCCESS     = "$ESC[38;2;72;199;142m"
$WARN        = "$ESC[38;2;251;189;35m"
$ERROR_COL   = "$ESC[38;2;252;87;87m"
$INFO        = "$ESC[38;2;148;163;184m"
$MUTED       = "$ESC[38;2;71;85;105m"
$WHITE       = "$ESC[38;2;241;245;249m"
$CYAN        = "$ESC[38;2;34;211;238m"
$RESET       = "$ESC[0m"

$INSTALL_DIR = Join-Path $env:LOCALAPPDATA "apiai-cli"
$BIN_DIR     = Join-Path $INSTALL_DIR "bin"
$PS1_DIR     = Join-Path $INSTALL_DIR "lib\ps1"
$API_BAT     = Join-Path $BIN_DIR "api.bat"
$VERSION     = "1.0.0"

# Source URLs — update to wherever you host these files
$BASE_URL    = "https://raw.githubusercontent.com/se-kunal/apiai-cli/main/cli/lib/ps1"

$PS1_FILES   = @(
    "run.ps1",
    "ui.ps1",
    "logger.ps1",
    "detector.ps1",
    "state.ps1"
)

function ln($color, $text) { Write-Host "$color$text$RESET" }
function blank { Write-Host "" }
function ok($msg)   { Write-Host "  $SUCCESS`u{2714}$RESET $msg" }
function warn($msg) { Write-Host "  $WARN`u{26A0}$RESET $msg" }
function fail($msg) { Write-Host "  $ERROR_COL`u{2718}$RESET $msg" }
function info($msg) { Write-Host "  $INFO`u{25CF}$RESET $msg" }

function Write-Logo {
    Clear-Host
    blank
    ln $BRAND "   ___   ____  ____    ___   ____  "
    ln $BRAND "  / _ | / __ \/  _/   / _ | /  _/  "
    ln $BRAND " / __ |/ /_/ // /    / __ |_/ /    "
    ln $BRAND "/_/ |_/ .___/___/   /_/ |_/___/    "
    ln $BRAND "      /_/                           "
    blank
    ln $MUTED "  ────────────────────────────────────"
    ln $INFO  "  Installer  v$VERSION"
    blank
}

Write-Logo

# ----------------------------------------------------------------
# CONSENT
# ----------------------------------------------------------------
ln $WHITE "  This installer will:"
blank
ln $WHITE "  $([char]0x25CF) Copy CLI files to: $INSTALL_DIR"
ln $WHITE "  $([char]0x25CF) Add that folder to your user PATH"
ln $WHITE "  $([char]0x25CF) Make the  api  command available in any CMD or PowerShell"
blank
ln $MUTED "  Nothing is installed to system folders. Uninstall by deleting"
ln $MUTED "  $INSTALL_DIR and removing it from PATH."
blank

$answer = Read-Host "  $CYAN>$RESET Allow this? [Y/n]"
if ($answer -ne "" -and $answer.ToLower() -ne "y") {
    blank
    warn "Installation cancelled. Nothing was changed."
    blank
    exit 0
}

blank

# ----------------------------------------------------------------
# CREATE DIRECTORIES
# ----------------------------------------------------------------
Write-Host "  $INFO`u{25CF}$RESET Creating install directory..." -NoNewline
try {
    New-Item -ItemType Directory -Path $BIN_DIR  -Force | Out-Null
    New-Item -ItemType Directory -Path $PS1_DIR  -Force | Out-Null
    Write-Host " $SUCCESS`u{2714}$RESET"
} catch {
    Write-Host " $ERROR_COL`u{2718}$RESET"
    fail "Could not create directory: $INSTALL_DIR"
    fail $_.Exception.Message
    exit 1
}

# ----------------------------------------------------------------
# DOWNLOAD PS1 FILES
# ----------------------------------------------------------------
foreach ($file in $PS1_FILES) {
    $url  = "$BASE_URL/$file"
    $dest = Join-Path $PS1_DIR $file
    Write-Host "  $INFO`u{25CF}$RESET Downloading $file..." -NoNewline
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
        Write-Host " $SUCCESS`u{2714}$RESET"
    } catch {
        Write-Host " $ERROR_COL`u{2718}$RESET"
        fail "Could not download $file from $url"
        fail $_.Exception.Message
        blank
        ln $INFO "  Check your internet connection or the install URL."
        exit 1
    }
}

# ----------------------------------------------------------------
# WRITE api.bat  — the command users type
# ----------------------------------------------------------------
Write-Host "  $INFO`u{25CF}$RESET Writing api command..." -NoNewline

$batContent = @"
@echo off
setlocal enabledelayedexpansion

:: API.AI CLI — global launcher
:: Installed by the API.AI installer. Do not edit manually.

set PS1_ENTRY=$PS1_DIR\run.ps1

:: Check for .apiai in current directory
if not exist ".apiai" (
    echo.
    echo   API.AI ^| No .apiai file found in this folder.
    echo   Make sure you are in your project directory.
    echo   Create a .apiai file to configure your project.
    echo.
    exit /b 1
)

:: Hand off to PowerShell runtime
powershell -NoProfile -ExecutionPolicy Bypass ^
    -File "!PS1_ENTRY!" ^
    -ProjectRoot "%CD%" ^
    %*

exit /b %errorlevel%
"@

try {
    Set-Content -Path $API_BAT -Value $batContent -Encoding ASCII -Force
    Write-Host " $SUCCESS`u{2714}$RESET"
} catch {
    Write-Host " $ERROR_COL`u{2718}$RESET"
    fail "Could not write api.bat: $($_.Exception.Message)"
    exit 1
}

# ----------------------------------------------------------------
# ADD TO USER PATH  (no admin required)
# ----------------------------------------------------------------
Write-Host "  $INFO`u{25CF}$RESET Adding to PATH..." -NoNewline

try {
    $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -notlike "*$BIN_DIR*") {
        $newPath = "$userPath;$BIN_DIR"
        [System.Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Host " $SUCCESS`u{2714}$RESET"
    } else {
        Write-Host " $MUTED(already in PATH)$RESET"
    }
    # Also update current session
    $env:PATH = "$env:PATH;$BIN_DIR"
} catch {
    Write-Host " $WARN`u{26A0}$RESET"
    warn "Could not update PATH automatically."
    warn "Manually add this to your PATH: $BIN_DIR"
}

# ----------------------------------------------------------------
# DONE
# ----------------------------------------------------------------
blank
ln $MUTED "  ────────────────────────────────────"
blank
ok "API.AI CLI installed successfully!"
blank
ln $WHITE "  $CYAN`api start$RESET       Start your FastAPI project"
ln $WHITE "  $CYAN`api doctor$RESET      Run diagnostics"
ln $WHITE "  $CYAN`api help$RESET        Show all commands"
blank
ln $INFO  "  Open a new CMD window and cd to your project folder."
ln $INFO  "  Make sure your project has a .apiai file."
blank
ln $MUTED "  To uninstall: delete $INSTALL_DIR"
ln $MUTED "  and remove it from your user PATH."
blank
