@echo off
cd /d "%~dp0"
echo.
echo [backend] Starting API at http://0.0.0.0:8000
echo [backend] Phone app should use http://YOUR_PC_IP:8000
echo.
py -3.12 -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
