# Claude Traffic Light

A traffic light for [Claude Code](https://claude.com/claude-code) in the Windows taskbar.
Every Claude Code session gets its own colored dot in the system tray, so you can see at a glance
which sessions are working, which are done, and which are waiting for you — and click a dot to
jump straight to that session.

| Color | Meaning |
|---|---|
| 🟡 Yellow | **Working** — Claude is processing a prompt or running tools |
| 🔴 Red | **Needs you** — Claude is waiting for input or a permission decision |
| 🟢 Green | **Done** — Claude has finished and is waiting for your next message |
| ⚪ Grey | **No active session** — shown only when no sessions exist, so the menu is always reachable |

Each dot shows a short label such as `C1` or `F2`: the first letter of the project folder plus a
number. The same label and color appear in Claude Code's status line, so you always know which
dot belongs to which terminal:

```
● C1 · claude-traffic-light · Working
```

## Features

- **One dot per session**, with a project-based label (`C1`, `C2`, `F1`, …) that stays the same
  for the lifetime of the session.
- **Left-click a dot** to bring that session's window to the front (restored if minimized).
  - With the VS Code extension, it also switches to the **exact terminal tab** the session runs in,
    even when several Claude sessions share the same VS Code window.
  - For **background agents** (started from Claude Code's agent view or with `claude --bg`), it opens
    a `claude attach` tab for that agent in the editor area, next to the terminal you started it
    from. The tab is reused on the next click and closes itself when you detach (Ctrl+Z).
- **Right-click a dot** for a menu:
  - **Close dot** — hides that dot. It comes back (with the same label) if the session becomes active again.
  - **Stop agent** — background agents only; runs `claude stop`. The conversation is kept, so
    `claude attach` can reopen it.
  - **Reset (clear all sessions)** — removes all dots.
  - **Quit traffic light (all dots)** — exits the tray app. Your Claude sessions keep running.
- **Hover a dot** to see the label, project, status and full path.
- **Status line** in Claude Code showing the same label and color as the dot.
- **No duplicate dots after `/resume` or `/clear`.** The new session keeps the old dot's label, and
  dots for sessions Claude Code no longer considers active are removed automatically.
- Sessions that haven't been heard from in 12 hours are forgotten automatically.

## Requirements

- Windows 10 or 11
- [Claude Code](https://claude.com/claude-code) (CLI)
- [Git for Windows](https://git-scm.com/download/win) — the hook and status line scripts run in Git Bash
- Windows PowerShell 5.1 (included with Windows)
- Optional: [VS Code](https://code.visualstudio.com/) and [Node.js](https://nodejs.org/) to build and install the extension

## Installation

The examples below assume the repository is cloned to `C:\Projekt\claude-traffic-light`.
Adjust the paths if you put it somewhere else.

### 1. Clone the repository

```powershell
git clone https://github.com/woltrananton/claude-traffic-light.git C:\Projekt\claude-traffic-light
```

### 2. Add the hooks and status line to Claude Code

Add the following to `~/.claude/settings.json` (`C:\Users\<you>\.claude\settings.json`), merging it
with any settings you already have:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"C:/Projekt/claude-traffic-light/statusline.sh\"",
    "refreshInterval": 2
  },
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash \"C:/Projekt/claude-traffic-light/hook.sh\" start", "timeout": 10 }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "bash \"C:/Projekt/claude-traffic-light/hook.sh\" yellow", "timeout": 10 }] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "bash \"C:/Projekt/claude-traffic-light/hook.sh\" yellow", "timeout": 10 }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "bash \"C:/Projekt/claude-traffic-light/hook.sh\" red", "timeout": 10 }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "bash \"C:/Projekt/claude-traffic-light/hook.sh\" green", "timeout": 10 }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "bash \"C:/Projekt/claude-traffic-light/hook.sh\" end", "timeout": 10 }] }
    ]
  }
}
```

`bash` must be Git Bash. If `bash` on your `PATH` resolves to something else (for example WSL),
use the full path instead, e.g. `"C:/Program Files/Git/bin/bash.exe"`.

### 3. Start the tray app

Double-click `start-trafficlight.vbs`. It starts `trafficlight.ps1` without showing a PowerShell window.

To start it automatically at login, put a shortcut in your Startup folder:

```powershell
$startup = [Environment]::GetFolderPath('Startup')
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut("$startup\Claude Traffic Light.lnk")
$shortcut.TargetPath = 'C:\WINDOWS\system32\wscript.exe'
$shortcut.Arguments = '"C:\Projekt\claude-traffic-light\start-trafficlight.vbs"'
$shortcut.Save()
```

Only one instance runs at a time, so starting it twice is harmless.

### 4. (Optional) Install the VS Code extension

The extension is what lets a click switch to the right VS Code window and terminal tab.
Without it, a click still brings up a window, but VS Code runs all of its windows in a single
process, so it can't tell which window or tab a session belongs to.

```powershell
cd C:\Projekt\claude-traffic-light\vscode-extension
npx @vscode/vsce package --skip-license -o claude-traffic-light-focus.vsix
code --install-extension claude-traffic-light-focus.vsix --force
```

Then reload every open VS Code window once (Ctrl+Shift+P → **Developer: Reload Window**).

## Usage

Just use Claude Code as normal. A dot appears as soon as a session starts or you send the first
message, changes color as Claude works, and disappears when the session ends.

- **Left-click** a dot to jump to its session.
- **Right-click** a dot for its menu.
- **Hover** a dot to see details.

## How it works

```
Claude Code ──hooks──▶ hook.sh ──writes──▶ ~/.claude/trafficlight/<session-id>
                                                   │
                         ┌─────────────────────────┼────────────────────────┐
                         ▼                         ▼                        ▼
                  trafficlight.ps1           statusline.sh          (label shared by both)
                  (tray dots, clicks)        (Claude Code status line)
                         │
                 click ──┴──writes──▶ ~/.claude/trafficlight-focus
                                                   │
                                                   ▼
                                     VS Code extension (in every window)
                                     ──writes──▶ ~/.claude/trafficlight-windows/<pid>.json
