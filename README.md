# macbook-24h-server

**English** | [中文](#中文说明)

**Why?** A retired or spare MacBook is a silent, low-power machine you already
own. This skill revives an old computer and puts it back to work as a 7×24
server — home NAS, build agent, remote development hop, AI worker — no new
hardware needed.

A [WorkBuddy](https://www.workbuddy.cn) skill that turns any MacBook into a
24/7 always-on server:

- System / disk / network never idle-sleep
- Closing the lid does not sleep it (while on AC power)
- The display still turns off after idle — you choose when: **30 / 60 / 90
  minutes or fully custom** — or **never**: the skill switches caffeinate to
  `-dimsu` (`-u` asserts `UserIsActive`) and warns you up front that the screen
  will stay lit permanently (extra power, OLED burn-in risk)
- Optionally disables **App Nap** for remote-control apps — WorkBuddy, Codex,
  Claude, Trae, Qoder, or any GUI app — so phone / remote sessions survive the
  screen turning off
- Login auto-start, crash auto-restart via a user-level LaunchAgent — no root
  daemon needed

## The pitfall this skill fixes

`caffeinate` alone is not enough for a headless Mac. Two classic traps:

1. **App Nap** — macOS throttles the timers/websockets of apps with no visible
   window once the display is off. The machine is awake, but your remote-control
   channel silently goes offline. `caffeinate` cannot fix this; the skill sets
   `NSAppSleepDisabled` per app.
2. **Network roaming** — a laptop moving between home Wi-Fi and a phone hotspot
   changes its public IP and leaves stale websockets half-open.

See [`references/troubleshooting.md`](references/troubleshooting.md) for the
full diagnostic playbook.

## Install

Drop the `macbook-24h-server/` folder into:

```
~/.workbuddy/skills/          # user scope (recommended)
<project>/.workbuddy/skills/  # project scope
```

Then tell WorkBuddy:

> make this MacBook a 24-hour server

The skill asks you for the display-off timeout first (30 / 60 / 90 / custom /
never), then installs, loads and verifies everything in one pass. If you choose
"never", it warns you that the display will stay on forever before applying.

## Use the script directly (without WorkBuddy)

```bash
# install: display off after 90 idle minutes, keep WorkBuddy remote-alive
bash scripts/macbook-24h-server.sh setup \
  --display-sleep 90 \
  --appnap-bundle com.tencent.workbuddy.mac

# multiple remote apps are fine (flag is repeatable)
bash scripts/macbook-24h-server.sh setup \
  --display-sleep 60 \
  --appnap-bundle com.tencent.workbuddy.mac \
  --appnap-bundle com.openai.codex \
  --appnap-bundle com.anthropic.claudefordesktop \
  --appnap-bundle cn.trae.app \
  --appnap-bundle com.qoder.QoderWakeCN.MenuBar

# health check
bash scripts/macbook-24h-server.sh verify --appnap-bundle com.tencent.workbuddy.mac

# remove
bash scripts/macbook-24h-server.sh remove
```

Options:

| Flag | Values | Meaning |
|---|---|---|
| `--display-sleep` | `30`–`n` / `keep` / `off` | AC display timeout in minutes; `keep` pins the display awake forever via `-dimsu` (screen never turns off — expect higher power use and OLED burn-in risk); `off` leaves system setting untouched |
| `--appnap-bundle` | any bundle id | Disable App Nap for that app (repeatable). Works for any GUI app, e.g. `com.tencent.workbuddy.mac`, `com.openai.codex`, `com.anthropic.claudefordesktop`, `cn.trae.app`, `com.qoder.QoderWakeCN.MenuBar`. Find ids with `osascript -e 'id of app "AppName"'` |

## How it works

| Layer | Mechanism |
|---|---|
| Never idle-sleep | `caffeinate -ims` held by a LaunchAgent (`com.macbook24h.server`), `RunAtLoad` + `KeepAlive` |
| Display off on schedule | `pmset -c displaysleep N` (AC only; authorization dialog if sudo unavailable) |
| Remote apps survive | `defaults write <bundle> NSAppSleepDisabled -bool YES` + app relaunch |

Requirements: macOS (Apple Silicon or Intel), AC power for lid-close
protection. Tested on macOS 27.x / caffeinate and launchd stock tooling only.

## Caveats

- Lid-close protection requires AC power (Apple hard rule — battery + lid
  closed always sleeps).
- `NSAppSleepDisabled` takes effect only after the target app relaunches.
- `remove` uninstalls the agent but does not restore your previous
  `displaysleep` value automatically.

## License

MIT — see [LICENSE](LICENSE).

---

## 中文说明

为什么需要这个技能：退役或闲置的 MacBook 是一台你自己已经拥有的静音、低功耗电脑。本技能让旧电脑重新复活，变身为 7×24 小时持续干活的服务器——家庭 NAS、构建机、远程开发跳板、AI 打工机——不必再买专用硬件。

功能：系统/磁盘/网络永不空闲休眠、合盖不睡（需接电源）、屏幕按你选择的时长（30/60/90 分钟或自定义）自动熄灭省电；也可以选「永不熄屏」——此时 caffeinate 切换为 `-dimsu`（`-u` 模拟用户活动使屏幕常亮），技能会先明确提示你这个选择意味着屏幕不会再关。并可为远程控制类 App（WorkBuddy、Codex、Claude、Trae、Qoder 等任意 GUI 应用）关闭 App Nap，让熄屏后手机远程会话不断线。

最大的坑：`caffeinate` 管得了系统睡眠，管不了 macOS 对单个 App 的 **App Nap 节流**——熄屏后没有可见窗口的 App 心跳会被限流，云端判定设备离线，远程控制在「机器明明醒着」的情况下失灵。本技能用 `NSAppSleepDisabled` 精准解决。

安装：把 `macbook-24h-server/` 放进 `~/.workbuddy/skills/`，对 WorkBuddy 说「把这台 MacBook 变成 24 小时服务器」即可。技能会先问你熄屏时间再动手。

不带 WorkBuddy 也可以直接跑脚本，用法见上方英文一节。
