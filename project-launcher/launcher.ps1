# Project Launcher: pick a folder in Documents and open it in Antigravity, a terminal or Claude Desktop with Claude running.
# Before launching it opens the project's Obsidian vault and links Claude's "obsidian" connection to it.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
. (Join-Path $PSScriptRoot 'vault-tools.ps1')

# Start the Usage and Status widgets through their desktop shortcuts if they aren't already running.
$running = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'").CommandLine -join "`n"
foreach ($w in @{ 'usage-widget.ps1' = 'Claude Usage'; 'status-widget.ps1' = 'Claude Status' }.GetEnumerator()) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$($w.Value).lnk"
    if ($running -notlike "*$($w.Key)*" -and (Test-Path $lnk)) { Start-Process $lnk }
}

$root = [Environment]::GetFolderPath('MyDocuments')
$ide  = "$env:LOCALAPPDATA\Programs\Antigravity IDE\Antigravity IDE.exe"

# Runs `claude` in the IDE terminal when the folder opens (VS Code folderOpen task).
$tasksJson = @'
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Claude",
      "type": "shell",
      "command": "__CMD__",
      "presentation": { "reveal": "always", "focus": true, "panel": "dedicated" },
      "runOptions": { "runOn": "folderOpen" }
    }
  ]
}
'@

function Test-LauncherTasks($tasks) { (Test-Path $tasks) -and ((Get-Content $tasks -Raw) -match '"label": "Claude"') }

# -c continues the folder's last chat (starts a new one if there is none).
function Get-ClaudeCmd { 'claude --dangerously-skip-permissions' + $(if ($resume.Checked) { ' -c' }) }

# Opens and links the project's vault first, so Claude's obsidian connection is up when the session starts.
function Connect-Vault($path, $waitSec = 20) {
    if (-not (Find-Vault $path)) { return }
    $status.Text = 'Opening Obsidian vault...'; $status.Visible = $true; $form.Cursor = 'WaitCursor'; $form.Refresh()
    try { [void](Connect-ProjectVault $path $waitSec) } catch {}
    $status.Text = ''; $status.Visible = $false; $form.Cursor = 'Default'
}

