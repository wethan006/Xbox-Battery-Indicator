<#
  Controller Battery Warning
  Shows your Bluetooth controller's battery % as a tray icon by the clock, and a Windows notification when it's low.
  Right-click the tray icon for Check now / Icon style / Check every / Xbox Mode On Start-Up / Uninstall / Exit.
  Run once to test:  powershell -ExecutionPolicy Bypass -File .\ControllerBatteryWarning.ps1 -Test
  Preview icon colors:  powershell -ExecutionPolicy Bypass -File .\ControllerBatteryWarning.ps1 -FakePercent 50
#>
param(
    [int]$Threshold = 20,          # warn at or below this %
    [int]$CheckMinutes = 60,       # how often to check (hourly)
    [string]$NameMatch = 'Xbox',   # part of the controller's Bluetooth name
    [switch]$Test,                 # print the current level, show a sample notification, then exit
    [switch]$AtSignIn,             # set by the startup shortcut; used for 'Open Xbox mode at sign-in'
    [int]$FakePercent = -1         # testing only: pretend the controller is at this % (e.g. -FakePercent 50)
)

$BatteryKey   = '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2'   # Bluetooth battery level property
$ConnectedKey = '{83DA6326-97A6-4088-9453-A1923F573B29} 15'  # "is connected right now" property

function Test-DeviceConnected($Device) {
    # A paired controller that is switched off still keeps its last battery value, so skip it unless it's connected.
    $c = Get-PnpDeviceProperty -InstanceId $Device.InstanceId -KeyName $ConnectedKey -ErrorAction SilentlyContinue
    if ($c -and $null -ne $c.Data) { return [bool]$c.Data }
    return ($Device.Status -eq 'OK')   # fallback if Windows doesn't expose the property
}

function Get-ControllerBattery {
    if ($FakePercent -ge 0) { return [pscustomobject]@{ Name = 'Test controller'; Percent = $FakePercent } }
    Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -like "*$NameMatch*" } |
        Where-Object { Test-DeviceConnected $_ } |
        ForEach-Object {
            $p = Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName $BatteryKey -ErrorAction SilentlyContinue
            if ($p -and $null -ne $p.Data) {
                [pscustomobject]@{ Name = $_.FriendlyName; Percent = [int]$p.Data }
            }
        } | Sort-Object Percent | Select-Object -First 1
}

function Get-GamepadIcon {
    # Draws the Windows gamepad symbol (same icon font the Bluetooth popup uses) to a PNG once, then reuses it
    $dir  = Join-Path $env:LOCALAPPDATA 'ControllerBatteryWarning'
    $path = Join-Path $dir 'gamepad.png'
    if (Test-Path $path) { return $path }
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Add-Type -AssemblyName System.Drawing
        $fontName = 'Segoe Fluent Icons'
        if (-not ((New-Object System.Drawing.Text.InstalledFontCollection).Families.Name -contains $fontName)) { $fontName = 'Segoe MDL2 Assets' }
        $light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).SystemUsesLightTheme
        $color = if ($light -eq 1) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
        $bmp = New-Object System.Drawing.Bitmap 96, 96
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $font = New-Object System.Drawing.Font $fontName, 52, ([System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        $g.DrawString([string][char]0xE7FC, $font, (New-Object System.Drawing.SolidBrush $color), (New-Object System.Drawing.RectangleF 0, 0, 96, 96), $fmt)
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        return $path
    } catch { return $null }
}

function Show-Toast([string]$Title, [string]$Body) {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $t = [System.Security.SecurityElement]::Escape($Title)
    $b = [System.Security.SecurityElement]::Escape($Body)
    $icon = Get-GamepadIcon
    $img = if ($icon) { "<image placement='appLogoOverride' src='file:///$($icon -replace '\\','/')'/>" } else { '' }
    $xml.LoadXml("<toast><visual><binding template='ToastGeneric'>$img<text>$t</text><text>$b</text></binding></visual><audio src='ms-winsoundevent:Notification.Reminder' loop='false'/></toast>")
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
        [Windows.UI.Notifications.ToastNotification]::new($xml))
}

