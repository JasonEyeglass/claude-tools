# Shared Obsidian vault helpers for the project launcher and the status widget.
# Each vault runs the mcp-tools-istefox plugin. Its live port changes with open order, so connections use the
# plugin's stable route instead: http://127.0.0.1:27200/v1/<routeId>/mcp with the vault's bearer token.

$script:pluginId = 'mcp-tools-istefox'

# First folder holding .obsidian: the project itself, then one or two levels down.
function Find-Vault($projectPath) {
    if (Test-Path (Join-Path $projectPath '.obsidian')) { return $projectPath }
    foreach ($depth in 1, 2) {
        $hit = Get-ChildItem $projectPath -Directory -Recurse -Depth $depth -Filter '.obsidian' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\node_modules\\' } | Select-Object -First 1
        if ($hit) { return $hit.Parent.FullName }
    }
}

function Get-VaultData($vaultPath) {
    $f = Join-Path $vaultPath ".obsidian\plugins\$script:pluginId\data.json"
    if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json }
}

# @{ url; token } for a vault, or $null until the plugin has run once in it.
function Get-VaultMcp($vaultPath) {
    $d = Get-VaultData $vaultPath
    $route = $d.mcpClientConfig.codexDiscovery.routeId
    if ($route -and $d.mcpTransport.bearerToken) {
        @{ url = "http://127.0.0.1:27200/v1/$route/mcp"; token = $d.mcpTransport.bearerToken; port = $d.mcpTransport.livePort }
    }
}

# Every vault Obsidian knows about, keyed for lookup by route id and by live port.
function Get-KnownVaults {
    $list = try { (Get-Content "$env:APPDATA\obsidian\obsidian.json" -Raw | ConvertFrom-Json).vaults.PSObject.Properties.Value.path } catch { @() }
    foreach ($p in $list) {
        $m = Get-VaultMcp $p
        [pscustomobject]@{ path = $p; name = Split-Path $p -Leaf; url = $m.url; port = $m.port }
    }
}

# Vault name an MCP url points at: matches the stable route, else the live port (which may drift).
function Resolve-VaultName($url, $vaults) {
    $hit = $vaults | Where-Object { $_.url -and $_.url -eq $url } | Select-Object -First 1
    if ($hit) { return $hit.name }
    if ($url -match ':(\d+)/mcp$') {
        $port = $matches[1]; $hits = @($vaults | Where-Object { "$($_.port)" -eq $port })
        if ($hits.Count -eq 1) { "$($hits[0].name) (port $port, may drift)" } else { "unclear (port $port)" }
    }
}

# Server name if the vault's MCP answers ("Obsidian - <vault>"), else $null.
function Test-VaultOnline($mcp, $timeoutSec = 2) {
    $body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"launcher","version":"1"}}}'
    try {
        $r = Invoke-WebRequest -Uri $mcp.url -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $timeoutSec -UseBasicParsing `
            -Headers @{ Authorization = "Bearer $($mcp.token)"; Accept = 'application/json, text/event-stream' }
        if ($r.Content -match '"name"\s*:\s*"([^"]+)"') { $matches[1] } else { 'online' }
    } catch { $null }
}

# obsidian://open?path= ignores folders Obsidian doesn't know, so new vaults are added to its vault list first.
function Open-Vault($vaultPath) {
    $cfgFile = "$env:APPDATA\obsidian\obsidian.json"
    $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
    if ($cfg.vaults.PSObject.Properties.Value.path -notcontains $vaultPath) {
        $id = -join ((1..16) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
        $ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
        $cfg.vaults | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{ path = $vaultPath; ts = $ts })
        [IO.File]::WriteAllText($cfgFile, ($cfg | ConvertTo-Json -Depth 10 -Compress))
        # A running Obsidian only reads its vault list at startup; it saves notes as you type, so a restart is safe.
        $running = Get-Process Obsidian -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($running) {
            $exe = $running.Path
            Stop-Process -Name Obsidian; Start-Sleep 3
            Start-Process $exe; Start-Sleep 6
        }
    }
    Start-Process "obsidian://open?path=$([uri]::EscapeDataString($vaultPath))"
}

# Points this project's "obsidian" connection (local scope: only this project, token stays out of project files)
# at its vault's stable route. Does nothing when it already matches.
function Set-ProjectObsidian($projectPath, $mcp) {
    $key = $projectPath.Replace('\', '/')
    $cur = try { (Get-Content "$env:USERPROFILE\.claude.json" -Raw | ConvertFrom-Json).projects.$key.mcpServers.obsidian } catch { $null }
    if ($cur.url -eq $mcp.url -and $cur.headers.Authorization -eq "Bearer $($mcp.token)") { return }
    Push-Location $projectPath
    try {
        if ($cur) { & claude mcp remove obsidian -s local 2>&1 | Out-Null }
        & claude mcp add --transport http -s local obsidian $mcp.url --header "Authorization: Bearer $($mcp.token)" 2>&1 | Out-Null
    } finally { Pop-Location }
}

# New vault <project>\<name> with the MCP plugin copied from an existing vault (code only; the plugin makes its own
# token and route the first time Obsidian loads it).
function New-ProjectVault($projectPath, $name) {
    $template = Get-KnownVaults | Where-Object { Test-Path (Join-Path $_.path ".obsidian\plugins\$script:pluginId\main.js") } | Select-Object -First 1
    $vault = Join-Path $projectPath $name
    $plugins = Join-Path $vault '.obsidian\plugins'
    New-Item -ItemType Directory -Force $plugins | Out-Null
    if ($template) {
        $dest = Join-Path $plugins $script:pluginId
        New-Item -ItemType Directory -Force $dest | Out-Null
        Get-ChildItem (Join-Path $template.path ".obsidian\plugins\$script:pluginId") -File |
            Where-Object { $_.Name -ne 'data.json' -and $_.Extension -ne '.log' } | Copy-Item -Destination $dest
        [IO.File]::WriteAllText((Join-Path $vault '.obsidian\community-plugins.json'), "[`n  `"$script:pluginId`"`n]")
    }
    $vault
}

# Opens the project's vault and links it; waits briefly for a fresh vault's plugin to come up. Returns the vault or $null.
function Connect-ProjectVault($projectPath, $waitSec = 20) {
    $vault = Find-Vault $projectPath
    if (-not $vault) {
        # Projects made outside the launcher get a <Name>\<Name> vault too, kept out of git locally.
        $name = Split-Path $projectPath -Leaf
        $vault = New-ProjectVault $projectPath $name
        $exclude = Join-Path $projectPath '.git\info\exclude'
        if (Test-Path (Split-Path $exclude)) { Add-Content $exclude "`n/$name/" }
    }
    $mcp = Get-VaultMcp $vault
    if (-not ($mcp -and (Test-VaultOnline $mcp 1))) { Open-Vault $vault }
    $deadline = (Get-Date).AddSeconds($waitSec)
    while (-not ($mcp -and (Test-VaultOnline $mcp 1)) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $mcp = Get-VaultMcp $vault
    }
    if ($mcp) { Set-ProjectObsidian $projectPath $mcp }
    $vault
}
