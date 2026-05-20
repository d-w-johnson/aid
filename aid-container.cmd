@echo off
REM Double-clickable Windows entry point for AID Container Manager.
REM Prefers PowerShell 7 (pwsh) when available, falls back to Windows PowerShell 5.x.
REM ExecutionPolicy is bypassed for this invocation only — machine policy is unchanged.

where pwsh >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    pwsh -ExecutionPolicy Bypass -NoProfile -File "%~dp0aid-container.ps1" %*
) else (
    powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0aid-container.ps1" %*
)

REM Pause only when launched without args (likely double-clicked from Explorer)
REM so the console window doesn't close before the user sees the final output.
if "%~1"=="" pause