if ($Test) {
    $c = Get-ControllerBattery
    if ($c) { Write-Host "$($c.Name): $($c.Percent)%" } else { Write-Host "No '$NameMatch' Bluetooth controller with a battery reading found. Is it connected?" }
    Show-Toast 'Low Battery (test)' ($(if ($c) { "$($c.Percent)% - $($c.Name)" } else { 'No controller reading found.' }))
    return
}

# Only one copy at a time: if it's already running (e.g. opened again from the Start menu), just quit.
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\ControllerBatteryWarning')
if (-not $script:mutex.WaitOne(0)) { return }

# ---- Tray icon: battery level by the clock (vertical battery, horizontal battery or gamepad), checks every $CheckMinutes minutes ----
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Native -Name Icon -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);'
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}
[Native.Icon]::SetProcessDPIAware() | Out-Null   # so the icon is drawn at the real tray size, not scaled (blurry)
$IconSize = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width

$light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).SystemUsesLightTheme
$normalColor = if ($light -eq 1) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
$lowColor = [System.Drawing.Color]::FromArgb(235, 60, 60)
$midColor = [System.Drawing.Color]::FromArgb(245, 190, 30)
$script:hIcon = [IntPtr]::Zero

function Write-Log([string]$Msg) {
    try { Add-Content -Path (Join-Path $env:LOCALAPPDATA 'ControllerBatteryWarning\log.txt') -Value "$(Get-Date -Format s)  $Msg" } catch {}
}

function New-RoundedRect([float]$X, [float]$Y, [float]$W, [float]$H, [float]$R) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-BatteryBitmap([int]$Percent, [System.Drawing.Color]$Color, [bool]$NoController, [double]$BodyRatio, [System.Drawing.Color]$BarColor = $Color) {
    # Vertical rounded battery with 3 bars (each about 33%) filling from the bottom,
    # laid out on whole pixels at the exact tray size so edges stay sharp
    $S   = [int]$IconSize
    $pw  = [int][math]::Max(1, [math]::Round($S / 12))     # outline thickness
    $nh  = [int][math]::Max(2, [math]::Round($S / 10))     # nub height
    $bh  = $S - $nh                                        # body uses the full height
    $bw  = [int][math]::Round($S * $BodyRatio)             # body width
    $r   = [int][math]::Max(2, [math]::Round($S / 7))      # corner radius
    $pad = 1                                               # space between outline and bars
    $sp  = if ($S -ge 24) { 2 } else { 1 }                 # space between bars
    $ox  = [int][math]::Floor(($S - $bw) / 2)
    $by  = $nh

    $bmp = New-Object System.Drawing.Bitmap $S, $S
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half   # whole-pixel edges, no half-pixel blur
    $brush = New-Object System.Drawing.SolidBrush $Color          # outline, nub and no-controller dash
    $barBrush = New-Object System.Drawing.SolidBrush $BarColor    # only the bars change color with the level

    # Outline: fill the outer rounded shape, then cut out the inner one
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $outer = New-RoundedRect $ox $by $bw $bh $r
    $inner = New-RoundedRect ($ox + $pw) ($by + $pw) ($bw - 2 * $pw) ($bh - 2 * $pw) ([math]::Max(1, $r - $pw))
    $g.FillPath($brush, $outer)
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $clear = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Transparent)
    $g.FillPath($clear, $inner)
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver

    # Nub on top and bars: plain whole-pixel rectangles, no smoothing
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $nw = [int][math]::Round($bw * 0.45)
    $g.FillRectangle($brush, $ox + [int][math]::Floor(($bw - $nw) / 2), 0, $nw, $nh)

    $ix = $ox + $pw + $pad; $iy = $by + $pw + $pad
    $iw = $bw - 2 * ($pw + $pad); $ih = $bh - 2 * ($pw + $pad)
    if ($NoController) {
        $dw = [math]::Max(1, $pw)
        $g.FillRectangle($brush, $ix + [int](($iw - $dw) / 2), $iy + [int]($ih / 4), $dw, [int]($ih / 2))
    } else {
        $bars = [int][math]::Min(3, [math]::Ceiling([math]::Max(0, $Percent) / 33.34))
        $barH = [int][math]::Floor(($ih - 2 * $sp) / 3)
        $bottom = $iy + $ih
        for ($i = 0; $i -lt $bars; $i++) { $g.FillRectangle($barBrush, $ix, $bottom - ($i + 1) * $barH - $i * $sp, $iw, $barH) }
    }
    $g.Dispose(); $brush.Dispose(); $barBrush.Dispose(); $clear.Dispose(); $outer.Dispose(); $inner.Dispose()
    return $bmp
}

