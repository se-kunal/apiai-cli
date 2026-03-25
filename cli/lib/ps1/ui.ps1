# ================================================================
#  API.AI  |  UI Engine  |  lib/ui.ps1
#  All visual output, animations, color, and layout lives here.
#  Business logic never touches the screen directly.
# ================================================================

# ----------------------------------------------------------------
# CAPABILITY TIER (set by caller after detection)
# ----------------------------------------------------------------
$global:UI_TIER       = 1          # 1=CMD-fallback  2=ANSI  3=Full
$global:UI_WIDTH      = 64
$global:CURSOR_HIDDEN = $false

# ----------------------------------------------------------------
# COLOR PALETTE  (ANSI escape sequences)
# ----------------------------------------------------------------
$ESC = [char]27

$global:C = @{
    # Brand
    Brand       = "$ESC[38;2;99;179;237m"      # sky blue  — API.AI identity
    BrandDim    = "$ESC[38;2;49;116;173m"

    # Semantic
    Success     = "$ESC[38;2;72;199;142m"       # green
    Warn        = "$ESC[38;2;251;189;35m"       # amber
    Error       = "$ESC[38;2;252;87;87m"        # red
    Info        = "$ESC[38;2;148;163;184m"      # slate
    Muted       = "$ESC[38;2;71;85;105m"        # dim slate

    # Content
    White       = "$ESC[38;2;241;245;249m"      # near-white
    Bright      = "$ESC[1;38;2;255;255;255m"    # bold white
    Cyan        = "$ESC[38;2;34;211;238m"       # cyan
    CyanDim     = "$ESC[38;2;22;135;153m"

    # Decoration
    Border      = "$ESC[38;2;51;65;85m"         # subtle border
    Accent      = "$ESC[38;2;139;92;246m"       # violet accent

    # Control
    Reset       = "$ESC[0m"
    Bold        = "$ESC[1m"
    Dim         = "$ESC[2m"
    ClearLine   = "$ESC[2K`r"
    Up1         = "$ESC[1A"
    HideCursor  = "$ESC[?25l"
    ShowCursor  = "$ESC[?25h"
    SaveCursor  = "$ESC[s"
    RestCursor  = "$ESC[u"
}

# ----------------------------------------------------------------
# UNICODE SETS  (tier-aware)
# ----------------------------------------------------------------
function Get-Symbols {
    if ($global:UI_TIER -ge 2) {
        return @{
            Check   = [char]0x2714        # ✔
            Cross   = [char]0x2718        # ✘
            Warn    = [char]0x26A0        # ⚠
            Arrow   = [char]0x276F        # ❯
            Bullet  = [char]0x25CF        # ●
            Diamond = [char]0x25C6        # ◆
            Dash    = [char]0x2500        # ─
            VBar    = [char]0x2502        # │
            TL      = [char]0x256D        # ╭
            TR      = [char]0x256E        # ╮
            BL      = [char]0x2570        # ╰
            BR      = [char]0x256F        # ╯
            LMid    = [char]0x251C        # ├
            RMid    = [char]0x2524        # ┤
            Dot     = [char]0x00B7        # ·
            Ellip   = [char]0x2026        # …
            Rocket  = [char]0x25B6        # ▶
            Spark   = [char]0x2605        # ★
        }
    } else {
        return @{
            Check   = '+'
            Cross   = 'X'
            Warn    = '!'
            Arrow   = '>'
            Bullet  = '*'
            Diamond = '*'
            Dash    = '-'
            VBar    = '|'
            TL      = '+'
            TR      = '+'
            BL      = '+'
            BR      = '+'
            LMid    = '+'
            RMid    = '+'
            Dot     = '.'
            Ellip   = '...'
            Rocket  = '>'
            Spark   = '*'
        }
    }
}

# ----------------------------------------------------------------
# WRITE HELPERS
# ----------------------------------------------------------------
function Write-Raw($text) {
    [Console]::Write($text)
}

function Write-Color($color, $text, [switch]$NoNewline) {
    if ($global:UI_TIER -ge 2) {
        if ($NoNewline) { [Console]::Write("$color$text$($global:C.Reset)") }
        else            { [Console]::WriteLine("$color$text$($global:C.Reset)") }
    } else {
        if ($NoNewline) { [Console]::Write($text) }
        else            { [Console]::WriteLine($text) }
    }
}

function Write-Blank { [Console]::WriteLine("") }

# ----------------------------------------------------------------
# CURSOR CONTROL
# ----------------------------------------------------------------
function Hide-Cursor {
    if ($global:UI_TIER -ge 2) { Write-Raw $global:C.HideCursor; $global:CURSOR_HIDDEN = $true }
}
function Show-Cursor {
    if ($global:UI_TIER -ge 2) { Write-Raw $global:C.ShowCursor; $global:CURSOR_HIDDEN = $false }
}

