# reset-for-testing.ps1 -- wipes all runtime files to simulate a fresh clone
# DO NOT run this on a live installation you care about.
# Mirrors reset-for-testing.sh behaviour exactly.
#
# NOTE: This file intentionally uses only ASCII characters.
# PowerShell 5.1 reads .ps1 files as Windows-1252 when no BOM is present;
# UTF-8 multi-byte sequences (em-dash, box-drawing chars, etc.) can contain
# byte 0x94 which Windows-1252 maps to a curly double-quote -- a valid PS
# string delimiter -- causing silent parse failures.

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'   # be forgiving - deletion is best-effort

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# -- Resolve APP_DATA_DIR (mirrors paths.py logic) ----------------------------
$AppDataDir      = Join-Path $env:APPDATA 'Butterfly Effect'
$PlaywrightCache = Join-Path $env:USERPROFILE '.cache\butterfly-effect\playwright'

# -- Quick browser-only reset -------------------------------------------------
if ($args.Count -gt 0 -and $args[0] -eq '--browser-only') {
    if (Test-Path $PlaywrightCache) {
        Remove-Item $PlaywrightCache -Recurse -Force
        Write-Host "Deleted Playwright cache: $PlaywrightCache"
        Write-Host "Chromium will re-download (~250 MB) on next launch or Connect to Monarch."
    } else {
        Write-Host "Playwright cache not found - already clean."
    }
    exit 0
}

Write-Host "This will kill the running server and delete all runtime files and the virtual environment."
Write-Host ""
Write-Host "  App data dir : $AppDataDir"
Write-Host "  Project dir  : $ScriptDir"
Write-Host ""
Write-Host "Use this only for testing a fresh install simulation."
Write-Host ""
$delBrowser = Read-Host "Also delete the Playwright Chromium browser cache (~250 MB re-download)? (yes/no)"
Write-Host ""
$confirm = Read-Host "Are you sure you want to reset everything? (yes/no)"
if ($confirm -ne 'yes') {
    Write-Host "Aborted."
    exit 0
}

Write-Host ""

# -- Kill running server ------------------------------------------------------
$PidFile = Join-Path $ScriptDir '.server.pid'
if (Test-Path $PidFile) {
    $pid_ = Get-Content $PidFile -ErrorAction SilentlyContinue
    if ($pid_) {
        $proc = Get-Process -Id ([int]$pid_) -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "  killing server (pid $pid_)..."
            Stop-Process -Id ([int]$pid_) -Force
            Start-Sleep -Seconds 1
        }
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

# Kill by port as well (covers run.ps1 and bundled app invocations)
$conns = Get-NetTCPConnection -LocalPort 5002 -ErrorAction SilentlyContinue
foreach ($c in $conns) {
    if ($c.OwningProcess -and $c.OwningProcess -ne 0) {
        Write-Host "  killing process on port 5002 (pid $($c.OwningProcess))..."
        Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}

# -- Delete runtime files from APP_DATA_DIR -----------------------------------
Write-Host "  deleting runtime files from: $AppDataDir"

$AppDataFiles = @(
    '.env', 'config.yaml', 'browser_state.json', 'insights.json',
    'payment_overrides.json', 'payment_monthly_amounts.json',
    'payment_skips.json', 'payment_day_overrides.json', 'scenarios.json',
    'dismissed_suggestions.json', 'monarch_accounts_cache.json',
    'monarch_raw_cache.json', 'user_context.md'
)

foreach ($f in $AppDataFiles) {
    $target = Join-Path $AppDataDir $f
    if (Test-Path $target) {
        Remove-Item $target -Force
        Write-Host "    deleted: $target"
    }
}

# -- Delete leftover runtime files from project dir (pre-migration remnants) --
Write-Host "  checking project dir for pre-migration remnants..."

$ProjectFiles = @(
    '.env', 'config.yaml', 'browser_state.json', 'insights.json',
    'payment_overrides.json', 'payment_monthly_amounts.json',
    'payment_skips.json', 'payment_day_overrides.json', 'scenarios.json',
    'dismissed_suggestions.json', 'monarch_accounts_cache.json',
    'monarch_raw_cache.json', 'user_context.md',
    '.server.pid', '.server.log'
)

foreach ($f in $ProjectFiles) {
    $target = Join-Path $ScriptDir $f
    if (Test-Path $target) {
        Remove-Item $target -Force
        Write-Host "    deleted (legacy): $target"
    }
}

# -- Delete Playwright browser cache (optional) -------------------------------
if ($delBrowser -eq 'yes') {
    if (Test-Path $PlaywrightCache) {
        Remove-Item $PlaywrightCache -Recurse -Force
        Write-Host "  deleted Playwright cache: $PlaywrightCache"
    } else {
        Write-Host "  Playwright cache not found (already clean)"
    }
} else {
    Write-Host "  skipping Playwright cache (will reuse existing browser)"
}

# -- __pycache__ directories --------------------------------------------------
Get-ChildItem $ScriptDir -Recurse -Directory -Filter '__pycache__' | ForEach-Object {
    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "    deleted: $($_.FullName)"
}

# -- Virtual environment ------------------------------------------------------
$Venv = Join-Path $ScriptDir '.venv'
if (Test-Path $Venv) {
    # Ensure all files are writable before removal (mirrors chmod -R u+w in run.sh)
    Get-ChildItem $Venv -Recurse -File | ForEach-Object {
        $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
    }
    Remove-Item $Venv -Recurse -Force
    Write-Host "  deleted: $Venv"
}

Write-Host ""
Write-Host "Done. Run 'Start Butterfly Effect - Windows.cmd' to test a fresh install."
