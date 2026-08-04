# remote-shelley

Turn an exe.dev VM into a pure routing front-end for a **remote Shelley** —
for example a Shelley running on your own infrastructure behind Tailscale.
One command swaps the VM's Shelley port over to a reverse proxy pointed at the
remote instance, so that anyone who opens the VM's normal Shelley URL is
actually talking to the remote one. Swap back, or let the auto-restore safety
net put the local Shelley back by itself.

---

## TL;DR

### On the VM

```sh
git clone git@github.com:nekkoai/shelley-tools.git
cd shelley-tools/remote-shelley
./install.sh
# review the printed config path, then:
remote-shelley status
```

### In any Shelley conversation on that VM

```
remote-shelley http://aifoundry1:32768     # swap the port to the remote
remote-shelley keep                        # stay on the remote (cancel auto-restore)
remote-shelley off                         # swap back to the local Shelley
remote-shelley status                      # what's answering right now?
```

(The `/remote-shelley ...` slash form and the `/usr/local/bin/remote-shelley`
CLI do the same thing.)

---

## How it works

```
            https://<vm>.exe.xyz   (exe.dev native HTTPS proxy: TLS + auth,
                     │              injects X-Exedev-* headers — unchanged)
                     ▼
        127.0.0.1:9999 on the VM — NORMALLY shelley.socket
                     │
     during a swap:  remote-shelley.service (the reverse proxy)
                     │
                     ▼  over Tailscale
        http://aifoundry1:32768  (the REMOTE Shelley on your infra)
```

The proxy binds the **same** port the local Shelley serves on, so exe.dev's
proxying needs no reconfiguration at all — TLS termination, the login flow,
and the auth headers the remote Shelley may rely on are preserved end-to-end.
WebSockets and long-lived SSE streams (Shelley's live updates) are proxied
with no response timeout.

### Why everything is detached

A swap **stops the local Shelley — which is the process serving the very
conversation that asked for the swap**. Run in the foreground, the operation
kills itself mid-step and leaves nothing listening on the port. So the CLI and
the hooks never perform the swap inline: they schedule a **detached systemd
transient unit** (`remote-shelley-swap.service`) that survives the restart and
does the work:

1. **Preflight** — the upstream URL must answer HTTP before anything is
   disturbed. If not, the local Shelley is left untouched.
2. Stop `shelley.socket` + `shelley.service`, freeing the port.
3. Start the proxy bound to that port and **health-check** that it serves the
   remote.
4. On any failure → **immediately restore the local Shelley**; the VM is never
   left with nothing answering.
5. On success → start a **watchdog** and arm an **auto-restore timer** (default
   5min). If the operator doesn't type `remote-shelley keep`, the local
   Shelley comes back on its own — so a bad or unwanted swap can never strand
   you.

### Continuous monitoring (the watchdog)

While a swap is active, `remote-shelley-watchdog.service` runs alongside the
proxy (its lifecycle is bound to it via systemd `BindsTo`/`PartOf`). Every
`REMOTE_SHELLY_WATCH_INTERVAL` seconds (default 15) it makes a **fresh
end-to-end request through the proxy** to the upstream — a cache-busted GET on
the proxy's own port, so it exercises the whole VM → proxy → remote → back
path, not just "is the process alive."

If the probe fails `REMOTE_SHELLY_WATCH_FAILS` times in a row (default 3, so
~45s of sustained outage — e.g. the remote Shelley crashed, or Tailscale
dropped), the watchdog **fails over automatically to the local Shelley** and
logs it. It never fights a deliberate restore: if the proxy stops because a
restore is already underway, the watchdog stands down instead of re-adding the
proxy.

The same machinery powers `off` (manual restore) and `keep` (cancel the
timer). Orchestration log: `~/.config/shelley/remote-shelley/swap.log`;
per-request proxy log: `proxy.log`; watchdog log: `watchdog.log` (same dir).

## Usage

| Command | What it does |
|---|---|
| `remote-shelley <url>` / `remote-shelley swap <url>` | Take over the port with a proxy to `<url>` (default: `REMOTE_SHELLY_UPSTREAM` from config). |
| `remote-shelley keep` | Cancel the pending auto-restore; the remote stays. |
| `remote-shelley off` | Swap back to the local Shelley now. |
| `remote-shelley status` | Show what's listening on the port, unit states, last upstream, pending timers. |

All four work as: the first word of a Shelley message (rewritten by the
chat-message / new-conversation hooks), the `/remote-shelley` slash command,
or the `remote-shelley` CLI on the VM.

## Design notes

- **Trust & scope.** The remote Shelley instance inherits this VM's exe.dev
  authentication boundary: anyone who can reach `https://<vm>.exe.xyz` can now
  drive the *remote* Shelley. That's usually exactly what you want (the VM is
  the routing mechanism), but be deliberate about which remote you point at.
