#!/usr/bin/env bash
# Watchdog: continuously verify the remote-shelley proxy is actually serving
# the REMOTE Shelley, and fail over to the LOCAL Shelley if it stops working
# for a sustained period.
#
# Runs as remote-shelley-watchdog.service, started automatically with the
# proxy (BindsTo/PartOf) and stopped whenever the proxy stops. If the proxy
# dies because a RESTORE is underway, the watchdog sees the proxy unit go
# inactive and exits quietly WITHOUT restoring (the restore is already doing
# that). It only initiates a restore itself when the proxy is supposedly
# running but traffic is failing end-to-end.
#
# Config (config.env): REMOTE_SHELLY_WATCH_INTERVAL, REMOTE_SHELLY_WATCH_FAILS,
# REMOTE_SHELLY_SOCK_URL. The probe hits the proxy's own port with a cache-buster
# so it exercises the full VM->proxy->upstream->back path on every check.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/../config.env"
[ -f "$CFG" ] || { echo "FATAL: no config at $CFG" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CFG"
RESTORE="$HERE/remote-shelley-restore.sh"
mkdir -p "$REMOTE_SHELLY_STATE_DIR"
LOG="$REMOTE_SHELLY_STATE_DIR/swap.log"
log() { echo "$(date -Is) [watchdog] $*" >>"$LOG"; }

INTERVAL="${REMOTE_SHELLY_WATCH_INTERVAL:-15}"
MAXFAILS="${REMOTE_SHELLY_WATCH_FAILS:-3}"

# trigger_restore <reason>
# Hand the restore to a DETACHED systemd transient unit. CRITICAL: the restore
# stops remote-shelley.service, which (via BindsTo/PartOf) also stops THIS
# watchdog service — so running the restore inline would kill the restore
# script itself (a child of the watchdog) before it could start the local
# Shelley, leaving the VM dark. A detached unit survives that teardown.
# systemd-run needs root; the watchdog runs as root already (its unit has no
# User=), but use sudo defensively in case that ever changes.
trigger_restore() {
  local reason="$1"
  log "triggering detached restore ($reason)"
  local SUDO=""; [ "$(id -u)" = "0" ] || SUDO="sudo"
  $SUDO systemctl reset-failed remote-shelley-restore.service 2>/dev/null || true
  $SUDO systemd-run --collect --unit=remote-shelley-restore --on-active=2s "$RESTORE" || \
    log "ERROR: failed to schedule detached restore"
}

log "start: probing $REMOTE_SHELLY_SOCK_URL every ${INTERVAL}s, failover after $MAXFAILS consecutive failures"
fails=0
while true; do
  sleep "$INTERVAL"

  # If the proxy unit is no longer active, a restore/swap-off is in progress
  # or the proxy crashed and systemd is restarting it. Either way our job is
  # not to fight it: if the proxy is gone for good, this unit is stopped via
  # PartOf; if it's restarting, the next loop will probe again.
  if ! systemctl is-active --quiet remote-shelley.service; then
    log "proxy unit inactive — assuming restore/restart in progress; standing down"
    fails=0
    # Give systemd a moment; if the proxy isn't coming back and no local
    # Shelley is serving either, ensure the local Shelley is restored so the
    # VM is never left dark.
    sleep "$INTERVAL"
    if ! systemctl is-active --quiet remote-shelley.service; then
      if ! curl -s -m 4 -o /dev/null "$REMOTE_SHELLY_SOCK_URL"; then
        log "nothing answering after proxy stop; ensuring local Shelley is restored"
        trigger_restore "proxy-stopped-nothing-serving"
      fi
      exit 0
    fi
    continue
  fi

  # End-to-end probe through the proxy (cache-buster defeats any caching).
  if curl -s -m 8 -o /dev/null "$REMOTE_SHELLY_SOCK_URL?rs-watchdog=$(date +%s)"; then
    if [ "$fails" -gt 0 ]; then log "recovered after $fails failure(s)"; fi
    fails=0
  else
    # Tailscale-awareness: if the tailnet itself is down (tailscaled restarting,
    # MagicDNS 100.100.100.100 unreachable, tunnel dropped), the probe failure is
    # NOT the remote Shelley's fault and is usually transient (tailscaled
    # restarts on-failure in a few seconds). Don't burn failover budget on it —
    # wait it out. Only failure WHILE Tailscale is healthy means the remote
    # Shelley itself is gone and we should fail over.
    ts_state="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || echo unknown)"
    if [ "$ts_state" != "Running" ]; then
      log "probe failed but Tailscale BackendState='$ts_state' (transient) — waiting, NOT counting"
      continue
    fi
    fails=$((fails + 1))
    log "probe FAILED with Tailscale healthy ($fails/$MAXFAILS)"
    if [ "$fails" -ge "$MAXFAILS" ]; then
      log "upstream unreachable for $((MAXFAILS * INTERVAL))s+ (Tailscale OK) — failing over to local Shelley"
      trigger_restore "watchdog-failover"
      exit 0
    fi
  fi
done
