@echo off
rem QuickDeploy launcher - runs the tool elevated in an STA Windows PowerShell 5.1 session
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0QuickDeploy.ps1" %*