- **One tool, one hooks dir.** Installing this drops `command-dispatch.py`,
  `new-conversation`, `chat-message`, `config.env`, and
  `slash/remote-shelley` into `~/.config/shelley/hooks/`. If you also use the
  sibling [`hooks/`](../hooks) tool (rebase/swap/keep/rollback for the Shelley
  *binary*), note both ship files with these names — install them into
  different VMs or merge their dispatchers.
- **Config.** Environment-specific values live in one file:
  `hooks/config.env` (copied on install to `~/.config/shelley/hooks/config.env`
  and `~/.config/shelley/remote-shelley/config.env`). Edit the listen address,
  default upstream, grace period there.

### Tailscale notes (when the remote is on your tailnet)

- The upstream is usually a **MagicDNS name** (`http://aifoundry1:32768`).
  Resolution depends entirely on Tailscale's DNS (`100.100.100.100`) — there is
  no `/etc/hosts` fallback — so a tailscaled restart briefly breaks resolution.
  The proxy re-resolves per connection (cgo system resolver, no stale cache),
  so it recovers on its own once tailscaled is back.
- The **watchdog is Tailscale-aware**: it checks `tailscale status`
  (`BackendState`) on each failed probe. A failure while Tailscale is *down* is
  treated as transient and does NOT count toward failover; only failures while
  Tailscale is *healthy* mean the remote Shelley itself is gone. This keeps a
  tailscaled restart (~2–5s) from triggering a spurious failover.
- The VM's tailnet node is tagged (e.g. `tagged-devices`) with a persistent
  node key in `/var/lib/tailscale/` — it survives reboots without re-auth.
  Wiping that dir re-registers the node (new IP / lost ACLs); the tool only
  ever talks *outbound* to the upstream, so it doesn't depend on the VM's own
  tailnet identity beyond basic connectivity.
- Failover is always safe: the fallback target is the *local* Shelley, which
  has no Tailscale dependency, so it's reachable no matter what Tailscale does.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Nothing answers on the Shelley URL after a swap | Check `~/.config/shelley/remote-shelley/swap.log`. The auto-restore timer will bring the local Shelley back on its own; or SSH in and run `remote-shelley off`. |
| 502 through the proxy | Remote unreachable from the VM. Verify Tailscale is up (`tailscale status`) and `curl -sI <upstream>/` answers. |
| Swap keeps reverting before you can `keep` | The proxy health-check passed but the upstream then stopped serving. Check `proxy.log` and the remote Shelley's stability. |
| Swapped to remote, later back on local without `off` | The watchdog detected the remote stopped answering (while Tailscale was healthy) and failed over. Check `swap.log` for `watchdog` lines. |
| Failing over every time tailscaled restarts | Shouldn't happen — the watchdog waits out `BackendState != Running` without counting it. If it recurs, check `swap.log` to confirm the discriminator is seeing Tailscale state. |

## What's in this folder

- `main.go` — the reverse proxy (single static Go binary).
- `install.sh` — idempotent installer (see [repo conventions](../AGENTS.md)).
- `remote-shelley.skill.md` — Shelley skill file, auto-registered by `install.sh`.
- `hooks/` — the hook payload: `command-dispatch.py`, `new-conversation`,
  `chat-message`, `slash/remote-shelley`, the `remote-shelley` CLI,
  `scripts/remote-shelley-{swap,restore}.sh`, the systemd unit, and
  `config.env.example`.
