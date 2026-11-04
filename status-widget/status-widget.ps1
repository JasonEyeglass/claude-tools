# Claude status widget: on-screen side tab showing running Claude sessions (where, which folder, which connections)
# plus plugin switches. Click the tab for the panel; drag it anywhere (snaps to screen edges).
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Win32 -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
'@
. "$PSScriptRoot\..\project-launcher\vault-tools.ps1"

$settingsFile = "$env:USERPROFILE\.claude\settings.json"
$posFile      = Join-Path $PSScriptRoot 'position.txt'
$refreshMs    = 8000
$panelW       = 340
$tabW = 36; $tabH = 100
$plugins = [ordered]@{ 'Ponytail' = 'ponytail@ponytail'; 'Caveman' = 'caveman@caveman' }

# ---------- data ----------

function Get-PluginState($id) {
    $raw = Get-Content $settingsFile -Raw
    if ($raw -match ('"' + [regex]::Escape($id) + '"\s*:\s*(true|false)')) { $matches[1] -eq 'true' }
}

# Flips one enabledPlugins entry in place so the rest of settings.json keeps its formatting.
function Switch-Plugin($id) {
    $raw = Get-Content $settingsFile -Raw
    $pattern = '("' + [regex]::Escape($id) + '"\s*:\s*)(true|false)'
    if ($raw -notmatch $pattern) { return }
    $new = [regex]::Replace($raw, $pattern, { param($m) $m.Groups[1].Value + $(if ($m.Groups[2].Value -eq 'true') { 'false' } else { 'true' }) }, 'None', [TimeSpan]::FromSeconds(1))
    [IO.File]::WriteAllText($settingsFile, $new)
}

