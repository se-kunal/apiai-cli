# API.AI CLI

A global `api` command for your FastAPI projects.  
Users install once, then it works in any project folder that has a `.apiai` file.

---

## For you — hosting setup

You need to host these files somewhere publicly accessible (GitHub raw, Cloudflare Pages, S3, your own server — anything):

```
your-domain.com/
  install.ps1       ← installer/install.ps1
  uninstall.ps1     ← installer/uninstall.ps1
  cli/
    run.ps1         ← cli/lib/ps1/run.ps1
    ui.ps1          ← cli/lib/ps1/ui.ps1
    logger.ps1      ← cli/lib/ps1/logger.ps1
    detector.ps1    ← cli/lib/ps1/detector.ps1
    state.ps1       ← cli/lib/ps1/state.ps1
```

**Then update two things in `install.ps1`:**

```powershell
$BASE_URL = "https://your-domain.com/cli"   # line ~30
```

That's it. The installer downloads the PS1 files at install time, so they
live on the user's machine permanently — no internet needed to run `api` daily.

### Easiest free hosting: GitHub Pages or raw GitHub

1. Push this repo to GitHub
2. In `install.ps1`, set:
   ```
   $BASE_URL = "https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/cli/lib/ps1"
   ```
3. Share the install command pointing to:
   ```
   https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/installer/install.ps1
   ```

---

## For your users — install command

Give them this one line to paste into **any PowerShell window**:

```powershell
irm https://your-domain.com/install.ps1 | iex
```

That's the only thing they ever need from you. After that:

```
cd my-project
api start
```

---

## The .apiai file

Drop this in any FastAPI project root. All fields are optional:

```ini
# .apiai
name        = My API
version     = 1.0.0
description = A FastAPI REST API
main        = main.py       # your entry file
app         = app           # FastAPI variable name
port        = 8000          # preferred port
python      = 3.8           # minimum Python version
```

---

## What `api` does

| Command | Action |
|---|---|
| `api start` | Install deps if needed, launch server, open browser |
| `api install` | Set up venv and install requirements.txt |
| `api restart` | Stop and restart the running server |
| `api doctor` | Run 10 diagnostic checks |
| `api clean` | Remove .venv and reset state |
| `api help` | Show help |

---

## What gets written to the user's project

| Path | Purpose |
|---|---|
| `.venv/` | Python virtual environment |
| `.env` | Copied from `.env.example` if missing |
| `.apiai_state` | Checksum snapshot for drift detection |
| `logs/` | Error reports (only on failure) |

---

## Uninstall (for users)

```powershell
irm https://your-domain.com/uninstall.ps1 | iex
```

Or manually: delete `%LOCALAPPDATA%\apiai-cli` and remove it from user PATH.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (built into Windows 10/11)
- Python 3.8+ (users are prompted if missing)
- No Node.js, no npm, no admin rights required
