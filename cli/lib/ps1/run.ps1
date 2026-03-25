# ================================================================
#  API.AI  |  Main Orchestrator  |  run.ps1
#  Entry point for the PowerShell experience.
#  Dot-sourced from run.bat after environment detection.
# ================================================================

#Requires -Version 5.1
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

param(
    [string]$ProjectRoot = "",   # passed by the npm CLI launcher
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$RemainingArgs
)

# Re-expose remaining args as $args for the rest of the script
$PSBoundParameters.Remove('ProjectRoot') | Out-Null
$PSBoundParameters.Remove('RemainingArgs') | Out-Null

# ----------------------------------------------------------------
# GLOBALS
# ----------------------------------------------------------------
$global:SCRIPT_ROOT  = Split-Path -Parent $MyInvocation.MyCommand.Path          # …/lib/ps1 inside npm package
$global:PROJECT_ROOT = if ($ProjectRoot -ne "") {
    $ProjectRoot    # passed in by npm CLI — the user's actual project folder
} else {
    Split-Path -Parent $global:SCRIPT_ROOT   # fallback: go up one level (legacy layout)
}
$global:APP_NAME = "API.AI"
$global:APP_VERSION = "1.0.0"
$global:VENV_DIR = Join-Path $global:PROJECT_ROOT ".venv"
$global:PORT_START = 8000
$global:PORT_END = 8010
$global:PID_FILE = Join-Path $global:PROJECT_ROOT ".apiai_pid"
$global:APP_OBJECT = "app"
$global:PYTHON_CMD = $null
$global:IS_ADMIN = $false
$global:IS_DOUBLE_CLICK = $false
$global:NETWORK_OK = $true
$global:UI_TIER = 1

# ----------------------------------------------------------------
# READ .apiai METADATA  — overrides defaults if present
# ----------------------------------------------------------------
$global:MAIN_FILE  = "main.py"
$global:APP_DESC   = ""
$global:PYTHON_MIN = "3.8"

function Read-ApiaiMeta {
    $metaPath = Join-Path $global:PROJECT_ROOT ".apiai"
    if (-not (Test-Path $metaPath)) { return }
    try {
        Get-Content $metaPath | ForEach-Object {
            $line = $_.Trim()
            if ($line -eq "" -or $line.StartsWith("#")) { return }
            if ($line -match "^([^=]+)=(.*)$") {
                $key = $matches[1].Trim().ToLower()
                $val = $matches[2].Trim().Trim('"').Trim("'")
                switch ($key) {
                    "name"        { $global:APP_NAME    = $val }
                    "version"     { $global:APP_VERSION = $val }
                    "main"        { $global:MAIN_FILE   = $val }
                    "app"         { $global:APP_OBJECT  = $val }
                    "port"        { $global:PORT_START  = [int]$val; $global:PORT_END = [int]$val + 10 }
                    "python"      { $global:PYTHON_MIN  = $val }
                    "description" { $global:APP_DESC    = $val }
                }
            }
        }
    } catch {}
}
Read-ApiaiMeta

# ----------------------------------------------------------------
# LOAD LIBRARIES
# ----------------------------------------------------------------
. (Join-Path $PSScriptRoot "ui.ps1")
. (Join-Path $PSScriptRoot "logger.ps1")
. (Join-Path $PSScriptRoot "detector.ps1")
. (Join-Path $PSScriptRoot "state.ps1")

# ----------------------------------------------------------------
# REGISTER CLEAN EXIT (Ctrl+C handler)
# ----------------------------------------------------------------
Register-CleanExit

# ----------------------------------------------------------------
# SILENT DETECTION   runs before anything renders
# ----------------------------------------------------------------
$null = Invoke-Detection

# ----------------------------------------------------------------
# COMMAND ROUTING
# ----------------------------------------------------------------
$CMD = if ($RemainingArgs -and $RemainingArgs[0]) { $RemainingArgs[0].ToLower() } else { "" }

# Smart default: no args = agentic decision
if ($CMD -eq "") {
    $CMD = Get-SmartDefault
}

switch ($CMD) {
    "start" { Invoke-Start }
    "install" { Invoke-Install }
    "clean" { Invoke-Clean }
    "doctor" { Invoke-Doctor }
    "restart" { Invoke-Restart }
    "help" { Show-Help }
    default {
        Write-Banner "Runtime CLI"
        Write-Blank
        Write-Color $global:C.Warn "  Unknown command: $CMD"
        Write-Blank
        Show-Help
    }
}

