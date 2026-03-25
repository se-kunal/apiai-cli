function Invoke-Detection {
    $meta = @{}

    $psVer = $PSVersionTable.PSVersion
    $meta["PS_Version"] = "{0}.{1}.{2}" -f $psVer.Major, $psVer.Minor, $psVer.Patch
    $meta["PS_Edition"] = $PSVersionTable.PSEdition

    $isWT = ($env:WT_SESSION -ne $null -and $env:WT_SESSION -ne "")
    $meta["Windows_Terminal"] = $isWT

    $termType = "Unknown"
    if ($isWT) { $termType = "Windows Terminal" }
    elseif ($env:TERM_PROGRAM) { $termType = $env:TERM_PROGRAM }
    elseif ($env:TERM -eq "xterm-256color") { $termType = "xterm-256color" }
    elseif ($Host.Name -eq "ConsoleHost") { $termType = "PowerShell Console" }
    elseif ($Host.Name -match "ISE") { $termType = "PowerShell ISE" }
    $meta["Terminal"] = $termType

    $ansiSupported = $false
    try {
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
        $mode = 0
        [WinAPI.ConsoleNative]::GetConsoleMode($handle, [ref]$mode) | Out-Null
        $newMode = $mode -bor $ENABLE_VIRTUAL_TERMINAL_PROCESSING
        $ansiSupported = [WinAPI.ConsoleNative]::SetConsoleMode($handle, $newMode)
    }
    catch {
        $ansiSupported = ($psVer.Major -ge 7)
    }
    $meta["ANSI_Support"] = $ansiSupported

    $unicodeSupported = $false
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $enc = [Console]::OutputEncoding
        $unicodeSupported = ($enc.CodePage -eq 65001) -or ($enc.CodePage -eq 1200) -or ($enc.IsSingleByte -eq $false)
    }
    catch {
        $unicodeSupported = $false
    }
    $meta["Unicode_Support"] = $unicodeSupported

    if ($ansiSupported -and $unicodeSupported) {
        if ($isWT -or $psVer.Major -ge 7) { $global:UI_TIER = 3 } else { $global:UI_TIER = 2 }
    }
    else {
        $global:UI_TIER = 1
    }
    $meta["UI_Tier"] = $global:UI_TIER

    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        $isAdmin = $false
    }
    $meta["Is_Admin"] = $isAdmin
    $global:IS_ADMIN = $isAdmin

    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
        $parentName = $null
        if ($proc -and $proc.ParentProcessId) {
            $parent = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $proc.ParentProcessId) -ErrorAction SilentlyContinue
            if ($parent) { $parentName = $parent.Name }
        }
        $global:IS_DOUBLE_CLICK = ($parentName -eq "explorer.exe")
        $meta["Launch_Mode"] = if ($global:IS_DOUBLE_CLICK) { "Double-click" } else { "Terminal" }
    }
    catch {
        $global:IS_DOUBLE_CLICK = $false
        $meta["Launch_Mode"] = "Terminal"
    }

    try {
        $w = [Console]::WindowWidth
        if ($w -gt 40) { $global:UI_WIDTH = [math]::Min($w - 4, 80) }
    }
    catch {}
    $meta["Console_Width"] = $global:UI_WIDTH

    $pythonCmd = $null
    $pythonVer = $null
    foreach ($cmd in @("python", "python3", "py")) {
        try {
            $ver = & $cmd --version 2>&1
            if ($ver -match "Python (\d+\.\d+\.\d+)") {
                $pythonCmd = $cmd
                $pythonVer = $matches[1]
                break
            }
        }
        catch {}
    }
    $meta["Python_Cmd"] = if ($pythonCmd) { $pythonCmd } else { "not found" }
    $meta["Python_Version"] = if ($pythonVer) { $pythonVer } else { "not found" }
    $global:PYTHON_CMD = $pythonCmd
    $global:PYTHON_VERSION = $pythonVer

    $networkOk = $false
    try {
        $networkOk = Test-Connection -ComputerName "pypi.org" -Count 1 -Quiet -TimeoutSeconds 2 -ErrorAction SilentlyContinue
    }
    catch {
        $networkOk = $false
    }
    $meta["Network_PyPI"] = $networkOk
    $global:NETWORK_OK = $networkOk

    $global:IS_UNC_PATH = $global:PROJECT_ROOT.StartsWith("\\")
    $meta["UNC_Path"] = $global:IS_UNC_PATH

    $global:PATH_TOO_LONG = ($global:PROJECT_ROOT.Length -gt 200)
    $meta["Path_Length"] = $global:PROJECT_ROOT.Length

    $global:IS_CLOUD_PATH = $false
    $meta["Cloud_Sync"] = "None"
    foreach ($marker in @("OneDrive", "Dropbox", "Google Drive", "iCloudDrive")) {
        if ($global:PROJECT_ROOT -match [regex]::Escape($marker)) {
            $global:IS_CLOUD_PATH = $true
            $meta["Cloud_Sync"] = $marker
            break
        }
    }

    $global:CONDA_ACTIVE = ($env:CONDA_DEFAULT_ENV -ne $null -and $env:CONDA_DEFAULT_ENV -ne "")
    $meta["Conda_Active"] = $global:CONDA_ACTIVE

    $global:SESSION_META = $meta
    return $meta
}

function Write-DetectionSummary {
    $tierLabel = switch ($global:UI_TIER) {
        3 { "Full (Windows Terminal / PS7+)" }
        2 { "Enhanced (ANSI + Unicode)" }
        default { "Basic (fallback)" }
    }

    Write-Status ("Terminal    {0}" -f $global:SESSION_META["Terminal"]) -State info
    Write-Status ("Experience  {0}" -f $tierLabel) -State info

    if ($global:IS_ADMIN) {
        Write-Status "Running as Administrator" -State warn
    }
    if ($global:IS_UNC_PATH) {
        Write-Status "Network path detected - some features may be limited" -State warn
    }
    if ($global:PATH_TOO_LONG) {
        Write-Status ("Path is very long ({0} chars) - watch for Windows path limits" -f $global:PROJECT_ROOT.Length) -State warn
    }
    if ($global:IS_CLOUD_PATH) {
        Write-Status "Cloud-synced folder detected - state file may conflict with sync" -State warn
    }
    if ($global:CONDA_ACTIVE) {
        Write-Status ("Conda environment active ({0}) - this may interfere with venv" -f $env:CONDA_DEFAULT_ENV) -State warn
    }
}
