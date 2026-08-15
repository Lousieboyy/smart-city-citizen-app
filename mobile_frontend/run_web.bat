@echo off
cd /d "%~dp0"
"C:\Users\User\OneDrive\Desktop\APP\flutter\flutter\bin\flutter.bat" run -d web-server --web-port 5001 --web-hostname 127.0.0.1 --dart-define=BASE_URL=http://127.0.0.1:8000