# ================================================================
#  SMART DEFAULT   agentic decision when no command given
# ================================================================
function Get-SmartDefault {
    # Check if server is already running (PID file exists and process is live)
    if (Test-Path $global:PID_FILE) {
        try {
            $savedPid = Get-Content $global:PID_FILE -Raw
            $proc = Get-Process -Id ([int]$savedPid) -ErrorAction SilentlyContinue
            if ($proc) { return "running" }
        }
        catch {}
    }

    # Check if venv and deps exist
    $venvReady = Test-Path (Join-Path $global:VENV_DIR "Scripts\python.exe")
    $mainReady = Test-Path (Join-Path $global:PROJECT_ROOT $global:MAIN_FILE)

    if ($mainReady -and $venvReady) { return "start" }
    if ($mainReady) { return "setup-and-start" }

    return "help"
}

# ================================================================
#  START
# ================================================================
function Invoke-Start {
    Write-Banner "Starting your API"
    Write-DetectionSummary

    # Self check
    $check = Invoke-SelfCheck
    if (-not $check.OK) {
        Write-Blank
        $missingList = $check.Missing -join ", "
        $logFile = Write-ErrorLog -Step "Self Check" `
            -HumanMessage "Required files are missing: $missingList" `
            -Exception "Missing files: $missingList" `
            -ExtraContext @{ Missing = $missingList }
        Write-ErrorMoment -HumanMessage "Your project is missing required files: $missingList" `
            -LogFile $logFile
        Exit-Gracefully 1
        return
    }

    Write-Section "Environment"

    # Python
    if (-not (Assert-Python)) { Exit-Gracefully 1; return }

    # Venv
    if (-not (Assert-Venv)) { Exit-Gracefully 1; return }

    # Deps
    if (-not (Assert-Deps)) { Exit-Gracefully 1; return }

    # Env file
    Assert-EnvFile

    Write-Section "Launch"

    # Port
    $port = Resolve-Port
    if ($null -eq $port) {
        $logFile = Write-ErrorLog -Step "Port Resolution" `
            -HumanMessage "No free ports available" `
            -Exception "All ports $($global:PORT_START)-$($global:PORT_END) in use"
        Write-ErrorMoment -HumanMessage "All ports between $($global:PORT_START) and $($global:PORT_END) are in use." `
            -LogFile $logFile
        Exit-Gracefully 1
        return
    }

    # Check if already running
    if (Test-Path $global:PID_FILE) {
        try {
            $existingPid = Get-Content $global:PID_FILE -Raw
            $proc = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Status "Server already running on port $port (PID $existingPid)" -State warn
                $answer = Ask-YesNo "Stop the existing server and restart?" -Default $true
                if ($answer) {
                    Stop-Server
                }
                else {
                    Write-Blank
                    Write-Color $global:C.Info "  Opening existing server..."
                    Start-Process "http://localhost:$port/docs" -ErrorAction SilentlyContinue
                    Exit-Gracefully 0
                    return
                }
            }
        }
        catch {}
    }

    Write-Status "Port $port is available" -State ok

    # Update state before launching
    Update-State

    # Open browser after short delay (give server time to bind)
    $null = Start-Job -ScriptBlock {
        param($p)
        Start-Sleep -Seconds 2
        try { Start-Process "http://localhost:$p/docs" } catch {}
    } -ArgumentList $port

    # Launch server
    Write-Blank
    Start-SpinnerInline "Booting server"
    Start-Sleep -Milliseconds 600
    Stop-SpinnerInline -Success $true -Message "Server initializing"

    # Write PID placeholder  uvicorn will be the actual process
    # We track the job instead
    Write-LaunchBox -Port $port -AppName $global:APP_NAME -Version $global:APP_VERSION

    # Run uvicorn  this blocks until Ctrl+C
    $uvicorn = Join-Path $global:VENV_DIR "Scripts\uvicorn.exe"
    $appObj = "$($global:APP_OBJECT):app"

    try {
        $mainModule = [System.IO.Path]::GetFileNameWithoutExtension($global:MAIN_FILE); & $uvicorn "$mainModule`:$($global:APP_OBJECT)" --host 0.0.0.0 --port $port --reload 2>&1 | ForEach-Object {
            # Filter uvicorn output  show only meaningful lines
            $line = $_.ToString()
            if ($line -match "Application startup complete") {
                Write-Status "Application startup complete" -State ok
            }
            elseif ($line -match "ERROR|error") {
                # Capture uvicorn errors for log
                Write-Color $global:C.Error "  $line"
            }
            # All other uvicorn chatter is suppressed
        }
    }
    catch {
        $logFile = Write-ErrorLog -Step "Server Runtime" `
            -HumanMessage "The server encountered an unexpected error" `
            -Exception $_ `
            -ExtraContext @{ Port = $port; AppObject = $global:APP_OBJECT }
        Write-ErrorMoment -HumanMessage "The server stopped unexpectedly." -LogFile $logFile
    }
    finally {
        # Clean up PID file
        if (Test-Path $global:PID_FILE) { Remove-Item $global:PID_FILE -Force -ErrorAction SilentlyContinue }
        Show-Cursor
    }

    Exit-Gracefully 0
}

# ================================================================
#  SETUP AND START   agentic: install then start
# ================================================================
function Invoke-SetupAndStart {
    Invoke-Install -Silent
    Invoke-Start
}

# ================================================================
#  INSTALL
# ================================================================
function Invoke-Install {
    param([switch]$Silent)

    if (-not $Silent) { Write-Banner "Setting up environment" }
    Write-DetectionSummary

    $check = Invoke-SelfCheck
    if (-not $check.OK) {
        $missingList = $check.Missing -join ", "
        $logFile = Write-ErrorLog -Step "Install / Self Check" `
            -HumanMessage "Required files missing: $missingList" `
            -Exception "Missing: $missingList"
        Write-ErrorMoment -HumanMessage "Cannot install  required files are missing: $missingList" `
            -LogFile $logFile
        Exit-Gracefully 1
        return
    }

    Write-Section "Environment Setup"

    if (-not (Assert-Python)) { Exit-Gracefully 1; return }
    if (-not (Assert-Venv)) { Exit-Gracefully 1; return }
    if (-not (Assert-Deps)) { Exit-Gracefully 1; return }
    Assert-EnvFile

    Update-State

    Write-Blank
    Write-Color $global:C.Success "  Environment is ready. Run  run.bat start  to launch."
    Write-Blank
    Exit-Gracefully 0
}

