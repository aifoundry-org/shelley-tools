#!/usr/bin/env bash
# Detached swap applier. Runs as root inside its own systemd transient unit
# (NOT in shelley's cgroup), so it survives restarting the shelley service.
#
# Args: <new-binary-path> <backup-path>
#
# Hardened flow. A naive version blindly installs + restarts, then arms a dumb
# 5-minute rollback to a backup that itself may not boot -> double failure. Now:
#   0. PREFLIGHT the new binary. If it can't even start, abort and DO NOT touch
#      the live binary. (This alone prevents the primary failure mode.)
#   1. Pre-select a VERIFIED-bootable rollback target BEFORE we change anything,
#      so the safety net is known-good rather than assumed-good.
#   2. Install the new binary atomically and restart the service.
#   3. HEALTH-CHECK: service active + socket answering HTTP. On failure, roll
#      back IMMEDIATELY to the verified target (don't wait 5 minutes).
#   4. Only if the new binary is healthy do we arm the 5-minute auto-rollback
#      grace timer for the operator's `keep`/`rollback` decision.
set -uo pipefail
NEWBIN="${1:-}"; BACKUP="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shelley-swap-lib.sh
. "$HERE/shelley-swap-lib.sh"
ROLLBACK="$HERE/shelley-swap-rollback.sh"
LOG=/tmp/shelley-swap.log
exec >>"$LOG" 2>&1
echo
log "=== APPLY: install $NEWBIN (backup=$BACKUP) ==="

# --- 0. Preflight the NEW binary --------------------------------------------
if [ ! -x "$NEWBIN" ]; then log "FATAL: new binary $NEWBIN missing/not executable"; exit 1; fi
if ! preflight_binary "$NEWBIN"; then
  log "FATAL: new binary FAILED preflight (won't start — e.g. 'UI build is stale!')."
  log "ABORTING swap. Live binary left untouched; service undisturbed."
  exit 1
fi
log "new binary passed preflight"

# --- 1. Pre-select a verified-bootable rollback target ----------------------
# Prefer the caller-supplied backup, but only if it actually boots; otherwise
# fall back to the newest bootable backup / CI binary. We snapshot the CURRENT
# live binary too, so we can return to exactly what's running now if it's good.
NOW_BAK="$STATE_DIR/shelley-prelive-$(date +%Y%m%d-%H%M%S)"
cp -a "$LIVE" "$NOW_BAK" 2>/dev/null && log "snapshotted current live binary -> $NOW_BAK"
SAFE_TARGET="$(choose_good_target "${BACKUP:-}")" || SAFE_TARGET=""
if [ -z "$SAFE_TARGET" ]; then
  # Last resort: the just-taken snapshot of the currently-running (working) bin.
  if preflight_binary "$NOW_BAK"; then SAFE_TARGET="$NOW_BAK"; fi
fi
if [ -z "$SAFE_TARGET" ]; then
  log "WARNING: no verified-bootable rollback target found. Proceeding, but"
  log "         auto-rollback will have nothing safe to restore."
else
  log "verified rollback target: $SAFE_TARGET"
fi

# --- 2. Install atomically + restart ----------------------------------------
install_atomic "$NEWBIN"
log "installed new binary at $LIVE"
systemctl restart "$SVC"
log "restart issued; health-checking..."

# --- 3. Health-check; roll back immediately on failure ----------------------
if healthcheck_service 40; then
  log "new binary is SERVING."
else
  log "new binary did NOT come up. Rolling back IMMEDIATELY."
  if [ -n "$SAFE_TARGET" ]; then
    "$ROLLBACK" "$SAFE_TARGET" || log "ERROR: immediate rollback script returned nonzero"
  else
    "$ROLLBACK" || log "ERROR: immediate self-selecting rollback returned nonzero"
  fi
  log "APPLY finished with rollback (new build rejected)."
  exit 1
fi

# --- 4. Arm the 5-minute operator grace timer -------------------------------
# Only reached when the new binary is healthy. Gives the operator time to run
# `keep`. If they do nothing, we restore the verified-good SAFE_TARGET.
systemctl stop shelley-swap-rollback.timer 2>/dev/null || true
systemctl reset-failed shelley-swap-rollback.service 2>/dev/null || true
if [ -n "$SAFE_TARGET" ]; then
  systemd-run --collect --unit=shelley-swap-rollback --on-active=5min \
    "$ROLLBACK" "$SAFE_TARGET"
  log "armed auto-rollback at +5min -> restore $SAFE_TARGET (run 'keep' to cancel)"
else
  log "NOT arming auto-rollback: no verified-good target. Run 'rollback' manually if needed."
fi
log "APPLY complete: new binary healthy and serving."
