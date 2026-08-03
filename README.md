# shelley-tools

A collection of tools that extend the capabilities of [Shelley](https://exe.dev/docs/shelley/intro),
the exe.dev coding agent. Each subdirectory is a self-contained tool that gives
Shelley a new superpower — controlling a remote browser, driving other services,
reaching resources outside its VM, etc.

## Tools in this repo

| Tool | What it does |
|---|---|
| [`rbrowser/`](./rbrowser) | Lets Shelley drive **your** local Chrome (navigate, click, type, screenshot) via Chrome DevTools Protocol tunneled over SSH. No browser extension required. |
| [`rb/`](./rb) | Lets Shelley do **web research without getting CAPTCHA'd**: drives a real, visible, persistent Chrome **on the VM** over CDP, with a search/fetch CLI, automatic block detection, and a noVNC view so a human can take over and clear a challenge in the same session. |
| [`cyclo/`](./cyclo) | Deploy and operate [Cyclo](https://github.com/glguida/cyclo) — Git-defined multi-agent teams in Docker — safely: bounded-retry runs, task confirmation, watching, cost accounting, run forensics, and teardown. |
| [`hooks/`](./hooks) | Extensible **operator commands** for Shelley (`rebase`, `swap`, `keep`, `rollback`) via lifecycle hooks: type a command and Shelley expands it into a full task, e.g. rebasing a fork or hot-swapping the running binary with an auto-rollback safety net. |

## Installing a tool

Every tool in this repo follows the same convention: it ships a top-level
`install.sh` that sets everything up on the VM. To install any tool:

```sh
git clone git@github.com:nekkoai/shelley-tools.git
cd shelley-tools/<tool>
./install.sh
```

The installer is responsible for:

1. Installing whatever runtime / dependencies the tool needs (venv, npm, etc.).
2. Symlinking any user-facing binaries into `/usr/local/bin` (via `sudo` if needed).
3. **Registering the Shelley skill** so future Shelley sessions on the VM
   auto-activate the tool by description matching. Concretely, this means
   copying `<tool>.skill.md` to `~/.config/shelley/<tool>/SKILL.md`.
4. Printing any remaining manual steps (e.g. local-side setup the user
   still has to do on their laptop).

A well-behaved `install.sh` is idempotent: running it twice does nothing bad.

## Layout convention

Each tool lives in its own top-level directory with this layout:

```
<tool>/
├── README.md            # human docs; TL;DR setup section at the top
├── install.sh           # idempotent installer (see above)
├── <tool>.skill.md      # Shelley skill file (front-matter + body)
└── …                    # scripts, code, config the tool needs
```

The skill file has YAML front-matter:

```markdown
---
name: <tool>
description: Use when … (concise, action-oriented, so Shelley matches on it).
---

# Body: full context a fresh Shelley session needs to use the tool.
```

See [`rbrowser/`](./rbrowser) for a fully worked example.

## Adding a new tool

1. Copy the structure of an existing tool (start from `rbrowser/`).
2. Write a `README.md` with a **TL;DR** section covering both remote (VM)
   and local (user's machine) setup, if applicable.
3. Write a `<tool>.skill.md` that a fresh Shelley session can read to
   bootstrap full understanding. Include: what it is, prerequisites,
   command reference, recipes, gotchas, troubleshooting.
4. Write `install.sh` following the four responsibilities above.
5. Add a one-liner to the table at the top of this README.

## License

Apache 2.0 — see [LICENSE](./LICENSE).