# ================================================================
#  CLEAN
# ================================================================
function Invoke-Clean {
    Write-Banner "Clean"

    $answer = Ask-YesNo "Remove the virtual environment and reset state?" -Default $false
    if (-not $answer) {
        Write-Blank
        Write-Color $global:C.Info "  Nothing removed."
        Exit-Gracefully 0
        return
    }

    Write-Section "Cleaning"

    Start-SpinnerInline "Removing virtual environment"
    Start-Sleep -Milliseconds 300
    if (Test-Path $global:VENV_DIR) {
        try {
            Remove-Item -Path $global:VENV_DIR -Recurse -Force -ErrorAction Stop
            Stop-SpinnerInline -Success $true -Message "Virtual environment removed"
        }
        catch {
            Stop-SpinnerInline -Success $false -Message "Could not remove venv"
            $logFile = Write-ErrorLog -Step "Clean" -HumanMessage "Failed to remove virtual environment" -Exception $_
            Write-ErrorMoment -HumanMessage "Could not delete the virtual environment folder." -LogFile $logFile
        }
    }
    else {
        Stop-SpinnerInline -Success $true -Message "Nothing to clean"
    }

    # Remove state file
    if (Test-Path $global:STATE_FILE) {
        Remove-Item $global:STATE_FILE -Force -ErrorAction SilentlyContinue
        Write-Status "State file cleared" -State ok
    }

    Write-Blank
    Write-Color $global:C.Success "  Clean complete. Run  run.bat install  to set up again."
    Write-Blank
    Exit-Gracefully 0
}