```

### Files

| File | Purpose |
|---|---|
| `hook.sh` | Claude Code hook. Writes one state file per session with status, project folder, label and window info. |
| `find-window.ps1` | Called once per session by `hook.sh`. Walks up the process tree to find the session's window and terminal. |
| `trafficlight.ps1` | The tray app. Polls the state files every second and draws, updates and removes dots. Handles clicks and menus. |
| `start-trafficlight.vbs` | Starts the tray app without a visible console window. |
| `statusline.sh` | Claude Code status line showing the session's label, project and status. |
| `vscode-extension/` | VS Code extension that maps terminals to windows and switches to the right terminal tab. |

### Session state files

`hook.sh` writes `~/.claude/trafficlight/<session-id>`, one line per field:

| Line | Content | Example |
|---|---|---|
| 1 | Status: `yellow`, `red` or `green` | `yellow` |
| 2 | Project folder (cwd) | `C:\Projekt\claude-traffic-light` |
| 3 | Label shown on the dot and in the status line | `C1` |
| 4 | Window handle (HWND) of the terminal / VS Code window, `0` if none was found | `4331566` |
| 5 | PID of the VS Code terminal's shell, `0` outside VS Code | `15292` |
| 6 | `1` for a background agent, otherwise `0` | `0` |
| 7 | PID of the Claude process running the session | `948` |
| 8 | `hidden` if the dot was closed from the menu (the hook writes only 7 lines, so the dot returns on the next activity) | |

Files are written atomically (write to `.tmp`, then rename), so the tray app never reads a half-written file.

### Hooks and colors

| Claude Code event | Status |
|---|---|
| `SessionStart` | Keeps the existing status, or green for a new session |
| `UserPromptSubmit`, `PreToolUse` | Yellow |
| `Notification` | Red — except idle notifications ("Claude is waiting for your input"), which keep the current status |
| `Stop` | Green |
| `SessionEnd` | The state file is deleted and the dot disappears |

### Labels

The label is the first letter of the project folder plus the lowest free number among the current
sessions (`C1`, `C2`, …). A lock directory prevents two sessions that start at the same moment
from getting the same label.

### Removing stale dots

`/resume` and `/clear` switch to a new session ID without the old session ending, so its dot would
otherwise stay behind. Two mechanisms handle this:

- **Same Claude process:** when a new session starts in a Claude process that already has a dot
  (line 7 of the state file), the hook takes over that dot's label and deletes the old file.
- **Active session check:** every 30 seconds the tray app runs `claude agents --json` in the
  background. A dot whose session is missing from two checks in a row, and whose state file hasn't
  been written in the last 15 seconds, is removed — but only if the session is really gone:
  - a background agent that's no longer listed
  - a terminal session whose Claude process has exited, now runs another session, or has switched
    to a background session after `/resume` (`parkedJobId` in `~/.claude/sessions/<pid>.json`)

  A terminal session waiting for your next message can be missing from the list, so the list alone
  never removes it. If the command fails or returns no sessions, nothing is removed.

### Finding the window

On the first hook call of a session, `find-window.ps1` walks up from the hook's process
(`bash` → `claude.exe` → shell → terminal / VS Code) until it reaches a process with a window. It
also records the shell that VS Code started the terminal with. This lookup takes well under a second
and runs only once per session.

Background agents run under Claude Code's daemon rather than in a terminal. The daemon records which
process started it (`--spawned-by`), so the lookup continues from there to the terminal where you
started the agents.

### Click handling

1. The tray app writes `~/.claude/trafficlight-focus` with the terminal's shell PID (plus the session
   id and label for background agents).
2. It brings the window to the front. For VS Code, which runs every window in one process, it picks
   the window whose title contains the session's workspace name, as reported by the extension, and
   falls back to matching the project folder name.
   A conversation you `/resume` in a terminal may continue as a background session that the terminal
   only displays. Claude Code doesn't record which terminal that is, but the terminal's Claude process
   gets a `parkedJobId` in `~/.claude/sessions/<pid>.json`. If exactly one such terminal has the same
   project folder, the click goes to that terminal instead of opening a new tab.
3. The VS Code extension in every window watches the focus file. Only the window that owns the
   terminal reacts: it shows that terminal tab, or opens or reuses a `claude attach` tab for a
   background agent.

## Limitations

- **Windows only.** The tray app uses Windows Forms and Win32 APIs.
- **Terminal tabs in Windows Terminal** can't be selected. A click brings up the right window, but
  not a specific tab.
- **Two VS Code windows with the same folder open** can't be told apart. The most recently used one wins.
- **The Claude Code VS Code panel** (chat view) isn't supported for tab switching — only Claude
  running in VS Code's integrated terminal.
- **Switching agents inside agent view** isn't possible from outside Claude Code, so background
  agents open in their own `claude attach` tab instead.
- Background agent tabs open in the window where Claude Code's daemon was first started from, which
  is usually the first terminal you started agents in.

## Troubleshooting

**The dots are gone.** The tray app was probably closed. Double-click `start-trafficlight.vbs`.

**A dot stays grey or doesn't appear.** Check that the hooks are in `~/.claude/settings.json` and
that `bash` is Git Bash. Look in `~/.claude/trafficlight/` for the session's state file.

**Clicking a dot brings up the wrong VS Code window, or doesn't switch tab.** Make sure the extension
is installed (`code --list-extensions | findstr traffic`) and reload the VS Code window. Sessions
that were started before the extension was installed get their terminal info on their next hook
call, for example when you send a message.

**A background agent tab shows "terminated with exit code 1".** The agent may no longer be running.
Run `claude agents` to see the active agents.

**Stale dots after a crash.** Right-click → **Close dot**, or **Reset (clear all sessions)**.
Dots that haven't been updated for 12 hours are removed automatically.

## Uninstall

1. Right-click a dot → **Quit traffic light (all dots)**.
2. Delete the Startup shortcut (`shell:startup` → `Claude Traffic Light.lnk`).
3. Remove the `statusLine` and `hooks` entries from `~/.claude/settings.json`.
4. Uninstall the extension: `code --uninstall-extension woltrananton.claude-traffic-light-focus`.
5. Delete `~/.claude/trafficlight/`, `~/.claude/trafficlight-windows/`, `~/.claude/trafficlight-focus`
   and `~/.claude/trafficlight-agents.json` (plus `.err`).

## License

MIT, see [LICENSE](LICENSE).
