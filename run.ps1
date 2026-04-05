# run.ps1 — Butterfly Effect launcher for Windows
# Usage: double-click "Start Butterfly Effect - Windows.cmd", or: powershell -ExecutionPolicy Bypass -File run.ps1
#
# Mirrors run.sh logic exactly:
#   1. Detect Python 3.11+
#   2. Create / verify .venv
#   3. Upgrade pip if needed; pip install -r requirements.txt
#   4. Install Playwright Chromium on first run (~250 MB, one-time)
#   5. Start Flask server and open startup.html in the default browser

#Requires -Version 5.1
Set-StrictMode -Version Latest
# Use 'Continue' so that native commands writing to stderr (pip warnings, py.exe launcher
# notices, playwright progress, etc.) don't trigger NativeCommandError and crash the script.
# Real failures are caught explicitly via $LASTEXITCODE checks throughout.
$ErrorActionPreference = 'Continue'
# Set UTF-8 console output so Unicode characters (ellipsis, progress bars, etc.) render correctly.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding            = [System.Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# ── Status file & JSONP server for startup screen progress ───────────────────
$StatusFile = Join-Path $env:TEMP "butterfly-status-$PID.json"
$StatusServerJob = $null

function Write-Status {
    param(
        [string]$Stage,
        [int]$Pct,
        [string]$Detail,
        [int]$Step  = 0,
        [int]$Total = 0
    )
    $Detail = $Detail -replace '"', '\"'
    $json = "{`"stage`":`"$Stage`",`"pct`":$Pct,`"detail`":`"$Detail`",`"step`":$Step,`"total`":$Total}"
    [System.IO.File]::WriteAllText($StatusFile, $json)
}

function Start-StatusServer {
    # Inline Python stdlib HTTP server — no pip packages needed, runs before venv exists.
    $pyCode = @"
import http.server, sys, pathlib
sf = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        try:    body = ('window.__BF_STATUS=' + pathlib.Path(sf).read_text(encoding='utf-8').strip() + ';').encode()
        except: body = b'window.__BF_STATUS=null;'
        self.send_response(200)
        self.send_header('Content-Type', 'application/javascript; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)
try:
    http.server.HTTPServer(('127.0.0.1', 5003), H).serve_forever()
except Exception:
    pass
"@
    $script:StatusServerJob = Start-Job -ScriptBlock {
        param($python, $code, $sf)
        & $python -c $code $sf
    } -ArgumentList $script:PYTHON, $pyCode, $StatusFile
}

function Stop-StatusServer {
    if ($script:StatusServerJob) {
        Stop-Job  $script:StatusServerJob -ErrorAction SilentlyContinue
        Remove-Job $script:StatusServerJob -ErrorAction SilentlyContinue
        $script:StatusServerJob = $null
    }
    if (Test-Path $StatusFile) { Remove-Item $StatusFile -ErrorAction SilentlyContinue }
}

# Ensure cleanup on exit
$null = Register-EngineEvent PowerShell.Exiting -Action { Stop-StatusServer }

# ── Helper: open startup.html in the default browser ─────────────────────────
function Open-Startup {
    param([string]$Params = '')
    # Write a temp copy so we can inject window.__BF_PARAMS without modifying the source
    $tmp = Join-Path $env:TEMP "butterfly-startup-$PID.html"
    Copy-Item (Join-Path $ScriptDir 'startup.html') $tmp -Force
    if ($Params) {
        $escaped = $Params -replace "'", "''"
        $inject  = "<script>window.__BF_PARAMS='$escaped';</script></head>"
        (Get-Content $tmp -Raw -Encoding UTF8) -replace '</head>', $inject | Set-Content $tmp -Encoding UTF8
    }
    Start-Process "file:///$($tmp -replace '\\','/')"
}

# ── Python detection ──────────────────────────────────────────────────────────
$script:PYTHON = $null
# 'py' is the Windows Python Launcher (installed to System32, never shadowed by App Execution
# Aliases).  It is the most reliable way to find Python on Windows, so check it first.
foreach ($candidate in @('py', 'python', 'python3', 'python3.13', 'python3.12', 'python3.11')) {
    $found = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($found) {
        # Wrap in try/catch: Windows App Execution Aliases write to stderr ("Python was not
        # found$([char]8230)") which triggers NativeCommandError under $ErrorActionPreference='Stop'.
        try {
            $null = & $candidate -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>&1
            if ($LASTEXITCODE -eq 0) { $script:PYTHON = $candidate; break }
        } catch { }
    }
}

# Allow forcing the no-python error for testing.
# Preferred: "Start Butterfly Effect - Windows.cmd" --simulate-no-python   (flag passed through via %*)
# Fallback:  set SIMULATE_NO_PYTHON=1 && "Start Butterfly Effect - Windows.cmd"   (must be same cmd.exe window)
if ($env:SIMULATE_NO_PYTHON -eq '1' -or $args -contains '--simulate-no-python') {
    $script:PYTHON = $null
}

if (-not $script:PYTHON) {
    Open-Startup 'e=nopython&os=windows'
    Write-Host ''
    Write-Host ('-' * 52)
    Write-Host '  Python 3.11 or higher is required.'
    Write-Host ''
    Write-Host '  Option 1 - Direct download:'
    Write-Host '    https://python.org/downloads'
    Write-Host '    (Check "Add Python to PATH" during install)'
    Write-Host ''
    Write-Host '  Option 2 - winget (Windows 11 / updated Windows 10):'
    Write-Host '    winget install Python.Python.3.12'
    Write-Host ''
    Write-Host '  After installing, open a new Command Prompt window'
    Write-Host '  and run "Start Butterfly Effect - Windows.cmd" again.'
    Write-Host ('-' * 52)
    Write-Host ''
    exit 1
}

# ── Detect which setup steps are needed (for accurate step counter) ───────────
$Venv             = Join-Path $ScriptDir '.venv'
$PlaywrightCache  = Join-Path $env:USERPROFILE '.cache\butterfly-effect\playwright'

$VenvOk = $false
$VenvPy = Join-Path $Venv 'Scripts\python.exe'
$VenvPip = Join-Path $Venv 'Scripts\pip.exe'
if ((Test-Path $VenvPy) -and (Test-Path $VenvPip)) {
    $null = & $VenvPip --version 2>$null
    if ($LASTEXITCODE -eq 0) { $VenvOk = $true }
}

# Detect pip 25.x / Python 3.14 installation bug (same check as run.sh)
if ($VenvOk) {
    $null = & $VenvPip show icalendar 2>$null
    if ($LASTEXITCODE -eq 0) {
        & $VenvPy -c 'from icalendar import Calendar' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  Detected broken icalendar install (pip 25.x + Python 3.14 bug). Rebuilding venv...'
            $VenvOk = $false
        }
    }
}
if ($VenvOk) {
    $null = & $VenvPip show websockets 2>$null
    if ($LASTEXITCODE -eq 0) {
        & $VenvPy -c 'import websockets.frames' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  Detected broken websockets install (pip 25.x + Python 3.14 bug). Rebuilding venv...'
            $VenvOk = $false
        }
    }
}

$NeedPlaywright = -not (Test-Path $PlaywrightCache) -or
                  (@(Get-ChildItem $PlaywrightCache -ErrorAction SilentlyContinue).Count -eq 0)

$TotalSteps = 2   # pip check + start server always happen
if (-not $VenvOk)       { $TotalSteps++ }
if ($NeedPlaywright)     { $TotalSteps++ }
$Step = 0

# ── Open startup page and start live-progress status server ───────────────────
Write-Status 'starting' 2 "Starting Butterfly Effect$([char]8230)" 0 $TotalSteps
Start-StatusServer
Start-Sleep -Milliseconds 300   # give status server a moment to bind port 5003
Open-Startup

# ── Application data directory ────────────────────────────────────────────────
$AppData = Join-Path $env:APPDATA 'Butterfly Effect'
New-Item -ItemType Directory -Path $AppData -Force -ErrorAction SilentlyContinue | Out-Null

# ── One-time migration: move existing data files to AppData ───────────────────
$MigrateFiles = @(
    'config.yaml', '.env', 'browser_state.json', 'insights.json', 'user_context.md',
    'payment_overrides.json', 'payment_skips.json', 'payment_monthly_amounts.json',
    'payment_day_overrides.json', 'scenarios.json', 'monarch_accounts_cache.json',
    'dismissed_suggestions.json'
)
foreach ($f in $MigrateFiles) {
    $src = Join-Path $ScriptDir $f
    $dst = Join-Path $AppData   $f
    if ((Test-Path $src) -and -not (Test-Path $dst)) {
        Move-Item $src $dst
        Write-Host "Migrated $f to AppData"
    }
}

# ── Bootstrap config files on first run ──────────────────────────────────────
if (-not (Test-Path (Join-Path $AppData 'config.yaml'))) {
    Write-Host 'First run: creating config.yaml...'
    Copy-Item (Join-Path $ScriptDir 'config.yaml.example') (Join-Path $AppData 'config.yaml')
}
if (-not (Test-Path (Join-Path $AppData '.env'))) {
    Write-Host 'First run: creating .env (credentials file)...'
    New-Item -ItemType File -Path (Join-Path $AppData '.env') | Out-Null
}

# ── Virtual environment ───────────────────────────────────────────────────────
if (-not $VenvOk) {
    $Step++
    Write-Status 'venv' 5 "Creating Python environment$([char]8230)" $Step $TotalSteps
    Write-Host "Creating virtual environment at $Venv ..."
    if (Test-Path $Venv) { Remove-Item $Venv -Recurse -Force }
    & $script:PYTHON -m venv $Venv
    if ($LASTEXITCODE -ne 0) {
        Open-Startup 'e=novenv&os=windows'
        Write-Host 'Error: could not create virtual environment. See the browser window for details.'
        exit 1
    }
    # Upgrade pip to avoid the pip 25.x wheel-install bug.
    # Use the venv's own python (not the system launcher) so --target isn't needed
    # and py.exe stderr noise can't trigger NativeCommandError.
    try {
        & $VenvPy -m pip install --upgrade pip --quiet 2>&1 | Out-Null
    } catch { }
    Write-Host "  pip upgraded."
}

# Activate venv for this session
$env:VIRTUAL_ENV = $Venv
$env:PATH        = (Join-Path $Venv 'Scripts') + ';' + $env:PATH
$pip             = Join-Path $Venv 'Scripts\pip.exe'
$python          = Join-Path $Venv 'Scripts\python.exe'

# ── Dependencies ──────────────────────────────────────────────────────────────
$Step++
Write-Status 'pip' 18 "Installing Python packages$([char]8230)" $Step $TotalSteps
Write-Host -NoNewline 'Checking dependencies'

$pipLog = Join-Path $env:TEMP "butterfly-pip-$PID.log"
$pipJob = Start-Job -ScriptBlock {
    param($pip, $req, $log)
    # Must set explicitly — Start-Job runspaces don't inherit the parent's preference,
    # so pip stderr notices would otherwise trigger NativeCommandError and fail the job.
    $ErrorActionPreference = 'Continue'
    & $pip install -r $req 2>&1 | Tee-Object -FilePath $log | Out-Null
    $LASTEXITCODE   # emit exit code as job output, captured by Receive-Job below
} -ArgumentList $pip, (Join-Path $ScriptDir 'requirements.txt'), $pipLog

while ($pipJob.State -eq 'Running') {
    Write-Host -NoNewline '.'
    Start-Sleep -Seconds 1
}
$pipExitCode = Receive-Job $pipJob -Wait
$pipFailed   = $pipJob.State -eq 'Failed' -or ($pipExitCode -ne 0)
Remove-Job $pipJob

if ($pipFailed) {
    Write-Host ' failed.'
    Write-Host ''
    Write-Host 'pip output:'
    Get-Content $pipLog -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
    Remove-Item $pipLog -ErrorAction SilentlyContinue
    Open-Startup 'e=pipfail&os=windows'
    Write-Host ''
    Write-Host 'Error: dependency install failed. See above and the browser window for details.'
    exit 1
}
Remove-Item $pipLog -ErrorAction SilentlyContinue
Write-Host ' done.'
Write-Status 'pip' 42 'Python packages ready' $Step $TotalSteps

# ── Playwright browser ────────────────────────────────────────────────────────
$env:PLAYWRIGHT_BROWSERS_PATH = $PlaywrightCache

if ($NeedPlaywright) {
    $Step++
    Write-Status 'playwright' 47 "Downloading Chromium browser (~250 MB)$([char]8230)" $Step $TotalSteps
    Write-Host ''
    Write-Host 'Installing Chromium browser (first time only, ~250 MB)...'

    New-Item -ItemType Directory -Path $PlaywrightCache -Force | Out-Null

    $pwLog = Join-Path $env:TEMP "butterfly-pw-$PID.log"
    '' | Set-Content $pwLog -Encoding UTF8

    $pwJob = Start-Job -ScriptBlock {
        param($python, $browsers, $log)
        # Must set explicitly — Start-Job runspaces don't inherit the parent's preference.
        # Node.js (used by playwright) writes deprecation warnings to stderr which would
        # otherwise trigger NativeCommandError and fail the job.
        $ErrorActionPreference = 'Continue'
        $env:PLAYWRIGHT_BROWSERS_PATH = $browsers
        & $python -m playwright install chromium *>&1 | Tee-Object -FilePath $log
        exit $LASTEXITCODE
    } -ArgumentList $python, $PlaywrightCache, $pwLog

    Write-Host -NoNewline '  Downloading'
    while ($pwJob.State -eq 'Running') {
        Write-Host -NoNewline '.'
        # Scan log for progress lines: "X.X MiB / Y.Y MiB"
        $prog = Select-String -Path $pwLog -Pattern '(\d+\.?\d*)\s+MiB\s*/\s*(\d+\.?\d*)\s+MiB' -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($prog) {
            $mb  = $prog.Matches[0].Groups[1].Value
            $mbt = $prog.Matches[0].Groups[2].Value
            $dp  = [int]([double]$mb * 100 / [double]$mbt)
            if ($dp -gt 100) { $dp = 100 }
            $op  = 47 + [int]($dp * 44 / 100)
            Write-Status 'playwright' $op "Downloading Chromium: $mb of $mbt MB" $Step $TotalSteps
        }
        Start-Sleep -Seconds 2
    }
    Write-Host ''

    # -ErrorAction SilentlyContinue suppresses NativeCommandError records that
    # Receive-Job would otherwise surface from Node.js stderr inside the job.
    $null = Receive-Job $pwJob -Wait -ErrorAction SilentlyContinue
    $pwExit    = if ($pwJob.State -eq 'Failed') { 1 } else { 0 }
    Remove-Job $pwJob

    Write-Host "  [playwright] install log:"
    Get-Content $pwLog -Encoding UTF8 -ErrorAction SilentlyContinue |
        Where-Object { $_ -notmatch '^\s*\|' } |
        Where-Object { $_ -notmatch '^\s*(At line:\d|\+\s+[~&]|\+\s+(CategoryInfo|FullyQualifiedErrorId))' } |
        ForEach-Object { Write-Host "    $_" }
    Remove-Item $pwLog -ErrorAction SilentlyContinue

    if ($pwExit -ne 0) {
        Write-Host ''
        Write-Host "WARNING: Chromium browser install may have failed."
        Write-Host "  The app will still start, but 'Connect to Monarch' may not work."
        Write-Host "  To retry: `$env:PLAYWRIGHT_BROWSERS_PATH='$PlaywrightCache'; python -m playwright install chromium"
    } else {
        Write-Status 'playwright_done' 93 'Browser download complete' $Step $TotalSteps
        Write-Host '  Browser install complete.'
    }
}

# ── Launch ────────────────────────────────────────────────────────────────────
$Step++
Write-Status 'starting' 96 "Starting server$([char]8230)" $Step $TotalSteps
Write-Host 'Starting Butterfly Effect at http://localhost:5002'
Stop-StatusServer   # Flask server takes over; status server no longer needed

# Force UTF-8 for all Python I/O so Unicode characters in print() statements
# (e.g. checkmarks, arrows, em-dashes in ai_daily.py and ai_advisor.py) don't
# crash with UnicodeEncodeError on Windows consoles that default to cp1252.
$env:PYTHONUTF8 = '1'

& $python (Join-Path $ScriptDir 'server.py')