# ----------------------------------------------------------------
# TYPEWRITER  — types a string character by character
# ----------------------------------------------------------------
function Write-Typewriter {
    param(
        [string]$Text,
        [string]$Color = $global:C.White,
        [int]$DelayMs  = 18,
        [switch]$NoNewline
    )
    if ($global:UI_TIER -lt 2) {
        Write-Color $Color $Text -NoNewline:$NoNewline
        return
    }
    Write-Raw $Color
    foreach ($char in $Text.ToCharArray()) {
        Write-Raw $char
        Start-Sleep -Milliseconds $DelayMs
    }
    Write-Raw $global:C.Reset
    if (-not $NoNewline) { [Console]::WriteLine("") }
}

# ----------------------------------------------------------------
# STAGGER  — reveals lines one by one with a delay
# ----------------------------------------------------------------
function Write-Stagger {
    param(
        [string[]]$Lines,
        [string]$Color    = $global:C.White,
        [int]$DelayMs     = 60
    )
    foreach ($line in $Lines) {
        Write-Color $Color $line
        Start-Sleep -Milliseconds $DelayMs
    }
}

# ----------------------------------------------------------------
# SPINNER  — runs during a script block, resolves in-place
# ----------------------------------------------------------------
$global:SPINNER_FRAMES_BRAILLE = @(
    [char]0x280B, [char]0x2819, [char]0x2839, [char]0x2838,
    [char]0x283C, [char]0x2834, [char]0x2826, [char]0x2827,
    [char]0x2807, [char]0x280F
)
$global:SPINNER_FRAMES_SIMPLE = @('|','/','-','\')

function Invoke-WithSpinner {
    param(
        [string]$Label,
        [scriptblock]$Action,
        [string]$SuccessMsg = "",
        [string]$FailMsg    = ""
    )

    $sym = Get-Symbols
    $result = $null
    $error_detail = $null

    if ($global:UI_TIER -ge 2) {
        $frames = $global:SPINNER_FRAMES_BRAILLE
    } else {
        $frames = $global:SPINNER_FRAMES_SIMPLE
    }

    Hide-Cursor

    # Run action in a job so spinner can animate on main thread
    $job = Start-Job -ScriptBlock $Action

    $i = 0
    while ($job.State -eq 'Running') {
        $frame = $frames[$i % $frames.Count]
        $prefix = "  $($global:C.Cyan)$frame$($global:C.Reset)"
        Write-Raw "$($global:C.ClearLine)$prefix $($global:C.Info)$Label$($global:C.Reset)"
        Start-Sleep -Milliseconds 80
        $i++
    }

    $result      = Receive-Job $job -ErrorVariable joberr 2>&1
    $jobState    = $job.State
    $jobFailed   = ($joberr.Count -gt 0) -or ($jobState -eq 'Failed')
    Remove-Job $job -Force

    # Resolve the spinner line in-place
    Write-Raw $global:C.ClearLine
    if (-not $jobFailed) {
        $msg = if ($SuccessMsg) { $SuccessMsg } else { $Label }
        Write-Color $global:C.Success "  $($sym.Check) $msg"
    } else {
        $msg = if ($FailMsg) { $FailMsg } else { $Label }
        Write-Color $global:C.Error "  $($sym.Cross) $msg"
        $error_detail = $joberr | Out-String
    }

    Show-Cursor

    return @{
        Success = (-not $jobFailed)
        Output  = $result
        Error   = $error_detail
    }
}

# Lightweight inline spinner for steps that run synchronously
function Start-SpinnerInline {
    param([string]$Label)
    $global:_spinnerLabel = $Label
    $global:_spinnerIdx   = 0
    $global:_spinnerActive = $true

    if ($global:UI_TIER -ge 2) {
        $global:_spinnerFrames = $global:SPINNER_FRAMES_BRAILLE
    } else {
        $global:_spinnerFrames = $global:SPINNER_FRAMES_SIMPLE
    }
    Hide-Cursor
}

function Step-SpinnerInline {
    if (-not $global:_spinnerActive) { return }
    $frame = $global:_spinnerFrames[$global:_spinnerIdx % $global:_spinnerFrames.Count]
    Write-Raw "$($global:C.ClearLine)  $($global:C.Cyan)$frame$($global:C.Reset) $($global:C.Info)$($global:_spinnerLabel)$($global:C.Reset)"
    $global:_spinnerIdx++
    Start-Sleep -Milliseconds 80
}

function Stop-SpinnerInline {
    param([bool]$Success = $true, [string]$Message = "")
    $global:_spinnerActive = $false
    $sym = Get-Symbols
    $msg = if ($Message) { $Message } else { $global:_spinnerLabel }
    Write-Raw $global:C.ClearLine
    if ($Success) {
        Write-Color $global:C.Success "  $($sym.Check) $msg"
    } else {
        Write-Color $global:C.Error   "  $($sym.Cross) $msg"
    }
    Show-Cursor
}

# ----------------------------------------------------------------
# PROGRESS BAR  — for operations with known steps
# ----------------------------------------------------------------
function Write-ProgressBar {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Label = "",
        [int]$Width    = 30
    )
    $pct   = [math]::Floor(($Current / $Total) * $Width)
    $empty = $Width - $pct

    if ($global:UI_TIER -ge 2) {
        $filled = [string][char]0x2588 * $pct
        $unfill = [string][char]0x2591 * $empty
        $bar    = "$($global:C.Brand)$filled$($global:C.Muted)$unfill$($global:C.Reset)"
    } else {
        $filled = '#' * $pct
        $unfill = '-' * $empty
        $bar    = "[$filled$unfill]"
    }

    $pctNum = [math]::Floor(($Current / $Total) * 100)
    Write-Raw "$($global:C.ClearLine)  $bar $($global:C.Info)$pctNum% $Label$($global:C.Reset)"
}