# ================================================================
#  DOCTOR
# ================================================================
function Invoke-Doctor {
    Write-Banner "Diagnostics"
    Write-DetectionSummary

    Write-Section "System Checks"

    $checks = 0
    $passed = 0
    $warned = 0
    $failed = 0

    function Run-Check([string]$Label, [scriptblock]$Test) {
        $checks++
        Start-SpinnerInline $Label
        Start-Sleep -Milliseconds 250
        try {
            $result = & $Test
            Stop-SpinnerInline -Success $true -Message $Label
            if ($result.State -eq 'warn') {
                Write-Color $global:C.Muted "    $($global:C.Warn)$($result.Detail)$($global:C.Reset)"
                $script:warned++
            }
            elseif ($result.State -eq 'ok') {
                if ($result.Detail) {
                    Write-Color $global:C.Muted "    $($result.Detail)"
                }
                $script:passed++
            }
        }
        catch {
            Stop-SpinnerInline -Success $false -Message "$Label  check failed"
            $script:failed++
        }
    }

    Run-Check "Python installation" {
        if ($global:PYTHON_CMD) {
            return @{ State = 'ok'; Detail = "$($global:PYTHON_CMD) $($global:PYTHON_VERSION)" }
        }
        else {
            $script:failed++
            return @{ State = 'error'; Detail = "Python not found" }
        }
    }

    Run-Check "Python version (minimum 3.8)" {
        if ($global:PYTHON_VERSION) {
            $parts = $global:PYTHON_VERSION -split '\.'
            $major = [int]$parts[0]; $minor = [int]$parts[1]
            if ($major -ge 3 -and $minor -ge 8) {
                return @{ State = 'ok'; Detail = "$($global:PYTHON_VERSION) : OK" }
            }
            else {
                return @{ State = 'warn'; Detail = "$($global:PYTHON_VERSION) : minimum 3.8 recommended" }
            }
        }
        return @{ State = 'error'; Detail = "Cannot determine Python version" }
    }

    Run-Check "Virtual environment" {
        $venvPy = Join-Path $global:VENV_DIR "Scripts\python.exe"
        if (Test-Path $venvPy) {
            # Check venv Python version
            $venvVer = & $venvPy --version 2>&1
            return @{ State = 'ok'; Detail = "$venvVer" }
        }
        else {
            return @{ State = 'warn'; Detail = "Not created, run  install" }
        }
    }

    Run-Check "requirements.txt" {
        $reqPath = Join-Path $global:PROJECT_ROOT "requirements.txt"
        if (Test-Path $reqPath) {
            $lines = (Get-Content $reqPath | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }).Count
            return @{ State = 'ok'; Detail = "$lines packages listed" }
        }
        return @{ State = 'error'; Detail = "Missing" }
    }

    Run-Check "Dependencies installed" {
        $pipPath = Join-Path $global:VENV_DIR "Scripts\pip.exe"
        if (Test-Path $pipPath) {
            $pkgs = & $pipPath list 2>&1 | Measure-Object -Line
            return @{ State = 'ok'; Detail = "$($pkgs.Lines) packages installed" }
        }
        return @{ State = 'warn'; Detail = "Cannot check  venv missing" }
    }

    Run-Check ".env file" {
        $envPath = Join-Path $global:PROJECT_ROOT ".env"
        $exPath = Join-Path $global:PROJECT_ROOT ".env.example"
        if (Test-Path $envPath) {
            return @{ State = 'ok'; Detail = "Present" }
        }
        elseif (Test-Path $exPath) {
            return @{ State = 'warn'; Detail = "Missing: .env.example available to copy from" }
        }
        else {
            return @{ State = 'warn'; Detail = "Neither .env nor .env.example found" }
        }
    }

    Run-Check "main.py" {
        $mainPath = Join-Path $global:PROJECT_ROOT $global:MAIN_FILE
        if (Test-Path $mainPath) {
            $content = Get-Content $mainPath -Raw -ErrorAction SilentlyContinue
            if ($content -match 'FastAPI\s*\(') {
                return @{ State = 'ok'; Detail = "FastAPI app found" }
            }
            return @{ State = 'warn'; Detail = "No FastAPI app found" }
        }
        return @{ State = 'error'; Detail = "Missing" }
    }

    Run-Check "Network  PyPI reachable" {
        if ($global:NETWORK_OK) {
            return @{ State = 'ok'; Detail = "PyPI reachable" }
        }
        return @{ State = 'warn'; Detail = "PyPI not reachable : pip install may fail" }
    }

    Run-Check "Port availability" {
        $port = Resolve-Port
        if ($port) {
            return @{ State = 'ok'; Detail = "Port $port is free" }
        }
        return @{ State = 'warn'; Detail = "No free ports in range $($global:PORT_START)-$($global:PORT_END)" }
    }

    Run-Check "State file integrity" {
        if (Test-Path $global:STATE_FILE) {
            try {
                $raw = Get-Content $global:STATE_FILE -Raw -Encoding UTF8
                $null = $raw | ConvertFrom-Json -AsHashtable
                return @{ State = 'ok'; Detail = "State file valid" }
            }
            catch {
                return @{ State = 'warn'; Detail = "State file corrupted  will regenerate on next run" }
            }
        }
        return @{ State = 'info'; Detail = "No state file will be created on first run" }
    }

    # Summary
    Write-Blank
    Write-Separator
    $sym = Get-Symbols
    Write-Blank

    $summaryColor = if ($failed -gt 0) { $global:C.Error } elseif ($warned -gt 0) { $global:C.Warn } else { $global:C.Success }
    Write-Color $summaryColor "  $($sym.Diamond)  $passed passed  $warned warnings  $failed failed   out of $checks checks"
    Write-Blank

    if ($failed -gt 0) {
        Write-Color $global:C.Info "  Run  run.bat install  to attempt auto-repair."
    }
    elseif ($warned -gt 0) {
        Write-Color $global:C.Info "  Warnings are non-critical but worth reviewing."
    }
    else {
        Write-Color $global:C.Success "  Everything looks great. Run  run.bat start  to launch."
    }

    Write-Blank
    Exit-Gracefully 0
}

