@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo.
echo ========================================
echo  Android Wi-Fi debugging setup (ADB)
echo ========================================
echo.
echo [IMPORTANT] Two different addresses:
echo   PC IP (for run_android.bat API):  e.g. 172.30.1.93:8000
echo   PHONE IP (for adb pair/connect):  shown ON THE PHONE screen
echo.
echo Phone and PC must be on the SAME Wi-Fi.
echo.

where adb >nul 2>&1
if errorlevel 1 (
  echo ERROR: adb not found. Add Android SDK platform-tools to PATH.
  pause
  exit /b 1
)

adb kill-server
adb start-server

echo ========================================
echo  STEP 1: Pairing code (first time only)
echo ========================================
echo.
echo On your PHONE:
echo   Settings ^> Developer options ^> Wireless debugging ^> ON
echo   Tap "Pair device with pairing code" (or "Pair with pairing code")
echo.
echo The PHONE screen shows THREE things — copy from the PHONE:
echo   - Wi-Fi pairing code  ....... 6-digit number (e.g. 070812)
echo   - IP address ^& port ......... e.g. 172.30.1.47:37123
echo     ^(NOT your PC IP 172.30.1.93 — use the phone's IP^)
echo.
set /p PAIR_ADDR=Phone pairing IP:port (must include :port): 
echo %PAIR_ADDR% | findstr /R ":[0-9][0-9]*" >nul
if errorlevel 1 (
  echo.
  echo ERROR: You must enter IP:port together, e.g. 172.30.1.47:37123
  echo You entered: %PAIR_ADDR%
  echo 172.30.1.93 alone is your PC — that is wrong for adb pair.
  pause
  exit /b 1
)
set /p PAIR_CODE=6-digit pairing code from PHONE screen: 
adb pair %PAIR_ADDR% %PAIR_CODE%
if errorlevel 1 (
  echo.
  echo Pairing failed.
  echo - Code expires in ~1 minute — open pairing screen again for a new code
  echo - Use IP:port from PHONE, not PC (172.30.1.93)
  echo - Phone and PC on same Wi-Fi
  pause
  exit /b 1
)

echo.
echo ========================================
echo  STEP 2: Connect
echo ========================================
echo.
echo Go BACK to the main "Wireless debugging" screen on the phone.
echo At the top it shows "IP address ^& port" — use THAT (different port from step 1).
echo Example: 172.30.1.47:5555
echo.
set /p CONNECT_ADDR=Phone debug IP:port from main screen: 
echo %CONNECT_ADDR% | findstr /R ":[0-9][0-9]*" >nul
if errorlevel 1 (
  echo ERROR: Enter IP:port, e.g. 172.30.1.47:5555
  pause
  exit /b 1
)
adb connect %CONNECT_ADDR%
if errorlevel 1 (
  echo Connect failed.
  pause
  exit /b 1
)

echo.
echo ========================================
echo  STEP 3: Verify
echo ========================================
adb devices
echo.
echo If you see your phone as "device", run (note the space before http):
echo   run_android.bat http://172.30.1.93:8000
echo   ^(172.30.1.93 = your PC IP from ipconfig — for the app API only^)
echo.
pause
