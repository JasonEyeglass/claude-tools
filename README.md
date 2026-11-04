# claude-tools

Small Windows helpers for Claude Code. They're written in PowerShell 5.1 with WinForms, and nothing needs installing.

| Tool | Script | What it does |
|------|--------|--------------|
| Open Project | `project-launcher/launcher.ps1` | Lists your Claude projects in Documents. It opens the one you pick in Antigravity IDE, Windows Terminal, or Claude Desktop, with `claude --dangerously-skip-permissions` already running. It also opens and links the project's Obsidian vault. **+ New** creates a project folder with its own vault. |
| Claude Usage | `usage-widget/usage-widget.ps1` | An always-on-top side tab and a tray icon. They show your 5-hour, weekly, and Fable usage limits for either Claude Code or Claude Desktop. |
| Claude Status | `status-widget/status-widget.ps1` | An always-on-top side tab. It shows running Claude sessions: where each one runs, its folder, its session ID, and its MCP connections. It also has toggles for the Ponytail and Caveman plugins. |

## Run

Create a shortcut with this target:

```
conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path>\usage-widget\usage-widget.ps1"
```

`conhost --headless` keeps the console window and its taskbar icon hidden.

## Needs

- Windows 10 or 11
- Claude Code, signed in. The usage widget reads your token from `~/.claude/.credentials.json` and never stores it anywhere else.
- Optional:
  - Antigravity IDE
  - Claude Desktop
  - Obsidian with the `mcp-tools-istefox` plugin, for the vault linking