# Live modes the plugins' prompt hooks read: caveman per session id, ponytail per project folder (sha256 of its path).
$claudeDir = "$env:USERPROFILE\.claude"
$sha = [Security.Cryptography.SHA256]::Create()
function Get-PonytailFile($cwd) { "$claudeDir\ponytail-modes\" + (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($cwd)) | ForEach-Object { $_.ToString('x2') })) }
function Read-Flag($file) { try { (Get-Content $file -Raw -ErrorAction Stop).Trim() } catch { $null } }
function Get-CaveFile($id) { if ($id -match '^[A-Za-z0-9_-]{1,128}$') { "$claudeDir\.caveman-sessions\$id.mode" } }

function Get-SessionModes($id, $cwd) {
    $cave = $(if ($file = Get-CaveFile $id) { Read-Flag $file })
    if ($null -eq $cave) { $cave = Read-Flag "$claudeDir\.caveman-active" }
    $pony = Read-Flag (Get-PonytailFile $cwd)
    @{ cave = $(if ($cave -and $cave -ne 'off') { $cave }); pony = $(if ($pony -and $pony -ne 'off') { $pony }) }
}

# Writes the mode file the way the plugin's own command does, then copies that command: caveman reacts to the file
# from the next prompt, but only the command (pasted in the session) swaps the rules the session started with.
function Switch-SessionMode($kind, $id, $cwd, $on) {
    if ($kind -eq 'Caveman') {
        $file = Get-CaveFile $id; if (-not $file) { return }
        New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
        [IO.File]::WriteAllText($file, $(if ($on) { 'off' } else { 'caveman' }))
        # Shared mirror for the statusline; caveman never stores 'off' in it.
        if ($on) { Remove-Item "$claudeDir\.caveman-active" -ErrorAction SilentlyContinue } else { [IO.File]::WriteAllText("$claudeDir\.caveman-active", 'caveman') }
        $cmd = if ($on) { 'stop caveman' } else { '/caveman' }
    } else {
        $files = (Get-PonytailFile $cwd), "$claudeDir\.ponytail-active"
        if ($on) { Remove-Item $files -ErrorAction SilentlyContinue }
        else { New-Item -ItemType Directory -Force (Split-Path $files[0]) | Out-Null; foreach ($p in $files) { [IO.File]::WriteAllText($p, 'full') } }
        $cmd = if ($on) { '/ponytail off' } else { '/ponytail' }
    }
    Set-Clipboard $cmd
    "$kind $(if ($on) { 'off' } else { 'on' }) - paste '$cmd' in that session"
}

# Where a session runs, from the programs above its claude.exe.
function Get-Where($procId, $byId, $entry) {
    $p = $byId[[int]$byId[[int]$procId].ParentProcessId]
    for ($i = 0; $p -and $i -lt 8; $i++) {
        switch ($p.Name) {
            'Antigravity IDE.exe' { return 'Antigravity' }
            'WindowsTerminal.exe' { return 'Terminal' }
            'Code.exe'            { return 'VS Code' }
        }
        # The Desktop app is also Claude.exe (same as the CLI, names ignore case), so tell it by its install folder.
        if ($p.CommandLine -match '\\WindowsApps\\Claude_|\\AnthropicClaude\\') { return 'Desktop' }
        $p = $byId[[int]$p.ParentProcessId]
    }
    if ($entry -eq 'claude-desktop') { 'Desktop' } elseif ($entry -eq 'cli') { 'Terminal' } else { "$entry" }
}

function Get-Descendants($procId, $children) {
    $out = @(); $queue = @([int]$procId)
    while ($queue.Count) {
        $next = @(); foreach ($q in $queue) { foreach ($c in @($children[$q])) { if ($c) { $out += $c; $next += [int]$c.ProcessId } } }
        $queue = $next
    }
    $out
}

# Connections a session in $cwd gets: user ones, overridden by this project's local and .mcp.json ones.
function Get-McpConfig($cwd, $claudeJson) {
    $all = [ordered]@{}
    foreach ($src in @($claudeJson.mcpServers, $claudeJson.projects.($cwd.Replace('\', '/')).mcpServers)) {
        if ($src) { foreach ($p in $src.PSObject.Properties) { $all[$p.Name] = $p.Value } }
    }
    $proj = Join-Path $cwd '.mcp.json'
    if (Test-Path $proj) { try { foreach ($p in (Get-Content $proj -Raw | ConvertFrom-Json).mcpServers.PSObject.Properties) { $all[$p.Name] = $p.Value } } catch {} }
    $all
}

$script:probeCache = @{}
function Get-HttpStatus($url, $token) {
    $hit = $script:probeCache[$url]
    if ($hit -and ((Get-Date) - $hit.at).TotalSeconds -lt 20) { return $hit.name }
    $name = Test-VaultOnline @{ url = $url; token = $token } 1
    $script:probeCache[$url] = @{ at = Get-Date; name = $name }
    $name
}

function Get-Sessions {
    $procs = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine)
    $byId = @{}; $children = @{}
    foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p; $children[[int]$p.ParentProcessId] = @($children[[int]$p.ParentProcessId]) + $p }
    $claudeJson = Get-Content "$env:USERPROFILE\.claude.json" -Raw | ConvertFrom-Json
    $vaults = @(Get-KnownVaults)
    foreach ($f in Get-ChildItem "$env:USERPROFILE\.claude\sessions\*.json" -ErrorAction SilentlyContinue) {
        $s = try { Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $byId[[int]$s.pid] -or $byId[[int]$s.pid].Name -notlike 'claude*') { continue }
        $desc = Get-Descendants $s.pid $children
        $conns = foreach ($e in (Get-McpConfig $s.cwd $claudeJson).GetEnumerator()) {
            $cfg = $e.Value
            if ($cfg.type -in 'http', 'sse') {
                $token = "$($cfg.headers.Authorization)" -replace '^Bearer\s+'
                $live = Get-HttpStatus $cfg.url $token
                $vault = $vaults | Where-Object { $_.url -eq $cfg.url } | Select-Object -First 1
                $label = if ($live) { $live -replace '^Obsidian - ', '' } else { Resolve-VaultName $cfg.url $vaults }
                [pscustomobject]@{ name = $e.Key; on = [bool]$live; detail = $label; vault = $vault.path }
            } else {
                # A stdio server is up when its process runs under this session.
                $needle = @($cfg.args) + $cfg.command | Where-Object { $_ -and $_ -notmatch '^[/-]' } | Select-Object -Last 1
                $leaf = if ($needle) { Split-Path $needle -Leaf } else { '' }
                $on = [bool]($leaf -and ($desc | Where-Object { $_.CommandLine -like "*$leaf*" }))
                [pscustomobject]@{ name = $e.Key; on = $on; detail = ''; vault = $null }
            }
        }
        [pscustomobject]@{
            id = $s.sessionId; name = $s.name; cwd = $s.cwd; status = $s.status
            where = Get-Where $s.pid $byId $s.entrypoint; conns = @($conns); modes = Get-SessionModes $s.sessionId $s.cwd
        }
    }
}

# ---------- look ----------

function RGB($r, $g, $b) { [Drawing.Color]::FromArgb($r, $g, $b) }
$c = @{
    bg = RGB 28 27 26; surface = RGB 40 38 36; track = RGB 56 53 50; pill = RGB 48 46 43
    text = RGB 238 234 228; sub = RGB 176 169 160; dim = RGB 128 121 114
    accent = RGB 217 119 87; green = RGB 110 190 120; red = RGB 229 83 75; amber = RGB 230 170 60
}
$f = @{
    title = New-Object Drawing.Font('Segoe UI Semibold', 10.5)
    head  = New-Object Drawing.Font('Segoe UI Semibold', 8)
    label = New-Object Drawing.Font('Segoe UI', 9)
    bold  = New-Object Drawing.Font('Segoe UI Semibold', 9)
    small = New-Object Drawing.Font('Segoe UI', 7.5)
    big   = New-Object Drawing.Font('Segoe UI Semibold', 13)
}
$center = New-Object Drawing.StringFormat -Property @{ Alignment = 'Center' }
$rightFmt = New-Object Drawing.StringFormat -Property @{ Alignment = 'Far' }

function New-Round($x, $y, $w, $h, $r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Min($r * 2, [Math]::Min($w, $h))
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); $p
}
function Fill-Round($g, $color, $x, $y, $w, $h, $r) {
    $b = New-Object Drawing.SolidBrush $color; $p = New-Round $x $y $w $h $r; $g.FillPath($b, $p); $p.Dispose(); $b.Dispose()
}
function Draw-Text($g, $text, $font, $color, $x, $y, $fmt = $null) {
    $b = New-Object Drawing.SolidBrush $color
    if ($fmt) { $g.DrawString($text, $font, $b, [single]$x, [single]$y, $fmt) } else { $g.DrawString($text, $font, $b, [single]$x, [single]$y) }
    $b.Dispose()
}
function Draw-Dot($g, $color, $x, $y) { $b = New-Object Drawing.SolidBrush $color; $g.FillEllipse($b, $x, $y, 7, 7); $b.Dispose() }
function Add-Hit($x, $y, $w, $h, $action, $tip) { $script:hits += [pscustomobject]@{ rect = New-Object Drawing.Rectangle($x, $y, $w, $h); action = $action; tip = $tip } }

$whereColor = @{ Antigravity = (RGB 120 150 230); Terminal = (RGB 150 150 150); Desktop = (RGB 217 119 87) }

# Draws the panel (or just measures it when $g is $null). Returns its height.
function Draw-Panel($g) {
    $pad = 16; $inner = $panelW - $pad * 2; $script:hits = @()
    if ($g) {
        Draw-Dot $g $c.accent $pad 20
        Draw-Text $g 'Claude status' $f.title $c.text ($pad + 14) 13
        Draw-Text $g $script:note $f.small $c.dim ($panelW - $pad) 18 $rightFmt
    }
    $y = 46
    if ($g) { Draw-Text $g 'PLUGINS  (new sessions)' $f.head $c.dim $pad $y }
    $y += 18; $x = $pad
    foreach ($k in $plugins.Keys) {
        $on = Get-PluginState $plugins[$k]
        $label = "$k  " + $(if ($null -eq $on) { 'n/a' } elseif ($on) { 'ON' } else { 'OFF' })
        $w = 100
        if ($g) {
            Fill-Round $g $(if ($on) { RGB 58 48 42 } else { $c.pill }) $x $y $w 26 13
            Draw-Dot $g $(if ($on) { $c.accent } else { $c.track }) ($x + 10) ($y + 10)
            Draw-Text $g $label $f.bold $(if ($on) { $c.text } else { $c.sub }) ($x + 22) ($y + 5)
        }
        $id = $plugins[$k]; Add-Hit $x $y $w 26 ([scriptblock]::Create("Switch-Plugin '$id'; `$script:note = 'Saved - applies to new sessions'")) "Turn $k on/off"
        $x += $w + 8
    }
    $gr = Test-Path "$env:USERPROFILE\.claude\skills\graphify"
    if ($g) {
        Fill-Round $g $c.pill $x $y ($panelW - $pad - $x) 26 13
        Draw-Dot $g $(if ($gr) { $c.green } else { $c.track }) ($x + 10) ($y + 10)
        Draw-Text $g 'graphify' $f.label $c.sub ($x + 22) ($y + 5)
    }
    $y += 40

    if ($g) { Draw-Text $g "SESSIONS  ($(@($script:sessions).Count) running)" $f.head $c.dim $pad $y }
    $y += 18
    if (-not $script:sessions) { if ($g) { Draw-Text $g 'No Claude sessions running.' $f.label $c.dim $pad $y }; $y += 24 }
    foreach ($s in $script:sessions) {
        $connH = 18 * [Math]::Max(1, $s.conns.Count)
        $cardH = 48 + $connH
        if ($g) {
            Fill-Round $g $c.surface $pad $y $inner $cardH 8
            $wc = $whereColor[$s.where]; if (-not $wc) { $wc = $c.sub }
            $tw = $g.MeasureString($s.where, $f.small).Width + 12
            Fill-Round $g $wc ($pad + 10) ($y + 9) $tw 17 8
            Draw-Text $g $s.where $f.small ([Drawing.Color]::White) ($pad + 10 + $tw / 2) ($y + 11) $center
            Draw-Text $g "$($s.name)" $f.bold $c.text ($pad + 16 + $tw) ($y + 8)
            Draw-Dot $g $(if ($s.status -eq 'busy') { $c.amber } else { $c.green }) ($panelW - $pad - 52) ($y + 13)
            Draw-Text $g $s.status $f.small $c.sub ($panelW - $pad - 10) ($y + 9) $rightFmt
            Draw-Text $g ("$(Split-Path $s.cwd -Leaf)  -  $("$($s.id)".PadRight(8).Substring(0, 8))") $f.small $c.dim ($pad + 10) ($y + 29)
        }
        $sid = $s.id
        Add-Hit $pad $y $inner 44 ([scriptblock]::Create("Set-Clipboard '$sid'; `$script:note = 'Session id copied'")) 'Copy session id'
        # Per-session mode pills, right of the folder line; drawn after the card hit so their clicks win.
        $px = $panelW - $pad - 10
        foreach ($k in 'Ponytail', 'Caveman') {
            $mode = if ($k -eq 'Caveman') { $s.modes.cave } else { $s.modes.pony }
            $pw = 64
            $px -= $pw
            if ($g) {
                Fill-Round $g $(if ($mode) { RGB 58 48 42 } else { $c.pill }) $px ($y + 26) $pw 17 8
                Draw-Dot $g $(if ($mode) { $c.accent } else { $c.track }) ($px + 7) ($y + 31)
                Draw-Text $g $k $f.small $(if ($mode) { $c.text } else { $c.dim }) ($px + 17) ($y + 28)
            }
            $cwdArg = "$($s.cwd)".Replace("'", "''")
            Add-Hit $px ($y + 26) $pw 17 ([scriptblock]::Create("`$script:note = Switch-SessionMode '$k' '$sid' '$cwdArg' `$$([bool]$mode)")) "$k is $(if ($mode) { "on ($mode)" } else { 'off' }) here. Click to switch, then paste the copied command in that session."
            $px -= 6
        }
        $cy = $y + 46
        if (-not $s.conns.Count -and $g) { Draw-Text $g 'no connections' $f.small $c.dim ($pad + 10) $cy }
        foreach ($cn in $s.conns) {
            if ($g) {
                Draw-Dot $g $(if ($cn.on) { $c.green } else { $c.red }) ($pad + 12) ($cy + 4)
                Draw-Text $g $cn.name $f.label $c.text ($pad + 24) ($cy - 1)
                if ($cn.detail) { Draw-Text $g $cn.detail $f.small $c.sub ($pad + 120) ($cy + 1) }
            }
            if ($cn.vault) {
                $v = $cn.vault.Replace("'", "''")
                Add-Hit ($pad + 6) $cy ($inner - 12) 18 ([scriptblock]::Create("Open-Vault '$v'; `$script:note = 'Vault opening - then /mcp > Reconnect'")) 'Open this vault in Obsidian'
            }
            $cy += 18
        }
        $y += $cardH + 8
    }
    if ($g) {
        Draw-Text $g 'Click a session to copy its id. Click obsidian to open its vault.' $f.small $c.dim $pad ($y + 2)
        Draw-Text $g 'Click Ponytail/Caveman to switch it for that session.' $f.small $c.dim $pad ($y + 16)
    }
    $y + 38
}

function Draw-Tab($g) {
    $n = @($script:sessions).Count; $cx = $tabW / 2
    Draw-Text $g "$n" $f.big $c.text $cx 14 $center
    Draw-Text $g 'live' $f.small $c.dim $cx 38 $center
    $down = @($script:sessions | ForEach-Object { $_.conns } | Where-Object { -not $_.on }).Count
    Draw-Dot $g $(if ($down) { $c.red } elseif ($n) { $c.green } else { $c.track }) ($cx - 3.5) 60
    $grip = New-Object Drawing.SolidBrush $c.track
    foreach ($gy in 82, 87) { $g.FillEllipse($grip, $cx - 5, $gy, 3, 3); $g.FillEllipse($grip, $cx + 2, $gy, 3, 3) }
    $grip.Dispose()
}

# ---------- window (same behavior as the usage widget) ----------

$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form = New-Object Windows.Forms.Form -Property @{
    Text = 'Claude Status'; FormBorderStyle = 'None'; ShowInTaskbar = $false; StartPosition = 'Manual'; TopMost = $true
    BackColor = $c.bg; Size = "$tabW,$tabH"
}
$form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($form, $true)
$form.Add_Paint({
    $g = $_.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    if ($script:expanded) { [void](Draw-Panel $g) } else { $g.Clear($c.surface); Draw-Tab $g }
})
$tip = New-Object Windows.Forms.ToolTip

$script:expanded = $false; $script:sessions = @(); $script:hits = @(); $script:note = ''
$script:tabX = $wa.Right - $tabW; $script:tabY = $wa.Top + [int](($wa.Height - $tabH) / 2) - 130
try {
    $x, $y = (Get-Content $posFile -ErrorAction Stop).Split(',') | ForEach-Object { [int]$_ }
    if ([Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($x + 1, $y + 1) }) { $script:tabX = $x; $script:tabY = $y }
} catch {}

function Get-TabScreen { [Windows.Forms.Screen]::FromPoint((New-Object Drawing.Point(($script:tabX + $tabW / 2), ($script:tabY + 10)))).WorkingArea }
# The other widget's tab (from its saved position, with an 8 px margin), so tabs and open panels keep clear of it.
$otherPosFile = "$PSScriptRoot\..\usage-widget\position.txt"
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
    $script:expanded = $open
    $area = Get-TabScreen
    $form.Size = if ($open) { New-Object Drawing.Size($panelW, [Math]::Min($area.Height, (Draw-Panel $null))) } else { New-Object Drawing.Size($tabW, $tabH) }
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
}

