---
name: remote-shelley
description: Use when the user wants this VM to act as a routing front-end that swaps its Shelley port over to a REMOTE Shelley instance (e.g. one on their own infrastructure, reached over Tailscale at http://aifoundry1:32768), so that opening this VM's normal Shelley URL talks to the remote instance. Handles swap / off / status; swaps are sticky and guarded by a watchdog that fails over to the local Shelley if the remote stops answering.
---

# remote-shelley — swap this VM's Shelley for a remote one

## What it is

`remote-shelley` makes the exe.dev VM a pure routing mechanism: it stops the
local Shelley, binds Shelley's local port (127.0.0.1:9999) with a small
reverse proxy, and forwards everything to a REMOTE Shelley instance —
typically on the user's own infrastructure, reached over Tailscale.

Because the proxy binds the SAME port the local Shelley serves on, exe.dev's
native HTTPS proxy (which already fronts :9999) keeps working unchanged: TLS
termination, authentication, and the `X-Exedev-*` headers are preserved
end-to-end. WebSockets and long-lived SSE streams are supported.

## The danger this is built around

Swapping the port **stops the local Shelley, which kills the very agent
process serving this conversation**. A naive swap in the foreground dies
mid-operation, leaving NOTHING listening on the port. So the actual swap is
always handed off to a DETACHED systemd unit (`remote-shelley-swap.service`)
that survives the restart, health-checks the result, and starts a watchdog
that fails over to the local Shelley if the remote stops answering.

The swap is **sticky**: there is deliberately NO timed auto-restore, because
after a swap the UI in front of the user is the REMOTE Shelley — which has no
`remote-shelley` tool — so there'd be nowhere to type `keep` to stop a grace
timer from bouncing a good swap back. The watchdog is the safety net.

**You (the agent) never run the swap steps yourself. You only schedule the
detached unit, then end your turn so your report flushes before the restart.**

## Prerequisites

- The remote Shelley URL must be reachable from the VM, e.g. over Tailscale:
  `curl -sI http://aifoundry1:32768/`  should return an HTTP status.
- Tailscale must be up on the VM if the remote is tailnet-only.

## Commands

Typed as the first word of a message (the chat-message/new-conversation hooks
rewrite it), or via the `/remote-shelley` slash command, or the CLI at
`/usr/local/bin/remote-shelley`:

| Command | Effect |
|---|---|
| `remote-shelley <url>` | Swap the port to proxy `<url>` (e.g. `http://aifoundry1:32768`). Sticky. |
| `remote-shelley swap <url>` | Same, explicit form. |
| `remote-shelley off` | Swap back to the local Shelley now. |
| `remote-shelley status` | Show what's answering on the port + watchdog activity. |
| `remote-shelley keep` | No-op (legacy). Swaps are sticky, so nothing to confirm. |

With no URL, the default is `REMOTE_SHELLY_UPSTREAM` from
`~/.config/shelley/hooks/config.env`.

## How to drive it (agent behavior)

For a **swap**: run `remote-shelley swap <url>` DIRECTLY (no subagent). It
schedules the detached unit ~5s out. Then immediately tell the user the swap
is armed and STICKY (no grace timer — nothing to confirm), that a watchdog
guards it (auto fail-back to local if the remote dies), and that to return to
the local Shelley they run `remote-shelley off` from a still-open local
conversation or over SSH. The log is at
`~/.config/shelley/remote-shelley/swap.log`. **End your turn promptly — the
restart kills you; do not wait to observe it.**

While a swap is active, a **watchdog** (`remote-shelley-watchdog.service`)
probes the proxy end-to-end every ~15s; if the remote stops answering for
~45s+ it fails over to the local Shelley automatically and logs it to
`swap.log`. So a swap can self-heal even without the operator.

**Tailscale:** the upstream is usually a MagicDNS name whose resolution depends
on Tailscale's DNS (`100.100.100.100`). The watchdog is Tailscale-aware — it
checks `tailscale status` `BackendState` on each failed probe and waits out a
transient tailscaled restart WITHOUT counting it toward failover. Only failures
while Tailscale is healthy fail over. Failover is always safe: the local
Shelley fallback has no Tailscale dependency.

For **keep** / **off** / **status**: also direct one-liners via the CLI.

## Layout

- Proxy binary + config + scripts live in `~/.config/shelley/remote-shelley/`.
- systemd unit: `remote-shelley.service` (started only during a swap).
- Hook payload: `~/.config/shelley/hooks/{new-conversation,chat-message,command-dispatch.py,config.env,slash/remote-shelley}`.
- Logs: `~/.config/shelley/remote-shelley/swap.log` (orchestration) and
  `proxy.log` (per-request proxy log).

## Troubleshooting

| Symptom | Fix |
|---|---|
| After a swap, nothing answers on the URL | The swap preflights the upstream first and restores the local Shelley on failure; check `swap.log`. If the VM is wedged, the watchdog fails over to local. |
| Swap starts but later bounces back to local | The watchdog detected the remote stopped answering (while Tailscale was healthy) and failed over. Check `swap.log` for `watchdog` lines and the remote's stability. |
| 502 from the proxy | Remote Shelley unreachable from the VM (Tailscale down?). Check `curl -sI <upstream>/`. |
| Conversation cut off mid-swap | Expected — the restart kills the agent. Wait a few seconds and reload; if the swap failed, the local Shelley is restored automatically. |
| Swapped to remote, but later I'm back on local without running `off` | The watchdog detected the remote stopped answering and failed over. Check `swap.log` for `watchdog` lines and confirm the remote + Tailscale are stable. |

## Verifying installation

```sh
remote-shelley status
curl -sI http://aifoundry1:32768/   # upstream reachable
ls ~/.config/shelley/hooks/remote-shelley 2>/dev/null; ls ~/.config/shelley/hooks/slash/remote-shelley
```
