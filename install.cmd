@echo off
if not exist "%~dp0src\install.ps1" (
    echo The src folder is missing. Extract the whole zip first, then run install.cmd from the extracted folder.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\install.ps1"
pause
