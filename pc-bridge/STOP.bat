@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f='%~dp0logs\pids.json'; if (Test-Path $f) { $p = Get-Content $f -Raw | ConvertFrom-Json; foreach ($i in @($p.server, $p.ngrok)) { if ($i) { Stop-Process -Id $i -Force -ErrorAction SilentlyContinue } }; Remove-Item $f -Force; Write-Host 'PC Bridge stopped.' } else { Write-Host 'PC Bridge is not running.' }"
pause
