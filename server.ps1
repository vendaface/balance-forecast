# server.ps1 — Butterfly Effect server management for Windows
# Usage: .\server.ps1 [start|stop|restart|status|logs]
# Mirrors server.sh behaviour exactly.

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$Venv    = Join-Path $ScriptDir '.venv'
$PidFile = Join-Path $ScriptDir '.server.pid'
$LogFile = Join-Path $ScriptDir '.server.log'
$Port    = 5002

# ── Helpers ───────────────────────────────────────────────────────────────────

function Get-VenvPython { Join-Path $Venv 'Scripts\python.exe' }
function Get-VenvPip    { Join-Path $Venv 'Scripts\pip.exe'    }

function Ensure-Venv {
    $py  = Get-VenvPython
    $pip = Get-VenvPip
    $healthy = (Test-Path $py) -and (Test-Path $pip)
    if ($healthy) {
        & $pip --version 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $healthy = $false }
    }
    if (-not $healthy) {
        Write-Host "Virtual environment missing or corrupted — rebuilding at $Venv ..."
        if (Test-Path $Venv) { Remove-Item $Venv -Recurse -Force }
        $python = $null
        foreach ($c in @('python', 'python3', 'python3.13', 'python3.12', 'python3.11')) {
            $found = Get-Command $c -ErrorAction SilentlyContinue
            if ($found) {
                & $c -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>$null
                if ($LASTEXITCODE -eq 0) { $python = $c; break }
            }
        }
        if (-not $python) {
            Write-Host 'x Python 3.11+ not found. Install from https://python.org'
            exit 1
        }
        & $python -m venv $Venv
        & (Get-VenvPip) install -q -r (Join-Path $ScriptDir 'requirements.txt')
        Write-Host 'v Virtual environment rebuilt'
    }
}

function Is-Running {
    if (Test-Path $PidFile) {
        $pid_ = Get-Content $PidFile -ErrorAction SilentlyContinue
        if ($pid_) {
            $proc = Get-Process -Id ([int]$pid_) -ErrorAction SilentlyContinue
            if ($proc) { return $true }
        }
        Remove-Item $PidFile -ErrorAction SilentlyContinue
    }
    return $false
}

function Kill-PortProcess {
    param([int]$PortNum)
    $conns = Get-NetTCPConnection -LocalPort $PortNum -ErrorAction SilentlyContinue
    foreach ($c in $conns) {
        if ($c.OwningProcess -and $c.OwningProcess -ne 0) {
            Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
            Write-Host "v Killed process on port $PortNum (PID $($c.OwningProcess))"
        }
    }
}

# ── Commands ──────────────────────────────────────────────────────────────────

function cmd_status {
    if (Is-Running) {
        $pid_ = Get-Content $PidFile
        Write-Host "v Server is running (PID $pid_) at http://localhost:$Port"
    } else {
        Write-Host "x Server is not running"
    }
}

function cmd_start {
    if (Is-Running) {
        $pid_ = Get-Content $PidFile
        Write-Host "Server already running (PID $pid_). Use '.\server.ps1 restart' to restart."
        return
    }

    # Open startup page — JS polls /_ping and auto-redirects when Flask is ready
    $startupPath = (Join-Path $ScriptDir 'startup.html') -replace '\\', '/'
    Start-Process "file:///$startupPath"

    Ensure-Venv

    $py  = Get-VenvPython
    $pip = Get-VenvPip
    & $pip install -q -r (Join-Path $ScriptDir 'requirements.txt')

    Write-Host 'Starting Butterfly Effect...'
    $proc = Start-Process -FilePath $py `
                          -ArgumentList (Join-Path $ScriptDir 'server.py') `
                          -RedirectStandardOutput $LogFile `
                          -RedirectStandardError  $LogFile `
                          -WindowStyle Hidden `
                          -PassThru
    $proc.Id | Set-Content $PidFile
    Start-Sleep -Seconds 1

    if (Is-Running) {
        Write-Host "v Server started (PID $($proc.Id)) at http://localhost:$Port"
    } else {
        Write-Host "x Server failed to start. Check logs:"
        Get-Content $LogFile -Tail 20 -ErrorAction SilentlyContinue
        exit 1
    }
}

function cmd_stop {
    if (Is-Running) {
        $pid_ = [int](Get-Content $PidFile)
        Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue
        Remove-Item $PidFile -ErrorAction SilentlyContinue
        Write-Host "v Server stopped (PID $pid_)"
    }
    # Also kill any orphaned process on the port
    Kill-PortProcess -PortNum $Port
}

function cmd_restart {
    cmd_stop
    Start-Sleep -Seconds 1
    cmd_start
}

function cmd_logs {
    if (-not (Test-Path $LogFile)) {
        Write-Host "No log file found ($LogFile). Has the server been started?"
        exit 1
    }
    Get-Content $LogFile -Tail 50 -Wait
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
$Cmd = if ($args.Count -gt 0) { $args[0] } else { 'status' }
switch ($Cmd) {
    'start'   { cmd_start   }
    'stop'    { cmd_stop    }
    'restart' { cmd_restart }
    'status'  { cmd_status  }
    'logs'    { cmd_logs    }
    default {
        Write-Host "Usage: .\server.ps1 [start|stop|restart|status|logs]"
        exit 1
    }
}
