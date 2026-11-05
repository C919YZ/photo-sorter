@echo off
rem ============================================================
rem  PhotoSorter - main menu
rem  double-click this file if you do not want to type commands
rem ============================================================
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\Menu.ps1" %*
echo.
pause
