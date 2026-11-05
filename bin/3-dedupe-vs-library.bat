@echo off
rem ============================================================
rem  PhotoSorter - Step 3: dedupe inbox AGAINST the library
rem  library wins; duplicates go to  duplicates\
rem ============================================================
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\Dedupe.ps1" -Scope Library %*
echo.
pause
