#!/usr/bin/env python3
"""Shared command dispatcher for the remote-shelley Shelley hooks.

Recognizes `remote-shelley` typed as the first word of a message and rewrites
it into a detailed instruction telling the current agent to carry out the
requested swap/keep/off operation — usually by handing off to the DETACHED
systemd machinery, because swapping the port kills the agent's own Shelley.

Entry points (all symlink/exec to this file):
  - new-conversation hook: stdin/stdout JSON, "prompt" field.
  - chat-message hook:     stdin/stdout JSON, "message" field.
  - slash/remote-shelley:  stdin JSON {"command","args",...}, PLAIN-text stdout.

Unknown/no-match => empty stdout (no change).

Environment-specific values come from config.env sitting next to this file.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
# The installed CLI is preferred; fall back to the in-repo launcher (dev).
CLI = "/usr/local/bin/remote-shelley"
if not os.path.exists(CLI):
    CLI = os.path.join(HERE, "remote-shelley")


def load_config():
    """Parse the sibling config.env (simple KEY=VALUE lines)."""
    path = os.path.join(HERE, "config.env")
    if not os.path.isfile(path):
        sys.stderr.write(
            f"remote-shelley: config not found at {path} (run install.sh)\n"
        )
        sys.exit(1)
    cfg = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


CFG = load_config()
DEFAULT_UPSTREAM = CFG.get("REMOTE_SHELLY_UPSTREAM", "")
GRACE = CFG.get("REMOTE_SHELLY_GRACE", "5min")
STATE_DIR = CFG.get("REMOTE_SHELLY_STATE_DIR", "/tmp")


def expand(args: str):
    """Return expanded instruction text for `remote-shelley <args>`, or None."""
    tokens = args.split()
    sub = ""
    rest = ""
    if tokens:
        sub = tokens[0].lower()
        rest = " ".join(tokens[1:])

    if sub in ("", "swap") or sub.startswith(("http://", "https://")):
        # `remote-shelley <url>`, `remote-shelley swap <url>`, or bare `remote-shelley`.
        if sub == "swap":
            upstream = rest.strip()
        else:
            upstream = args.strip()
        if not upstream:
            upstream = DEFAULT_UPSTREAM
        if not upstream.startswith(("http://", "https://")):
            return None
        return f"""Swap this VM's Shelley port over to the REMOTE Shelley at
{upstream}. The user will then be talking to that remote instance through
this VM's normal Shelley URL (exe.dev's native proxy fronts the same port).

Do this DIRECTLY (no subagent) — it is a single hand-off:

  {CLI} swap {upstream}

That schedules a DETACHED systemd unit which stops the local Shelley, binds
its port with a reverse proxy to {upstream}, health-checks it, and starts a
watchdog that fails over to the local Shelley if the remote stops answering.
The swap is STICKY — there is no grace timer to confirm against (there'd be
nowhere to type `keep` once the UI is the remote).

CRITICAL: the swap stops the local Shelley, which kills THIS conversation's
process. So: run the command, immediately relay to the user that the swap is
armed (~5s out) and sticky, that a watchdog guards it (auto fail-back if the
remote dies), and that to return to the local Shelley they run
`remote-shelley off` from a still-open local conversation or over SSH. Log:
{STATE_DIR}/swap.log. Then END YOUR TURN promptly so the report flushes
before the restart. Do not wait to observe the swap — you cannot survive it."""

    if sub == "keep":
        return f"""The operator ran `remote-shelley keep`. NOTE: as of the sticky-swap change
there is no longer a grace timer to cancel — a successful swap already stays
on the remote indefinitely, guarded by the watchdog. So `keep` is a no-op.

Do this directly (one-liner, no subagent):

  {CLI} keep

Then tell the user plainly: the swap is already sticky, nothing to confirm,
and to return to the local Shelley they can run `remote-shelley off` (from a
still-open local conversation or over SSH)."""

    if sub in ("off", "restore"):
        return f"""The operator wants to swap BACK to the LOCAL Shelley now (do not wait for
the auto-restore timer).

The restore must run DETACHED, because it kills the proxy the operator may be
talking through. Do this directly:

  {CLI} off

Report that the local Shelley is being restored (~3s out), then end the turn
promptly."""

    if sub == "status":
        return f"""Show the current remote-shelley status. Do this directly:

  {CLI} status

Report which Shelley (local or remote) is answering on the port, the units'
states, the last-used upstream, and any pending auto-restore timer."""

    return None


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return  # no-op on bad input

    # Slash-hook shape: {"command": "remote-shelley", "args": "...", ...}.
    # Slash hooks expect PLAIN replacement text on stdout (not JSON).
    if "command" in data and "args" in data:
        if str(data.get("command", "")).lower() not in ("remote-shelley",):
            return
        expanded = expand(data.get("args") or "")
        if expanded is None:
            return
        sys.stdout.write(expanded)
        return

    # new-conversation / chat-message shape: JSON in, JSON out.
    if "message" in data:
        field = "message"
    elif "prompt" in data:
        field = "prompt"
    else:
        return

    text = data.get(field) or ""
    m = re.match(r"\s*remote-shelley\b(.*)", text, re.DOTALL | re.IGNORECASE)
    if not m:
        return  # not our command: empty stdout = no change

    expanded = expand(m.group(1))
    if expanded is None:
        return

    print(json.dumps({field: expanded}))


if __name__ == "__main__":
    main()
