# The Expeditor

The Expeditor is the eyes between you and the kitchen. It has two parts:

- **dot-agent-deck** — Rust terminal dashboard. Shows all active stations (line cook panes) and their state. Homebrew installable.
- **falcode-zellij** — Zellij WASM plugin. Fires notifications when a line cook finishes or needs input. Lets you jump directly to that station.

Neither is built by brigade — you install them once. This document covers that install plus wiring them to brigade.

---

## dot-agent-deck

### Install

```bash
brew tap vfarcic/tap && brew install dot-agent-deck
dot-agent-deck hooks install
```

### Run

Launch in a separate Zellij tab or pane — it reads all active panes across your Zellij session:

```bash
dot-agent-deck
```

### What you see

dot-agent-deck surfaces the Zellij tab state that line cooks write:

| Tab name prefix | Meaning |
|---|---|
| `⏳ brigade-<id>` | Working — line cook mid-turn |
| `🔴 brigade-<id>` | In the weeds — needs your input |
| `✅ brigade-<id>` | On the pass — done, awaiting review |

Line cooks update their own tab name via `zellij action rename-tab`. You read the tab state visually — no polling, no custom classifier.

### Pane control

dot-agent-deck's pane control feature (send commands to agent panes) is not yet shipped. Brigade uses `brigade-send.sh` for pane control directly via the Zellij CLI — no dependency on dot-agent-deck for this.

---

## falcode-zellij

### 1. Install the Zellij WASM plugin

```bash
mkdir -p ~/.config/zellij/plugins
curl -L https://github.com/victor-falcon/falcode-zellij/releases/latest/download/falcode-zellij-sessions.wasm \
  -o ~/.config/zellij/plugins/falcode-zellij-sessions.wasm
```

Register it in your Zellij config (`~/.config/zellij/config.kdl`):

```kdl
keybinds {
    shared {
        bind "Alt f" {
            LaunchOrFocusPlugin "file:~/.config/zellij/plugins/falcode-zellij-sessions.wasm" {
                floating true
            }
        }
    }
}
```

### 2. Install the Claude Code hook

```bash
mkdir -p ~/.local/state/falcode-zellij
curl -L https://raw.githubusercontent.com/victor-falcon/falcode-zellij/main/claude-extension/falcode-hook.sh \
  -o ~/.local/state/falcode-zellij/falcode-hook.sh
chmod +x ~/.local/state/falcode-zellij/falcode-hook.sh
```

Merge this into `~/.claude/settings.json` (adjust `HOME_PATH` to your actual home dir — Claude Code does not expand `~`):

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "HOME_PATH/.local/state/falcode-zellij/falcode-hook.sh SessionStart" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "HOME_PATH/.local/state/falcode-zellij/falcode-hook.sh UserPromptSubmit" }] }],
    "PreToolUse":       [{ "hooks": [{ "type": "command", "command": "HOME_PATH/.local/state/falcode-zellij/falcode-hook.sh PreToolUse" }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "HOME_PATH/.local/state/falcode-zellij/falcode-hook.sh PostToolUse" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "HOME_PATH/.local/state/falcode-zellij/falcode-hook.sh Notification" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "HOME_PATH/.local/state/falcode-zellij/falcode-hook.sh Stop" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "HOME_PATH/.local/state/falcode-zellij/falcode-hook.sh Stop" }] }]
  }
}
```

Replace `HOME_PATH` with the output of `echo $HOME`.

brigade-spawn.sh automatically installs a `Stop` hook per-ticket into the worktree's `.claude/settings.local.json` for the turn-end signal. The falcode hook in your global `~/.claude/settings.json` is separate — it handles the Expeditor notifications, not brigade's internal signalling. Both coexist without conflict.

### 3. Install the OpenCode plugin (if using opencode harness)

```bash
mkdir -p ~/.config/opencode/plugins
curl -L https://raw.githubusercontent.com/victor-falcon/falcode-zellij/main/opencode-plugin/falcode.js \
  -o ~/.config/opencode/plugins/falcode.js
```

Add to `~/.config/opencode/config.json`:

```json
{
  "plugin": ["./plugins/falcode.js"]
}
```

### 4. Install the pi extension (if using pi harness)

```bash
mkdir -p ~/.pi/agent/extensions
curl -L https://raw.githubusercontent.com/victor-falcon/falcode-zellij/main/pi-extension/falcode.ts \
  -o ~/.pi/agent/extensions/falcode.ts
```

Then restart pi or run `/reload` inside pi.

### 5. codex harness

codex does not have a falcode extension. brigade-spawn's turn-end hook via `-c notify=[...]` in the launch command handles brigade's internal signalling. The Expeditor (dot-agent-deck + tab states) gives you visibility without the notification jump; this is the expected behaviour for codex stations.

---

## Notification behaviour

When a line cook finishes or gets stuck, falcode fires a macOS/Linux notification:

| State | Notification |
|---|---|
| `waiting_user_input` (after working) | "idle" — cook is done, your turn |
| `asking_permissions` | "permission" — tool needs approval |
| `waiting_user_answers` | "question" — cook has a question |

Jump to the station directly from the notification (macOS) or use the falcode popup (`Alt f` by default) to focus the right pane.

---

## Verification checklist

After setup, confirm the following work end-to-end (Phase 06 test):

- [ ] dot-agent-deck shows active brigade stations with correct `⏳`/`🔴`/`✅` tab names
- [ ] Firing a ticket opens a new `⏳ brigade-<id>` tab visible in dot-agent-deck
- [ ] When a claude line cook finishes, a notification fires and Status shows `✅`
- [ ] `Alt f` opens the falcode popup listing the active station
- [ ] `brigade-86 <id>` closes the tab and it disappears from dot-agent-deck
