---
name: macbook-24h-server
description: Turn a MacBook into a 24/7 always-on server that never sleeps while the display auto-turns-off after idle — revive an old or spare Mac and keep it usefully running. Installs a user-level caffeinate LaunchAgent with login auto-start and crash auto-restart, configures AC display sleep with a mandatory user choice of 30, 60, 90 minutes, custom, or never (screen stays on, warned explicitly), and optionally disables App Nap for remote-control apps such as WorkBuddy, Codex, Claude, Trae or Qoder so phone or remote sessions stay alive after the screen goes dark. Use this skill when the user wants to keep a Mac permanently running as a server or home server, repurpose an old laptop as a server, prevent MacBook sleep, make remote control work after the screen turns off, undo the setup, or diagnose a machine that is awake but unreachable.
agent_created: true
---

# MacBook 24-Hour Server

Why this skill exists: a retired or spare MacBook is a silent, low-power, x86/
ARM machine you already own. This skill brings such an old computer back to
life as a 7×24 server that keeps on working — home NAS, build agent, remote
development hop, AI worker — without buying dedicated hardware.

Convert a MacBook into an always-on server: system, disk, network and lid-closed
operation never sleep; the display still turns off after an idle period to save
power and protect the panel.

## Critical rule: ask the display-sleep choice first

Before ANY setup action, ask the user how many idle minutes until the display
turns off. Offer exactly these options:

1. **30 minutes**
2. **60 minutes**
3. **90 minutes**
4. **Custom** (accept any number of minutes the user types)
5. **Never turn off** (maps to `--display-sleep keep`)

Do not assume a value even if one is configured already — the current value may
be a leftover default. Only proceed after the user picks.

**When the user picks "Never turn off"**: the script switches caffeinate to
`-dimsu`, where `-d` (prevent display sleep) and `-u` (simulate user activity,
asserting `UserIsActive = 1`) pin the display awake forever. You MUST warn the
user in text before applying it, e.g.: "此选择将使屏幕**永不熄灭**——更耗电、
屏幕长期点亮，OLED 机型还有烧屏风险；系统本身仍永不休眠。确认继续吗？"
Proceed only after the user confirms.

## Workflow

### 1. Preflight

```bash
pmset -g custom          # show current sleep settings
pmset -g batt | head -1  # AC vs battery
sw_vers                  # macOS version
```

Warn the user up front: lid-close protection requires **AC power** (Apple hard
rule — on battery, closing the lid always sleeps regardless of this setup).

### 2. Ask about remote-control apps

If the user mentioned using a phone app / remote control against this Mac, ask
whether to disable App Nap for the relevant desktop app(s) so the remote
channel survives the screen-off. Any GUI app works — the mechanism
(`NSAppSleepDisabled`) is per-bundle and app-agnostic. Known ids for common
remote-control / AI-coding desktop apps:

| App | Bundle id |
|---|---|
| WorkBuddy | `com.tencent.workbuddy.mac` |
| Codex (desktop) | `com.openai.codex` |
| Claude (Desktop) | `com.anthropic.claudefordesktop` |
| Trae | `cn.trae.app` |
| Qoder | `com.qoder.QoderWakeCN.MenuBar` (CN 版菜单栏组件) |

Table ids may drift with app versions — always confirm on the user's machine
with `osascript -e 'id of app "AppName"'` (or read
`/Applications/<App>.app/Contents/Info.plist`). CLI-only tools (e.g. a `codex`
command-line agent launched from Terminal) have no bundle id to set; App Nap
does not apply to them. Note the flag requires an app relaunch.

### 3. Setup

Use the bundled script (idempotent; replaces any older copy of this agent):

```bash
bash scripts/macbook-24h-server.sh setup --display-sleep <minutes|keep> [--appnap-bundle <bundle-id>]...
```

What the script does:

- Writes `~/Library/LaunchAgents/com.macbook24h.server.plist` running
  `caffeinate -ims` (in `keep` / "never turn off" mode it becomes `-dimsu`,
  adding `-d` prevent-display-sleep and `-u` simulate-user-activity so
  `UserIsActive = 1` pins the screen on — warn the user first), with
  `RunAtLoad` + `KeepAlive` so it survives logout/login and crashes.
- Loads the agent with `launchctl bootstrap`; if that fails (brokered/sandboxed
  agent shells can hit "Bootstrap failed: 5: Input/output error" on the gui
  domain), it retries via `osascript ... with administrator privileges` +
  `launchctl asuser` — the user sees one macOS authorization dialog.
- Sets AC display sleep via `pmset -c displaysleep N`: tries passwordless sudo,
  then a native macOS authorization dialog (user clicks "Allow" once), and only
  falls back to asking the user to run it manually if both fail.

After setup succeeds, tell the user the LaunchAgent persists across reboots —
no need to re-run setup; only `verify` is needed to confirm health.

### 4. Verify (script prints a verdict table)

```bash
bash scripts/macbook-24h-server.sh verify [--appnap-bundle <bundle-id>]...
```

All of these must be green/informational:

- caffeinate process alive; `PreventUserIdleSystemSleep`, `PreventDiskIdle`,
  `PreventSystemSleep` all = 1
- `PreventUserIdleDisplaySleep` = 0 (display may turn off) — or = 1 in `keep` mode
- `displaysleep(AC)` equals the chosen minutes
- LaunchAgent plist exists (login persistence)
- App Nap flag per requested bundle

### 5. Handoff notes to the user

- Plug in power for true 24/7 operation.
- If App Nap was disabled for an app, **relaunch that app now** (or tell the
  user to) — the flag is read at process start.
- Keep the Mac on one stable network; roaming between home Wi-Fi and a phone
  hotspot breaks long-lived remote connections.

## Undo

```bash
bash scripts/macbook-24h-server.sh remove
```

Removes the LaunchAgent and running caffeinate. The `displaysleep` value is
left as-is; restore with `sudo pmset -c displaysleep 10` if the user wants the
old default back.

## Known pitfall: "machine awake but remote control dead"

If the user reports the screen turns off fine but phone/remote sessions drop,
this is per-app **App Nap** throttling, not sleep — `caffeinate` cannot fix it.
Run setup again with `--appnap-bundle`, relaunch the app, and see
`references/troubleshooting.md` for the full diagnostic playbook (log-gap
analysis, network roaming, lock-vs-sleep confusion).

## Redeploy warning (never leave the machine unprotected)

When changing the LaunchAgent label or re-running setup, install-and-load the
NEW service BEFORE killing the old caffeinate process, and run `verify`
immediately after. Removing the agent first creates a naked window where the
Mac can sleep again.
