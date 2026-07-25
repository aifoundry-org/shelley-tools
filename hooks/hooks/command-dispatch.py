#!/usr/bin/env python3
"""Shared command dispatcher for Shelley hooks.

Recognizes a small, growing set of "commands" that the user types as the
first word of a message (e.g. `rebase v0.99.917353104`). When a message
matches a known command, we REWRITE it into a detailed instruction telling
the current agent to launch a subagent that carries out the task.

Entry points (all symlink to this file):
  - new-conversation hook: stdin/stdout JSON, "prompt" field.
  - chat-message hook:     stdin/stdout JSON, "message" field.
  - slash/<cmd> hooks:     stdin JSON {"command","args",...}, PLAIN-text stdout.

Unknown/no-match => empty stdout (no change).

Environment-specific values (repo path, service, remotes, ...) come from
config.env sitting next to this file. To add a command: add a handler and
register it in COMMANDS, then add a slash/<name> symlink.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
SCRIPTS = os.path.join(HERE, "scripts")


def load_config():
    """Parse the sibling config.env (simple KEY=VALUE lines)."""
    path = os.path.join(HERE, "config.env")
    if not os.path.isfile(path):
        sys.stderr.write(
            f"shelley-command-hooks: config not found at {path} "
            "(copy config.env.example and edit)\n"
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
REPO = CFG["SHELLEY_REPO"]
SVC = CFG["SHELLEY_SVC"]
LIVE = CFG["SHELLEY_LIVE_BIN"]
STATE_DIR = CFG["SHELLEY_STATE_DIR"]
UPSTREAM = CFG["SHELLEY_UPSTREAM_REMOTE"]
FORK = CFG["SHELLEY_FORK_REMOTE"]
FORK_BRANCH = CFG["SHELLEY_FORK_BRANCH"]
PREFIX = CFG["SHELLEY_BRANCH_PREFIX"]
# Base name of the rollback timer unit (kept fixed so keep/rollback can find it).
ROLLBACK_TIMER = "shelley-swap-rollback"


def cmd_rebase(arg: str):
    tag = arg.strip().split()[0] if arg.strip() else ""
    if not tag:
        return None
    branch = f"{PREFIX}{tag}"
    fork_ref = f"{FORK}/{FORK_BRANCH}"
    up_ref = f"{UPSTREAM}/{FORK_BRANCH}"
    return f"""Launch a subagent to rebase the fork onto upstream tag `{tag}`.

Use the `subagent` tool with slug `rebase-{tag}` and reasoning `high`. Do NOT
do the git work yourself in this conversation — delegate it. Pass the subagent
the full context and instructions below. Report back to me ONLY once the
subagent reports success (branch builds + tests pass), or if it needs a
decision from me. It is fine for the subagent to ask me for help.

=== Instructions to give the subagent ===

You are performing a careful git rebase in the repo at `{REPO}`.

Background / repo layout:
  - Remote `{UPSTREAM}` = upstream mainline. Release tags like `{tag}` live here.
  - Remote `{FORK}` = the downstream fork. The fork's work lives on
    `{fork_ref}` (this is "the fork branch").

Goal: create a branch `{branch}` based on upstream tag `{tag}`, then replay all
of the fork's own commits on top of it.

Steps — be very careful, and stop to ask the user if anything is ambiguous:
  1. `cd {REPO}`. Confirm the working tree is clean (`git status`). If it is
     dirty, STOP and ask the user how to proceed — do not discard work.
  2. Fetch the latest state of every remote, including tags:
       `git fetch --all --tags --prune`
  3. Verify the tag exists: `git rev-parse --verify refs/tags/{tag}`. If it
     does not exist, STOP and ask the user to confirm the tag name.
  4. Create the target branch from the tag:
       `git checkout -b {branch} {tag}`
     (If `{branch}` already exists, STOP and ask the user whether to overwrite.)
  5. Rebase the fork's commits onto this branch. The commits to replay are
     those on `{fork_ref}` that are not already upstream. Determine the fork's
     divergence point with the upstream default branch:
       `MB=$(git merge-base {fork_ref} {up_ref})`
     Then rebase that range onto the new branch:
       `git rebase --onto {branch} $MB {fork_ref}`
     Inspect `git log --oneline $MB..{fork_ref}` first to sanity-check the set
     of commits being moved, and make sure it looks like the fork's real
     changes (not thousands of unrelated commits). If the range looks wrong,
     STOP and ask the user.
  6. Resolve conflicts one commit at a time. For each conflict, understand
     both sides before resolving. If a conflict is non-trivial, risky, or you
     are not confident in the correct resolution, STOP and ask the user for
     help rather than guessing. Never blindly take one side.
  7. When the rebase completes, ensure `{branch}` points at the final rebased
     commit.
  8. Build and test — everything must pass:
       - `make build`  (builds UI + Go binary)
       - `go test ./server`
       - `cd ui && pnpm run type-check && pnpm run type-check:vue`
     If any build/test fails due to the rebase, investigate and fix if the
     fix is obvious and safe; otherwise STOP and ask the user.
  9. Do NOT push anything unless the user explicitly asks. Leave the branch
     `{branch}` checked out locally.

