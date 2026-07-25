#!/usr/bin/env bash
# Restores a KNOWN-GOOD shelley binary and restarts the service.
# Invoked by: the 5-minute auto-rollback timer, the applier's immediate
# rollback-on-failure path, or manually via the `rollback` command.
#
# Arg (optional): <backup-path> — a PREFERRED target. It is used only if it
# actually boots; otherwise (or if omitted) we self-select the newest bootable
# candidate. This is the core fix for the double-failure incident: a naive
# rollback blindly restores whatever path it was handed, which may be a dev
# binary that cannot start ('UI build is stale!'), leaving the service dead.
# We NEVER install a binary we haven't watched boot, and we ESCALATE through
# candidates + health-check the result.
set -uo pipefail
PREF="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shelley-swap-lib.sh
. "$HERE/shelley-swap-lib.sh"
LOG=/tmp/shelley-swap.log
exec >>"$LOG" 2>&1
echo
log "=== ROLLBACK: preferred='$PREF' ==="

restore_and_check() {
  local target="$1"
  log "restoring $target"
  install_atomic "$target"
  systemctl restart "$SVC"
  if healthcheck_service 40; then
    log "rollback SUCCESS: service serving on $target"
    return 0
  fi
  log "rollback target $target restarted but did NOT come up"
  return 1
}

# Build the ordered candidate list (preferred first) and try each until one is
# both bootable (preflight) and actually serves (healthcheck).
tried_any=0
while IFS= read -r c; do
  [ -e "$c" ] || continue
  tried_any=1
  if ! preflight_binary "$c"; then
    log "skip (won't boot on preflight): $c"
    continue
  fi
  if restore_and_check "$c"; then
    # Best effort: cancel any pending auto-rollback timer (manual rollback case).
    systemctl stop shelley-swap-rollback.timer 2>/dev/null || true
    exit 0
  fi
done < <(candidate_targets "$PREF")

if [ "$tried_any" = "0" ]; then
  log "FATAL: no rollback candidates exist at all."
else
  log "FATAL: exhausted all rollback candidates; none booted+served."
  log "       Operator intervention required. Known CI fallbacks:"
  log "       $LIVE.prev , $LIVE.old"
fi
exit 1
