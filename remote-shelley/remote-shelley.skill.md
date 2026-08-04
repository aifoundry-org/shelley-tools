---
name: remote-shelley
description: Use when the user wants this VM to act as a routing front-end that swaps its Shelley port over to a REMOTE Shelley instance (e.g. one on their own infrastructure, reached over Tailscale at http://aifoundry1:32768), so that opening this VM's normal Shelley URL talks to the remote instance. Handles swap / keep / off / status with an auto-restore safety net.
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
that survives the restart, health-checks the result, and arms an
auto-restore timer that puts the local Shelley back unless the operator
confirms with `keep`.

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
| `remote-shelley <url>` | Swap the port to proxy `<url>` (e.g. `http://aifoundry1:32768`). |
| `remote-shelley swap <url>` | Same, explicit form. |
| `remote-shelley keep` | Cancel the auto-restore; stay on the remote. |
| `remote-shelley off` | Swap back to the local Shelley now. |
| `remote-shelley status` | Show what's answering on the port + pending timers. |

With no URL, the default is `REMOTE_SHELLY_UPSTREAM` from
`~/.config/shelley/hooks/config.env`.

## How to drive it (agent behavior)

For a **swap**: run `remote-shelley swap <url>` DIRECTLY (no subagent). It
schedules the detached unit ~5s out. Then immediately tell the user the swap
is armed, that they have the grace period (default 5min) to type
`remote-shelley keep` or it swaps back, and that the log is at
`~/.config/shelley/remote-shelley/swap.log`. **End your turn promptly — the
restart kills you; do not wait to observe it.**

While a swap is active, a **watchdog** (`remote-shelley-watchdog.service`)
probes the proxy end-to-end every ~15s; if the remote stops answering for
~45s+ it fails over to the local Shelley automatically and logs it to
`swap.log`. So a swap can self-heal even without the operator.

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
| After a swap, nothing answers on the URL | The swap preflights the upstream first and restores the local Shelley on failure; check `swap.log`. If the VM is wedged, the auto-restore timer fires regardless. |
| Swap starts but immediately swaps back | Upstream answered preflight but stopped serving; check `proxy.log` and that the remote is stable. `remote-shelley keep` only helps once the proxy is healthy. |
| 502 from the proxy | Remote Shelley unreachable from the VM (Tailscale down?). Check `curl -sI <upstream>/`. |
| Conversation cut off mid-swap | Expected — the restart kills the agent. Wait a few seconds and reload; if the swap failed, the local Shelley is restored automatically. |
| Swapped to remote, but later I'm back on local without running `off` | The watchdog detected the remote stopped answering and failed over. Check `swap.log` for `watchdog` lines and confirm the remote + Tailscale are stable. |

## Verifying installation

```sh
remote-shelley status
curl -sI http://aifoundry1:32768/   # upstream reachable
ls ~/.config/shelley/hooks/remote-shelley 2>/dev/null; ls ~/.config/shelley/hooks/slash/remote-shelley
```
