# ================================================================
#  API.AI  |  Detector  |  lib/detector.ps1
#  Silent environment sniff. Runs before anything renders.
#  Sets $global:UI_TIER and $global:SESSION_META.
#  No output. Never fails. Always resolves.
# ================================================================

function Invoke-Detection {

    $meta = @{}

    # ---- PowerShell version ----
    $psVer = $PSVersionTable.PSVersion
    $meta['PS_Version']   = "$($psVer.Major).$($psVer.Minor).$($psVer.Patch)"
    $meta['PS_Edition']   = $PSVersionTable.PSEdition

    # ---- Windows Terminal ----
    $isWT = ($env:WT_SESSION -ne $null -and $env:WT_SESSION -ne "")
    $meta['Windows_Terminal'] = $isWT

    # ---- Terminal type ----
    $termType = "Unknown"
    if ($isWT)                           { $termType = "Windows Terminal" }
    elseif ($env:TERM_PROGRAM)           { $termType = $env:TERM_PROGRAM }
    elseif ($env:TERM -eq "xterm-256color") { $termType = "xterm-256color" }
    elseif ($Host.Name -eq "ConsoleHost") { $termType = "PowerShell Console" }
    elseif ($Host.Name -match "ISE")     { $termType = "PowerShell ISE" }
    $meta['Terminal'] = $termType

    # ---- ANSI color support test ----
    # Try writing an ANSI code and see if console supports VT processing
    $ansiSupported = $false
    try {
        $handle = [Console]::OutputEncoding
        # PowerShell 5.1+ on Windows 10 1511+ supports VT sequences natively
        # We check via kernel32 if available
        Add-Type -Name "ConsoleNative" -Namespace "WinAPI" -MemberDefinition @"
            [DllImport("kernel32.dll", SetLastError=true)]
            public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
            [DllImport("kernel32.dll", SetLastError=true)]
            public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
            [DllImport("kernel32.dll", SetLastError=true)]
            public static extern IntPtr GetStdHandle(int nStdHandle);
"@ -ErrorAction SilentlyContinue 2>$null

        $STD_OUTPUT_HANDLE = -11
        $ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        $handle = [WinAPI.ConsoleNative]::GetStdHandle($STD_OUTPUT_HANDLE)
        $mode   = 0
        [WinAPI.ConsoleNative]::GetConsoleMode($handle, [ref]$mode) | Out-Null
        # Try to enable VT processing
        $newMode = $mode -bor $ENABLE_VIRTUAL_TERMINAL_PROCESSING
        $ok = [WinAPI.ConsoleNative]::SetConsoleMode($handle, $newMode)
        $ansiSupported = $ok
    } catch {
        # Fallback: PowerShell 7+ always supports it
        $ansiSupported = ($psVer.Major -ge 7)
    }
    $meta['ANSI_Support'] = $ansiSupported

    # ---- Unicode support ----
    $unicodeSupported = $false
    try {
        $enc = [Console]::OutputEncoding
        $unicodeSupported = ($enc.CodePage -eq 65001) -or    # UTF-8
                            ($enc.CodePage -eq 1200)  -or    # UTF-16 LE
                            ($enc.IsSingleByte -eq $false)
        # Force UTF-8 for best results
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $unicodeSupported = $true
    } catch {
        $unicodeSupported = $false
    }
    $meta['Unicode_Support'] = $unicodeSupported

    # ---- Determine UI tier ----
    # Tier 3: Windows Terminal OR PS7+ with ANSI + Unicode
    # Tier 2: Any ANSI + Unicode capable terminal
    # Tier 1: Fallback — plain text
    if ($ansiSupported -and $unicodeSupported) {
        if ($isWT -or $psVer.Major -ge 7) {
            $global:UI_TIER = 3
        } else {
            $global:UI_TIER = 2
        }
    } else {
        $global:UI_TIER = 1
    }
    $meta['UI_Tier'] = $global:UI_TIER

    # ---- Running as administrator ----
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $isAdmin = $false }
    $meta['Is_Admin'] = $isAdmin
    $global:IS_ADMIN  = $isAdmin

    # ---- Running via double-click (no parent terminal) ----
    # When double-clicked, parent process is explorer.exe
    try {
        $parentId   = (Get-Process -Id $PID).Parent.Id
        $parentName = (Get-Process -Id $parentId -ErrorAction SilentlyContinue).Name
        $global:IS_DOUBLE_CLICK = ($parentName -eq "explorer")
        $meta['Launch_Mode'] = if ($global:IS_DOUBLE_CLICK) { "Double-click" } else { "Terminal" }
    } catch {
        $global:IS_DOUBLE_CLICK = $false
        $meta['Launch_Mode'] = "Terminal"
    }

    # ---- Console width ----
    try {
        $w = [Console]::WindowWidth
        if ($w -gt 40) {
            $global:UI_WIDTH = [math]::Min($w - 4, 80)
        }
    } catch {}
    $meta['Console_Width'] = $global:UI_WIDTH

    # ---- Python detection (preliminary — full check happens in doctor) ----
    $pythonCmd  = $null
    $pythonVer  = $null

    foreach ($cmd in @('python', 'python3', 'py')) {
        try {
            $ver = & $cmd --version 2>&1
            if ($ver -match 'Python (\d+\.\d+\.\d+)') {
                $pythonCmd = $cmd
                $pythonVer = $matches[1]
                break
            }
        } catch {}
    }
    $meta['Python_Cmd']     = if ($pythonCmd) { $pythonCmd } else { "not found" }
    $meta['Python_Version'] = if ($pythonVer) { $pythonVer } else { "not found" }
    $global:PYTHON_CMD      = $pythonCmd
    $global:PYTHON_VERSION  = $pythonVer

    # ---- Network reachability (quick, non-blocking) ----
    $networkOk = $false
    try {
        $ping = Test-Connection -ComputerName "pypi.org" -Count 1 -Quiet -TimeoutSeconds 2 -ErrorAction SilentlyContinue
        $networkOk = $ping
    } catch { $networkOk = $false }
    $meta['Network_PyPI'] = $networkOk
    $global:NETWORK_OK    = $networkOk

    # ---- Path sanity checks ----
    # UNC path check (\\server\share style)
    $global:IS_UNC_PATH = $global:PROJECT_ROOT.StartsWith("\\")
    $meta['UNC_Path'] = $global:IS_UNC_PATH

    # Long path check
    $global:PATH_TOO_LONG = ($global:PROJECT_ROOT.Length -gt 200)
    $meta['Path_Length']  = $global:PROJECT_ROOT.Length

    # Cloud sync detection (OneDrive / Dropbox / Google Drive)
    $cloudMarkers = @('OneDrive','Dropbox','Google Drive','iCloudDrive')
    $global:IS_CLOUD_PATH = $false
    foreach ($marker in $cloudMarkers) {
        if ($global:PROJECT_ROOT -match [regex]::Escape($marker)) {
            $global:IS_CLOUD_PATH = $true
            $meta['Cloud_Sync'] = $marker
            break
        }
    }
    if (-not $global:IS_CLOUD_PATH) { $meta['Cloud_Sync'] = "None" }

    # ---- Conda active ----
    $global:CONDA_ACTIVE = ($env:CONDA_DEFAULT_ENV -ne $null -and $env:CONDA_DEFAULT_ENV -ne "")
    $meta['Conda_Active'] = $global:CONDA_ACTIVE

    # ---- Store meta globally for logger ----
    $global:SESSION_META = $meta

    return $meta
}

