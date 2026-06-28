@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo.
echo [run_windows] mobile folder: %CD%
echo.

where flutter >nul 2>&1
if errorlevel 1 (
  echo ERROR: flutter command not found in PATH.
  echo Install Flutter SDK and reopen the terminal.
  pause
  exit /b 1
)

where powershell >nul 2>&1
if errorlevel 1 (
  echo ERROR: powershell.exe not found in PATH.
  echo Add this folder to PATH, then reopen the terminal:
  echo   C:\Windows\System32\WindowsPowerShell\v1.0
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_windows.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  echo.
  echo [run_windows] Failed with exit code %EXITCODE%
  pause
)
exit /b %EXITCODE%
