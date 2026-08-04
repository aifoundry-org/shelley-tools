#!/usr/bin/env bash
# Restore the LOCAL Shelley on its port, displacing the remote-shelley proxy.
# Invoked by: the auto-restore grace timer, the swap script's immediate
# failure path, or manually via `remote-shelley off`. Detached (systemd unit),
# because the restore kills the proxy that the operator may be talking through.
#
# Health-checks the result; if the local Shelley fails to come up we try to
# put the PROXY back so the VM is never left with nothing answering.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/../config.env"
[ -f "$CFG" ] || { echo "FATAL: no config at $CFG" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CFG"
mkdir -p "$REMOTE_SHELLY_STATE_DIR"
LOG="$REMOTE_SHELLY_STATE_DIR/swap.log"
exec >>"$LOG" 2>&1
log() { echo "$(date -Is) $*"; }

healthy() {
  local deadline=$(( $(date +%s) + 40 )) code
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if code="$(curl -s -m 4 -o /dev/null -w '%{http_code}' "$REMOTE_SHELLY_SOCK_URL" 2>/dev/null)"; then
      case "$code" in ""|000) : ;; *) return 0 ;; esac
    fi
    sleep 2
  done
  return 1
}

echo
log "=== RESTORE: local Shelley back on ${REMOTE_SHELLY_LISTEN} ==="
systemctl stop remote-shelley-restore.timer 2>/dev/null || true
systemctl stop remote-shelley-watchdog.service 2>/dev/null || true
systemctl stop remote-shelley.service 2>/dev/null || true
sleep 1
systemctl start "$SHELLEY_SOCKET_UNIT" "$SHELLEY_SERVICE_UNIT"

if healthy; then
  log "RESTORE complete: local Shelley serving."
  exit 0
fi

log "WARNING: local Shelley did not come up; attempting to put the proxy back."
systemctl start remote-shelley.service 2>/dev/null || true
if healthy; then
  log "proxy restored as fallback — local Shelley needs operator attention."
else
  log "FATAL: neither local Shelley nor proxy is serving on $REMOTE_SHELLY_SOCK_URL."
fi
exit 1
