@echo off
rem ============================================================
rem  PhotoSorter - Step 1: dedupe INSIDE the inbox
rem  same content keeps 1 copy, the rest go to  duplicates\
rem ============================================================
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\Dedupe.ps1" -Scope Inbox %*
echo.
pause
