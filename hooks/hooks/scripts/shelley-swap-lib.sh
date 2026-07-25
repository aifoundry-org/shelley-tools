#!/usr/bin/env bash
# Shared helpers for the shelley hot-swap apply/rollback scripts.
# Sourced (not executed) by shelley-swap-apply.sh and shelley-swap-rollback.sh.
# These scripts run as root inside a detached systemd transient unit.
#
# The hard lesson these helpers encode:
#   * A shelley binary can be present on disk yet REFUSE to start, because of
#     the ui/embedfs.go "UI build is stale!" self-check that runs in init() and
#     os.Exit(1)s on any invocation. So "the file exists" is NOT proof it boots.
#   * Therefore: never install a binary we haven't watched start (preflight),
#     and never roll back to a binary we haven't watched start either. Always
#     pick a rollback target by actually trying to boot candidates.

# --- Load environment-specific config ---------------------------------------
# config.env lives next to the hooks (../config.env relative to scripts/).
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CFG="$_LIB_DIR/../config.env"
if [ ! -f "$_CFG" ]; then
  echo "FATAL: config not found at $_CFG (copy config.env.example and edit)" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$_CFG"

LIVE="$SHELLEY_LIVE_BIN"
SVC="$SHELLEY_SVC"
SOCK_URL="$SHELLEY_SOCK_URL"
SVC_USER="$SHELLEY_SVC_USER"
STATE_DIR="$SHELLEY_STATE_DIR"

log() { echo "$(date -Is) $*"; }

# preflight_binary <path>
# Returns 0 iff the binary starts and exits cleanly on a cheap subcommand
# (`version`). This exercises the SAME init()-time staleness gate that would
# kill it under systemd, so a pass here means it will boot as the service.
# Runs as the service user from a neutral cwd with the service's HOME, because
# the staleness check walks srcDir relative to nothing and reads env.
preflight_binary() {
  local bin="$1"
  [ -n "$bin" ] || return 2
  [ -f "$bin" ] && [ -x "$bin" ] || return 2
  if [ "$(id -u)" = "0" ]; then
    ( cd /tmp && timeout 20 sudo -u "$SVC_USER" -H \
        env HOME=/home/"$SVC_USER" USER="$SVC_USER" \
        "$bin" version ) >/dev/null 2>&1
  else
    ( cd /tmp && timeout 20 "$bin" version ) >/dev/null 2>&1
  fi
}

# install_atomic <src>
# Copy src onto the live path atomically (temp on same fs, then rename).
install_atomic() {
  local src="$1" tmp
  tmp="$(dirname "$LIVE")/.shelley.swap.$$"
  install -m 0755 "$src" "$tmp"
  mv -f "$tmp" "$LIVE"
}

# healthcheck_service [timeout_secs]
# Returns 0 iff the service becomes active AND the socket answers HTTP within
# the timeout. This is the real proof the swapped/rolled-back binary is serving.
healthcheck_service() {
  local deadline=$(( $(date +%s) + ${1:-30} )) state code
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state="$(systemctl is-active "$SVC" 2>/dev/null || true)"
    if [ "$state" = "active" ]; then
      # Key off curl's EXIT STATUS, not just the printed code: on a refused/
      # timed-out connection curl exits nonzero and prints "000". Only a
      # successful transfer with a real (non-000) HTTP status counts as serving.
      if code="$(curl -s -m 4 -o /dev/null -w '%{http_code}' "$SOCK_URL" 2>/dev/null)"; then
        case "$code" in
          ""|000) : ;;  # connected process died mid-response / no status
          *) log "healthcheck OK (state=active http=$code)"; return 0 ;;
        esac
      fi
    fi
    if [ "$state" = "failed" ]; then
      log "healthcheck: service entered failed state"
    fi
    sleep 2
  done
  log "healthcheck FAILED (last state=$state http=${code:-n/a})"
  return 1
}

# candidate_targets [preferred]
# Emit, one per line, an ordered list of rollback-candidate binary paths:
# the caller-preferred one first, then newest backups/snapshots, then the
# CI fallbacks. Deduplicated; the live path itself is intentionally excluded.
candidate_targets() {
  local preferred="${1:-}"
  {
    [ -n "$preferred" ] && printf '%s\n' "$preferred"
    ls -1t "$STATE_DIR"/shelley-backup-* 2>/dev/null
    ls -1t "$STATE_DIR"/shelley-prelive-* 2>/dev/null
    printf '%s\n' "$LIVE.prev"
    printf '%s\n' "$LIVE.old"
  } | awk 'NF && !seen[$0]++'
}

# choose_good_target [preferred]
# Print the first candidate that PREFLIGHTS (actually boots now). Return 1 if
# none do. This is what makes rollback reliable: we never install a binary that
# we couldn't get to start.
choose_good_target() {
  local preferred="${1:-}" c
  while IFS= read -r c; do
    [ -e "$c" ] || continue
    if preflight_binary "$c"; then
      log "rollback target verified bootable: $c" 1>&2
      printf '%s\n' "$c"
      return 0
    else
      log "candidate rejected (won't boot): $c" 1>&2
    fi
  done < <(candidate_targets "$preferred")
  return 1
}
