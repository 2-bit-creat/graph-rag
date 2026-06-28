# MyLife English — Flutter App

GraphRAG-based personalized daily English learning client.

## Setup

```powershell
cd mobile
flutter pub get
```

First time only (if platform folders missing):

```powershell
flutter create . --platforms=web,windows,android,ios
```

## Run

```powershell
# Web (Chrome) — recommended on Windows without an emulator
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000

# Windows desktop
flutter run -d windows --dart-define=API_BASE_URL=http://localhost:8000

# Android emulator
flutter run -d android --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

There is **no** `frontend/` folder — this `mobile/` app is the only client.
