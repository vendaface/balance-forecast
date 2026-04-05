@echo off
:: Butterfly Effect — Windows launcher
:: Double-click this file or run it from cmd.exe to start the app.
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0run.ps1" %*