# ----------------------------------------------------------------
# SEPARATOR
# ----------------------------------------------------------------
function Write-Separator {
    param([string]$Color = $global:C.Border)
    $sym  = Get-Symbols
    $line = $sym.Dash * ($global:UI_WIDTH - 2)
    Write-Color $Color "  $line"
}

# ----------------------------------------------------------------
# SECTION HEADER  — named phase marker
# ----------------------------------------------------------------
function Write-Section {
    param([string]$Title, [string]$Color = $global:C.Brand)
    $sym = Get-Symbols
    Write-Blank
    Write-Color $Color "  $($sym.Diamond) $Title"
    Write-Separator $global:C.Border
}

# ----------------------------------------------------------------
# STATUS LINE  — single resolved check
# ----------------------------------------------------------------
function Write-Status {
    param(
        [string]$Label,
        [ValidateSet('ok','warn','error','info')]
        [string]$State = 'info',
        [string]$Detail = ""
    )
    $sym = Get-Symbols
    switch ($State) {
        'ok'    { $icon = $sym.Check;   $color = $global:C.Success }
        'warn'  { $icon = $sym.Warn;    $color = $global:C.Warn    }
        'error' { $icon = $sym.Cross;   $color = $global:C.Error   }
        'info'  { $icon = $sym.Bullet;  $color = $global:C.Info    }
    }
    $detail_str = if ($Detail) { " $($global:C.Muted)$Detail$($global:C.Reset)" } else { "" }
    Write-Color $color "  $icon $Label$detail_str"
}

# ----------------------------------------------------------------
# BOX  — draws a rounded box with title and lines
# ----------------------------------------------------------------
function Write-Box {
    param(
        [string]$Title       = "",
        [string[]]$Lines     = @(),
        [string]$BorderColor = $global:C.Brand,
        [string]$TitleColor  = $global:C.Bright,
        [int]$Width          = $global:UI_WIDTH,
        [int]$AnimDelayMs    = 0
    )

    $sym        = Get-Symbols
    $innerWidth = $Width - 4   # 2 border chars + 2 padding
    $dash       = $sym.Dash * ($Width - 2)

    function Pad-Line([string]$s) {
        $pad = $innerWidth - $s.Length
        if ($pad -lt 0) { $pad = 0 }
        return $s + (' ' * $pad)
    }

    # Top border
    if ($AnimDelayMs -gt 0) { Start-Sleep -Milliseconds $AnimDelayMs }
    Write-Color $BorderColor "  $($sym.TL)$dash$($sym.TR)"

    # Title
    if ($Title) {
        if ($AnimDelayMs -gt 0) { Start-Sleep -Milliseconds $AnimDelayMs }
        $titlePadded = Pad-Line " $Title "
        Write-Raw "  $($BorderColor)$($sym.VBar)$($TitleColor) $titlePadded$($BorderColor)$($sym.VBar)$($global:C.Reset)`n"

        if ($AnimDelayMs -gt 0) { Start-Sleep -Milliseconds $AnimDelayMs }
        Write-Color $BorderColor "  $($sym.LMid)$dash$($sym.RMid)"
    }

    # Content lines
    foreach ($line in $Lines) {
        if ($AnimDelayMs -gt 0) { Start-Sleep -Milliseconds $AnimDelayMs }
        $padded = Pad-Line $line
        Write-Raw "  $($BorderColor)$($sym.VBar)$($global:C.White) $padded$($BorderColor)$($sym.VBar)$($global:C.Reset)`n"
    }

    # Bottom border
    if ($AnimDelayMs -gt 0) { Start-Sleep -Milliseconds $AnimDelayMs }
    Write-Color $BorderColor "  $($sym.BL)$dash$($sym.BR)"
}

