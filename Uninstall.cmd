@echo off
rem Removes Controller Battery Warning: stops it, deletes its shortcuts and its folder.
echo Stopping Controller Battery Warning...
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*ControllerBatteryWarning.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
timeout /t 2 /nobreak >nul
del /f /q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Controller Battery Warning.lnk" 2>nul
del /f /q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Controller Battery Warning.lnk" 2>nul
rmdir /s /q "%LOCALAPPDATA%\ControllerBatteryWarning" 2>nul
echo Uninstalled.
pause
