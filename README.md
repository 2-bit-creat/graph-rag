# MyLife English — GraphRAG Language Platform

Flutter (mobile/web) + FastAPI backend. Personalized daily English learning from Korean voice journals.

## Structure

```
Graph-RAG/
├── backend/     # FastAPI, GraphRAG, Whisper, pgvector
├── mobile/      # Flutter app (iOS, Android, Web, Windows)
└── docker-compose.yml
```

> **Note:** The old `frontend/` (Next.js) folder was removed. Use `mobile/` only.

## Quick start

```powershell
# 1. Infrastructure
docker compose up -d postgres redis worker

# 2. Backend
cd backend
py -3.12 -m pip install -r requirements.txt
py -3.12 -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

# 3. Flutter (from repo root — NOT frontend)
cd mobile
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

**Device-specific API URL:**

| Target | `API_BASE_URL` |
|--------|----------------|
| Chrome / Windows (local) | `http://localhost:8000` |
| Android emulator | `http://10.0.2.2:8000` |
| Physical phone (same Wi‑Fi) | `http://<your-pc-ip>:8000` |

**Wireless debugging on a physical phone:**

```powershell
# Find your PC Wi-Fi IPv4
ipconfig

# Backend must bind 0.0.0.0 (see command above)

# Flutter — replace with your LAN IP
cd mobile
flutter run --dart-define=API_BASE_URL=http://192.168.x.x:8000
```

Quiz audio streams from `http://<pc-ip>:8000/static/audio/{quiz_id}.mp3` after generation.

**Windows desktop (VS 2019):** use the launcher script (includes CMake patch):

```cmd
cd mobile
run_windows.bat
```

If you use **PowerShell**, `.\run_windows.ps1` also works.

> **Note:** In **cmd.exe**, `.\run_windows.ps1` does **not** run — use `run_windows.bat` instead.
> If Flutter says `PowerShell executable not found`, close the terminal and reopen it
> (or add `C:\Windows\System32\WindowsPowerShell\v1.0` to PATH).

**Physical Android (Wi‑Fi):** install Android SDK, enable USB/wireless debugging, then:

```cmd
cd mobile
setup_android_wifi.bat
run_android.bat http://192.168.x.x:8000
```

`setup_android_wifi.bat` pairs/connects ADB over Wi‑Fi (one-time after reboot).  
`run_android.bat` URL is your **PC** IP for the app API — not the phone's wireless-debugging port.

Android manifest allows HTTP to your PC (`usesCleartextTraffic` + network security config).

Set `OPENAI_API_KEY` in `backend/.env`.