function New-GamepadBitmap([System.Drawing.Color]$Color, [bool]$Tall = $false, $Fill = $null) {
    # Outlined pill-shaped gamepad with a + D-pad and two buttons, traced from the notification's gamepad.
    # Drawn 4x larger with smoothing, then scaled down to the exact tray size for clean curves.
    $S = [int]$IconSize; $k = 4; $B = $S * $k
    $u  = $B / 100.0
    $t  = [math]::Max(2, [math]::Round($S / 9)) * $k / $u     # outline thickness (a bit heavier than the batteries)
    $big = New-Object System.Drawing.Bitmap $B, $B
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $brush = New-Object System.Drawing.SolidBrush $Color
    $clear = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Transparent)

    # Outline: fill the pill, then cut out a slightly smaller one
    if ($Tall) { $x0 = 2; $y0 = 0;  $w = 96; $h = 100; $r = 40 }   # fills the whole slot height
    else       { $x0 = 3; $y0 = 12; $w = 94; $h = 76;  $r = 34 }   # wider pill shape
    $outer = New-RoundedRect ($x0 * $u) ($y0 * $u) ($w * $u) ($h * $u) ($r * $u)
    $inner = New-RoundedRect (($x0 + $t) * $u) (($y0 + $t) * $u) (($w - 2 * $t) * $u) (($h - 2 * $t) * $u) (($r - $t) * $u)
    $g.FillPath($brush, $outer)
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $g.FillPath($clear, $inner)
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver

    # Optional fill inside the outline (white, yellow or red) with a small gap, and black D-pad and buttons on top
    if ($null -ne $Fill) {
        $gap = $t * 0.35
        $fp = New-RoundedRect (($x0 + $t + $gap) * $u) (($y0 + $t + $gap) * $u) (($w - 2 * ($t + $gap)) * $u) (($h - 2 * ($t + $gap)) * $u) (($r - $t - $gap) * $u)
        $fb = New-Object System.Drawing.SolidBrush $Fill
        $g.FillPath($fb, $fp); $fb.Dispose()
        $g.SetClip($fp); $fp.Dispose()   # keep the black D-pad and buttons inside the fill
        $brush.Dispose(); $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Black)
    }

    # D-pad (+) on the left, two buttons on a diagonal on the right
    $ps = $t * 0.8; $cx = 32; $cy = 50; $L = if ($Tall) { 32 } else { 28 }
    $g.FillRectangle($brush, ($cx - $L / 2) * $u, ($cy - $ps / 2) * $u, $L * $u, $ps * $u)
    $g.FillRectangle($brush, ($cx - $ps / 2) * $u, ($cy - $L / 2) * $u, $ps * $u, $L * $u)
    if ($Tall) {
        $g.FillEllipse($brush, 63 * $u, 29 * $u, 15 * $u, 15 * $u)
        $g.FillEllipse($brush, 52 * $u, 55 * $u, 15 * $u, 15 * $u)
    } else {
        $g.FillEllipse($brush, 64 * $u, 32 * $u, 13 * $u, 13 * $u)
        $g.FillEllipse($brush, 53 * $u, 53 * $u, 13 * $u, 13 * $u)
    }
    $g.ResetClip()
    $g.Dispose(); $brush.Dispose(); $clear.Dispose(); $outer.Dispose(); $inner.Dispose()

    $bmp = New-Object System.Drawing.Bitmap $S, $S
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($big, 0, 0, $S, $S)
    $g.Dispose(); $big.Dispose()
    return $bmp
}