Only report SUCCESS once branch `{branch}` exists, contains the rebased fork
commits, builds cleanly, and all tests pass. Otherwise, report exactly what
you need from the user.
"""


def cmd_swap(arg: str):
    ref = arg.strip().split()[0] if arg.strip() else ""
    if not ref:
        return None
    return f"""Launch a subagent to build git ref `{ref}` and hot-swap it in as the running
shelley binary, with an automatic 5-minute rollback safety net.

Use the `subagent` tool with slug `swap-{ref}` and reasoning `high`. Do NOT do
this work yourself in this conversation. Pass the subagent the full context and
instructions below. Report back to me as soon as the swap has been *scheduled*
(binary built, backup made, restart armed) — do not wait for the restart, because
the restart will kill this very conversation's process. It is fine for the
subagent to ask me for help.

IMPORTANT for YOU (the parent): after the subagent returns, immediately relay
its summary to me and remind me that I have ~5 minutes to confirm with `keep`
(the new build is good) or it will auto-roll-back. Then end your turn promptly
so the report is flushed to disk before the service restarts.

=== Instructions to give the subagent ===

You are hot-swapping the running shelley binary in the repo at `{REPO}`.

CRITICAL CONTEXT: shelley runs as the systemd service `{SVC}` with binary
`{LIVE}`. You (this subagent) execute *inside* that process. Restarting the
service will kill you. Therefore you must NOT restart the service yourself —
instead you build + back up, then hand off the install / restart /
rollback-arming to a DETACHED systemd transient unit that survives the restart.
Scripts for this already exist and are tested:
  - build:    {SCRIPTS}/shelley-swap-build.sh <repo> [out]  (prints BUILT=<path>)
  - apply:    {SCRIPTS}/shelley-swap-apply.sh <newbin> <backup>
  - rollback: {SCRIPTS}/shelley-swap-rollback.sh [target]

