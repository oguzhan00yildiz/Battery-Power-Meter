# Tray icon showing live battery power draw (watts)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Name Native -Namespace W -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr h); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[W.Native]::SetProcessDPIAware() | Out-Null   # sharp text on high-DPI screens; must happen before any window exists
Add-Type -TypeDefinition (Get-Content (Join-Path $PSScriptRoot 'PowerPanel.cs') -Raw -Encoding UTF8) -ReferencedAssemblies System.Windows.Forms, System.Drawing

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\PowerMeterTray', [ref]$created)
if (-not $created) { exit }

$tray = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $menu.Items.Add('Exit', $null, { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$tray.ContextMenuStrip = $menu
$script:hIcon = [IntPtr]::Zero
$script:family = try { New-Object System.Drawing.FontFamily 'Bahnschrift SemiBold Condensed' } catch { New-Object System.Drawing.FontFamily 'Segoe UI' }

function Set-TrayIcon([string]$text, [System.Drawing.Color]$color) {
    # Number plus a smaller "W" in a condensed font, stretched to fill the whole icon edge to edge
    $S = 64
    $bmp = New-Object System.Drawing.Bitmap $S, $S
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $sf = [System.Drawing.StringFormat]::GenericTypographic
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddString($text, $script:family, [int][System.Drawing.FontStyle]::Bold, 100, (New-Object System.Drawing.PointF 0, 0), $sf)
    if ($text -match '\d') {
        # smaller W, bottom-aligned with the digits
        $nb = $path.GetBounds()
        $wb = New-Object System.Drawing.Drawing2D.GraphicsPath
        $wb.AddString('W', $script:family, [int][System.Drawing.FontStyle]::Bold, 68, (New-Object System.Drawing.PointF 0, 0), $sf)
        $wy = $nb.Bottom - $wb.GetBounds().Bottom
        $wb.Dispose()
        $path.AddString('W', $script:family, [int][System.Drawing.FontStyle]::Bold, 68, (New-Object System.Drawing.PointF ($nb.Right + 4), $wy), $sf)
    }
    $b = $path.GetBounds()
    $m = New-Object System.Drawing.Drawing2D.Matrix
    $sy = ($S - 2) / $b.Height
    $sx = [math]::Min(($S - 2) / $b.Width, $sy * 1.15)
    $m.Translate(($S - $b.Width * $sx) / 2, 1)
    $m.Scale($sx, $sy)
    $m.Translate(-$b.X, -$b.Y)
    $path.Transform($m)
    $g.FillPath((New-Object System.Drawing.SolidBrush $color), $path)
    $path.Dispose(); $g.Dispose()
    $h = $bmp.GetHicon(); $bmp.Dispose()
    $tray.Icon = [System.Drawing.Icon]::FromHandle($h)
    if ($script:hIcon -ne [IntPtr]::Zero) { [W.Native]::DestroyIcon($script:hIcon) | Out-Null }
    $script:hIcon = $h
}

# Background sampler: per-app activity (CPU % + weighted GPU %) every few seconds, off the UI thread
$shared = [hashtable]::Synchronized(@{ Top = @(); Total = 0; Cpu = $null; Gpu = 0; Ready = $false })
# "Rest of laptop" power (screen, RAM, SSD, Wi-Fi...) = battery draw - CPU - GPU, learned on battery, used on AC
$restFile = Join-Path $PSScriptRoot 'rest-watts.txt'
$script:rest = try { [double](Get-Content $restFile -ErrorAction Stop) } catch { 5.0 }
$script:restSaved = Get-Date
$script:drawHistory = New-Object 'System.Collections.Generic.List[object]'
$script:chargeHistory = New-Object 'System.Collections.Generic.List[object]'
$script:fullCapacity = try { [double](Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity } catch { 0 }
$sampler = [PowerShell]::Create()
$null = $sampler.AddScript({
    param($shared)
    $n = [Environment]::ProcessorCount
    $prev = @{}; $t0 = Get-Date
    $gpuCat = try { New-Object System.Diagnostics.PerformanceCounterCategory 'GPU Engine' } catch { $null }
    $gpuPrev = @{}
    # Intel RAPL sensor: measured CPU package power (CPU + Intel graphics), works on AC too
    $emCat = try { New-Object System.Diagnostics.PerformanceCounterCategory 'Energy Meter' } catch { $null }
    $emPrev = $null
    $nvId = (Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue | Where-Object FriendlyName -like '*NVIDIA*' | Select-Object -First 1).InstanceId
    $nvSmi = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
    $nvAwake = $false; $iter = 0
    $errLog = Join-Path $env:LOCALAPPDATA 'PowerMeter\sampler-errors.log'
    while ($true) {
      Start-Sleep -Seconds $(if ($iter -eq 0) { 1 } else { 5 })   # first round only sets the baseline
      $iter++
      try {
        $now = Get-Date; $dt = ($now - $t0).TotalSeconds; $t0 = $now
        $cur = @{}; $act = @{}; $names = @{}
        foreach ($p in Get-Process) {
            if ($p.Id -eq 0) { continue }
            try { $c = $p.TotalProcessorTime.TotalSeconds } catch { continue }
            $cur[$p.Id] = $c; $names[$p.Id] = $p.ProcessName
            if ($prev.ContainsKey($p.Id)) { $act[$p.ProcessName] += 100 * ($c - $prev[$p.Id]) / ($dt * $n) }
        }
        $prev = $cur
        # GPU busy % per engine = delta of busy time / delta of wall time (both in 100 ns units)
        $gpuCur = @{}
        if ($gpuCat) {
            try {
                foreach ($e in $gpuCat.ReadCategory()['Utilization Percentage'].Values) {
                    $smp = $e.Sample; $gpuCur[$e.InstanceName] = $smp
                    $old = $gpuPrev[$e.InstanceName]
                    if ($old -and $smp.RawValue -gt $old.RawValue -and $e.InstanceName -match '^pid_(\d+)_') {
                        $nm = $names[[int]$matches[1]]
                        $pctGpu = 100 * ($smp.RawValue - $old.RawValue) / [math]::Max(1, $smp.TimeStamp100nSec - $old.TimeStamp100nSec)
                        if ($nm) { $act[$nm] += 0.5 * [math]::Min(100, $pctGpu) }
                    }
                }
            } catch {}
        }
        $gpuPrev = $gpuCur
        if ($emCat) {
            try {
                $emCur = $emCat.ReadCategory()['Power']['RAPL_Package0_PKG'].Sample
                if ($emPrev) { $shared.Cpu = [Diagnostics.CounterSample]::Calculate($emPrev, $emCur) / 1000 }  # mW -> W
                $emPrev = $emCur
            } catch {}
        }
        # NVIDIA card: only ask for its power when it is already awake (D0), so we never wake it up.
        # Checking its power state is slow (~1 s), so do that every 30 s rather than every round.
        if ($nvId -and $nvSmi) {
            if ($iter % 6 -eq 1) {
                try { $nvAwake = (Get-PnpDeviceProperty -InstanceId $nvId -KeyName DEVPKEY_Device_PowerData -ErrorAction Stop).Data[4] -eq 1 } catch { $nvAwake = $false }
            }
            $shared.Gpu = if ($nvAwake) { try { [double](& $nvSmi --query-gpu=power.draw --format=csv,noheader,nounits | Select-Object -First 1) } catch { 0 } } else { 0 }
        }
        $shared.Total = ($act.Values | Measure-Object -Sum).Sum
        # Even on an idle laptop list the busiest apps; only skip ones doing essentially nothing
        $shared.Top = @($act.GetEnumerator() | Where-Object Value -gt 0.02 | Sort-Object Value -Descending | Select-Object -First 4 |
            ForEach-Object { [pscustomobject]@{ Name = $_.Key; Act = $_.Value } })
        if ($iter -ge 2) { $shared.Ready = $true }
      } catch {
        # Never let one bad round stop the sampler; keep a short log of what went wrong
        try { Add-Content $errLog ("{0:yyyy-MM-dd HH:mm:ss}  {1}  (line {2})" -f (Get-Date), $_, $_.InvocationInfo.ScriptLineNumber) } catch {}
      }
    }
}).AddArgument($shared)
$null = $sampler.BeginInvoke()

$script:appInfo = @{}
$friendly = @{
    dwm = 'Windows display (dwm)'; System = 'Windows system'; svchost = 'Windows services'; MsMpEng = 'Microsoft Defender'
    explorer = 'File Explorer & taskbar'; SearchHost = 'Windows Search'; audiodg = 'Windows audio'; csrss = 'Windows (csrss)'
    WmiPrvSE = 'Windows management (WMI)'; Registry = 'Windows registry'; MemCompression = 'Windows memory compression'
}

function Get-AppInfo([string]$proc) {
    # Friendly name + icon for a process name, looked up once and cached
    if ($script:appInfo.ContainsKey($proc)) { return $script:appInfo[$proc] }
    $info = [pscustomobject]@{ Name = $proc; Icon = $null }
    if ($friendly.ContainsKey($proc)) { $info.Name = $friendly[$proc] }
    $path = (Get-Process -Name $proc -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1).Path
    if ($path) {
        try { $info.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($path) } catch {}
        if (-not $friendly.ContainsKey($proc)) {
            $desc = try { [Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileDescription } catch { $null }
            if ($desc -and $desc.Trim().Length -le 40) { $info.Name = $desc.Trim() }
        }
    }
    $script:appInfo[$proc] = $info
    $info
}

function Get-AppRows([double]$w) {
    # Apps share the measured CPU + GPU power by their share of activity; everything else is screen/system
    $rows = New-Object 'System.Collections.Generic.List[PM.AppRow]'
    $top = @($shared.Top); $total = [double]$shared.Total
    if (-not $top -or $total -le 0) {
        # Nothing busy: once the sampler has run, everything is screen & system rather than "collecting data"
        if ($shared.Ready) { $r = New-Object PM.AppRow; $r.Name = 'Screen & system'; $r.Glyph = [string][char]0xE7F4; $r.Watts = $w; $rows.Add($r) }
        return ,$rows
    }
    $appW = if ($null -ne $shared.Cpu) { [math]::Min($w, $shared.Cpu + [double]$shared.Gpu) } else { [math]::Max(0, $w - $script:rest) }
    # Skip apps whose share rounds to 0.0 W; their bit counts toward screen & system
    $shown = @($top | Select-Object -First 4 | Where-Object { $appW * $_.Act / $total -ge 0.05 })
    foreach ($a in $shown) {
        $info = Get-AppInfo $a.Name
        $r = New-Object PM.AppRow; $r.Name = $info.Name; $r.Icon = $info.Icon; $r.Watts = $appW * $a.Act / $total
        $rows.Add($r)
    }
    $r = New-Object PM.AppRow; $r.Name = 'Screen & system'; $r.Glyph = [string][char]0xE7F4
    $r.Watts = $w - $appW * (($shown | Measure-Object Act -Sum).Sum) / $total
    $rows.Add($r)
    ,$rows
}

function Format-Duration([double]$hours) {
    $m = [int]($hours * 60)
    "{0}h{1:D2}m" -f [int][math]::Floor($m / 60), ($m % 60)
}

function Get-Average($history, [double]$value) {
    # Rolling 3-minute average, so time estimates don't jump around
    $now = Get-Date
    $history.Add([pscustomobject]@{ T = $now; W = $value })
    $history.RemoveAll({ param($x) ($now - $x.T).TotalSeconds -gt 180 }) | Out-Null
    ($history | Measure-Object W -Average).Average
}

function Update-Meter {
    try {
        $s = Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1
        $pct = (Get-CimInstance Win32_Battery | Select-Object -First 1).EstimatedChargeRemaining
        $cpu = $shared.Cpu; $gpu = [double]$shared.Gpu
        $remWh = $s.RemainingCapacity / 1000; $fullWh = $script:fullCapacity / 1000
        $d = New-Object PM.PanelData
        $d.Percent = [double]$pct; $d.PluggedIn = [bool]$s.PowerOnline
        $d.CapacityText = "{0:N1} / {1:N1} Wh" -f $remWh, $fullWh
        $d.Footer = "CPU {0}  ·  NVIDIA {1}  ·  app values are estimates" -f $(if ($null -ne $cpu) { '{0:N1} W' -f $cpu } else { '...' }), $(if ($gpu -gt 0) { '{0:N1} W' -f $gpu } else { 'off' })
        if ($s.PowerOnline) {
            $script:drawHistory.Clear()
            # On AC the battery can't see what the laptop uses, so estimate: measured CPU + GPU + learned rest
            if ($null -eq $cpu) {
                # No CPU power sensor yet (or none at all, e.g. on AMD): show charging info only
                Set-TrayIcon '..' ([System.Drawing.Color]::Gray)
                $d.WattsText = $(if ($shared.Ready) { 'Plugged in' } else { 'Measuring...' })
                $d.Status = $(if ($s.ChargeRate -gt 0) { "Charging +{0:N0} W" -f ($s.ChargeRate / 1000) } else { 'Not charging' })
                $d.TimeText = $(if ($s.ChargeRate -gt 0) { "Full in {0}" -f (Format-Duration ([math]::Max(0, $fullWh - $remWh) / (Get-Average $script:chargeHistory ($s.ChargeRate / 1000)))) } else { 'Usage needs a CPU power sensor while plugged in' })
                $d.Charging = $s.ChargeRate -gt 0
                Show-Data $d; return
            }
            $w = $cpu + $gpu + $script:rest
            $d.WattsText = "~{0:N1} W" -f $w
            if ($s.ChargeRate -gt 0) {
                $d.Charging = $true
                $avgChg = Get-Average $script:chargeHistory ($s.ChargeRate / 1000)
                $d.Status = "Plugged in  ·  charging +{0:N0} W" -f ($s.ChargeRate / 1000)
                $d.TimeText = "Full in {0}" -f (Format-Duration ([math]::Max(0, $fullWh - $remWh) / $avgChg))
            } else {
                $script:chargeHistory.Clear()
                $full = $pct -ge 95
                $d.Status = 'Plugged in  ·  ' + $(if ($full) { 'fully charged' } else { 'not charging' })
                $d.TimeText = $(if ($full) { 'Battery is full' } else { 'Not charging right now' })
            }
        } else {
            $script:chargeHistory.Clear()
            $w = $s.DischargeRate / 1000
            if ($null -ne $cpu -and $w -gt 0) {
                $script:rest = [math]::Min(12, [math]::Max(2, 0.95 * $script:rest + 0.05 * ($w - $cpu - $gpu)))
                if (((Get-Date) - $script:restSaved).TotalMinutes -ge 5) { try { "{0:N2}" -f $script:rest -replace ',', '.' | Set-Content $restFile } catch {}; $script:restSaved = Get-Date }
            }
            # Time left: 3-minute average draw, leaving out the last 2% because Windows hibernates the laptop at 2%
            $avg = Get-Average $script:drawHistory $w
            $usableWh = [math]::Max(0, $remWh - 0.02 * $fullWh)
            $d.WattsText = "{0:N1} W" -f $w
            $d.Status = 'On battery'
            $d.TimeText = $(if ($avg -gt 0) { "{0} left" -f (Format-Duration ($usableWh / $avg)) } else { 'Calculating time left...' })
        }
        $c = if ($w -lt 15) { [System.Drawing.Color]::LimeGreen } elseif ($w -lt 25) { [System.Drawing.Color]::Orange } else { [System.Drawing.Color]::Red }
        Set-TrayIcon ([string][math]::Round($w)) $c
        $d.Watts = $w
        $d.Apps = Get-AppRows $w
        Show-Data $d
    } catch {
        Set-TrayIcon '?' ([System.Drawing.Color]::Gray)
        $d = New-Object PM.PanelData; $d.WattsText = 'No data'; $d.Status = 'Could not read the battery'; Show-Data $d
    }
}

# Hover panel: shows while the mouse rests on the tray icon, hides shortly after it leaves
$panel = New-Object PM.Panel
$script:data = New-Object PM.PanelData
$script:anchor = [System.Drawing.Point]::Empty
$script:lastMove = Get-Date

function Show-Data($d) {
    $script:data = $d
    if ($panel.Visible) { $panel.Data = $d; $panel.Relayout() }
}

function Open-Panel {
    if ($menu.Visible) { return }   # showing the panel closes the open menu
    $script:anchor = [System.Windows.Forms.Cursor]::Position
    $script:lastMove = Get-Date
    if (-not $panel.Visible) { $panel.Data = $script:data; $panel.ShowAt($script:anchor) }
}

$tray.Text = ''   # no plain-text tooltip; the panel replaces it
$tray.Add_MouseMove({ Open-Panel })
$tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Open-Panel } })
$menu.Add_Opening({ $panel.Hide() })

$hideTimer = New-Object System.Windows.Forms.Timer
$hideTimer.Interval = 150
$hideTimer.Add_Tick({
    if (-not $panel.Visible) { return }
    $p = [System.Windows.Forms.Cursor]::Position
    if ($panel.Bounds.Contains($p)) { return }
    $dx = $p.X - $script:anchor.X; $dy = $p.Y - $script:anchor.Y
    $away = [math]::Sqrt($dx * $dx + $dy * $dy) -gt (24 * $panel.UiScale)
    if ($away -and ((Get-Date) - $script:lastMove).TotalMilliseconds -gt 400) { $panel.Hide() }
})

Update-Meter
$tray.Visible = $true
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Update-Meter })
$timer.Start()
$hideTimer.Start()
[System.Windows.Forms.Application]::Run()
$timer.Stop(); $hideTimer.Stop(); $sampler.Stop(); $panel.Dispose(); $tray.Dispose(); $mutex.ReleaseMutex()
