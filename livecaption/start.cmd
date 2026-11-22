@echo off
setlocal
cd /d "%~dp0"
set "VENV=..\.local\live-runtime"
if not exist "%VENV%\Scripts\python.exe" (
    py -3.12 -m venv "%VENV%"
    if errorlevel 1 goto fail
)
fc /b requirements.txt "%VENV%\installed-requirements.txt" >nul 2>nul
if errorlevel 1 (
    "%VENV%\Scripts\python.exe" -m pip install --disable-pip-version-check --only-binary=:all: -r requirements.txt
    if errorlevel 1 goto fail
    copy /y requirements.txt "%VENV%\installed-requirements.txt" >nul
)
"%VENV%\Scripts\python.exe" -B app.py
if errorlevel 1 goto fail
exit /b 0
:fail
echo Could not start live captions. Windows x64 and Python 3.12 with Tk are required.
pause
exit /b 1