The apply/rollback scripts are hardened: the applier PREFLIGHTS the new binary
(refuses to install anything that won't even start), installs atomically,
restarts, HEALTH-CHECKS (service active + socket serving), and rolls back
IMMEDIATELY on failure to a VERIFIED-bootable target. So your job is mainly to
produce a good binary and hand it off; the scripts protect the service.

Note: `{ref}` may be a tag OR a local branch. Verify it with
`git rev-parse --verify {ref}` (do not assume refs/tags/).

Steps — be careful and stop to report if anything is ambiguous. Use change_dir,
not chained `cd`.

  1. Work in `{REPO}`. Note the current git state so you can return to it
     (`git rev-parse --abbrev-ref HEAD`, `git stash list`, `git status`). If
     the working tree is dirty, STOP and ask me how to proceed — do not discard
     work.
  2. `git fetch --all --tags --prune` (a fork-remote SSH failure may be
     harmless if the ref is local). Verify the ref: `git rev-parse --verify
     {ref}`. If not, STOP and ask me.
  3. Check out the ref: `git checkout --detach {ref}` (detached HEAD is fine;
     if checkout fails due to local changes, STOP and ask me).
  4. Build a fresh RELEASE binary using the version-independent wrapper:
       `{SCRIPTS}/shelley-swap-build.sh "$(pwd)" "$(pwd)/bin/shelley"`
     This builds the UI + Go binary to `bin/shelley`, but crucially produces a
     binary with the "UI build is stale!" self-check DISABLED. You MUST use
     this wrapper, NOT a plain `make build`. Background: a plain build embeds
     the absolute path of `ui/src` and the binary then runs a startup
     self-check that os.Exit(1)s if any source file is newer than the build.
     Since you build and deploy on the SAME machine, step 8's `git switch` back
     to the branch bumps ui/src mtimes and would brick the deployed binary on
     its next restart. The wrapper blanks the embedded srcDir, and works for
     arbitrary tags. It prints `BUILT=<path>` on success. If the build fails,
     restore the original git state (`git switch -`) and STOP, reporting the
     failure. Do NOT touch the running binary if the build failed.
  5. Sanity-check the built binary boots: `( cd /tmp && bin/shelley version )`
     should exit 0 and NOT print "UI build is stale!" (the applier will
     preflight it again before installing).
  6. Make a timestamped backup of the CURRENTLY running binary:
       `cp -a {LIVE} {STATE_DIR}/shelley-backup-$(date +%Y%m%d-%H%M%S)`
     Capture the exact backup path — you'll pass it to the apply script and it
     is the rollback target. (Use `sudo cp -a` if permission denied.)
  7. Clear any stale apply unit, then hand off to the DETACHED applier ~20s out
     so this conversation can flush its report first:
       `sudo systemctl reset-failed shelley-swap-apply.service 2>/dev/null; \\
        sudo systemctl stop shelley-swap-apply.timer 2>/dev/null`
       `sudo systemd-run --collect --unit=shelley-swap-apply --on-active=20s \\
          {SCRIPTS}/shelley-swap-apply.sh "$(pwd)/bin/shelley" "<backup-path>"`
     The apply script preflights, picks a verified-bootable rollback target,
     atomically installs at {LIVE}, restarts {SVC}, health-checks it (rolling
     back at once on failure), and only then arms an independent 5-minute
     auto-rollback timer (`{ROLLBACK_TIMER}`). Log: /tmp/shelley-swap.log.
  8. Restore the repo to its original branch/state (`git switch -`) so the
     working copy isn't left detached. (Does not affect the handed-off binary.)
  9. Report back with: the ref, the built binary path, the exact backup path,
     that the swap+restart is scheduled ~20s out, and that an automatic
     rollback fires in 5 minutes unless the operator runs `keep`. Do NOT wait.

Do not report success as "tested and working" — you cannot test the swapped
binary yourself (the restart kills you). Report only that the swap is armed,
plus your step-5 preflight result.
"""


def cmd_keep(arg: str):
    return f"""The operator has confirmed the freshly swapped shelley build is GOOD. Cancel
the pending 5-minute auto-rollback so the new binary stays.

Do this directly (no subagent needed — it's a one-liner):
  `sudo systemctl stop {ROLLBACK_TIMER}.timer 2>/dev/null; \\
   sudo systemctl reset-failed {ROLLBACK_TIMER}.service 2>/dev/null; \\
   echo "$(date -Is) KEEP: auto-rollback cancelled" | sudo tee -a /tmp/shelley-swap.log`

Then confirm to me that the auto-rollback is cancelled and the new binary is
now permanent. Also show `systemctl list-timers 'shelley-swap-*'` to prove the
timer is gone. If there was no pending timer (e.g. it already fired or was
never armed), say so plainly."""


def cmd_rollback(arg: str):
    return f"""The operator wants to immediately roll back the last shelley binary swap (do
not wait for the 5-minute timer).

The rollback must run DETACHED, because restarting {SVC} kills this
conversation's process. Find the most recent backup and hand off to the
detached rollback script:
  1. `BK=$(ls -1t {STATE_DIR}/shelley-backup-* 2>/dev/null | head -1)`.
     If none exists, STOP and tell me — there is nothing to roll back to.
  2. Schedule the detached rollback ~10s out so this report flushes first:
     `sudo systemd-run --collect --unit=shelley-swap-manual-rollback --on-active=10s \\
        {SCRIPTS}/shelley-swap-rollback.sh "$BK"`
  3. Report to me which backup is being restored and that the restart is
     scheduled ~10s out. Then end the turn promptly."""


# Registry of commands: name -> handler(arg_string) -> expanded text | None.
COMMANDS = {
    "rebase": cmd_rebase,
    "swap": cmd_swap,
    "keep": cmd_keep,
    "rollback": cmd_rollback,
}


def expand(message: str):
    """Return expanded instruction text, or None to leave message unchanged."""
    if not message:
        return None
    m = re.match(r"\s*([A-Za-z][A-Za-z0-9_-]*)\b(.*)", message, re.DOTALL)
    if not m:
        return None
    name, rest = m.group(1).lower(), m.group(2)
    handler = COMMANDS.get(name)
    if not handler:
        return None
    return handler(rest)


def main():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return  # no-op on bad input

    # Slash-hook shape: {"command": "swap", "args": "v1.2.3", ...}.
    # Slash hooks expect PLAIN replacement text on stdout (not JSON).
    if "command" in data and "args" in data:
        handler = COMMANDS.get(str(data.get("command", "")).lower())
        if not handler:
            return
        expanded = handler(data.get("args") or "")
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

    expanded = expand(data.get(field) or "")
    if expanded is None:
        return  # empty stdout = no change

    print(json.dumps({field: expanded}))


if __name__ == "__main__":
    main()
