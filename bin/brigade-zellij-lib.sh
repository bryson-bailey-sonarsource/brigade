#!/usr/bin/env bash
# brigade-zellij-lib.sh — shared Zellij pane primitives for brigade.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Sourced by both the away-mode
# daemon (bin/brigade-supervise-daemon.sh) and bin/brigade-send.sh so the composer/submit
# logic cannot drift between the two.
#
# Zellij pane operations:
#   - Write text:  zellij action write-chars <text>  (targets focused pane)
#   - Send key:    zellij action write <bytes>         (raw key codes)
#   - Dump screen: zellij action dump-screen /tmp/pane-<id>.txt
#   - Focus pane:  zellij action focus-next-pane / focus-previous-pane
#
# Pane targeting: Zellij CLI acts on the FOCUSED pane. Brigade tracks pane IDs
# in state/<id>.meta (pane=<zellij-pane-id>). To target a specific pane we
# focus it first, run the action, then restore focus if needed.
#
# Tab state convention (AGENTS.md):
#   ⏳ <name>  — working
#   🔴 <name>  — needs input
#   ✅ <name>  — done
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# dim-ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors brigade-watch.sh / the daemon).
#
# All functions are `set -u` and `set -e` safe (guarded zellij calls, explicit
# returns) so they can be sourced into either context.

FM_ZELLIJ_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.'

# ---------------------------------------------------------------------------
# fm_zellij_dump_pane: dump the visible screen of a pane to stdout.
# Uses zellij action dump-screen which writes to a file; we read + delete it.
# ---------------------------------------------------------------------------
fm_zellij_dump_pane() {  # <pane-id>
  local pane_id=$1 tmpfile
  tmpfile=$(mktemp /tmp/brigade-pane-XXXXXX.txt)
  # Focus the target pane, dump, restore is not needed for read-only ops.
  # dump-screen writes the current visible contents to a file.
  if ! zellij action focus-terminal-pane "$pane_id" 2>/dev/null; then
    rm -f "$tmpfile"
    return 1
  fi
  if ! zellij action dump-screen "$tmpfile" 2>/dev/null; then
    rm -f "$tmpfile"
    return 1
  fi
  cat "$tmpfile"
  rm -f "$tmpfile"
}

# ---------------------------------------------------------------------------
# fm_zellij_strip_ghost: remove dim/faint (ANSI SGR 2) styled runs from one
# captured composer line. Identical logic to the old tmux version — the input
# source changed (dump-screen vs capture-pane) but the ANSI stripping is the same.
# ---------------------------------------------------------------------------
fm_zellij_strip_ghost() {
  LC_ALL=C awk '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    {
      line = $0; out = ""; dim = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38" || code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0" || code == "22") dim = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue
        }
        if (dim == 0) out = out c
        i++
      }
      print out
    }
  '
}

# ---------------------------------------------------------------------------
# fm_zellij_composer_state: classify the cursor/composer line of a pane.
# Returns: empty | pending | unknown
# Dumps the last few lines of the pane and checks the bottom-most non-blank line.
# ---------------------------------------------------------------------------
fm_zellij_composer_state() {  # <pane-id> -> empty|pending|unknown
  local pane_id=$1 tmpfile raw line stripped
  tmpfile=$(mktemp /tmp/brigade-composer-XXXXXX.txt)

  if ! zellij action focus-terminal-pane "$pane_id" 2>/dev/null; then
    rm -f "$tmpfile"
    printf 'unknown'; return 0
  fi
  if ! zellij action dump-screen "$tmpfile" 2>/dev/null; then
    rm -f "$tmpfile"
    printf 'unknown'; return 0
  fi

  # Get the last non-empty line (the composer line)
  raw=$(tail -20 "$tmpfile" | grep -v '^[[:space:]]*$' | tail -1 || true)
  rm -f "$tmpfile"

  [ -n "$raw" ] || { printf 'empty'; return 0; }

  line=$(printf '%s\n' "$raw" | fm_zellij_strip_ghost)
  # Strip composer box borders
  stripped=${line//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  # Trim whitespace
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"

  [ -n "$stripped" ] || { printf 'empty'; return 0; }

  if [ -n "${FM_COMPOSER_IDLE_RE:-}" ] \
     && printf '%s' "$stripped" | grep -qiE "$FM_COMPOSER_IDLE_RE"; then
    printf 'empty'; return 0
  fi

  case "$stripped" in
    '>'|'❯'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac

  if printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_ZELLIJ_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi

  printf 'pending'; return 0
}

# ---------------------------------------------------------------------------
# fm_pane_input_pending: true if the cursor line holds real unsubmitted text.
# ---------------------------------------------------------------------------
fm_pane_input_pending() {  # <pane-id>
  [ "$(fm_zellij_composer_state "$1")" = pending ]
}

# ---------------------------------------------------------------------------
# fm_pane_is_busy: true if the pane's last lines show a busy footer.
# ---------------------------------------------------------------------------
fm_pane_is_busy() {  # <pane-id>
  local pane_id=$1 tmpfile tail40
  tmpfile=$(mktemp /tmp/brigade-busy-XXXXXX.txt)
  if ! zellij action focus-terminal-pane "$pane_id" 2>/dev/null || \
     ! zellij action dump-screen "$tmpfile" 2>/dev/null; then
    rm -f "$tmpfile"
    return 1
  fi
  tail40=$(tail -40 "$tmpfile")
  rm -f "$tmpfile"
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_ZELLIJ_BUSY_REGEX_DEFAULT}"
}

# ---------------------------------------------------------------------------
# fm_zellij_submit_enter_core: send Enter, verify composer cleared, retry.
# ---------------------------------------------------------------------------
fm_zellij_submit_enter_core() {  # <pane-id> <retries> <enter-sleep>
  local pane_id=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    # Focus and send Enter (byte 13 = carriage return)
    zellij action focus-terminal-pane "$pane_id" 2>/dev/null || true
    zellij action write 13 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_zellij_composer_state "$pane_id")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# ---------------------------------------------------------------------------
# fm_zellij_submit_core: type text into pane ONCE, send Enter, verify.
# Returns verdict: empty|pending|unknown|send-failed
# ---------------------------------------------------------------------------
fm_zellij_submit_core() {  # <pane-id> <text> <retries> <enter-sleep> <settle>
  local pane_id=$1 text=$2 retries=$3 sleep_s=$4 settle=$5

  # Focus pane, write text
  if ! zellij action focus-terminal-pane "$pane_id" 2>/dev/null; then
    printf 'send-failed'; return 0
  fi
  if ! zellij action write-chars "$text" 2>/dev/null; then
    printf 'send-failed'; return 0
  fi
  sleep "$settle"
  fm_zellij_submit_enter_core "$pane_id" "$retries" "$sleep_s"
}
