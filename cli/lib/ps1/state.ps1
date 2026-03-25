$global:STATE_FILE = Join-Path $global:PROJECT_ROOT ".apiai_state"
$global:CHECKSUM_STATE = @{}

# Files we track for checksum drift.
$WATCHED_FILES = @(
    $global:MAIN_FILE,
    "requirements.txt",
    ".env",
    ".env.example"
)

# Files required to run.
$REQUIRED_FILES = @(
    $global:MAIN_FILE,
    "requirements.txt"
)

function Get-FileChecksum([string]$Path) {
    try {
        $hash = Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop
        return $hash.Hash
    }
    catch {
        return $null
    }
}

function Get-DirectorySnapshot {
    $snap = @{}
    foreach ($file in $WATCHED_FILES) {
        $fullPath = Join-Path $global:PROJECT_ROOT $file
        if (Test-Path $fullPath) {
            $snap[$file] = Get-FileChecksum $fullPath
        }
        else {
            $snap[$file] = "MISSING"
        }
    }
    return $snap
}

function Invoke-SelfCheck {
    $missing = @()
    $warnings = @()

    Write-Section "Self Check"

    Start-SpinnerInline "Scanning project files"
    Start-Sleep -Milliseconds 400
    Stop-SpinnerInline -Success $true -Message "Project files scanned"

    foreach ($file in $REQUIRED_FILES) {
        $fullPath = Join-Path $global:PROJECT_ROOT $file
        if (Test-Path $fullPath) {
            Write-Status $file -State ok
        }
        else {
            Write-Status $file -State error -Detail "required - not found"
            $missing += $file
        }
    }

    foreach ($file in @(".env", ".env.example")) {
        $fullPath = Join-Path $global:PROJECT_ROOT $file
        if (Test-Path $fullPath) {
            Write-Status $file -State ok
        }
        else {
            Write-Status $file -State warn -Detail "optional - not found"
            $warnings += $file
        }
    }

    $mainPath = Join-Path $global:PROJECT_ROOT $global:MAIN_FILE
    if (Test-Path $mainPath) {
        Start-SpinnerInline ("Inspecting " + $global:MAIN_FILE)
        Start-Sleep -Milliseconds 300
        $content = Get-Content $mainPath -Raw -ErrorAction SilentlyContinue
        Stop-SpinnerInline -Success $true -Message ($global:MAIN_FILE + " inspected")

        if ($content -match "FastAPI\s*\(") {
            Write-Status "FastAPI app detected" -State ok
        }
        else {
            Write-Status ("No FastAPI app found in {0}" -f $global:MAIN_FILE) -State warn -Detail "expected: app = FastAPI()"
            $warnings += ("{0}:no-fastapi" -f $global:MAIN_FILE)
        }

        if ($content -match "\bapp\s*=\s*FastAPI") {
            $global:APP_OBJECT = "app"
        }
        elseif ($content -match "(\w+)\s*=\s*FastAPI") {
            $global:APP_OBJECT = $matches[1]
            Write-Status ("App object is '{0}'" -f $global:APP_OBJECT) -State info -Detail "non-standard name"
        }
        else {
            $global:APP_OBJECT = "app"
        }
    }

    Write-Blank
    $currentSnap = Get-DirectorySnapshot
    $global:CHECKSUM_STATE = $currentSnap
    $drift = @()

    if (Test-Path $global:STATE_FILE) {
        try {
            $raw = Get-Content $global:STATE_FILE -Raw -Encoding UTF8
            $savedSnap = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop

            Start-SpinnerInline "Verifying environment integrity"
            Start-Sleep -Milliseconds 400
            Stop-SpinnerInline -Success $true -Message "Integrity check complete"

            foreach ($file in $currentSnap.Keys) {
                $cur = $currentSnap[$file]
                $prev = $savedSnap[$file]
                if ($prev -and $cur -ne $prev) {
                    if ($cur -eq "MISSING") {
                        $drift += "$file was deleted"
                    }
                    elseif ($prev -eq "MISSING") {
                        $drift += "$file was added"
                    }
                    else {
                        $drift += "$file was modified"
                    }
                }
            }

            if ($drift.Count -eq 0) {
                Write-Status "Environment matches last known state" -State ok
            }
            else {
                Write-Status "Environment has changed since last run" -State warn
                foreach ($d in $drift) {
                    Write-Color $global:C.Muted "    $($global:C.Warn)~$($global:C.Reset) $d"
                }
                $warnings += $drift
            }
        }
        catch {
            Write-Status "State file unreadable - treating as first run" -State info
            Save-State $currentSnap
        }
    }
    else {
        Write-Status "First run - establishing baseline" -State info
        Save-State $currentSnap
    }

    return @{
        OK = ($missing.Count -eq 0)
        Missing = $missing
        Warnings = $warnings
        Drift = $drift
    }
}

function Save-State([hashtable]$Snapshot) {
    try {
        $Snapshot | ConvertTo-Json -Depth 3 | Set-Content -Path $global:STATE_FILE -Encoding UTF8 -Force
    }
    catch {
        # non-fatal
    }
}

function Update-State {
    $snap = Get-DirectorySnapshot
    $global:CHECKSUM_STATE = $snap
    Save-State $snap
}
