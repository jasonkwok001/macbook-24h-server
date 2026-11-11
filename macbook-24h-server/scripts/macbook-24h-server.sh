#!/bin/bash
# macbook-24h-server.sh — Turn a MacBook into a 24/7 always-on server.
# Subcommands: setup | verify | remove
# Usage:
#   macbook-24h-server.sh setup  [--display-sleep <minutes|keep|off>] [--appnap-bundle <bundle-id> ...]
#   macbook-24h-server.sh verify [--appnap-bundle <bundle-id> ...]
#   macbook-24h-server.sh remove [--restore-defaults]
#
# --display-sleep:
#   <minutes> : set AC display sleep to N minutes (may trigger a macOS admin
#               authorization dialog via osascript when sudo is unavailable)
#   keep      : do not touch the system displaysleep value; keep display awake
#               forever via caffeinate -dimsu (-d prevent-display-sleep plus
#               -u simulate user activity => UserIsActive asserted; the screen
#               NEVER turns off — higher power use, OLED burn-in risk)
#   off       : leave displaysleep as-is but do NOT prevent display sleep
#               (display turns off per whatever the system setting is)
# --appnap-bundle: additionally disable App Nap for the given app bundle id(s),
#               so long-lived websocket/remote-control channels of that app are
#               not throttled after the display goes off. Takes effect after the
#               app is relaunched.

set -u

LABEL="com.macbook24h.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_TAG="[macbook-24h-server]"

die() { echo "$LOG_TAG ERROR: $*" >&2; exit 1; }
info() { echo "$LOG_TAG $*"; }

# ---------- helpers ----------

current_power_source() {
  pmset -g batt | head -1 | grep -q "AC Power" && echo "AC" || echo "BATT"
}

set_displaysleep() {
  # Try passwordless sudo first, then GUI admin prompt, else instruct user.
  local mins="$1"
  if sudo -n pmset -c displaysleep "$mins" 2>/dev/null; then
    info "displaysleep set to $mins minutes (AC)."
    return 0
  fi
  if [ "${1:-}" != "" ] && command -v osascript >/dev/null 2>&1 && [ -n "${DISPLAY:-1}" ]; then
    # GUI session: trigger the native authorization dialog
    if osascript -e "do shell script \"pmset -c displaysleep $mins\" with administrator privileges with prompt \"$LOG_TAG: set display sleep to $mins minutes\"" 2>/dev/null; then
      info "displaysleep set to $mins minutes (AC) via authorization dialog."
      return 0
    fi
    info "Authorization dialog was cancelled or failed."
  fi
  info "Could not set displaysleep automatically. Please run manually:"
  info "    sudo pmset -c displaysleep $mins"
  return 1
}

write_plist() {
  local flags="$1"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>$flags</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/macbook24h.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/macbook24h.err</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF
  info "LaunchAgent written: $PLIST (caffeinate $flags)"
}

load_agent() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
    || launchctl load "$PLIST" 2>/dev/null
  # Fallback: inside brokered/sandboxed agent shells, bootstrap into the user
  # gui domain can fail with "error 5: Input/output error". Elevate via the
  # native authorization dialog and use launchctl asuser.
  if ! pgrep -f "caffeinate -" >/dev/null; then
    info "Plain bootstrap failed; retrying via launchctl asuser with admin privileges (you may see one macOS authorization dialog)."
    osascript -e "do shell script \"launchctl asuser $(id -u) launchctl bootstrap gui/$(id -u) $PLIST\" with administrator privileges with prompt \"$LOG_TAG: load always-on server agent\"" 2>/dev/null \
      || die "Failed to load LaunchAgent by all known methods."
  fi
  sleep 1
  pgrep -f "caffeinate -" >/dev/null || die "caffeinate is not running after bootstrap."
}

disable_appnap_for() {
  local bundle="$1"
  defaults write "$bundle" NSAppSleepDisabled -bool YES \
    && info "App Nap disabled for $bundle (takes effect after that app relaunches)." \
    || info "WARN: could not write NSAppSleepDisabled for $bundle"
}

