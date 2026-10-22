# Installs Power Meter for the current user. No admin rights needed.
# Usage: right-click install.ps1 > "Run with PowerShell"
#    or: powershell -ExecutionPolicy Bypass -File install.ps1
$ErrorActionPreference = 'Stop'
# Keep the window open on failure so the error can be read
trap {
    Write-Host "`nInstall failed: $_" -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}
$src  = Join-Path $PSScriptRoot 'src'
$dest = Join-Path $env:LOCALAPPDATA 'PowerMeter'
if (-not (Test-Path (Join-Path $src 'PowerMeter.ps1'))) {
    throw "The 'src' folder is missing next to install.ps1. Extract the whole zip first, then run install.ps1 from the extracted folder."
}

# Stop a running copy so its files can be replaced
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-WindowStyle Hidden -File "*\PowerMeter\PowerMeter.ps1"' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 500

New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $src 'PowerMeter.ps1'), (Join-Path $src 'PowerPanel.cs') $dest -Force
Get-ChildItem $dest | Unblock-File   # files from a downloaded zip are marked as "from the internet"

# Build the small launcher with the C# compiler that ships with Windows
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
& $csc /nologo /target:winexe "/out:$dest\PowerMeter.exe" /r:System.Windows.Forms.dll (Join-Path $src 'Launcher.cs')
if (-not (Test-Path "$dest\PowerMeter.exe")) { throw 'Could not build PowerMeter.exe' }

# Desktop shortcut + start with Windows
$shell = New-Object -ComObject WScript.Shell
foreach ($lnk in (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Power Meter.lnk'),
                 (Join-Path ([Environment]::GetFolderPath('Startup')) 'Power Meter.lnk')) {
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = "$dest\PowerMeter.exe"
    $s.WorkingDirectory = $dest
    $s.IconLocation = "$env:WINDIR\System32\powercpl.dll,0"
    $s.Description = 'Battery power meter'
    $s.Save()
}

Start-Process "$dest\PowerMeter.exe"
Write-Host "Power Meter installed to $dest and started. Look for the watt number next to the clock." -ForegroundColor Green
Read-Host 'Press Enter to close'
