@echo off
setlocal EnableExtensions
cd /d "%~dp0"

if "%~1"=="" (
  echo.
  echo Usage:
  echo   run_android.bat http://172.30.1.93:8000
  echo   ^^^^^^^^^^^^^ space here ^^^^^^^^^^^^^
  echo.
  echo Wrong:  run_android.bathttp://172.30.1.93:8000
  echo.
  echo Before running:
  echo   adb devices   ^(must show your phone as "device"^)
  echo   backend:      cd ..\backend ^& run_server.bat
  echo.
  pause
  exit /b 1
)

where flutter >nul 2>&1
if errorlevel 1 (
  echo ERROR: flutter command not found in PATH.
  pause
  exit /b 1
)

where adb >nul 2>&1
if errorlevel 1 (
  echo ERROR: adb not found. Add Android SDK platform-tools to PATH.
  pause
  exit /b 1
)

adb start-server >nul 2>&1
adb devices | findstr /R /C:"device" | findstr /V /C:"List of devices" >nul
if errorlevel 1 (
  echo.
  echo [run_android] No phone connected via adb.
  echo.
  echo   1. USB: plug in cable, unlock phone, allow USB debugging
  echo   2. Wi-Fi: setup_android_wifi.bat
  echo   3. Check:  adb devices
  echo      Example:  R5GL206FBNK    device
  echo.
  pause
  exit /b 1
)

where powershell >nul 2>&1
if errorlevel 1 (
  echo ERROR: powershell.exe not found in PATH.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_android.ps1" -ApiBaseUrl "%~1"
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" pause
exit /b %EXITCODE%
