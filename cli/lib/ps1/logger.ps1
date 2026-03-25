$global:LOG_DIR = Join-Path $global:PROJECT_ROOT "logs"
$global:SESSION_META = @{}

function Initialize-Logger {
    if (-not (Test-Path $global:LOG_DIR)) {
        New-Item -ItemType Directory -Path $global:LOG_DIR -Force | Out-Null
    }
}

function Write-ErrorLog {
    param(
        [string]$Step,
        [string]$HumanMessage,
        [object]$Exception,
        [hashtable]$ExtraContext = @{}
    )

    Initialize-Logger

    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $tsHuman = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $filePath = Join-Path $global:LOG_DIR ("apiai-error-{0}.log" -f $ts)

    $envSnapshot = @{}
    $safeKeys = @(
        "PATH", "USERPROFILE", "COMPUTERNAME", "OS", "PROCESSOR_ARCHITECTURE",
        "PYTHON_VERSION", "VIRTUAL_ENV", "CONDA_DEFAULT_ENV", "TERM",
        "WT_SESSION", "PSModulePath"
    )
    foreach ($k in $safeKeys) {
        $val = [System.Environment]::GetEnvironmentVariable($k)
        if ($val) { $envSnapshot[$k] = $val }
    }
    if ($envSnapshot["PATH"]) {
        $envSnapshot["PATH"] = "[present - redacted for length]"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $border = ("=" * 64)
    $divider = ("-" * 64)

    $lines.Add($border)
    $lines.Add("  API.AI  |  Error Report")
    $lines.Add($border)
    $lines.Add("")
    $lines.Add("  Generated   : $tsHuman")
    $lines.Add("  Step        : $Step")
    $lines.Add("  Message     : $HumanMessage")
    $lines.Add("")
    $lines.Add($divider)
    $lines.Add("  SYSTEM")
    $lines.Add($divider)
    $lines.Add("")

    foreach ($key in ($global:SESSION_META.Keys | Sort-Object)) {
        $lines.Add(("  {0}: {1}" -f $key.PadRight(22), $global:SESSION_META[$key]))
    }

    $lines.Add("")
    $lines.Add("  PowerShell Version : $($PSVersionTable.PSVersion)")
    $lines.Add("  OS                 : $([System.Environment]::OSVersion.VersionString)")
    $lines.Add("  Machine            : $([System.Environment]::MachineName)")
    $lines.Add("  Username           : $([System.Environment]::UserName)")
    $lines.Add("  64-bit OS          : $([System.Environment]::Is64BitOperatingSystem)")
    $lines.Add("  64-bit Process     : $([System.Environment]::Is64BitProcess)")
    $lines.Add("  UI Tier            : $global:UI_TIER")
    $lines.Add("  Script Root        : $global:SCRIPT_ROOT")
    $lines.Add("")

    $lines.Add($divider)
    $lines.Add("  EXCEPTION")
    $lines.Add($divider)
    $lines.Add("")

    if ($Exception -is [System.Management.Automation.ErrorRecord]) {
        $lines.Add("  Type       : $($Exception.Exception.GetType().FullName)")
        $lines.Add("  Message    : $($Exception.Exception.Message)")
        $lines.Add("  Category   : $($Exception.CategoryInfo.Category)")
        $lines.Add("  Target     : $($Exception.CategoryInfo.TargetName)")
        $lines.Add("")
        $lines.Add("  Stack Trace:")
        $lines.Add("")
        $st = $Exception.ScriptStackTrace
        if ($st) {
            foreach ($stLine in ($st -split "`n")) {
                $lines.Add("    $($stLine.TrimEnd())")
            }
        }
    }
    elseif ($Exception -is [System.Exception]) {
        $lines.Add("  Type    : $($Exception.GetType().FullName)")
        $lines.Add("  Message : $($Exception.Message)")
        $lines.Add("")
        $lines.Add("  Stack Trace:")
        $lines.Add("")
        foreach ($stLine in (($Exception.StackTrace | Out-String) -split "`n")) {
            if ($stLine.Trim()) { $lines.Add("    $($stLine.TrimEnd())") }
        }
    }
    else {
        $lines.Add("  Raw:")
        $lines.Add("")
        $lines.Add("    $Exception")
    }
    $lines.Add("")

    if ($ExtraContext.Count -gt 0) {
        $lines.Add($divider)
        $lines.Add("  EXTRA CONTEXT")
        $lines.Add($divider)
        $lines.Add("")
        foreach ($k in ($ExtraContext.Keys | Sort-Object)) {
            $lines.Add(("  {0}: {1}" -f $k.PadRight(22), $ExtraContext[$k]))
        }
        $lines.Add("")
    }

    $lines.Add($divider)
    $lines.Add("  ENVIRONMENT VARIABLES (selected)")
    $lines.Add($divider)
    $lines.Add("")
    foreach ($k in ($envSnapshot.Keys | Sort-Object)) {
        $lines.Add(("  {0}: {1}" -f $k.PadRight(28), $envSnapshot[$k]))
    }
    $lines.Add("")

    if ($global:CHECKSUM_STATE) {
        $lines.Add($divider)
        $lines.Add("  CHECKSUM STATE AT FAILURE")
        $lines.Add($divider)
        $lines.Add("")
        foreach ($k in ($global:CHECKSUM_STATE.Keys | Sort-Object)) {
            $lines.Add(("  {0}: {1}" -f $k.PadRight(28), $global:CHECKSUM_STATE[$k]))
        }
        $lines.Add("")
    }

    $lines.Add($divider)
    $lines.Add("  DIRECTORY SNAPSHOT")
    $lines.Add($divider)
    $lines.Add("")
    try {
        $items = Get-ChildItem -Path $global:PROJECT_ROOT -Depth 1 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^\.venv$|^node_modules$|^__pycache__$' } |
            Select-Object Name, Length, LastWriteTime
        foreach ($item in $items) {
            $size = if ($item.Length) { "{0} KB" -f [math]::Round($item.Length / 1KB, 1) } else { "<dir>" }
            $lines.Add(("  {0} {1} {2}" -f $item.Name.PadRight(32), $size.PadRight(12), $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm")))
        }
    }
    catch {
        $lines.Add("  [Could not list directory]")
    }
    $lines.Add("")
    $lines.Add($border)
    $lines.Add("  End of report  |  API.AI v$global:APP_VERSION")
    $lines.Add($border)

    try {
        $lines | Set-Content -Path $filePath -Encoding UTF8 -Force
        return $filePath
    }
    catch {
        return $null
    }
}

function Invoke-Safe {
    param(
        [string]$Step,
        [string]$HumanMessage,
        [scriptblock]$Action,
        [hashtable]$ExtraContext = @{}
    )

    try {
        & $Action
        return $true
    }
    catch {
        $logFile = Write-ErrorLog -Step $Step -HumanMessage $HumanMessage -Exception $_ -ExtraContext $ExtraContext
        Write-ErrorMoment -HumanMessage $HumanMessage -LogFile $logFile
        return $false
    }
}
