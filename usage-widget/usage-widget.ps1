# Claude usage widget: on-screen side tab (click or hover for the full panel) plus a system tray icon showing the 5-hour %.
# Shows 5-hour, weekly and per-model (e.g. Fable) limits for the Claude Code login or the Claude Desktop account.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Win32 -Name User32 -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
'@

$credFile   = "$env:USERPROFILE\.claude\.credentials.json"
# Optional second Claude Code profile signed in to the Desktop account (CLAUDE_CONFIG_DIR=~/.claude-desktop-acct).
$desktopCredFile = "$env:USERPROFILE\.claude-desktop-acct\.credentials.json"
$sourceFile = Join-Path $PSScriptRoot 'source.txt'
$pollMs     = 120000
$panelW     = 280

# 'code' = the Claude Code login (Antigravity/terminal); 'desktop' = the Claude Desktop app's account.
$script:source = try { (Get-Content $sourceFile -ErrorAction Stop).Trim() } catch { 'code' }
if ($script:source -notin 'code', 'desktop') { $script:source = 'code' }

# ---------- data ----------

function Get-Usage($file = $credFile) {
    # shortcut: uses the token Claude Code keeps refreshed; never refreshes it itself, so after long idle it waits for Claude Code to run once.
    $token = (Get-Content $file -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
    Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 15 `
        -Headers @{ Authorization = "Bearer $token"; 'anthropic-beta' = 'oauth-2025-04-20' }
}

# Returns @{ limits; asOf }. Desktop's login is encrypted, so read the usage samples Desktop saves itself instead.
function Get-Limits {
    if ($script:source -eq 'code') { return @{ limits = @((Get-Usage).limits); asOf = Get-Date } }
    # Live numbers and resets when the Desktop-account profile's login works; otherwise Desktop's own saved samples.
    if (Test-Path $desktopCredFile) { try { return @{ limits = @((Get-Usage $desktopCredFile).limits); asOf = Get-Date; live = $true } } catch {} }
    # shortcut: Desktop samples only have 5-hour and weekly % (no reset times, no Fable) and update only while Desktop runs.
    $file = Get-ChildItem "$env:LOCALAPPDATA\Claude-Data\claude_*\plan-usage-history.json", "$env:APPDATA\Claude\plan-usage-history.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $file) { throw 'Claude Desktop usage file not found' }
    $s = @((Get-Content $file.FullName -Raw | ConvertFrom-Json).samples | Where-Object { $null -ne $_.u.fh })[-1]
    if (-not $s) { throw 'No Claude Desktop usage yet' }
    @{
        limits = @([pscustomobject]@{ kind = 'session'; percent = $s.u.fh; resets_at = $null },
                   [pscustomobject]@{ kind = 'weekly_all'; percent = $s.u.sd; resets_at = $null })
        asOf   = [DateTimeOffset]::FromUnixTimeMilliseconds($s.t).LocalDateTime
    }
}

function Get-Label($limit) {
    switch ($limit.kind) {
        'session'    { '5-hour' }
        'weekly_all' { 'Weekly' }
        default      { if ($limit.scope.model.display_name) { "Weekly $([char]0xB7) $($limit.scope.model.display_name)" } else { $limit.kind } }
    }
}

function Format-Reset($iso) {
    if (-not $iso) { return '' }
    $at = [DateTimeOffset]::Parse($iso).LocalDateTime
    $left = $at - (Get-Date)
    if ($left.TotalMinutes -le 0) { return 'Resetting' }
    # Clock time of the reset (weekday added when it isn't today), then the countdown.
    $when = if ($at.Date -eq (Get-Date).Date) { $at.ToString('h:mm tt') } else { $at.ToString('ddd h:mm tt') }
    $in = if ($left.TotalDays -ge 1) { '{0}d {1}h' -f [int][Math]::Floor($left.TotalDays), $left.Hours } else { '{0}h {1}m' -f [int][Math]::Floor($left.TotalHours), $left.Minutes }
    "Resets $when  $([char]0xB7)  in $in"
}

# ---------- look ----------

function RGB($r, $g, $b) { [Drawing.Color]::FromArgb($r, $g, $b) }
$c = @{
    bg = RGB 28 27 26; surface = RGB 40 38 36; track = RGB 56 53 50; pill = RGB 48 46 43
    text = RGB 238 234 228; sub = RGB 176 169 160; dim = RGB 128 121 114
    accent = RGB 217 119 87; warn = RGB 232 170 66; danger = RGB 229 83 75
}
function Get-BarColor($pct) { if ($pct -ge 90) { $c.danger } elseif ($pct -ge 70) { $c.warn } else { $c.accent } }

$f = @{
    title = New-Object Drawing.Font('Segoe UI Semibold', 10.5)
    label = New-Object Drawing.Font('Segoe UI', 9)
    pct   = New-Object Drawing.Font('Segoe UI Semibold', 12)
    small = New-Object Drawing.Font('Segoe UI', 7.5)
    tab   = New-Object Drawing.Font('Segoe UI Semibold', 8.5)
}
$right = New-Object Drawing.StringFormat -Property @{ Alignment = 'Far' }
$center = New-Object Drawing.StringFormat -Property @{ Alignment = 'Center' }

function New-Round($x, $y, $w, $h, $r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Min($r * 2, [Math]::Min($w, $h))
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); $p
}
function Fill-Round($g, $color, $x, $y, $w, $h, $r) {
    $b = New-Object Drawing.SolidBrush $color; $p = New-Round $x $y $w $h $r
    $g.FillPath($b, $p); $p.Dispose(); $b.Dispose()
}
function Draw-Text($g, $text, $font, $color, $x, $y, $fmt = $null) {
    $b = New-Object Drawing.SolidBrush $color
    if ($fmt) { $g.DrawString($text, $font, $b, [single]$x, [single]$y, $fmt) } else { $g.DrawString($text, $font, $b, [single]$x, [single]$y) }
    $b.Dispose()
}

# Expanded panel height for the current data.
function Get-PanelHeight {
    $h = 50
    if ($script:err) { return $h + 52 }
    foreach ($l in $script:data.limits) { $h += if ($l.resets_at) { 60 } else { 44 } }
    $h + 30
}

function Draw-Panel($g) {
    $pad = 18; $inner = $panelW - $pad * 2
    # Header: accent dot, title, account pill.
    $dot = New-Object Drawing.SolidBrush $c.accent; $g.FillEllipse($dot, $pad, 21, 8, 8); $dot.Dispose()
    Draw-Text $g 'Claude usage' $f.title $c.text ($pad + 14) 14
    $acct = if ($script:source -eq 'code') { 'Antigravity' } else { 'Desktop' }
    $tw = $g.MeasureString($acct, $f.small).Width + 14
    Fill-Round $g $c.pill ($panelW - $pad - $tw) 15 $tw 20 10
    Draw-Text $g $acct $f.small $c.sub ($panelW - $pad - $tw / 2) 18 $center

    $y = 50
    if ($script:err) {
        Fill-Round $g $c.surface $pad $y $inner 40 8
        Draw-Text $g $script:err $f.label $c.danger ($pad + 12) ($y + 11)
        return
    }
    foreach ($l in $script:data.limits) {
        $pct = [Math]::Min(100, [Math]::Max(0, [int]$l.percent)); $col = Get-BarColor $pct
        Draw-Text $g (Get-Label $l) $f.label $c.sub $pad ($y + 3)
        Draw-Text $g "$pct%" $f.pct $c.text ($panelW - $pad + 3) ($y - 2) $right
        Fill-Round $g $c.track $pad ($y + 24) $inner 6 3
        if ($pct -gt 0) { Fill-Round $g $col $pad ($y + 24) ([Math]::Max(6, $inner * $pct / 100)) 6 3 }
        $reset = Format-Reset $l.resets_at
        if ($reset) { Draw-Text $g $reset $f.small $c.dim $pad ($y + 34); $y += 60 } else { $y += 44 }
    }
    $a = $script:data.asOf
    $stamp = if ($a.Date -eq (Get-Date).Date) { $a.ToString('h:mm tt') } else { $a.ToString('MMM d, h:mm tt') }
    $live = $script:source -eq 'code' -or $script:data.live
    $foot = if ($live) { "Updated $stamp" } else { "As of $stamp - saved by Desktop" }
    # Desktop only saves usage now and then, so flag numbers over 30 min old instead of passing them off as current.
    $age = (Get-Date) - $a
    $old = -not $live -and $age.TotalMinutes -gt 30
    if ($old) { $foot = "As of $stamp ($(if ($age.TotalHours -ge 1) { '{0}h' -f [int][Math]::Floor($age.TotalHours) } else { '{0}m' -f [int]$age.TotalMinutes }) old) - may be out of date" }
    $pen = New-Object Drawing.Pen $c.track; $g.DrawLine($pen, $pad, $y, $panelW - $pad, $y); $pen.Dispose()
    Draw-Text $g $foot $f.small $(if ($old) { $c.warn } else { $c.dim }) $pad ($y + 7)
}

function Get-SessionPct {
    $s = if ($script:data) { $script:data.limits | Where-Object kind -eq 'session' | Select-Object -First 1 }
    if ($s) { [Math]::Min(100, [Math]::Max(0, [int]$s.percent)) }
}

# Tray icon: ring gauge for the 5-hour limit with the % inside.
function New-TrayIcon {
    $pct = Get-SessionPct
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $pen = New-Object Drawing.Pen($c.track, 4); $g.DrawEllipse($pen, 2, 2, 28, 28)
    if ($pct -gt 0) { $pen.Color = Get-BarColor $pct; $g.DrawArc($pen, 2, 2, 28, 28, -90, [single]($pct * 3.6)) }
    $pen.Dispose()
    $txt = if ($script:err) { '!' } elseif ($null -ne $pct) { "$pct" } else { '' }
    $font = New-Object Drawing.Font('Segoe UI Semibold', $(if ($txt.Length -ge 3) { 9 } else { 12 }), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $b = New-Object Drawing.SolidBrush $(if ($script:err) { $c.danger } else { [Drawing.Color]::White })
    $fmt = New-Object Drawing.StringFormat -Property @{ Alignment = 'Center'; LineAlignment = 'Center' }
    $g.DrawString($txt, $font, $b, (New-Object Drawing.RectangleF(0, 1, 32, 32)), $fmt)
    $b.Dispose(); $font.Dispose(); $g.Dispose()
    $h = $bmp.GetHicon(); $bmp.Dispose()
    $icon = [Drawing.Icon]::FromHandle($h).Clone()
    [void][Win32.User32]::DestroyIcon($h)
    $icon
}

# Side tab: ring gauge for the 5-hour limit, % and a drag grip.
function Draw-Tab($g) {
    $pct = Get-SessionPct; if ($null -eq $pct) { $pct = 0 }
    $cx = $tabW / 2; $r = 11; $box = New-Object Drawing.RectangleF(($cx - $r), (24 - $r), ($r * 2), ($r * 2))
    $pen = New-Object Drawing.Pen($c.track, 3.5); $g.DrawEllipse($pen, $box)
    if ($pct -gt 0) { $pen.Color = Get-BarColor $pct; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $g.DrawArc($pen, $box, -90, [single]($pct * 3.6)) }
    $pen.Dispose()
    $txt = if ($script:err) { '!' } elseif ($script:data) { "$pct%" } else { '...' }
    Draw-Text $g $txt $f.tab $(if ($script:err) { $c.danger } else { $c.text }) $cx 44 $center
    Draw-Text $g '5h' $f.small $c.dim $cx 62 $center
    $grip = New-Object Drawing.SolidBrush $c.track
    foreach ($gy in 84, 89) { $g.FillEllipse($grip, $cx - 5, $gy, 3, 3); $g.FillEllipse($grip, $cx + 2, $gy, 3, 3) }
    $grip.Dispose()
}

# ---------- side tab window ----------

$tabW = 36; $tabH = 100
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form = New-Object Windows.Forms.Form -Property @{
    Text = 'Claude Usage'; FormBorderStyle = 'None'; ShowInTaskbar = $false; StartPosition = 'Manual'; TopMost = $true
    BackColor = $c.bg; Size = "$tabW,$tabH"
}
$form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($form, $true)
$form.Add_Paint({
    $g = $_.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    if ($script:expanded) { Draw-Panel $g } else { $g.Clear($c.surface); Draw-Tab $g }
})

# The tab's own spot is ($script:tabX, $script:tabY). Expanded, the panel opens toward the screen's middle.
$posFile = Join-Path $PSScriptRoot 'position.txt'
$script:expanded = $false; $script:data = $null; $script:err = $null
$script:tabX = $wa.Right - $tabW; $script:tabY = $wa.Top + [int](($wa.Height - $tabH) / 2)
try {
    $x, $y = (Get-Content $posFile -ErrorAction Stop).Split(',') | ForEach-Object { [int]$_ }
    # Ignore a saved spot that is no longer on any screen (e.g. monitor unplugged).
    if ([Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($x + 1, $y + 1) }) { $script:tabX = $x; $script:tabY = $y }
} catch {}

function Get-TabScreen { [Windows.Forms.Screen]::FromPoint((New-Object Drawing.Point(($script:tabX + $tabW / 2), ($script:tabY + 10)))).WorkingArea }
# The other widget's tab (from its saved position, with an 8 px margin), so tabs and open panels keep clear of it.
$otherPosFile = "$PSScriptRoot\..\status-widget\position.txt"
function Get-OtherTab {
    try { $x, $y = (Get-Content $otherPosFile -ErrorAction Stop).Split(',') | ForEach-Object { [int]$_ }; New-Object Drawing.Rectangle($x, ($y - 8), $tabW, ($tabH + 16)) } catch { $null }
}
function Test-HitsOther($x, $y, $w, $h) { $o = Get-OtherTab; [bool]($o -and (New-Object Drawing.Rectangle($x, $y, $w, $h)).IntersectsWith($o)) }

# Moves this tab just above or below the other one when they would touch.
function Clear-OtherTab($area) {
    if (-not (Test-HitsOther $script:tabX $script:tabY $tabW $tabH)) { return }
    $o = Get-OtherTab; $above = $o.Top - $tabH; $below = $o.Bottom
    $preferAbove = $script:tabY -lt $o.Top + 8
    $script:tabY = if (($preferAbove -and $above -ge $area.Top) -or $below + $tabH -gt $area.Bottom) { $above } else { $below }
    try { Set-Content $posFile "$($script:tabX),$($script:tabY)" } catch {}
}
Clear-OtherTab (Get-TabScreen)

function Set-Expanded($open) {
    $opening = $open -and -not $script:expanded
    $script:expanded = $open
    $area = Get-TabScreen
    $form.Size = if ($open) { New-Object Drawing.Size($panelW, (Get-PanelHeight)) } else { New-Object Drawing.Size($tabW, $tabH) }
    $openLeft = ($script:tabX + $tabW / 2) -gt ($area.Left + $area.Width / 2)
    $form.Left = if ($open -and $openLeft) { $script:tabX + $tabW - $form.Width } else { $script:tabX }
    $form.Left = [Math]::Max($area.Left, [Math]::Min($area.Right - $form.Width, $form.Left))
    $form.Top = [Math]::Max($area.Top, [Math]::Min($area.Bottom - $form.Height, $script:tabY))
    # An open panel must not cover the other tab: grow up from this tab instead, else open beside the tab column.
    if ($open -and (Test-HitsOther $form.Left $form.Top $form.Width $form.Height)) {
        $up = [Math]::Max($area.Top, $script:tabY + $tabH - $form.Height)
        if (-not (Test-HitsOther $form.Left $up $form.Width $form.Height)) { $form.Top = $up }
        else { $o = Get-OtherTab; $form.Left = if ($openLeft) { [Math]::Min($o.Left, $script:tabX) - $form.Width } else { [Math]::Max($o.Right, $script:tabX + $tabW) } }
    }
    $form.Invalidate()
    # Opening the panel fetches fresh numbers unless the last poll was under 30 s ago (the endpoint rate-limits).
    if ($opening -and ((Get-Date) - $script:lastPoll).TotalSeconds -gt 30) { Update-Widget }
}

# Click toggles the full panel. Drag (moving more than a few px) moves the tab anywhere;
# let go within 40px of a screen edge and it snaps flat to that edge.
$script:drag = $null; $script:pressAt = $null; $script:moved = $false
$form.Add_MouseDown({
    if ($_.Button -ne 'Left') { return }
    $p = [Windows.Forms.Cursor]::Position
    $script:pressAt = $p; $script:moved = $false
    $script:drag = New-Object Drawing.Point(($p.X - $form.Left), ($p.Y - $form.Top))
})
$form.Add_MouseMove({
    if ($null -eq $script:drag) { return }
    $p = [Windows.Forms.Cursor]::Position
    if (-not $script:moved) {
        if ([Math]::Abs($p.X - $script:pressAt.X) + [Math]::Abs($p.Y - $script:pressAt.Y) -lt 5) { return }
        $script:moved = $true
        # Carry the small tab, not the open panel.
        if ($script:expanded) {
            $script:tabX = $p.X - [int]($tabW / 2); $script:tabY = $p.Y - 20; Set-Expanded $false
            $script:drag = New-Object Drawing.Point(($p.X - $form.Left), ($p.Y - $form.Top))
        }
    }
    $form.Location = New-Object Drawing.Point(($p.X - $script:drag.X), ($p.Y - $script:drag.Y))
})
$form.Add_MouseUp({
    if ($null -eq $script:drag) { return }
    $script:drag = $null
    if (-not $script:moved) { if (-not $script:hoverMode) { Set-Expanded (-not $script:expanded) }; return }
    $script:tabX = $form.Left; $script:tabY = $form.Top
    $area = Get-TabScreen
    if ($script:tabX - $area.Left -lt 40) { $script:tabX = $area.Left }
    elseif ($area.Right - ($script:tabX + $tabW) -lt 40) { $script:tabX = $area.Right - $tabW }
    Clear-OtherTab $area
    Set-Expanded $false
    $script:tabX = $form.Left; $script:tabY = $form.Top
    try { Set-Content $posFile "$($script:tabX),$($script:tabY)" } catch {}
})

# ---------- tray icon ----------

$tray = New-Object Windows.Forms.NotifyIcon -Property @{ Visible = $true; Text = 'Claude usage' }

$script:lastPoll = [datetime]::MinValue
function Update-Widget {
    $script:lastPoll = Get-Date
    try { $script:data = Get-Limits; $script:err = $null }
    catch {
        $msg = "$_"
        # The usage endpoint rate-limits (429) now and then; keep showing the last numbers (their time stamp shows their age).
        if ($msg -match '429|rate_limit' -and $script:data) { $script:err = $null }
        else {
            $script:data = $null
            $script:err = if ($script:source -eq 'desktop') { "$($_.Exception.Message)" }
                          elseif ($msg -match '401') { 'Login expired - open Claude Code once' }
                          elseif ($msg -match '429|rate_limit') { 'Busy (rate limited) - retrying in 2 min' }
                          else { 'Offline or no Claude login' }
        }
    }
    $old = $tray.Icon; $tray.Icon = New-TrayIcon; if ($old) { $old.Dispose() }
    # NotifyIcon text is capped at 63 characters.
    $tip = if ($script:err) { "Claude: $($script:err)" } else {
        'Claude ' + (($script:data.limits | ForEach-Object { '{0} {1}%' -f ((Get-Label $_) -replace '^Weekly . ', ''), [int]$_.percent }) -join ', ')
    }
    $tray.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
    Set-Expanded $script:expanded
}

function Set-Source($name) {
    $script:source = $name; $script:data = $null  # don't keep the other account's numbers
    try { Set-Content $sourceFile $name } catch {}
    Update-Widget
}

# Left-click the tray icon shows or hides the side tab.
$tray.Add_MouseClick({ if ($_.Button -eq 'Left') { $form.Visible = -not $form.Visible } })

$menu = New-Object Windows.Forms.ContextMenuStrip
$codeItem    = $menu.Items.Add('Account: Antigravity / Claude Code', $null, { Set-Source 'code' })
$desktopItem = $menu.Items.Add('Account: Claude Desktop', $null, { Set-Source 'desktop' })
[void]$menu.Items.Add('-')
$showItem = $menu.Items.Add('Show on screen', $null, { $form.Visible = -not $form.Visible })
[void]$menu.Items.Add('Refresh', $null, { Update-Widget })
[void]$menu.Items.Add('Exit', $null, { $tray.Visible = $false; $tray.Dispose(); [Windows.Forms.Application]::Exit() })
$menu.Add_Opening({
    $codeItem.Checked = $script:source -eq 'code'; $desktopItem.Checked = $script:source -eq 'desktop'; $showItem.Checked = $form.Visible
})
$tray.ContextMenuStrip = $menu
$form.ContextMenuStrip = $menu

# Click mode: clicking anywhere else closes the open panel (but not while its right-click menu is up).
$form.Add_Deactivate({ if (-not $script:hoverMode -and $script:expanded -and -not $menu.Visible) { Set-Expanded $false } })

# Hover mode: the panel opens while the mouse is over the tab and closes when it leaves.
$modeFile = Join-Path $PSScriptRoot 'open-mode.txt'
$script:hoverMode = try { (Get-Content $modeFile -ErrorAction Stop).Trim() -eq 'hover' } catch { $false }
$hover = New-Object Windows.Forms.Timer -Property @{ Interval = 150 }
$hover.Add_Tick({
    if (-not $script:hoverMode -or -not $form.Visible -or $null -ne $script:drag) { return }
    $cur = [Windows.Forms.Cursor]::Position
    # The tab's own spot counts too: a panel opened beside the tab column no longer covers it.
    $inside = $form.Bounds.Contains($cur) -or ($menu.Visible -and $script:expanded) -or
              ($script:expanded -and (New-Object Drawing.Rectangle($script:tabX, $script:tabY, $tabW, $tabH)).Contains($cur))
    if ($inside -ne $script:expanded) { Set-Expanded $inside }
})
$hoverItem = New-Object Windows.Forms.ToolStripMenuItem('Open panel on hover (instead of click)', $null, {
    $script:hoverMode = -not $script:hoverMode
    try { Set-Content $modeFile $(if ($script:hoverMode) { 'hover' } else { 'click' }) } catch {}
})
$menu.Items.Insert(3, $hoverItem)
$menu.Add_Opening({ $hoverItem.Checked = $script:hoverMode })

$poll = New-Object Windows.Forms.Timer -Property @{ Interval = $pollMs }
$poll.Add_Tick({ Update-Widget })

# Windows 11 rounded corners and a subtle border (ignored on Windows 10).
$round = 2; [void][Win32.User32]::DwmSetWindowAttribute($form.Handle, 33, [ref]$round, 4)
$border = 0x00302E2C; [void][Win32.User32]::DwmSetWindowAttribute($form.Handle, 34, [ref]$border, 4)

Update-Widget
$form.Show()
$hover.Start(); $poll.Start()
[Windows.Forms.Application]::Run()