# ---------- commands ----------

cmd_setup() {
  local display_sleep="90"
  local bundles=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --display-sleep) display_sleep="${2:?missing value}"; shift 2 ;;
      --appnap-bundle) bundles+=("${2:?missing bundle id}"); shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  [ "$(uname)" = "Darwin" ] || die "This script only runs on macOS."

  local flags
  if [ "$display_sleep" = "keep" ]; then
    # Never let the display sleep either (-d pins display, -u asserts
    # UserIsActive). WARN upstream: the screen will stay lit forever.
    flags="-dimsu"
  else
    # Allow display to sleep; caffeinate only protects system/disk/lid.
    flags="-ims"
  fi

  info "Power source: $(current_power_source)  (note: lid-close protection requires AC)"
  write_plist "$flags"
  load_agent
  info "caffeinate running: $(pgrep -fl 'caffeinate -' | head -1)"

  if [ "$display_sleep" != "keep" ] && [ "$display_sleep" != "off" ]; then
    set_displaysleep "$display_sleep"
  fi

  for b in "${bundles[@]:-}"; do
    [ -n "$b" ] && disable_appnap_for "$b"
  done

  cmd_verify "${bundles[@]:-}"
}

cmd_verify() {
  local bundles=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --appnap-bundle) bundles+=("${2:?}"); shift 2 ;;
      *) shift ;;
    esac
  done
  echo "================ VERDICT ================"
  # 1. service
  if pgrep -f "caffeinate -" >/dev/null; then
    echo "[OK]   caffeinate running: $(pgrep -fl 'caffeinate -' | head -1 | cut -c1-70)"
  else
    echo "[FAIL] caffeinate NOT running (service dead?)"
  fi
  # 2. assertions
  local a
  for a in PreventUserIdleSystemSleep PreventDiskIdle PreventSystemSleep; do
    if pmset -g assertions | awk "/^ +$a /{print \$2}" | grep -q 1; then
      echo "[OK]   $a = 1"
    else
      echo "[FAIL] $a not asserted"
    fi
  done
  # 3. display assertion should be 0 unless 'keep'
  local disp
  disp=$(pmset -g assertions | awk '/^ +PreventUserIdleDisplaySleep /{print $2}')
  echo "[INFO] PreventUserIdleDisplaySleep = ${disp:-?} (0 = display may sleep; 1 = display pinned awake)"
  # 4. displaysleep value
  echo "[INFO] displaysleep(AC) = $(pmset -g custom | sed -n '/AC Power/,$p' | awk '/displaysleep/{print $2; exit}')"
  # 5. power source
  echo "[INFO] power source = $(current_power_source)  (BATT + lid close WILL sleep: Apple hard rule)"
  # 6. appnap
  for b in "${bundles[@]:-}"; do
    [ -z "$b" ] && continue
    if [ "$(defaults read "$b" NSAppSleepDisabled 2>/dev/null || echo 0)" = "1" ]; then
      echo "[OK]   App Nap disabled for $b"
    else
      echo "[FAIL] App Nap NOT disabled for $b"
    fi
  done
  # 7. boot persistence
  if [ -f "$PLIST" ]; then
    echo "[OK]   LaunchAgent plist present (auto-starts on login): $PLIST"
  else
    echo "[FAIL] LaunchAgent plist missing"
  fi
  echo "========================================="
}

cmd_remove() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null
  rm -f "$PLIST"
  pkill -f "caffeinate -ims" 2>/dev/null; pkill -f "caffeinate -dimsu" 2>/dev/null
  info "LaunchAgent removed. (Note: any displaysleep value previously set remains; restore with e.g. 'sudo pmset -c displaysleep 10' if desired.)"
}

case "${1:-}" in
  setup)  shift; cmd_setup "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  *) die "usage: $0 {setup [--display-sleep <min|keep|off>] [--appnap-bundle <id>]... | verify | remove}" ;;
esac