# ================================================================
#  RESTART
# ================================================================
function Invoke-Restart {
    Write-Banner "Restarting"
    Write-Section "Stopping current server"
    Stop-Server
    Write-Blank
    Start-Sleep -Milliseconds 500
    Invoke-Start
}

# ================================================================
#  RUNNING (shown when server is already up, no-arg launch)
# ================================================================
function Invoke-Running {
    Write-Banner "Already Running"
    try {
        $savedPid = Get-Content $global:PID_FILE -Raw
        $port = Resolve-Port   # we can't easily get the saved port, show nearest free
    }
    catch {}

    Write-Status "Server is already running" -State ok
    Write-Blank
    Write-Color $global:C.Cyan "  Opening docs in browser..."
    try { Start-Process "http://localhost:$($global:PORT_START)/docs" } catch {}
    Exit-Gracefully 0
}

# ================================================================
#  HELP
# ================================================================
function Show-Help {
    Write-Banner "Runtime CLI"

    $sym = Get-Symbols

    $lines = @(
        "  $($global:C.Muted)COMMANDS$($global:C.Reset)",
        "",
        "  $($global:C.Cyan)start$($global:C.Reset)      $($global:C.White)Start the API server$($global:C.Reset)                     $($global:C.Muted)Auto-installs if needed$($global:C.Reset)",
        "  $($global:C.Cyan)install$($global:C.Reset)    $($global:C.White)Set up the environment$($global:C.Reset)                   $($global:C.Muted)Python, venv, packages$($global:C.Reset)",
        "  $($global:C.Cyan)restart$($global:C.Reset)    $($global:C.White)Restart the server$($global:C.Reset)                       $($global:C.Muted)Stops then starts$($global:C.Reset)",
        "  $($global:C.Cyan)doctor$($global:C.Reset)     $($global:C.White)Run diagnostics$($global:C.Reset)                          $($global:C.Muted)10 system checks$($global:C.Reset)",
        "  $($global:C.Cyan)clean$($global:C.Reset)      $($global:C.White)Remove the virtual environment$($global:C.Reset)            $($global:C.Muted)Fresh start$($global:C.Reset)",
        "  $($global:C.Cyan)help$($global:C.Reset)       $($global:C.White)Show this screen$($global:C.Reset)",
        "",
        "  $($global:C.Muted)USAGE$($global:C.Reset)",
        "",
        "  $($global:C.White)run.bat start$($global:C.Reset)",
        "  $($global:C.White)run.bat doctor$($global:C.Reset)",
        ""
    )

    Write-Box -Title "  $($global:APP_NAME)  v$($global:APP_VERSION)" `
        -Lines $lines `
        -BorderColor $global:C.Border `
        -TitleColor $global:C.Brand `
        -AnimDelayMs 30

    Write-Blank
    Exit-Gracefully 0
}

# ================================================================
#  UTILITIES
# ================================================================

