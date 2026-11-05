@echo off
rem ============================================================
rem  PhotoSorter - Step 2: classify inbox into the library
rem  COPY mode: source files stay in the inbox
rem ============================================================
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\Classify.ps1" %*
echo.
pause