# ----------------------------------------------------------------
# LOGO  — ASCII art with staggered reveal
# ----------------------------------------------------------------
function Write-Logo {
    param([int]$DelayMs = 40)

    $logo = @(
        "   ___   ____  ____    ___   ____  ",
        "  / _ | / __ \/  _/   / _ | /  _/  ",
        " / __ |/ /_/ // /    / __ |_/ /    ",
        "/_/ |_/ .___/___/   /_/ |_/___/    ",
        "      /_/                           "
    )

    Write-Blank
    foreach ($line in $logo) {
        Write-Color $global:C.Brand $line
        if ($global:UI_TIER -ge 2) { Start-Sleep -Milliseconds $DelayMs }
    }
}

# ----------------------------------------------------------------
# BANNER  — full screen clear + logo + meta
# ----------------------------------------------------------------
function Write-Banner {
    param([string]$Subtitle = "Runtime CLI")
    Clear-Host
    Write-Logo
    Write-Blank
    $sym = Get-Symbols
    Write-Color $global:C.Muted "  $($sym.Dash * 36)"
    Write-Color $global:C.Info  "  $Subtitle"
    Write-Blank
}

# ----------------------------------------------------------------
# LAUNCH BOX  — the "wow" moment when server is ready
# ----------------------------------------------------------------
function Write-LaunchBox {
    param(
        [string]$Port,
        [string]$AppName  = "API.AI",
        [string]$Version  = "1.0.0"
    )

    Write-Blank
    Start-Sleep -Milliseconds 300

    $sym = Get-Symbols

    $lines = @(
        "",
        "  $($global:C.Muted)Local$($global:C.Reset)      $($global:C.Bright)http://localhost:$Port$($global:C.Reset)",
        "  $($global:C.Muted)Docs$($global:C.Reset)       $($global:C.Cyan)http://localhost:$Port/docs$($global:C.Reset)",
        "  $($global:C.Muted)Version$($global:C.Reset)    $($global:C.Info)$Version$($global:C.Reset)",
        ""
    )

    Write-Box -Title " $($sym.Spark)  $AppName  $($sym.Spark) " `
              -Lines $lines `
              -BorderColor $global:C.Brand `
              -TitleColor $global:C.Bright `
              -AnimDelayMs 60

    Write-Blank
    Write-Color $global:C.Success "  $($sym.Rocket)  Server is live. Your API is ready."
    Write-Blank
}

# ----------------------------------------------------------------
# ERROR MOMENT  — calm, human, with file reference
# ----------------------------------------------------------------
function Write-ErrorMoment {
    param(
        [string]$HumanMessage,
        [string]$LogFile
    )

    $sym = Get-Symbols
    Write-Blank
    Write-Color $global:C.Error "  $($sym.Cross) $HumanMessage"
    Write-Blank

    if ($LogFile) {
        $lines = @(
            "",
            "  A support file has been created:",
            "  $LogFile",
            "",
            "  Share this file with the API.AI team",
            "  and we'll get this sorted for you.",
            ""
        )
        Write-Box -Title "  Support Info" `
                  -Lines $lines `
                  -BorderColor $global:C.Warn `
                  -TitleColor $global:C.Warn `
                  -AnimDelayMs 40
    }
}

# ----------------------------------------------------------------
# QUESTION  — single Y/N prompt, returns bool
# ----------------------------------------------------------------
function Ask-YesNo {
    param(
        [string]$Question,
        [bool]$Default = $true
    )
    $sym     = Get-Symbols
    $hint    = if ($Default) { "[Y/n]" } else { "[y/N]" }
    Write-Blank
    Write-Raw "  $($global:C.Cyan)$($sym.Arrow)$($global:C.Reset) $($global:C.White)$Question $($global:C.Muted)$hint$($global:C.Reset) "
    $key = [Console]::ReadLine().Trim().ToLower()
    if ($key -eq "") { return $Default }
    return ($key -eq 'y')
}

# ----------------------------------------------------------------
# PAUSE  — for double-click / non-terminal launch
# ----------------------------------------------------------------
function Wait-AnyKey {
    Write-Blank
    Write-Color $global:C.Muted "  Press any key to exit..."
    $null = [Console]::ReadKey($true)
}

# ----------------------------------------------------------------
# TRAP Ctrl+C  — clean exit, restore cursor
# ----------------------------------------------------------------
function Register-CleanExit {
    [Console]::TreatControlCAsInput = $false
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        Show-Cursor
    }
}