function New-TrayIcon([int]$Percent, [System.Drawing.Color]$Color, [bool]$NoController = $false) {
    switch ($script:IconStyle) {
        'Horizontal' {
            $bmp = New-BatteryBitmap $Percent $script:normalColor $NoController 0.78 $Color
            $bmp.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone)   # nub to the right, bars fill left to right
        }
        { $_ -in 'Gamepad', 'GamepadTall' } {
            if ($NoController) {
                # Nothing connected: dimmed outline only, no fill
                $bmp = New-GamepadBitmap ([System.Drawing.Color]::FromArgb(130, $script:normalColor)) ($script:IconStyle -eq 'GamepadTall')
            } else {
                # Outline stays the normal color; the fill is white, then yellow or red as the battery drops
                $fill = if ($Color -eq $script:normalColor) { [System.Drawing.Color]::White } else { $Color }
                $bmp = New-GamepadBitmap $script:normalColor ($script:IconStyle -eq 'GamepadTall') $fill
            }
        }
        default { $bmp = New-BatteryBitmap $Percent $script:normalColor $NoController 0.78 $Color }
    }
    $h = $bmp.GetHicon(); $bmp.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($h)
    if ($script:hIcon -ne [IntPtr]::Zero) { [Native.Icon]::DestroyIcon($script:hIcon) | Out-Null }
    $script:hIcon = $h
    return $icon
}

# Remembered icon style: Vertical, Horizontal, Gamepad or GamepadTall
$SettingsFile = Join-Path $env:LOCALAPPDATA 'ControllerBatteryWarning\iconstyle.txt'
$script:IconStyle = 'GamepadTall'   # default style until you pick another
if (Test-Path $SettingsFile) { $saved = (Get-Content $SettingsFile -Raw).Trim(); if ($saved -in 'Vertical','Horizontal','Gamepad','GamepadTall') { $script:IconStyle = $saved } }
$script:last = $null

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application   # placeholder so the icon always shows
$tray.Text = 'Controller battery'
$tray.Visible = $true

function Set-TrayIcon {
    $c = $script:last
    if ($c) {
        # Bar color follows the level: 3 bars normal, 2 bars yellow, 1 bar red (battery outline stays normal)
        $iconColor = if ($c.Percent -le 33) { $script:lowColor } elseif ($c.Percent -le 66) { $script:midColor } else { $script:normalColor }
        $script:tray.Icon = New-TrayIcon $c.Percent $iconColor
        $tip = "$($c.Percent)% - $($c.Name)"
        $script:tray.Text = if ($tip.Length -gt 63) { $tip.Substring(0, 63) } else { $tip }
    } else {
        $script:tray.Icon = New-TrayIcon 0 $script:normalColor $true
        $script:tray.Text = 'No controller connected'
    }
}

function Update-Battery([bool]$Manual = $false) {
    try {
        $c = Get-ControllerBattery
        $script:last = $c
        Set-TrayIcon
        if ($c) {
            $tip = "$($c.Percent)% - $($c.Name)"
            # Warns on every hourly check while the battery is at or below the threshold
            if ($c.Percent -le $Threshold) { Show-Toast 'Low Battery' $tip }
            elseif ($Manual) { $script:tray.ShowBalloonTip(3000, 'Controller battery', $tip, 'None') }
        } elseif ($Manual) { $script:tray.ShowBalloonTip(3000, 'Controller battery', 'No controller connected', 'None') }
    } catch { Write-Log "Update failed: $_" }
}

