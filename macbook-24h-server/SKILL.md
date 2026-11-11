---
name: macbook-24h-server
description: Turn a MacBook into a 24/7 always-on server that never sleeps while the display auto-turns-off after idle. Installs a user-level caffeinate LaunchAgent with login auto-start and crash auto-restart, configures AC display sleep with a mandatory user choice of 30, 60, 90 minutes or custom, and optionally disables App Nap for remote-control apps such as WorkBuddy so phone or remote sessions stay alive after the screen goes dark. Use this skill when the user wants to keep a Mac permanently running as a server or home server, prevent MacBook sleep, make remote control work after the screen turns off, undo the setup, or diagnose a machine that is awake but unreachable.
agent_created: true
---

# MacBook 24-Hour Server

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
5. **Never turn off** (display stays on; maps to `--display-sleep keep`)

Do not assume a value even if one is configured already — the current value may
be a leftover default. Only proceed after the user picks.

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

If the user mentioned using a phone app / remote control against this Mac (e.g.
WorkBuddy mobile), ask whether to disable App Nap for the relevant desktop app
so the remote channel survives the screen-off. WorkBuddy's bundle id is
`com.tencent.workbuddy.mac`; discover other apps with
`osascript -e 'id of app "AppName"'`. Note it requires an app relaunch.

### 3. Setup

Use the bundled script (idempotent; replaces any older copy of this agent):

```bash
bash scripts/macbook-24h-server.sh setup --display-sleep <minutes|keep> [--appnap-bundle <bundle-id>]...
```

What the script does:

- Writes `~/Library/LaunchAgents/com.macbook24h.server.plist` running
  `caffeinate -ims` (`-d -u` added only in `keep` mode), with `RunAtLoad` +
  `KeepAlive` so it survives logout/login and crashes.
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
