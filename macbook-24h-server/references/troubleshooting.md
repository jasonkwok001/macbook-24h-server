# Troubleshooting: remote control / SSH stops working after the display turns off

Symptom: the MacBook is clearly still awake (machine, disk and network keep
running; `caffeinate` assertions all green), but a remote-control channel
(e.g. the mobile companion of WorkBuddy / Codex / Claude / Trae / Qoder, or
any app's websocket heartbeat to its cloud relay) silently goes offline until
someone sits in front of the machine and
interacts with it (witness: the OS demands the login password).

## Root cause: App Nap (per-app), not system sleep

macOS applies **App Nap** independently of system sleep. When an app has no
visible windows and no user interaction — typically right after the display
turns off — the system throttles its timers and network activity. Long-lived
websocket heartbeats get starved, the cloud side marks the device offline,
and remote control fails even though the machine itself never slept.

Key fact: `caffeinate` (any flag combination) does **not** disable App Nap.
The two mechanisms are orthogonal.

## Fix

1. Disable App Nap for the specific app:
   ```bash
   defaults write <bundle-id> NSAppSleepDisabled -bool YES
   ```
   (Find the bundle id with: `osascript -e 'id of app "AppName"'`)
2. **Relaunch the app** — the preference is read at process start.
3. Verify: the app's cloud connection log should stay `connected` across
   display-off periods with no "no ping / reconnect" churn.

## Secondary pitfalls found during diagnosis

- **Network migration:** if the machine roams between home Wi-Fi and a phone
  hotspot (gateway `172.20.x.x` = iPhone hotspot; home routers are usually
  `192.168.x.x`), the public IP changes and stale websockets enter a
  half-open state. Pin the server Mac to one network.
- **Battery + lid close WILL sleep regardless of `caffeinate -s`.** Apple
  hard rule; lid-close protection only holds while on AC power.
- **Screensaver password prompt is not the culprit.** "Asks for password"
  after idle only proves the machine locked, not that it slept. Cross-check
  `pmset -g log` sleep-event counts to confirm the machine stayed awake.
- **Log-gap detection technique:** grep the connection-status lines of the
  affected app across two days of logs and look for a window with no
  heartbeat at all. A flat, silence-for-hours pattern = process throttled
  (App Nap), whereas periodic reconnect churn = genuine network flapping.
