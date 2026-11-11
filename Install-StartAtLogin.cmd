@echo off
rem Copies the script to your user folder, starts it hidden at every sign-in, and adds a Start menu entry.
echo Stopping any copy that is already running...
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*ControllerBatteryWarning.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
timeout /t 2 /nobreak >nul
set "DEST=%LOCALAPPDATA%\ControllerBatteryWarning"
mkdir "%DEST%" 2>nul
copy /y "%~dp0ControllerBatteryWarning.ps1" "%DEST%\" >nul
rem Gamepad icon for the shortcuts: white for dark mode, black for light mode
set "ICON=gamepad_dark.ico"
for /f "tokens=3" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v SystemUsesLightTheme 2^>nul ^| find "0x"') do if "%%a"=="0x1" set "ICON=gamepad_light.ico"
copy /y "%~dp0%ICON%" "%DEST%\gamepad.ico" >nul
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Startup')+'\Controller Battery Warning.lnk'); $s.TargetPath='conhost.exe'; $s.Arguments='--headless powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%DEST%\ControllerBatteryWarning.ps1\" -AtSignIn'; $s.WorkingDirectory='%DEST%'; $s.IconLocation='%DEST%\gamepad.ico,0'; $s.Save()"
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Programs')+'\Controller Battery Warning.lnk'); $s.TargetPath='conhost.exe'; $s.Arguments='--headless powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%DEST%\ControllerBatteryWarning.ps1\"'; $s.WorkingDirectory='%DEST%'; $s.IconLocation='%DEST%\gamepad.ico,0'; $s.Save()"
cd /d "%DEST%"
start "" /D "%DEST%" conhost.exe --headless powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%DEST%\ControllerBatteryWarning.ps1"
echo Installed. It is running now, starts at every sign-in, and is in the Start menu as "Controller Battery Warning".
echo To remove: delete "Controller Battery Warning" from shell:startup and shell:programs, and the folder %DEST%
pause
