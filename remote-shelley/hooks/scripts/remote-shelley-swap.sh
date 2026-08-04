#!/usr/bin/env bash
# Detached swap applier: take over Shelley's local port with a reverse proxy
# to a REMOTE Shelley. Runs as root inside its own systemd transient unit
# (remote-shelley-swap.service), NOT in shelley's cgroup, so it survives
# stopping the local Shelley — which kills the agent process that requested
# the swap.
#
# Arg: <upstream-url>   e.g. http://aifoundry1:32768
#
# Flow (mirrors the hardened shelley-swap-apply.sh lessons):
#   1. PREFLIGHT the upstream: it must answer HTTP before we disturb anything.
#   2. Stop the local Shelley (socket + service). The port must free up.
#   3. Start the proxy unit bound to the SAME port, health-check it serving
#      the REMOTE (not the local) Shelley.
#   4. On any failure: immediately restore the local Shelley — never leave the
#      VM with no Shelley answering on its front page port.
#   5. On success: the swap is STICKY. The watchdog (started above) is the
#      safety net — it fails over to the local Shelley if the remote stops
#      answering. We deliberately do NOT arm a timed auto-restore here: there
#      is nowhere to type `keep` once the UI is the remote Shelley, so a grace
#      timer would just bounce a perfectly good swap back after a few minutes.
#      To return to the local Shelley, run `remote-shelley off` (works from a
#      still-open local conversation or over SSH).
set -uo pipefail
UPSTREAM="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/../config.env"
[ -f "$CFG" ] || { echo "FATAL: no config at $CFG" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CFG"
RESTORE="$HERE/remote-shelley-restore.sh"
mkdir -p "$REMOTE_SHELLY_STATE_DIR"
LOG="$REMOTE_SHELLY_STATE_DIR/swap.log"
exec >>"$LOG" 2>&1
log() { echo "$(date -Is) $*"; }

echo
log "=== SWAP: proxy ${REMOTE_SHELLY_LISTEN} -> $UPSTREAM ==="
[ -n "$UPSTREAM" ] || { log "FATAL: no upstream given"; exit 1; }

# --- 1. Preflight: upstream must answer before we touch the local Shelley ---
if ! curl -s -m 8 -o /dev/null "$UPSTREAM/"; then
  log "FATAL: upstream $UPSTREAM does not answer HTTP — aborting, local Shelley untouched."
  exit 1
fi
log "upstream preflight OK"

# --- 2. Stop the local Shelley (this kills the requesting agent — fine, we
#        are a separate systemd unit) -----------------------------------------
systemctl stop "$SHELLEY_SOCKET_UNIT" "$SHELLEY_SERVICE_UNIT"
# Write the desired upstream for the proxy unit to read at start.
echo "$UPSTREAM" > "$REMOTE_SHELLY_STATE_DIR/upstream"
sleep 1

# --- 3. Start the proxy on the freed port + health-check --------------------
systemctl reset-failed remote-shelley.service 2>/dev/null || true
systemctl start remote-shelley.service
# Start the watchdog alongside the proxy (its lifecycle is bound to the proxy).
systemctl reset-failed remote-shelley-watchdog.service 2>/dev/null || true
systemctl start remote-shelley-watchdog.service 2>/dev/null || true
ok=0
deadline=$(( $(date +%s) + 40 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if code="$(curl -s -m 4 -o /dev/null -w '%{http_code}' "$REMOTE_SHELLY_SOCK_URL" 2>/dev/null)"; then
    case "$code" in ""|000) : ;; *) ok=1; break ;; esac
  fi
  sleep 2
done

if [ "$ok" != 1 ]; then
  log "proxy did NOT come up on $REMOTE_SHELLY_SOCK_URL — restoring local Shelley immediately."
  "$RESTORE" || log "ERROR: immediate restore returned nonzero"
  exit 1
fi
log "proxy is SERVING $UPSTREAM on ${REMOTE_SHELLY_LISTEN}"
log "watchdog active: will fail over to local Shelley if the remote stops answering"

# --- 4. Swap is sticky; watchdog is the safety net ---------------------------
# No timed auto-restore: the watchdog continuously verifies the remote keeps
# answering and fails over to the local Shelley if it doesn't. A grace timer
# would strand a good swap (nowhere to type `keep` once the UI is remote).
systemctl stop remote-shelley-restore.timer 2>/dev/null || true
systemctl reset-failed remote-shelley-restore.service 2>/dev/null || true
log "SWAP complete and sticky — watchdog guards it. Run 'remote-shelley off' to return to local."
log "SWAP complete."
