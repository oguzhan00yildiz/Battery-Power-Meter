# Removes Power Meter: stops it, deletes its shortcuts and its folder.
# Usage: double-click uninstall.cmd
$dest = Join-Path $env:LOCALAPPDATA 'PowerMeter'

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-WindowStyle Hidden -File "*\PowerMeter\PowerMeter.ps1"' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 500

Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Power Meter.lnk'),
            (Join-Path ([Environment]::GetFolderPath('Startup')) 'Power Meter.lnk') -ErrorAction SilentlyContinue
Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Power Meter removed.' -ForegroundColor Green