# ----------------------------------------------------------------
# RENDER DETECTION SUMMARY  — brief, non-overwhelming
# Called after banner, shows just what matters
# ----------------------------------------------------------------
function Write-DetectionSummary {
    $sym  = Get-Symbols
    $tier = $global:UI_TIER

    $tierLabel = switch ($tier) {
        3 { "Full  $($global:C.Muted)(Windows Terminal / PS7+)$($global:C.Reset)" }
        2 { "Enhanced  $($global:C.Muted)(ANSI + Unicode)$($global:C.Reset)" }
        1 { "Basic  $($global:C.Muted)(CMD fallback)$($global:C.Reset)" }
    }

    Write-Status "Terminal    $($global:SESSION_META['Terminal'])" -State info
    Write-Status "Experience  $tierLabel" -State info

    if ($global:IS_ADMIN) {
        Write-Status "Running as Administrator" -State warn
    }
    if ($global:IS_UNC_PATH) {
        Write-Status "Network path detected — some features may be limited" -State warn
    }
    if ($global:PATH_TOO_LONG) {
        Write-Status "Path is very long ($($global:PROJECT_ROOT.Length) chars) — watch for Windows path limits" -State warn
    }
    if ($global:IS_CLOUD_PATH) {
        Write-Status "Cloud-synced folder detected — state file may conflict with sync" -State warn
    }
    if ($global:CONDA_ACTIVE) {
        Write-Status "Conda environment active ($env:CONDA_DEFAULT_ENV) — this may interfere with venv" -State warn
    }
}
