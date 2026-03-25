# ================================================================
#  API.AI  |  State & Checksum  |  lib/state.ps1
#  Tracks environment fingerprint across runs.
#  Detects drift, missing files, unexpected changes.
# ================================================================

$global:STATE_FILE       = Join-Path $global:PROJECT_ROOT ".apiai_state"
$global:CHECKSUM_STATE   = @{}

# Files we checksum — source files only, not generated artifacts
$WATCHED_FILES = @(
    "main.py",
    "requirements.txt",
    ".env",
    ".env.example"
)

# Files that MUST exist for the API to run (main.py resolved from .apiai at runtime)
$REQUIRED_FILES = @(
    $global:MAIN_FILE,
    "requirements.txt"
)

# ----------------------------------------------------------------
# COMPUTE CHECKSUM of a single file
# ----------------------------------------------------------------
function Get-FileChecksum([string]$Path) {
    try {
        $hash = Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop
        return $hash.Hash
    } catch {
        return $null
    }
}

# ----------------------------------------------------------------
# BUILD SNAPSHOT  — checksums of all watched files
# ----------------------------------------------------------------
function Get-DirectorySnapshot {
    $snap = @{}
    foreach ($file in $WATCHED_FILES) {
        $fullPath = Join-Path $global:PROJECT_ROOT $file
        if (Test-Path $fullPath) {
            $snap[$file] = Get-FileChecksum $fullPath
        } else {
            $snap[$file] = "MISSING"
        }
    }
    return $snap
}

# ----------------------------------------------------------------
# SELF CHECK  — sniff the directory, validate required files
# Returns a result object: { OK, Missing, Warnings }
# ----------------------------------------------------------------
function Invoke-SelfCheck {
    $sym      = Get-Symbols
    $missing  = @()
    $warnings = @()
    $present  = @()

    Write-Section "Self Check"

    # 1. Required files
    Start-SpinnerInline "Scanning project files"
    Start-Sleep -Milliseconds 400  # intentional beat — feels like it's thinking
    Stop-SpinnerInline -Success $true -Message "Project files scanned"

    foreach ($file in $REQUIRED_FILES) {
        $fullPath = Join-Path $global:PROJECT_ROOT $file
        if (Test-Path $fullPath) {
            Write-Status $file -State ok
            $present += $file
        } else {
            Write-Status $file -State error -Detail "required — not found"
            $missing += $file
        }
    }

    # Optional files — warn if missing
    $optionalFiles = @('.env', '.env.example')
    foreach ($file in $optionalFiles) {
        $fullPath = Join-Path $global:PROJECT_ROOT $file
        if (Test-Path $fullPath) {
            Write-Status $file -State ok
        } else {
            Write-Status $file -State warn -Detail "optional — not found"
            $warnings += $file
        }
    }

    # main.py sanity — check it contains a FastAPI app object
    $mainPath = Join-Path $global:PROJECT_ROOT "main.py"
    if (Test-Path $mainPath) {
        Start-SpinnerInline "Inspecting main.py"
        Start-Sleep -Milliseconds 300
        $content = Get-Content $mainPath -Raw -ErrorAction SilentlyContinue
        Stop-SpinnerInline -Success $true -Message "main.py inspected"

        if ($content -match 'FastAPI\s*\(') {
            Write-Status "FastAPI app detected" -State ok
        } else {
            Write-Status "No FastAPI app found in main.py" -State warn -Detail "expected: app = FastAPI()"
            $warnings += "main.py:no-fastapi"
        }

        # Check app variable name
        if ($content -match '\bapp\s*=\s*FastAPI') {
            $global:APP_OBJECT = "app"
        } elseif ($content -match '(\w+)\s*=\s*FastAPI') {
            $global:APP_OBJECT = $matches[1]
            Write-Status "App object is '$($global:APP_OBJECT)'" -State info -Detail "non-standard name"
        } else {
            $global:APP_OBJECT = "app"
        }
    }

    # 2. Checksum comparison
    Write-Blank
    $currentSnap = Get-DirectorySnapshot
    $global:CHECKSUM_STATE = $currentSnap

    $stateExists = Test-Path $global:STATE_FILE
    $drift       = @()

    if ($stateExists) {
        try {
            $raw       = Get-Content $global:STATE_FILE -Raw -Encoding UTF8
            $savedSnap = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop

            Start-SpinnerInline "Verifying environment integrity"
            Start-Sleep -Milliseconds 400
            Stop-SpinnerInline -Success $true -Message "Integrity check complete"

            foreach ($file in $currentSnap.Keys) {
                $cur  = $currentSnap[$file]
                $prev = $savedSnap[$file]

                if ($prev -and $cur -ne $prev) {
                    if ($cur -eq "MISSING") {
                        $drift += "$file was deleted"
                    } elseif ($prev -eq "MISSING") {
                        $drift += "$file was added"
                    } else {
                        $drift += "$file was modified"
                    }
                }
            }

            if ($drift.Count -eq 0) {
                Write-Status "Environment matches last known state" -State ok
            } else {
                Write-Status "Environment has changed since last run" -State warn
                foreach ($d in $drift) {
                    Write-Color $global:C.Muted "    $($global:C.Warn)~$($global:C.Reset) $d"
                }
                $warnings += $drift
            }

        } catch {
            # State file corrupted — treat as first run
            Write-Status "State file unreadable — treating as first run" -State info
            Save-State $currentSnap
        }
    } else {
        Write-Status "First run — establishing baseline" -State info
        Save-State $currentSnap
    }

    return @{
        OK       = ($missing.Count -eq 0)
        Missing  = $missing
        Warnings = $warnings
        Drift    = $drift
    }
}

# ----------------------------------------------------------------
# SAVE STATE  — write current snapshot to disk
# ----------------------------------------------------------------
function Save-State([hashtable]$Snapshot) {
    try {
        $Snapshot | ConvertTo-Json -Depth 3 | Set-Content -Path $global:STATE_FILE -Encoding UTF8 -Force
    } catch {
        # Non-fatal — if we can't write state, we just skip it silently
    }
}

# ----------------------------------------------------------------
# UPDATE STATE  — call after a successful run to refresh baseline
# ----------------------------------------------------------------
function Update-State {
    $snap = Get-DirectorySnapshot
    $global:CHECKSUM_STATE = $snap
    Save-State $snap
}