function Update-Widget {
    try { $script:sessions = @(Get-Sessions | Sort-Object where, name) } catch { $script:note = 'Could not read sessions' }
    Set-Expanded $script:expanded
}

# Click: on the panel runs the item under the mouse (or closes it); on the tab opens it. Drag moves; snaps near edges.
$script:drag = $null; $script:pressAt = $null; $script:moved = $false
$form.Add_MouseDown({
    if ($_.Button -ne 'Left') { return }
    $p = [Windows.Forms.Cursor]::Position
    $script:pressAt = $p; $script:moved = $false
    $script:drag = New-Object Drawing.Point(($p.X - $form.Left), ($p.Y - $form.Top))
})
$form.Add_MouseMove({
    if ($null -eq $script:drag) {
        $pt = $form.PointToClient([Windows.Forms.Cursor]::Position)
        $h = if ($script:expanded) { $script:hits | Where-Object { $_.rect.Contains($pt) } | Select-Object -Last 1 }
        $form.Cursor = if ($h) { 'Hand' } else { 'Default' }
        if ($h -and $tip.GetToolTip($form) -ne $h.tip) { $tip.SetToolTip($form, $h.tip) } elseif (-not $h) { $tip.SetToolTip($form, '') }
        return
    }
    $p = [Windows.Forms.Cursor]::Position
    if (-not $script:moved) {
        if ([Math]::Abs($p.X - $script:pressAt.X) + [Math]::Abs($p.Y - $script:pressAt.Y) -lt 5) { return }
        $script:moved = $true
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
    if (-not $script:moved) {
        if (-not $script:expanded) { Set-Expanded $true; return }
        $pt = $form.PointToClient([Windows.Forms.Cursor]::Position)
        $h = $script:hits | Where-Object { $_.rect.Contains($pt) } | Select-Object -Last 1
        if ($h) { & $h.action; Update-Widget } else { Set-Expanded $false }
        return
    }
    $script:tabX = $form.Left; $script:tabY = $form.Top
    $area = Get-TabScreen
    if ($script:tabX - $area.Left -lt 40) { $script:tabX = $area.Left }
    elseif ($area.Right - ($script:tabX + $tabW) -lt 40) { $script:tabX = $area.Right - $tabW }
    Clear-OtherTab $area
    Set-Expanded $false
    $script:tabX = $form.Left; $script:tabY = $form.Top
    try { Set-Content $posFile "$($script:tabX),$($script:tabY)" } catch {}
})

$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Refresh', $null, { $script:probeCache = @{}; Update-Widget })
[void]$menu.Items.Add('Exit', $null, { [Windows.Forms.Application]::Exit() })
$form.ContextMenuStrip = $menu
$form.Add_Deactivate({ if ($script:expanded -and -not $menu.Visible) { Set-Expanded $false } })

$timer = New-Object Windows.Forms.Timer -Property @{ Interval = $refreshMs }
$timer.Add_Tick({ if (-not $script:drag) { Update-Widget } })

# Other always-on-top windows (taskbar, Start, other apps) can bury a TopMost form; re-raise it without taking focus.
# Skipped while the right-click menu is open so the form doesn't cover it.
$raise = New-Object Windows.Forms.Timer -Property @{ Interval = 1500 }
$raise.Add_Tick({ if (-not $menu.Visible) { [void][Win32.Dwm]::SetWindowPos($form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13) } })

$round = 2; [void][Win32.Dwm]::DwmSetWindowAttribute($form.Handle, 33, [ref]$round, 4)
$border = 0x00302E2C; [void][Win32.Dwm]::DwmSetWindowAttribute($form.Handle, 34, [ref]$border, 4)

Update-Widget
$form.Show()
$timer.Start()
$raise.Start()
[Windows.Forms.Application]::Run()