# Other Claude Code profiles: ~/.claude-<name> folders signed in to another account (used through CLAUDE_CONFIG_DIR).
$profiles = @(Get-ChildItem $env:USERPROFILE -Directory -Force -Filter '.claude-*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName '.credentials.json') })

# Opens a terminal in the project with Claude already running, as the account picked for Terminal;
# falls back to plain PowerShell without Windows Terminal.
function Open-InTerminal($name, $vaultWaitSec = 20) {
    $path = Join-Path $root $name
    Connect-Vault $path $vaultWaitSec
    $cmd  = Get-ClaudeCmd
    if ($account.SelectedIndex -gt 0) { $cmd = "`$env:CLAUDE_CONFIG_DIR = '$($profiles[$account.SelectedIndex - 1].FullName)'; $cmd" }
    Start-Shell $path $cmd
    $form.Close()
}

function Start-Shell($dir, $cmd) {
    # Encoded so wt.exe doesn't split the command at ';' (its own tab separator).
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        Start-Process wt.exe -ArgumentList "-d `"$dir`" powershell.exe -NoExit -EncodedCommand $enc"
    } else {
        Start-Process powershell.exe -WorkingDirectory $dir -ArgumentList '-NoExit', '-EncodedCommand', $enc
    }
}

# Opens Claude in a new, empty profile ~/.claude-<name> so the user can sign in to another account there;
# the other logins are untouched. The account joins the list once signed in (next time the launcher opens).
function Add-Account {
    $dlg = New-Window 'Add account' 380 170
    $dlg.StartPosition = 'CenterParent'
    $box = New-Field $dlg 18 50 344 'Account name, e.g. work'
    $ok = New-Button $dlg 'Sign in' 18 104 344 $true
    $ok.DialogResult = 'OK'; $dlg.AcceptButton = $ok
    $dlg.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $dlg.Close() } })
    $dlg.Add_Shown({ $box.Focus() })
    if ($dlg.ShowDialog($form) -ne 'OK' -or -not $box.Text.Trim()) { return }
    $name = $box.Text.Trim()
    if ($name -notmatch '^[A-Za-z0-9_-]+$') { [void][Windows.Forms.MessageBox]::Show('Use only letters, numbers, - and _.', 'Add account'); return }
    $dir = "$env:USERPROFILE\.claude-$name"
    if (Test-Path "$dir\.credentials.json") { [void][Windows.Forms.MessageBox]::Show("'$name' is already signed in.", 'Add account'); return }
    Start-Shell $env:USERPROFILE "`$env:CLAUDE_CONFIG_DIR = '$dir'; claude"
    [void][Windows.Forms.MessageBox]::Show("Sign in with the new account in the window that opened (type /login if no login screen shows), then type /exit.`n`nOpen Project lists '$name' the next time you open it.", 'Add account')
}

# Opens a Claude Desktop code session in the project (its own deep link). Resume picks the folder's newest chat.
# shortcut: Desktop uses its own permission mode setting; --dangerously-skip-permissions can't be passed through a link.
function Open-InDesktop($name, $vaultWaitSec = 20) {
    $path = Join-Path $root $name
    Connect-Vault $path $vaultWaitSec
    $url = "claude://code/new?folder=$([uri]::EscapeDataString($path))"
    if ($resume.Checked) {
        $dir = Join-Path "$env:USERPROFILE\.claude\projects" ($path -replace '[^A-Za-z0-9]', '-')
        $last = Get-ChildItem $dir -Filter *.jsonl -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($last) { $url = "claude://code/continue?session=$($last.BaseName)" }
    }
    Start-Process $url
    $form.Close()
}

function Open-Project($name, $vaultWaitSec = 20) {
    $path  = Join-Path $root $name
    Connect-Vault $path $vaultWaitSec
    $tasks = Join-Path $path '.vscode\tasks.json'
    # shortcut: a tasks.json the launcher didn't write is left untouched, so Claude won't auto-start there; add the task by hand if wanted.
    if (-not (Test-Path $tasks) -or (Test-LauncherTasks $tasks)) {
        New-Item -ItemType Directory -Force (Split-Path $tasks) | Out-Null
        [IO.File]::WriteAllText($tasks, $tasksJson.Replace('__CMD__', (Get-ClaudeCmd)))  # no BOM
    }
    Start-Process -FilePath $ide -ArgumentList "`"$path`""
    $form.Close()
}

# ---------- look (matches the Claude Usage / Status widgets) ----------

Add-Type -Namespace Win32 -Name LauncherDwm -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wp, string lp);
'@
[Windows.Forms.Application]::EnableVisualStyles()  # needed for the search placeholder
function RGB($r, $g, $b) { [Drawing.Color]::FromArgb($r, $g, $b) }
$c = @{
    bg = RGB 28 27 26; hover = RGB 40 38 36; select = RGB 56 44 39; field = RGB 44 42 40
    text = RGB 238 234 228; sub = RGB 176 169 160; dim = RGB 128 121 114; green = RGB 110 190 120
    accent = RGB 217 119 87; accentHover = RGB 230 135 104; btn = RGB 56 53 50; btnHover = RGB 70 66 62
}
$font   = New-Object Drawing.Font('Segoe UI', 10.5)
$fName  = New-Object Drawing.Font('Segoe UI Semibold', 10.5)
$fSub   = New-Object Drawing.Font('Segoe UI', 8)
$fTitle = New-Object Drawing.Font('Segoe UI Semibold', 11)

function New-Round($x, $y, $w, $h, $r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90); $p.AddArc($x + $w - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
    $p.AddArc($x + $w - 2 * $r, $y + $h - 2 * $r, 2 * $r, 2 * $r, 0, 90); $p.AddArc($x, $y + $h - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $p.CloseFigure(); $p
}

# Borderless window with rounded corners and its own title row: drag it to move, x to close.
function New-Window($title, $w, $h) {
    $win = New-Object Windows.Forms.Form -Property @{
        Text = $title; Size = "$w,$h"; StartPosition = 'CenterScreen'; FormBorderStyle = 'None'
        BackColor = $c.bg; ForeColor = $c.text; Font = $font; KeyPreview = $true
    }
    $win.Add_HandleCreated({
        $v = 2; [void][Win32.LauncherDwm]::DwmSetWindowAttribute($this.Handle, 33, [ref]$v, 4)          # rounded corners
        $v = 0x00343230; [void][Win32.LauncherDwm]::DwmSetWindowAttribute($this.Handle, 34, [ref]$v, 4) # border color
    })
    $dot = New-Object Windows.Forms.Panel -Property @{ Location = '20,19'; Size = '9,9'; BackColor = $c.accent }
    $dot.Region = New-Object Drawing.Region (New-Round 0 0 9 9 4)
    $lbl = New-Object Windows.Forms.Label -Property @{ Text = $title; Location = '34,12'; AutoSize = $true; Font = $fTitle }
    $x = New-Object Windows.Forms.Label -Property @{
        Text = [string][char]0x2715; Location = "$($w - 42),10"; Size = '28,26'; TextAlign = 'MiddleCenter'; ForeColor = $c.dim; Cursor = 'Hand'
    }
    $x.Add_Click({ $this.FindForm().Close() })
    $x.Add_MouseEnter({ $this.ForeColor = $c.text }); $x.Add_MouseLeave({ $this.ForeColor = $c.dim })
    foreach ($ctl in @($win, $lbl)) {
        $ctl.Add_MouseDown({ if ($_.Button -eq 'Left') { $script:dragFrom = [Windows.Forms.Cursor]::Position } })
        $ctl.Add_MouseMove({
            if ($script:dragFrom) {
                $p = [Windows.Forms.Cursor]::Position; $f = $this.FindForm(); if (-not $f) { $f = $this }
                $f.Left += $p.X - $script:dragFrom.X; $f.Top += $p.Y - $script:dragFrom.Y; $script:dragFrom = $p
            }
        })
        $ctl.Add_MouseUp({ $script:dragFrom = $null })
    }
    $win.Controls.AddRange(@($dot, $lbl, $x))
    $win
}

function New-Button($parent, $text, $x, $y, $w, $primary) {
    $b = New-Object Windows.Forms.Button -Property @{
        Text = $text; Location = "$x,$y"; Size = "$w,38"; FlatStyle = 'Flat'; Cursor = 'Hand'; Font = $fName
        BackColor = $(if ($primary) { $c.accent } else { $c.btn }); ForeColor = [Drawing.Color]::White
    }
    $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.BorderColor = $b.BackColor  # no white ring on the default button
    $b.FlatAppearance.MouseOverBackColor = $(if ($primary) { $c.accentHover } else { $c.btnHover })
    $b.Region = New-Object Drawing.Region (New-Round 0 0 $w 38 8)
    $parent.Controls.Add($b); $b
}

# Text field: a rounded panel holding a borderless text box with a placeholder.
function New-Field($parent, $x, $y, $w, $placeholder) {
    $panel = New-Object Windows.Forms.Panel -Property @{ Location = "$x,$y"; Size = "$w,38"; BackColor = $c.field }
    $panel.Region = New-Object Drawing.Region (New-Round 0 0 $w 38 9)
    $tb = New-Object Windows.Forms.TextBox -Property @{
        Location = '14,9'; Width = ($w - 28); BorderStyle = 'None'; BackColor = $c.field; ForeColor = $c.text; Font = $font
    }
    # EM_SETCUEBANNER: gray placeholder text, kept while focused
    $tb.Add_HandleCreated({ [void][Win32.LauncherDwm]::SendMessage($this.Handle, 0x1501, [IntPtr]1, $placeholder) }.GetNewClosure())
    $panel.Controls.Add($tb)
    $parent.Controls.Add($panel); $tb
}

# ---------- project info for the list ----------

function Format-Ago($t) {
    if (-not $t) { return 'no Claude chats yet' }
    $d = (Get-Date) - $t
    if ($d.TotalMinutes -lt 1) { 'just now' }
    elseif ($d.TotalHours -lt 1) { "$([int][Math]::Floor($d.TotalMinutes))m ago" }
    elseif ($d.TotalDays -lt 1) { "$([int][Math]::Floor($d.TotalHours))h ago" }
    elseif ($d.TotalDays -lt 30) { "$([int][Math]::Floor($d.TotalDays))d ago" }
    else { $t.ToString('MMM d') }
}

# Name, vault, last Claude chat time, and whether a Claude session is running there now.
function Get-ProjectInfo($names) {
    $live = @(Get-ChildItem "$env:USERPROFILE\.claude\sessions\*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        $s = try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null }
        if ($s -and (Get-Process -Id $s.pid -ErrorAction SilentlyContinue)) { "$($s.cwd)".TrimEnd('\').ToLower() }
    })
    foreach ($n in $names) {
        $path = Join-Path $root $n
        $chat = Get-ChildItem (Join-Path "$env:USERPROFILE\.claude\projects" ($path -replace '[^A-Za-z0-9]', '-')) -Filter *.jsonl -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $vault = Find-Vault $path
        [pscustomobject]@{
            name = $n; last = $(if ($chat) { $chat.LastWriteTime }); running = $live -contains $path.ToLower()
            vault = $(if ($vault) { Split-Path $vault -Leaf })
        }
    }
}

# ---------- main window ----------

$W = 440; $H = 600
$form = New-Window 'Open Project' $W $H
$search = New-Field $form 18 50 ($W - 36) 'Search projects'

# The list is wider than its holder so the white system scrollbar is clipped off; the wheel and keys still scroll.
$listHolder = New-Object Windows.Forms.Panel -Property @{ Location = '18,100'; Size = "$($W - 36),$($H - 218)" }
$list = New-Object Windows.Forms.ListBox -Property @{
    Location = '0,0'; Size = "$($W - 36 + [Windows.Forms.SystemInformation]::VerticalScrollBarWidth),$($H - 218)"; BackColor = $c.bg; ForeColor = $c.text
    BorderStyle = 'None'; IntegralHeight = $false; DrawMode = 'OwnerDrawFixed'; ItemHeight = 52
}
$script:hoverIndex = -1
$list.Add_MouseMove({ $i = $list.IndexFromPoint($_.Location); if ($i -ne $script:hoverIndex) { $script:hoverIndex = $i; $list.Invalidate() } })
$list.Add_MouseLeave({ $script:hoverIndex = -1; $list.Invalidate() })
$list.Add_DrawItem({
    if ($_.Index -lt 0) { return }
    $g = $_.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
    $p = $list.Items[$_.Index]; $r = $_.Bounds
    $g.FillRectangle((New-Object Drawing.SolidBrush $c.bg), $r)
    $r = New-Object Drawing.Rectangle $r.X, $r.Y, $listHolder.Width, $r.Height  # draw within the visible part
    $sel = ($_.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
    $back = if ($sel) { $c.select } elseif ($_.Index -eq $script:hoverIndex) { $c.hover }
    if ($back) { $g.FillPath((New-Object Drawing.SolidBrush $back), (New-Round $r.X ($r.Y + 2) ($r.Width - 1) ($r.Height - 4) 9)) }
    if ($sel) { $g.FillPath((New-Object Drawing.SolidBrush $c.accent), (New-Round ($r.X + 4) ($r.Y + 15) 3 ($r.Height - 30) 1)) }
    $g.DrawString($p.name, $fName, (New-Object Drawing.SolidBrush $c.text), [single]($r.X + 16), [single]($r.Y + 8))
    $sub = Format-Ago $p.last
    if ($p.vault) { $sub += "    $([char]0x25C6) $($p.vault)" }
    $g.DrawString($sub, $fSub, (New-Object Drawing.SolidBrush $c.dim), [single]($r.X + 16), [single]($r.Y + 29))
    if ($p.running) {
        $g.FillEllipse((New-Object Drawing.SolidBrush $c.green), [single]($r.Right - 70), [single]($r.Y + 22), 8, 8)
        $g.DrawString('running', $fSub, (New-Object Drawing.SolidBrush $c.sub), [single]($r.Right - 58), [single]($r.Y + 18))
    }
})
$listHolder.Controls.Add($list); $form.Controls.Add($listHolder)

$resume = New-Object Windows.Forms.CheckBox -Property @{
    Text = 'Resume last session'; Location = "18,$($H - 108)"; AutoSize = $true; ForeColor = $c.sub; FlatStyle = 'Flat'; Cursor = 'Hand'
}
$resume.FlatAppearance.BorderColor = $c.dim; $resume.FlatAppearance.CheckedBackColor = $c.accent
# Status covers the key hints while a vault opens, leaving the resume row for the account picker.
$status = New-Object Windows.Forms.Label -Property @{ Location = "18,$($H - 26)"; Size = "$($W - 36),18"; ForeColor = $c.accent; BackColor = $c.bg; Font = $fSub; Visible = $false }
$account = New-Object Windows.Forms.ComboBox -Property @{
    DropDownStyle = 'DropDownList'; FlatStyle = 'Flat'; Location = "$($W - 198),$($H - 110)"; Width = 180
    BackColor = $c.field; ForeColor = $c.text; Font = $fSub; Cursor = 'Hand'
}
[void]$account.Items.Add('Terminal: main account')
foreach ($p in $profiles) { [void]$account.Items.Add('Terminal: ' + $p.Name.Substring(8)) }
[void]$account.Items.Add('+ Add account...')
$account.SelectedIndex = 0
# The last item is an action, not an account: run it and go back to the main account.
$account.Add_SelectionChangeCommitted({ if ($account.SelectedIndex -eq $account.Items.Count - 1) { $account.SelectedIndex = 0; Add-Account } })
$form.Controls.Add($account)
$keys = New-Object Windows.Forms.Label -Property @{
    Text = 'Enter  Antigravity      Ctrl+Enter  Terminal      Shift+Enter  Desktop'; Location = "18,$($H - 26)"; AutoSize = $true; ForeColor = $c.dim; Font = $fSub
}
$form.Controls.AddRange(@($resume, $status, $keys))

$by = $H - 74
$button     = New-Button $form 'Antigravity' 18 $by 118 $true
$termButton = New-Button $form 'Terminal' 142 $by 96 $false
$deskButton = New-Button $form 'Desktop' 244 $by 96 $false
$newButton  = New-Button $form '+ New' 346 $by 76 $false

# Asks for the new project's name and where to open it. Returns @{ name; target } or $null.
function Read-ProjectName {
    $dlg = New-Window 'New project' 380 200
    $dlg.StartPosition = 'CenterParent'
    $box = New-Field $dlg 18 50 344 'Project name'
    $hint = New-Object Windows.Forms.Label -Property @{ Text = 'Create and open in:'; Location = '18,100'; AutoSize = $true; ForeColor = $c.dim; Font = $fSub }
    $dlg.Controls.Add($hint)
    $script:newTarget = $null
    $x = 18
    foreach ($t in @(@('Antigravity', 124, $true), @('Terminal', 107, $false), @('Desktop', 107, $false))) {
        $b = New-Button $dlg $t[0] $x 128 $t[1] $t[2]
        $b.DialogResult = 'OK'; $b.Tag = $t[0]
        $b.Add_Click({ $script:newTarget = $this.Tag })
        if ($t[2]) { $dlg.AcceptButton = $b }
        $x += $t[1] + 6
    }
    $dlg.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $dlg.Close() } })
    $dlg.Add_Shown({ $box.Focus() })
    if ($dlg.ShowDialog($form) -eq 'OK' -and $box.Text.Trim()) {
        @{ name = $box.Text.Trim(); target = $(if ($script:newTarget) { $script:newTarget } else { 'Antigravity' }) }
    }
}

# Makes Documents\<name> with an Obsidian vault Documents\<name>\<name>, then opens it where the user picked.
function New-Project {
    $pick = Read-ProjectName
    if (-not $pick) { return }
    $name = $pick.name
    if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name.EndsWith('.')) {
        [void][Windows.Forms.MessageBox]::Show("A folder name can't contain \ / : * ? `" < > | or end with a dot.", 'New project'); return
    }
    if (Test-Path (Join-Path $root $name)) {
        [void][Windows.Forms.MessageBox]::Show("Documents already has a folder named '$name'.", 'New project'); return
    }
    New-Item -ItemType Directory (Join-Path $root $name) | Out-Null
    [void](New-ProjectVault (Join-Path $root $name) $name)
    [void][Windows.Forms.MessageBox]::Show("Obsidian will open the new vault '$name'.`n`nClick 'Trust author and enable plugins' there so Claude can connect to it.", 'New project')
    switch ($pick.target) {
        'Terminal' { Open-InTerminal $name 90 }
        'Desktop'  { Open-InDesktop $name 90 }
        default    { Open-Project $name 90 }
    }
}

