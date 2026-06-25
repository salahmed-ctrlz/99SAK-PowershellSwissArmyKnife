@echo off
title 99SAK v2.0 - PowerShell Swiss Army Knife
mode con: cols=120 lines=40

:: Elevation check via fltMC (reliable across all Windows 10/11 SKUs and domain configs)
fltMC.exe >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo   Requesting Administrator privileges...
    PowerShell -Command "Start-Process -FilePath '%~f0' -Verb RunAs" 2>nul
    if %errorlevel% neq 0 (
        echo   Auto-elevation failed. Please right-click this file and select "Run as administrator".
        pause
    )
    exit /b
)

:: Launch main script
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp099SAK.ps1"

:: Keep window open on exit so errors are visible
echo.
echo   Session ended. Press any key to close.
pause >nul
