@echo off
rem Puts the original "New Zombie" announcer back, from the backup made when it was muted.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0MuteNewZombie.ps1" -Restore %*
echo.
pause