# Only real projects: folders Claude Code has trusted, or ones this launcher set up.
$trusted = try {
    (Get-Content "$env:USERPROFILE\.claude.json" -Raw | ConvertFrom-Json).projects.PSObject.Properties |
        Where-Object { $_.Value.hasTrustDialogAccepted } | ForEach-Object { $_.Name.Replace('/', '\').TrimEnd('\').ToLower() }
} catch { @() }
$names = Get-ChildItem $root -Directory |
    Where-Object { ($trusted -contains $_.FullName.ToLower()) -or (Test-LauncherTasks (Join-Path $_.FullName '.vscode\tasks.json')) } |
    ForEach-Object Name
# Most recently used with Claude first; never-used ones last.
$all = @(Get-ProjectInfo $names | Sort-Object @{ Expression = { if ($_.last) { $_.last } else { [datetime]::MinValue } }; Descending = $true })
function Fill {
    $list.Items.Clear()
    $all | Where-Object { $_.name -like "*$($search.Text)*" } | ForEach-Object { [void]$list.Items.Add($_) }
    if ($list.Items.Count) { $list.SelectedIndex = 0 }
}
Fill

$go     = { if ($list.SelectedItem) { Open-Project $list.SelectedItem.name } }
$goTerm = { if ($list.SelectedItem) { Open-InTerminal $list.SelectedItem.name } }
$goDesk = { if ($list.SelectedItem) { Open-InDesktop $list.SelectedItem.name } }
$search.Add_TextChanged({ Fill })
$list.Add_DoubleClick($go)
$button.Add_Click($go)
$termButton.Add_Click($goTerm)
$deskButton.Add_Click($goDesk)
$newButton.Add_Click({ New-Project })
$form.Add_KeyDown({
    switch ($_.KeyCode) {
        'Enter'  { if ($_.Control) { & $goTerm } elseif ($_.Shift) { & $goDesk } else { & $go }; $_.SuppressKeyPress = $true }
        'Escape' { $form.Close() }
        'Down'   { if ($list.SelectedIndex -lt $list.Items.Count - 1) { $list.SelectedIndex++ }; $_.Handled = $true }
        'Up'     { if ($list.SelectedIndex -gt 0) { $list.SelectedIndex-- }; $_.Handled = $true }
    }
})

$form.Add_Shown({ $search.Focus() })
[void]$form.ShowDialog()