function Assert-Python {
    Start-SpinnerInline "Checking Python"
    Start-Sleep -Milliseconds 300

    if (-not $global:PYTHON_CMD) {
        Stop-SpinnerInline -Success $false -Message "Python not found"
        Write-Blank

        # Check for Microsoft Store stub
        $stubPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\python.exe"
        if (Test-Path $stubPath) {
            Write-Color $global:C.Warn "  Python from the Microsoft Store is a stub and won't work."
            Write-Color $global:C.Info "  Please install Python from https://python.org"
        }
        else {
            Write-Color $global:C.Info "  Python 3.8 or higher is required."
            Write-Color $global:C.Info "  Download it from https://python.org  check 'Add to PATH' during install."
        }

        $logFile = Write-ErrorLog -Step "Python Check" `
            -HumanMessage "Python not found on this system" `
            -Exception "No python/python3/py command found in PATH"
        Write-ErrorMoment -HumanMessage "Python could not be found on your system." -LogFile $logFile
        return $false
    }

    # Version gate
    $parts = $global:PYTHON_VERSION -split '\.'
    $major = [int]$parts[0]; $minor = [int]$parts[1]
    if (-not ($major -ge [int]($global:PYTHON_MIN.Split(".")[0]) -and $minor -ge [int]($global:PYTHON_MIN.Split(".")[1]))) {
        Stop-SpinnerInline -Success $false -Message "Python $($global:PYTHON_VERSION) is too old"
        Write-Color $global:C.Info "  Python 3.8 or higher is required. Found: $($global:PYTHON_VERSION)"
        $logFile = Write-ErrorLog -Step "Python Version" `
            -HumanMessage "Python version too old: $($global:PYTHON_VERSION)" `
            -Exception "Minimum 3.8 required, found $($global:PYTHON_VERSION)"
        Write-ErrorMoment -HumanMessage "Your Python version ($($global:PYTHON_VERSION)) is too old." -LogFile $logFile
        return $false
    }

    Stop-SpinnerInline -Success $true -Message "Python $($global:PYTHON_VERSION)"
    return $true
}

