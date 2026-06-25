#!/usr/bin/env bash
# Send one line of literal text to a line cook pane, then Enter.
# Usage: brigade-send.sh <ticket-id> <text...>
#   <ticket-id> resolved through state/<id>.meta to get the Zellij pane id.
#   Pass a numeric pane id directly to target a pane outside this brigade home.
# Special keys: brigade-send.sh <ticket-id> --key Escape   (or Enter, C-c, ...)
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the composer clears. If a swallowed
# Enter is positively confirmed (text still sitting in composer after all retries),
# brigade-send exits NON-ZERO so the caller knows the steer did not land.
# Tune with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP (0.4).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/brigade-zellij-lib.sh
. "$SCRIPT_DIR/brigade-zellij-lib.sh"

"$SCRIPT_DIR/brigade-guard.sh" || true

resolve_pane() {
  local arg=$1
  case "$arg" in
    [0-9]*)
      echo "$arg"
      ;;
    brigade-*)
      local meta="$STATE/${arg#brigade-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $arg in $STATE" >&2
        exit 1
      fi
      local pane
      pane=$(grep '^pane=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$pane" ] || { echo "error: no pane recorded in $meta" >&2; exit 1; }
      echo "$pane"
      ;;
    *)
      local meta="$STATE/$arg.meta"
      if [ -f "$meta" ]; then
        local pane
        pane=$(grep '^pane=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
        [ -n "$pane" ] || { echo "error: no pane recorded in $meta" >&2; exit 1; }
        echo "$pane"
      else
        echo "error: cannot resolve '$arg' to a pane id" >&2
        exit 1
      fi
      ;;
  esac
}

PANE=$(resolve_pane "$1")
shift

# Key name → Zellij byte sequence mapping
# zellij action write accepts decimal byte values
send_key() {
  local key=$1
  zellij action focus-terminal-pane "$PANE" 2>/dev/null || true
  case "$key" in
    Escape|ESC|esc)   zellij action write 27 ;;
    Enter|ENTER)      zellij action write 13 ;;
    "C-c"|ctrl-c)     zellij action write 3  ;;
    "C-d"|ctrl-d)     zellij action write 4  ;;
    Tab)              zellij action write 9  ;;
    *)
      echo "error: unknown key '$key'; supported: Escape, Enter, C-c, C-d, Tab" >&2
      exit 1
      ;;
  esac
}

if [ "${1:-}" = "--key" ]; then
  send_key "${2:-Enter}"
else
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing. Give popups time to settle.
  case "$*" in /*) settle=1.2 ;; *) settle=0.3 ;; esac
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify.
  verdict=$(fm_zellij_submit_core "$PANE" "$*" "$retries" "$sleep_s" "$settle")
  case "$verdict" in
    pending)
      echo "error: text not submitted to pane $PANE (Enter swallowed; text left in composer)" >&2
      exit 1
      ;;
    send-failed)
      echo "error: text not sent to pane $PANE (zellij write-chars failed)" >&2
      exit 1
      ;;
  esac
fi
