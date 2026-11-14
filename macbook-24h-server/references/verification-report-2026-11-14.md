# Verification Report: macbook-24h-server on a MacBook (Display Off, Remote Session Alive)

- **Date:** 2026-11-14 11:20–11:40 CST (GMT+8)
- **Host:** MacBook (Apple Silicon, built-in Liquid Retina XDR, macOS 26)
- **Skill version tested:** `jasonkwok001/macbook-24h-server` @ `e7c333e`
- **Scenario:** lid open, display off after idle, remote session driven from a phone through WorkBuddy
- **Verdict:** **PASS on configuration, PASS on AC sleep behaviour, but the "lid-close on AC" guarantee is overstated** — see Finding 3.

---

## 1. Why "it still responds" is not a proof

The tempting shortcut is: *the remote session works, therefore the whole setup works.*
That inference is invalid, because a Mac can respond while having slept and woken a minute earlier, or while sitting in a `DarkWake` state that still routes traffic for a while.

So this report does not treat reachability as evidence. It checks three independent layers:

| Layer | Question | Tool |
|---|---|---|
| Configuration | Is the always-on setup installed and loaded? | `launchctl print`, plist |
| Live assertions | Is the OS currently being told not to sleep, and by whom? | `pmset -g assertions` |
| History | Has the machine **actually** stayed awake since the service started? | `pmset -g log` |

The third layer is the one that matters and the one that a naive check skips. It is also where the two real problems surfaced.

---

## 2. Configuration layer — all green

```
[OK]   caffeinate running: 11404 /usr/bin/caffeinate -ims
[OK]   PreventUserIdleSystemSleep = 1
[OK]   PreventDiskIdle = 1
[OK]   PreventSystemSleep = 1
[INFO] PreventUserIdleDisplaySleep = 0 (display may sleep)
[INFO] displaysleep(AC) = 90
[INFO] power source = AC
[OK]   App Nap disabled for com.tencent.workbuddy.mac
[OK]   LaunchAgent plist present (auto-starts on login)
```

Managed by launchd, not a stray shell process:

```
$ launchctl print gui/501/com.macbook24h.server
  state = running
  program = /usr/bin/caffeinate
  pid = 11404
  last exit code = (never exited)
```

That distinction is worth stating explicitly. A `caffeinate` started by hand in a terminal also asserts all three flags, but it dies with the terminal and never comes back after a reboot. What makes this a *server* rather than a *temporary hack* is `RunAtLoad` + `KeepAlive` in `~/Library/LaunchAgents/com.macbook24h.server.plist`. Verify therefore checks the launchd domain, not just `pgrep`.

A portability note discovered while testing: `ps -p <pid> -o lstart=` is **refused** inside a brokered/sandboxed agent shell (`operation not permitted: ps`), while `pgrep` and `launchctl print` keep working. Any health check that depends on `ps` will report a false negative there. The shipped `verify` only uses `pgrep` + `pmset`, so it survives this — but the start-time derivation added in this round deliberately uses `pmset -g assertions` (the assertion age, e.g. `60:20:04`) instead of `ps`.

---

## 3. History layer — the important part

Window = from `caffeinate` start (`2026-11-11 23:08:43`) to now.

```
[AUDIT] sleep/wake events in window: 50  (AC=12  BATT=38)
[OK]    zero full-Sleep events on AC — no power-loss sleep
[WARN]  12 clamshell DarkWake event(s) on AC (lid-shut drop-outs)
        longest DarkWake dwell: 467 min (2026-11-12 02:22:13 -> 2026-11-12 10:09:47)
        assertion refreshes in it: 32 (expected ~31 at 15-min cadence)
[WARN]  38 event(s) on battery — outage while unplugged
```

### Finding 1 — On AC, the machine never fully slept. The assertions hold.

Zero `Entering Sleep state ... Using AC` records in the entire window. Every AC record is a `DarkWake`, not a full sleep. `caffeinate -ims` is doing exactly what it claims for the idle-sleep case.

### Finding 2 — The 38 battery events are expected, and they are real outages.

All 38 cluster between `2026-11-13 01:52` and `2026-11-13 09:34`, all tagged `Using Batt`, all starting from a single `Clamshell Sleep`. The machine went to sleep with the lid shut at 01:52 on battery and stayed effectively down, waking only for maintenance windows, until AC was reconnected at 13:45. That is not a configuration bug — it is the Apple hard rule the skill already documents. It does mean that "24/7" is conditional on the cable, and any monitoring that ignores the power source will report a healthy service during a seven-hour outage.

### Finding 3 — `Clamshell Sleep` on AC still drops the machine, for up to 467 minutes.

This contradicts the plain reading of the skill's own handoff note, which says lid-close protection *requires* AC power. It reads as: on AC, closing the lid is handled. The log says otherwise.

On AC with the lid shut, macOS does not enter full `Sleep` — it enters `DarkWake` (`Entering DarkWake state due to 'Clamshell Sleep'`). `DarkWake` is a low-power state in which the CPU, display and most user processes are suspended and revived only for scheduled maintenance windows. Twelve such events appear on AC. The worst one runs `02:22:13 → 10:09:47`: **467 minutes before the next `DarkWake to FullWake`.**