function Assert-Venv {
    $venvPy = Join-Path $global:VENV_DIR "Scripts\python.exe"

    # Detect corrupted venv  folder exists but python missing
    $venvDirExists = Test-Path $global:VENV_DIR
    $venvPyExists = Test-Path $venvPy

    if ($venvDirExists -and -not $venvPyExists) {
        Write-Status "Virtual environment appears corrupted  recreating" -State warn
        Remove-Item -Path $global:VENV_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $venvPy) {
        Start-SpinnerInline "Checking virtual environment"
        Start-Sleep -Milliseconds 200
        Stop-SpinnerInline -Success $true -Message "Virtual environment ready"
        return $true
    }

    # Create venv
    Start-SpinnerInline "Creating virtual environment"

    # UNC path guard
    if ($global:IS_UNC_PATH) {
        Stop-SpinnerInline -Success $false -Message "Cannot create venv on network path"
        Write-Color $global:C.Info "  Please copy the project to a local drive first."
        return $false
    }

    try {
        $result = & $global:PYTHON_CMD -m venv $global:VENV_DIR 2>&1
        if ($LASTEXITCODE -ne 0) { throw $result }
        Stop-SpinnerInline -Success $true -Message "Virtual environment created"
        return $true
    }
    catch {
        Stop-SpinnerInline -Success $false -Message "Failed to create virtual environment"
        $logFile = Write-ErrorLog -Step "Venv Creation" `
            -HumanMessage "Could not create the virtual environment" `
            -Exception $_ `
            -ExtraContext @{ VenvPath = $global:VENV_DIR }
        Write-ErrorMoment -HumanMessage "Could not create the Python virtual environment." -LogFile $logFile
        return $false
    }
}

function Assert-Deps {
    $pip = Join-Path $global:VENV_DIR "Scripts\pip.exe"
    $reqFile = Join-Path $global:PROJECT_ROOT "requirements.txt"

    # Network check before attempting install
    if (-not $global:NETWORK_OK) {
        Write-Status "Network unavailable  skipping dependency install" -State warn
        Write-Color $global:C.Info "  Connect to the internet and run  run.bat install  to complete setup."
        return $true   # non-fatal  let the user try to start anyway
    }

    # Count packages for messaging
    $pkgCount = 0
    try {
        $pkgCount = (Get-Content $reqFile | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }).Count
    }
    catch {}

    $label = if ($pkgCount -gt 0) { "Installing $pkgCount packages" } else { "Installing dependencies" }
    Start-SpinnerInline $label

    try {
        # Run pip with timeout simulation via job
        $job = Start-Job -ScriptBlock {
            param($pip, $req)
            & $pip install -r $req --quiet 2>&1
        } -ArgumentList $pip, $reqFile

        $elapsed = 0
        while ($job.State -eq 'Running') {
            Step-SpinnerInline
            $elapsed += 80
            # After 45s, update the label to reassure user
            if ($elapsed -eq 45000) {
                $global:_spinnerLabel = "Still installing  large packages can take a while"
            }
            # Hard timeout at 3 minutes
            if ($elapsed -gt 180000) {
                Stop-Job $job
                throw "Dependency install timed out after 3 minutes"
            }
        }

        $output = Receive-Job $job -ErrorVariable joberr 2>&1
        $didFail = ($joberr.Count -gt 0) -or ($job.State -eq 'Failed') -or ($LASTEXITCODE -ne 0)
        Remove-Job $job -Force

        if ($didFail) {
            # Try to extract the problem package from pip output
            $failedPkg = ""
            foreach ($line in ($output | Out-String) -split "`n") {
                if ($line -match "ERROR.*Could not find|No matching|ERROR.*requires") {
                    $failedPkg = $line.Trim()
                    break
                }
            }
            if ($failedPkg) { throw $failedPkg } else { throw "pip install failed" }
        }

        Stop-SpinnerInline -Success $true -Message "Dependencies installed"
        return $true

    }
    catch {
        Stop-SpinnerInline -Success $false -Message "Dependency install failed"
        $logFile = Write-ErrorLog -Step "Dependencies" `
            -HumanMessage "Package installation failed" `
            -Exception $_ `
            -ExtraContext @{ PackageCount = $pkgCount; NetworkOK = $global:NETWORK_OK }
        Write-ErrorMoment -HumanMessage "Some packages could not be installed." -LogFile $logFile
        return $false
    }
}

function Assert-EnvFile {
    $envPath = Join-Path $global:PROJECT_ROOT ".env"
    $exPath = Join-Path $global:PROJECT_ROOT ".env.example"

    if (Test-Path $envPath) { return }

    if (Test-Path $exPath) {
        Copy-Item $exPath $envPath -ErrorAction SilentlyContinue
        Write-Status ".env created from template  review and fill in your values" -State warn
    }
    else {
        Write-Status ".env not found  some features may not work" -State warn
    }
}

function Resolve-Port {
    for ($p = $global:PORT_START; $p -le $global:PORT_END; $p++) {
        $inUse = $false
        try {
            $connections = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
            foreach ($conn in $connections) {
                if ($conn.Port -eq $p) { $inUse = $true; break }
            }
        }
        catch {
            # Fallback to netstat
            $ns = netstat -ano 2>&1 | Select-String ":$p\s"
            $inUse = ($ns -ne $null)
        }
        if (-not $inUse) { return $p }
    }
    return $null
}

function Stop-Server {
    Start-SpinnerInline "Stopping server"
    Start-Sleep -Milliseconds 300

    $stopped = $false

    # Try PID file first  only kill OUR process
    if (Test-Path $global:PID_FILE) {
        try {
            $savedPid = [int](Get-Content $global:PID_FILE -Raw)
            $proc = Get-Process -Id $savedPid -ErrorAction SilentlyContinue
            if ($proc) {
                $proc | Stop-Process -Force
                $stopped = $true
            }
            Remove-Item $global:PID_FILE -Force -ErrorAction SilentlyContinue
        }
        catch {}
    }

    if (-not $stopped) {
        # Fallback  find uvicorn processes owned by our venv only
        $resolvedVenv = Resolve-Path $global:VENV_DIR -ErrorAction SilentlyContinue
        $venvAbsolute = if ($resolvedVenv) { $resolvedVenv.Path } else { $null }
        if ($venvAbsolute) {
            Get-Process -Name "python", "uvicorn" -ErrorAction SilentlyContinue | Where-Object {
                try {
                    $cmd = (Get-WmiObject Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
                    $cmd -and $cmd -match [regex]::Escape($venvAbsolute)
                }
                catch { $false }
            } | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    Stop-SpinnerInline -Success $true -Message "Server stopped"
}

function Exit-Gracefully([int]$Code = 0) {
    Show-Cursor
    Write-Blank
    if ($global:IS_DOUBLE_CLICK) {
        Wait-AnyKey
    }
    exit $Code
}
