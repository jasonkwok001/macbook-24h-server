#!/bin/bash
# macbook-24h-server.sh — Turn a MacBook into a 24/7 always-on server.
# Subcommands: setup | verify | audit | remove
# Usage:
#   macbook-24h-server.sh setup  [--display-sleep <minutes|keep|off>] [--appnap-bundle <bundle-id> ...]
#   macbook-24h-server.sh verify [--appnap-bundle <bundle-id> ...]
#   macbook-24h-server.sh audit  [--days N]
#   macbook-24h-server.sh remove [--restore-defaults]
#
# verify checks the *current* configuration; audit checks *history* — it reads
# the power log to prove whether the machine actually stayed awake since
# caffeinate started. Green assertions do not prove a clean sleep history, so
# run audit when you need evidence rather than configuration.
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
  echo "[INFO] power source = $(current_power_source)  (on BATT the machine sleeps; on AC a shut lid still drops to DarkWake — run 'audit')"
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

# ---------- audit ----------

# caffeinate_start_epoch: derive when the running caffeinate began, from the
# assertion age (e.g. "60:20:04"). Falls back to empty if unavailable.
caffeinate_start_epoch() {
  local el h m s
  el=$(pmset -g assertions 2>/dev/null \
       | awk '/pid [0-9]+\(caffeinate\).*PreventUserIdleSystemSleep/{print $4; exit}')
  [ -z "$el" ] && return 1
  IFS=: read -r h m s <<< "$el"
  echo $(( $(date +%s) - (10#$h*3600 + 10#$m*60 + 10#$s) ))
}

cmd_audit() {
  local days=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="${2:?missing value}"; shift 2 ;;
      *) shift ;;
    esac
  done

  local start_epoch start_str
  if start_epoch=$(caffeinate_start_epoch) && [ -n "$start_epoch" ]; then
    start_str=$(date -r "$start_epoch" '+%Y-%m-%d %H:%M:%S')
  else
    start_str=""
  fi
  # --days overrides: audit the tail of the window regardless of start time
  if [ "$days" -gt 0 ] 2>/dev/null; then
    start_epoch=$(( $(date +%s) - days*86400 ))
    start_str=$(date -r "$start_epoch" '+%Y-%m-%d %H:%M:%S')
  fi

  echo "================ AUDIT ================="
  if [ -n "$start_str" ]; then
    echo "[INFO] window start (caffeinate): $start_str"
  else
    echo "[WARN] could not derive caffeinate start; auditing whole power log"
  fi

  # Collect events at/after the window inside a single awk pass (timestamp
  # comparison is lexicographic and safe for the "%Y-%m-%d %H:%M:%S" prefix).
  local events
  events=$(pmset -g log 2>/dev/null \
    | grep -E "Entering (Sleep|DarkWake) state" \
    | awk -v t="$start_str" -F'	' 'length(t)==0 || substr($0,1,19) >= t')

  if [ -z "$events" ]; then
    echo "[OK]   zero sleep events in window — machine never slept"
  else
    local total ac batt real_sleep_ac
    total=$(printf '%s\n' "$events" | wc -l | tr -d ' ')
    ac=$(printf '%s\n' "$events" | grep -c "Using AC")
    batt=$(printf '%s\n' "$events" | grep -c "Using Batt")
    real_sleep_ac=$(printf '%s\n' "$events" | grep "Entering Sleep state" | grep -c "Using AC")

    echo "[INFO] sleep/wake events in window: $total  (AC=$ac  BATT=$batt)"

    # Real (non-darkwake) sleep on AC means the assertions are not holding.
    if [ "$real_sleep_ac" -gt 0 ]; then
      echo "[FAIL] $real_sleep_ac full Sleep event(s) on AC — assertions not holding"
      printf '%s\n' "$events" | grep "Entering Sleep state" | grep "Using AC" \
        | cut -c1-19 | sed 's/^/         /'
    else
      echo "[OK]   zero full-Sleep events on AC — no power-loss sleep"
    fi

    # Clamshell DarkWake on AC: the Mac drops to DarkWake while the lid is shut
    # even with caffeinate assertions. Long gaps are the real 24/7 risk.
    local clam_ac
    clam_ac=$(printf '%s\n' "$events" | grep "DarkWake state due to 'Clamshell" | grep -c "Using AC")
    if [ "$clam_ac" -gt 0 ]; then
      echo "[WARN] $clam_ac clamshell DarkWake event(s) on AC (lid-shut drop-outs)"
      echo "       Longest gap:"
      longest_gap "$start_str" | sed 's/^/         /'
    fi

    # Battery events: expected only if unplugged; each one is a real outage.
    if [ "$batt" -gt 0 ]; then
      echo "[WARN] $batt event(s) on battery — outage while unplugged"
      printf '%s\n' "$events" | grep "Using Batt" | cut -c1-19 | head -3 \
        | awk 'NR==1{print "         first: " $0} NR>1{print "            then: " $0}'
      echo "         (plug in AC for true 24/7; lid-close never holds on battery)"
    fi
  fi

  # Overall awake ratio from boot.
  echo "[INFO] uptime: $(uptime | sed 's/.*up //; s/,.*//')"
  echo "========================================"
}

# longest_gap: print the longest silent stretch between consecutive sleep/wake
# events, which approximates how long the machine was actually down.
longest_gap() {
  local start_str="$1"
  # Build "epoch<TAB>readable" pairs, then let awk pick the largest delta.
  # (BSD awk on macOS has no strftime, so formatting stays in date/sed.)
  pmset -g log 2>/dev/null \
    | grep -E "Entering (Sleep|DarkWake) state|Wake from" \
    | awk -v t="$start_str" 'length(t)==0 || substr($0,1,19) >= t' \
    | grep -oE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" \
    | while IFS= read -r ts; do
        e=$(date -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null) || continue
        printf '%s\t%s\n' "$e" "$ts"
      done \
    | awk -F'\t' 'NR>1{d=$1-p; if(d>max){max=d; a=pt; b=$2}} {p=$1; pt=$2}
                  END{if(max>0) printf "%d min (%s -> %s)\n", max/60, a, b}'
}

case "${1:-}" in
  setup)  shift; cmd_setup "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  audit)  shift; cmd_audit "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  *) die "usage: $0 {setup [--display-sleep <min|keep|off>] [--appnap-bundle <id>]... | verify | audit [--days N] | remove}" ;;
esac
