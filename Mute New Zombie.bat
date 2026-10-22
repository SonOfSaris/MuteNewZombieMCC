@echo off
rem Mutes the "New Zombie" announcer in Halo 3 (MCC). Drag the game folder onto this file if it isn't found.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MuteNewZombie.ps1" %*
echo.
pause
