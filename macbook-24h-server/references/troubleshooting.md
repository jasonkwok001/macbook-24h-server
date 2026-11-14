# Troubleshooting: remote control / SSH stops working after the display turns off

Symptom: the MacBook is clearly still awake (machine, disk and network keep
running; `caffeinate` assertions all green), but a remote-control channel
(e.g. the mobile companion of WorkBuddy / Codex / Claude / Trae / Qoder, or
any app's websocket heartbeat to its cloud relay) silently goes offline until
someone sits in front of the machine and
interacts with it (witness: the OS demands the login password).

## First question: is this even a Mac-side problem?

Before touching App Nap or power settings, make sure the fault is on this side
of the wire. Three independent domains can each produce "I cannot reach it":

1. **Power / lid** — the machine slept or dropped to `DarkWake`. Leaves a dwell
   in `pmset -g log`. This skill owns this one.
2. **App throttling** — App Nap starves the websocket heartbeat. Machine stays
   fully awake, no power-log dwell. Fixed by `NSAppSleepDisabled`.
3. **Network** — Wi-Fi drop, router reboot, ISP outage, VPN expiry, NAT table
   timeout, DHCP lease change. Machine stays fully awake, **no power-log dwell
   either**, and nothing on the Mac looks wrong.

Domains 2 and 3 look identical from inside the machine, and both look calm in
the power log. So "no sleep events" only rules out domain 1; it does not mean
the Mac is at fault at all.

Cheap evidence to separate 2 from 3:

- **Wi-Fi signal/roam history**: `log show --predicate 'process == "airportd"'`
  (must run outside the sandbox). A deauth/roam burst at the outage time points
  to network.
- **Router / NAT logs** for the same window — the only place a link drop is
  actually recorded.
- **Heartbeat pattern in the app log**: periodic reconnect churn = network
  flapping; one long flat silence until a local keypress = App Nap.
- **Public IP before/after** (`curl -s ifconfig.me`) — a changed IP means the
  machine moved networks, and stale websockets went half-open.

If the answer is "network", do not re-run `setup`. Changing power settings
cannot fix a router, and misattributing it hides the real cause.

Two traps that make this easy to get wrong:

- **Silence in `pmset -g log` ≠ sleep.** Powermgmt logs only *transitions*; an
  eight-hour awake stretch writes almost nothing and is indistinguishable from
  an eight-hour outage in that log alone.
- **`DarkWake` keeps assertions refreshing.** The kernel keeps ticking and
  `caffeinate` renews on schedule, yet user processes are parked. Cadence proves
  "not powered off", never "reachable".

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
  hard rule; lid-close operation only holds while on AC power.
- **AC + lid close is still not always-on.** On AC the machine skips full
  `Sleep` but enters `DarkWake due to 'Clamshell Sleep'`, which suspends user
  processes and can silence a remote session for hours (measured: 467 minutes
  with no wake record). `DarkWake` produces the *same symptom* as App Nap —
  machine looks awake, session is dead — so check the power source and lid
  state before blaming App Nap. See `verification-report-2026-11-14.md`.
- **`ps` may be unavailable inside agent shells.** `ps -p <pid> -o lstart=`
  can fail with `operation not permitted` in a brokered/sandboxed session
  while `pgrep` and `launchctl print` still work. Derive process start time
  from the assertion age (`pmset -g assertions`, e.g. `60:20:04`) instead of
  `ps`, or the health check reports a false negative.
- **BSD `awk` has no `strftime`.** Timestamp formatting in log analysis must
  go through `date -j -f`, not `awk`'s `strftime`, or the check dies with
  "calling undefined function".
- **Screensaver password prompt is not the culprit.** "Asks for password"
  after idle only proves the machine locked, not that it slept. Cross-check
  `pmset -g log` sleep-event counts to confirm the machine stayed awake.
- **Log-gap detection technique:** grep the connection-status lines of the
  affected app across two days of logs and look for a window with no
  heartbeat at all. A flat, silence-for-hours pattern = process throttled
  (App Nap), whereas periodic reconnect churn = genuine network flapping.
