# cyclo — deploy & operate Cyclo agent teams from Shelley

Gives Shelley a safe, repeatable way to **deploy and run [Cyclo](https://github.com/glguida/cyclo)**
— the local-first runtime that runs Git-defined multi-agent teams inside Docker
against a project directory, with provider credentials isolated behind a
credential gateway.

The tool ships `cyclo-ops`, an opinionated wrapper around the stock `cyclo` CLI
that encodes the operating procedure you actually need in production: **bounded
retries so a misbehaving run can't burn unbounded model spend, task-spec
confirmation, run watching, cost accounting, post-hoc run forensics, and clean
teardown.** It never hides `cyclo` — you can drop to `cyclo ...` at any point.

```
 team (Git repo)                    project (disposable clone)
  roster + roles/*.md                source being worked on
        \                             /
         cyclo-runtime container  (/team read-only, /workspace writable)
                       |
              private Docker network
                       |
         cyclo-gateway container  ->  cyclo-gateway-store volume
         proxy + usage + model scope    credentials / OAuth (never in team)
```

---

## TL;DR

### On the VM

```sh
git clone https://github.com/aifoundry-org/shelley-tools.git
cd shelley-tools/cyclo
./install.sh
```

The installer will:
1. Ensure the `cyclo` runtime exists (pip-installs into `~/.venvs/cyclo` if
   missing; set `CYCLO_SRC=/path/to/checkout` to install from source).
2. Symlink `cyclo-ops` into `/usr/local/bin`.
3. Register the Shelley skill so future sessions auto-activate it.

Requires Linux, Python 3.10+, Git, and a running Docker daemon.

### First run

```sh
cyclo-ops doctor                 # runtime + Docker health
cyclo-ops providers              # provider login routes
cyclo-ops login openrouter       # or: cyclo-ops login openai-codex (OAuth)
cyclo-ops models claude          # confirm models are reachable
```

---

## Usage

```sh
cyclo-ops run   <team-dir> <project-dir> [name]   # validate + run, safety caps on
cyclo-ops task  <instance> <task-id> <spec.md>    # show spec, confirm, submit
cyclo-ops watch <instance> <task-id>              # poll to terminal state
cyclo-ops cost  [instance]                        # token/request usage
cyclo-ops sleuth <instance> [task-id]             # forensic re-trace map
cyclo-ops stop  <instance> | cyclo-ops stop-all
```

Env: `CYCLO_STATE_ROOT`, `AGENTWS_MAX_JOB_ATTEMPTS` (default 2),
`AGENTWS_MAX_CONSECUTIVE_FAILURES` (default 3), `CYCLO_BIN`.

## Design notes

- **Safety first.** `run` exports bounded-retry env before starting a team,
  because a run with wrong command paths or recursive failure notifications can
  amplify model spend very quickly. Caps are overridable but on by default.
- **Credentials never on argv.** `login` reads API keys via stdin/prompt and
  shreds the temp file; keys land only in the gateway's Docker volume.
- **Forensics built in.** `sleuth` prints the exact files and commands to
  re-trace a run: manifest, task/job logs, the agent prompt, the curated
  transcript, the raw `pi-session` JSONL, work products, cost, and the git
  branch where the produced code actually lives.
- **Thin wrapper.** Every subcommand shells out to real `cyclo`; nothing is
  reimplemented or hidden.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cyclo: command not found` | Run `./install.sh`; add `~/.local/bin` to PATH. |
| `doctor` fails on Docker | Start/enable Docker; ensure your user can reach the daemon. |
| Job fails in seconds; `cyclo-ops cost` shows 429 | Provider throttling — switch model/provider (e.g. OpenRouter) or wait. |
| `.cyclo-worktrees/<task>` "not a git repository" | Expected; its gitdir points at container `/workspace`. Read the commit via branch `task/<task-id>`. |
| Runaway request count | `cyclo-ops stop <inst>`, lower `AGENTWS_MAX_*`, narrow the prompt. |

## What's in this folder

- `install.sh` — idempotent installer (see [repo conventions](../AGENTS.md)).
- `cyclo-ops` — the operations wrapper symlinked to `/usr/local/bin/cyclo-ops`.
- `cyclo.skill.md` — Shelley skill file, auto-registered by `install.sh`.