function Set-IconStyle([string]$Style) {
    try {
        $script:IconStyle = $Style
        Set-Content -Path $script:SettingsFile -Value $Style
        foreach ($item in $script:styleItem.DropDownItems) { $item.Checked = ($item.Tag -eq $Style) }
        Set-TrayIcon
    } catch { Write-Log "Style change failed: $_" }
}

function Set-RoundCorners($Strip) {
    # Ask Windows 11 to round a menu's corners (ignored on Windows 10)
    try { $pref = 2; [Native.Icon]::DwmSetWindowAttribute($Strip.Handle, 33, [ref]$pref, 4) | Out-Null } catch {}
}

[System.Windows.Forms.Application]::EnableVisualStyles()
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Font = New-Object System.Drawing.Font 'Segoe UI', 9   # crisp ClearType text at your screen scaling
$menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System
$menu.ShowImageMargin = $false
$menu.Add_Opened({ Set-RoundCorners $script:menu })

$checkItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Check now'
$checkItem.Add_Click({ Update-Battery $true })

$styleItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Icon style'
foreach ($pair in @(@('Vertical', 'Vertical battery'), @('Horizontal', 'Horizontal battery'), @('Gamepad', 'Gamepad'), @('GamepadTall', 'Gamepad (tall)'))) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem $pair[1]
    $it.Tag = $pair[0]
    $it.Checked = ($pair[0] -eq $script:IconStyle)
    $it.Add_Click({ param($sender, $e) Set-IconStyle $sender.Tag })
    $styleItem.DropDownItems.Add($it) | Out-Null
}
$styleItem.DropDown.Font = $menu.Font
$styleItem.DropDown.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System
$styleItem.DropDown.Add_Opened({ Set-RoundCorners $script:styleItem.DropDown })

# Check interval: saved next to the icon style, overrides -CheckMinutes once picked from the menu
$script:IntervalFile = Join-Path (Split-Path $script:SettingsFile) 'interval.txt'
try {
    $saved = 0
    if ((Test-Path $script:IntervalFile) -and [int]::TryParse((Get-Content $script:IntervalFile -Raw).Trim(), [ref]$saved) -and $saved -ge 1) { $CheckMinutes = $saved }
} catch {}
$script:CheckMinutes = $CheckMinutes

function Set-CheckInterval([int]$Minutes) {
    try {
        $script:CheckMinutes = $Minutes
        Set-Content -Path $script:IntervalFile -Value $Minutes
        foreach ($item in $script:intervalItem.DropDownItems) { $item.Checked = ([int]$item.Tag -eq $Minutes) }
        $script:timer.Stop(); $script:timer.Interval = $Minutes * 60 * 1000; $script:timer.Start()
        Write-Log "Check interval set to $Minutes min"
    } catch { Write-Log "Interval change failed: $_" }
}

$intervalItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Check every'
foreach ($pair in @(@(5, '5 minutes'), @(15, '15 minutes'), @(30, '30 minutes'), @(60, '1 hour'), @(120, '2 hours'))) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem $pair[1]
    $it.Tag = $pair[0]
    $it.Checked = ($pair[0] -eq $script:CheckMinutes)
    $it.Add_Click({ param($sender, $e) Set-CheckInterval ([int]$sender.Tag) })
    $intervalItem.DropDownItems.Add($it) | Out-Null
}
$intervalItem.DropDown.Font = $menu.Font
$intervalItem.DropDown.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System
$intervalItem.DropDown.Add_Opened({ Set-RoundCorners $script:intervalItem.DropDown })

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
$exitItem.Add_Click({
    $script:timer.Stop()
    $script:tray.Visible = $false; $script:tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$uninstallItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Uninstall'
$uninstallItem.Add_Click({
    try {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Remove Controller Battery Warning?`n`nThis closes it and deletes its Start menu entry, startup shortcut and settings.",
            'Uninstall', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        foreach ($f in @('Startup', 'Programs')) {
            Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath($f)) 'Controller Battery Warning.lnk') -Force -ErrorAction SilentlyContinue
        }
        # Delete the install folder a couple of seconds after this closes
        $dir = Join-Path $env:LOCALAPPDATA 'ControllerBatteryWarning'
        Start-Process cmd.exe -ArgumentList "/c timeout /t 3 /nobreak >nul & rmdir /s /q `"$dir`"" -WindowStyle Hidden
        $script:timer.Stop()
        $script:tray.Visible = $false; $script:tray.Dispose()
        [System.Windows.Forms.Application]::Exit()
    } catch { Write-Log "Uninstall failed: $_" }
})
# ---- Xbox mode at sign-in (desktop PCs don't get Windows' own "enter on startup" option) ----
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class XboxMode {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    struct RECT { public int L, T, R, B; }
    // Xbox mode is a full-screen app window (class ApplicationFrameWindow) titled exactly "XBOX" in capitals
    public static string LastMatch = "";
    // Game Bar keeps an invisible full-screen overlay called "Xbox Game Bar", so ignore anything with "Game Bar" in the title
    static bool IsXboxTitle(string t) {
        return t.IndexOf("Xbox", StringComparison.OrdinalIgnoreCase) >= 0 && t.IndexOf("Game Bar", StringComparison.OrdinalIgnoreCase) < 0;
    }
    public static bool IsActive() {
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1); bool found = false;
        EnumWindows((hwnd, l) => {
            if (!IsWindowVisible(hwnd)) return true;
            var sb = new StringBuilder(256); GetWindowText(hwnd, sb, 256);
            if (sb.ToString() != "XBOX") return true;
            var cls = new StringBuilder(256); GetClassName(hwnd, cls, 256);
            if (cls.ToString() != "ApplicationFrameWindow") return true;
            RECT r; if (GetWindowRect(hwnd, out r) && r.L <= 0 && r.T <= 0 && r.R >= w && r.B >= h) { LastMatch = sb.ToString(); found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // Any visible window with "Xbox" in its title (the Xbox app has opened)
    public static bool HasXboxWindow() {
        bool found = false;
        EnumWindows((hwnd, l) => {
            if (!IsWindowVisible(hwnd)) return true;
            var sb = new StringBuilder(256); GetWindowText(hwnd, sb, 256);
            if (IsXboxTitle(sb.ToString())) { LastMatch = sb.ToString(); found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    // Windows' own shortcut for Xbox mode: Win+F11 (it toggles, so check IsActive first)
    public static void SendWinF11() {
        keybd_event(0x5B, 0, 0, UIntPtr.Zero); keybd_event(0x7A, 0, 0, UIntPtr.Zero);
        keybd_event(0x7A, 0, 2, UIntPtr.Zero); keybd_event(0x5B, 0, 2, UIntPtr.Zero);
    }
}
"@
$script:XboxFile = Join-Path (Split-Path $script:SettingsFile) 'xboxmode.txt'
$script:XboxAtSignIn = (Test-Path $script:XboxFile) -and ((Get-Content $script:XboxFile -Raw).Trim() -eq '1')

function Set-XboxAtSignIn([bool]$On) {
    try {
        $script:XboxAtSignIn = $On
        Set-Content -Path $script:XboxFile -Value ([int]$On)
        foreach ($item in $script:xboxItem.DropDownItems) { $item.Checked = ([bool]$item.Tag -eq $On) }
    } catch { Write-Log "Xbox mode setting failed: $_" }
}

$xboxItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Xbox Mode On Start-Up'
foreach ($pair in @(@($true, 'On'), @($false, 'Off'))) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem $pair[1]
    $it.Tag = $pair[0]
    $it.Checked = ($pair[0] -eq $script:XboxAtSignIn)
    $it.Add_Click({ param($sender, $e) Set-XboxAtSignIn ([bool]$sender.Tag) })
    $xboxItem.DropDownItems.Add($it) | Out-Null
}
$xboxItem.DropDown.Font = $menu.Font
$xboxItem.DropDown.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::System
$xboxItem.DropDown.Add_Opened({ Set-RoundCorners $script:xboxItem.DropDown })

function Invoke-XboxModeCheck {
    # 8 seconds after Win+F11: if Xbox mode still isn't up, say so
    $script:xboxCheck = New-Object System.Windows.Forms.Timer
    $script:xboxCheck.Interval = 8000
    $script:xboxCheck.Add_Tick({
        $script:xboxCheck.Stop()
        try {
            if (-not [XboxMode]::IsActive()) {
                Write-Log 'Xbox mode did not open'
                Show-Toast 'Xbox Mode' "Xbox Mode couldn't be opened"
            }
        } catch { Write-Log "Xbox mode check failed: $_" }
    })
    $script:xboxCheck.Start()
}

if ($AtSignIn -and $script:XboxAtSignIn) {
    # Steps: wait 1 s, then watch for the Xbox app's window every 0.5 s (opening it after 30 s if needed, up to 60 s),
    # press Win+F11 the moment it appears, then confirm Xbox mode opened.
    $script:xboxStep = 'desktop'; $script:xboxWait = 0
    $script:xboxTimer = New-Object System.Windows.Forms.Timer
    $script:xboxTimer.Interval = 1000
    $script:xboxTimer.Add_Tick({
        try {
            switch ($script:xboxStep) {
                'desktop' {
                    if ([XboxMode]::IsActive()) { $script:xboxTimer.Stop(); Write-Log "Xbox mode already on (window: $([XboxMode]::LastMatch))"; return }
                    $script:xboxStep = 'app'; $script:xboxTimer.Interval = 500
                }
                'app' {
                    # The Xbox app normally opens by itself at sign-in; wait for it, and only open it if it hasn't shown up after 30 s
                    $script:xboxWait++
                    if ($script:xboxWait -eq 60 -and -not [XboxMode]::HasXboxWindow()) {
                        Start-Process explorer.exe 'shell:AppsFolder\Microsoft.GamingApp_8wekyb3d8bbwe!Microsoft.Xbox.App'
                        Write-Log 'Xbox app not running yet, opened it'
                    }
                    if ([XboxMode]::HasXboxWindow()) {
                        # Xbox mode can be entered while the app still says "Launching", so go right away
                        $script:xboxTimer.Stop()
                        if ([XboxMode]::IsActive()) { Write-Log "Xbox mode already on (window: $([XboxMode]::LastMatch))"; return }
                        [XboxMode]::SendWinF11(); Write-Log 'Sent Win+F11 for Xbox mode'
                        Invoke-XboxModeCheck
                    } elseif ($script:xboxWait -ge 120) {
                        $script:xboxTimer.Stop(); Write-Log 'Xbox app did not open'
                        Show-Toast 'Xbox Mode' "Xbox Mode couldn't be opened"
                    }
                }
            }
        } catch { $script:xboxTimer.Stop(); Write-Log "Xbox mode launch failed: $_" }
    })
    $script:xboxTimer.Start()
}

$menu.Items.AddRange(@($checkItem, $styleItem, $intervalItem, (New-Object System.Windows.Forms.ToolStripSeparator), $xboxItem, (New-Object System.Windows.Forms.ToolStripSeparator), $uninstallItem, $exitItem))
$tray.ContextMenuStrip = $menu

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $script:CheckMinutes * 60 * 1000
$timer.Add_Tick({ Update-Battery $false })
$timer.Start()

Update-Battery $false
[System.Windows.Forms.Application]::Run()