**Correction (added after re-reading the window):** an earlier draft of this report called those 467 minutes "no record at all". That was wrong, and the error matters. The window actually contains **359 power-log entries**, and `caffeinate` renewed its assertion **32 times at a perfect 15-minute cadence** (expected ≈31). So the kernel never stopped: the machine was in `DarkWake`, not powered off, and the power configuration was behaving as designed. What died was the remote path, and the power log cannot tell us whether that was the parked user processes or the network underneath them.

For a 24/7 server this is the failure mode that matters most, and it is invisible to `caffeinate`'s assertions. An interactive remote session cannot survive `DarkWake` — the transport is torn down, and from the phone the machine simply looks offline even though the disk is mounted, the network is up and `pmset -g assertions` is still all green. It is the same *symptom* as the App Nap problem (awake but unreachable) with a completely different *cause*, and `NSAppSleepDisabled` does nothing for it.

This is also why "the machine stayed awake" must never be reported as "the service was reachable". They are different claims, and only the first one is supported by this log.

The honest statement of the guarantee is therefore narrower than the skill currently claims:

> On AC power, an **open lid** with the display off is fully protected — system, disk and network keep running indefinitely. A **closed lid** on AC reduces the machine to `DarkWake`, which suspends user processes and can silence a remote session for hours. Lid-close operation is not a supported 24/7 mode; leave the lid open with the display off.

### Finding 4 — "Unreachable" has more than one owner, and this skill owns only one.

Everything above analyses the power domain. But a Mac that cannot be reached may
be perfectly healthy on the power side and failing somewhere else entirely:

| Domain | Typical cause | Power log signature |
|---|---|---|
| Power / lid | lid shut, unplugged, assertions lost | a `DarkWake` or `Sleep` dwell covering the outage |
| App throttling | App Nap starved the heartbeat | no dwell; machine fully awake |
| Network | Wi-Fi drop, router reboot, ISP, VPN expiry, NAT timeout, DHCP lease change | no dwell; machine fully awake |

The last two are indistinguishable from inside the machine, and neither leaves a
trace in `pmset -g log`. So the correct reading of a clean audit is narrow: **the
power configuration did not cause the outage** — not "the machine was reachable".

Practical consequence for diagnosis: if a user reports an outage and `audit`
shows no dwell over that window, stop. Do not re-run `setup`. Ask for router or
NAT logs for the same window, check `airportd` for a deauth/roam burst, and
compare public IP before/after. Reconfiguring power cannot fix a router, and
assuming it was power hides the real cause.

Limitation to state honestly: this machine cannot check the 11/12 window
retroactively. `/var/log/wifi.log` rotated at `2026-11-14 00:30` and the unified
log is not readable from a sandboxed shell (`log: Cannot run while sandboxed`),
so whether the 467-minute outage was parked processes or a dead link is **not
recoverable** from this host. The audit should report the dwell and say the split
is unknown, rather than assert either story.

---

## 4. Changes made to this repository as a result

1. **New `audit` subcommand.** `verify` can only prove that the configuration is *currently* correct — it reads live state and will happily report green on a machine that slept for seven hours yesterday. `audit` reads the power log instead, derives the service start time from the live assertion age, and reports AC full-sleeps, AC clamshell `DarkWake`s with their dwell time, and battery outages separately, because those three failure modes need different fixes.

   ```bash
   bash scripts/macbook-24h-server.sh audit          # since caffeinate started
   bash scripts/macbook-24h-server.sh audit --days 7  # fixed trailing window
   ```

2. **Corrected the lid-close claim** in `SKILL.md` and `references/troubleshooting.md` to describe the `DarkWake` behaviour instead of implying AC makes lid-close safe.

3. **Documented the `ps` restriction** and the `strftime`-free portability constraint, so the next person editing the health checks does not reintroduce a check that fails silently inside an agent shell.

---

## 5. Reproduce this report

```bash
bash scripts/macbook-24h-server.sh verify --appnap-bundle com.tencent.workbuddy.mac
bash scripts/macbook-24h-server.sh audit
pmset -g assertions        # who is asserting what, right now
pmset -g log | grep -E "Entering (Sleep|DarkWake) state"
```

Interpretation guide:

- `PreventUserIdleDisplaySleep = 0` is **correct** here. The display is supposed to turn off; that is not the bug.
- `PreventUserIdleDisplaySleep = 1` means `keep` mode was chosen (`caffeinate -dimsu`) and the screen is pinned on forever — a deliberate power/burn-in trade-off, not a default.
- If `verify` is green but remote control drops after the screen goes off, run `audit`. A clean `audit` plus a dead session points at App Nap or network roaming; a dirty `audit` points at `DarkWake` (lid shut) or a battery outage.

---

*Report generated from live system state on the machine in question; every figure above is copied from `pmset`/`launchctl` output captured during the session, not estimated.*