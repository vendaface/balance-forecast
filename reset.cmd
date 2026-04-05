@echo off
:: Butterfly Effect — Windows reset / repair launcher
:: Double-click this file or run it from cmd.exe to wipe runtime files and the virtual
:: environment, simulating a fresh install.  Mirrors reset-for-testing.sh on Mac/Linux.
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0reset-for-testing.ps1" %*
