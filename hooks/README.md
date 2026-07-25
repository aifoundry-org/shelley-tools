# shelley-command-hooks

A small, extensible set of **operator commands** for [Shelley](https://exe.dev),
implemented as Shelley hooks. You type a command as the first word of a message
— `rebase v0.99.x`, `swap v0.99.x`, `keep`, `rollback` — or the slash form
(`/swap v0.99.x`), and a hook rewrites it into a detailed instruction that makes
the agent do the work (usually by delegating to a subagent).

Everything env-specific lives in one file (`hooks/config.env`), so the same
repo drops onto any Shelley instance.

> **Note on the shelley-tools convention.** Other tools in this repo ship a
> `<tool>.skill.md` that `install.sh` registers at
> `~/.config/shelley/<tool>/SKILL.md`. This tool deliberately does **not**: its
> `<tool>` name would be `hooks`, and `~/.config/shelley/hooks` is precisely the
> Shelley hooks directory this tool *installs into* (see below) — so a skill
> file there would collide with the payload. This tool is not a skill you invoke
> by description; it is the hook layer itself. `install.sh` therefore only wires
> up the hooks.

## Install into shelley-tools layout

This tool lives at `hooks/` inside
[`shelley-tools`](https://github.com/aifoundry-org/shelley-tools). Its payload
(the hook executables) is the nested `hooks/hooks/` directory; the outer
`hooks/` holds `README.md` + `install.sh`. From a checkout:

```sh
cd shelley-tools/hooks && ./install.sh
```

## How it works

Shelley runs executables in its hooks directory at lifecycle events (see
`shelley skill cat shelley-hooks`). This repo provides:

| File | Shelley hook | Role |
|------|--------------|------|
| `hooks/new-conversation` | `new-conversation` | expands a command in the first message |
| `hooks/chat-message` | `chat-message` | expands a command in a follow-up message |
| `hooks/slash/<cmd>` | `slash/<cmd>` | lets you type `/<cmd>` explicitly |
| `hooks/command-dispatch.py` | — | shared brain all the above `exec` into |
| `hooks/scripts/*.sh` | — | the hardened swap/rollback/build machinery |
| `hooks/config.env` | — | the ONE place with machine-specific values (gitignored) |

The dispatcher detects the input shape (JSON for hooks, plain-text out for
slash) and, if the first word is a known command, emits the expanded
instruction. Unknown words pass through unchanged.

## Install (the natural hookup)

```sh
git clone <this-repo> ~/src/shelley-command-hooks
cd ~/src/shelley-command-hooks
./install.sh
```

`install.sh` symlinks Shelley's hooks dir at this repo:
`~/.config/shelley/hooks -> ~/src/shelley-command-hooks/hooks`. That's the
cleanest hookup: Shelley finds the hook executables directly, and a later
`git pull` updates behavior live — no re-install. It also creates
`hooks/config.env` from the example, autodetecting what it can. **Review
`hooks/config.env` before using.**

(If a real `~/.config/shelley/hooks` directory already exists, it is moved aside
to `*.bak.<ts>` first. `SHELLEY_HOOKS_DIR=/other/path ./install.sh` overrides
the destination.)

No Shelley restart is needed — hooks are read per-invocation.

## Commands

- **`rebase <tag>`** — subagent creates `<prefix><tag>` from upstream tag
  `<tag>` and rebases the fork branch onto it; builds + tests. Never pushes.
- **`swap <ref>`** — subagent builds git ref `<ref>` with the release wrapper,
  backs up the running binary, then hands off to a **detached** systemd unit
  that installs it, restarts the service, health-checks, and arms a 5-minute
  auto-rollback. Detached because the restart kills the agent.
- **`keep`** — confirm the swapped build is good; cancels the auto-rollback.
- **`rollback`** — immediately restore the most recent backup.

### Swap safety model

`scripts/shelley-swap-apply.sh` (run detached, as root):
preflight the new binary → pick a **verified-bootable** rollback target →
install atomically → restart → **health-check the socket** → roll back at once
on failure → only then arm the 5-min grace timer. It never installs (or rolls
back to) a binary it hasn't watched boot. `scripts/shelley-swap-build.sh`
produces a binary with the "UI build is stale!" self-check disabled, which is
mandatory when building and deploying on the same machine. Log:
`/tmp/shelley-swap.log`.

## Adding a command

1. Add `cmd_<name>(arg)` in `hooks/command-dispatch.py` returning the expansion
   (or `None` to decline), and register it in `COMMANDS`.
2. Add a slash shim: `ln -s ../command-dispatch.py hooks/slash/<name>` — or a
   two-line `exec` shim like the existing ones.

## Configuration (`hooks/config.env`)

See `hooks/config.env.example`. Keys: `SHELLEY_REPO`, `SHELLEY_SVC`,
`SHELLEY_LIVE_BIN`, `SHELLEY_SOCK_URL`, `SHELLEY_SVC_USER`, `SHELLEY_STATE_DIR`,
`SHELLEY_UPSTREAM_REMOTE`, `SHELLEY_FORK_REMOTE`, `SHELLEY_FORK_BRANCH`,
`SHELLEY_BRANCH_PREFIX`.
