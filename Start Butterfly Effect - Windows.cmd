@echo off
:: Butterfly Effect -- Windows launcher
:: Double-click this file or run it from cmd.exe to start the app.
::
:: chcp 65001 sets the console to UTF-8 (code page 65001) so that Unicode
:: characters written by PowerShell and subprocesses (block chars, ellipsis,
:: box-drawing lines, etc.) render correctly instead of showing as Gua garbage.
chcp 65001 > nul
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0run.ps1" %*
