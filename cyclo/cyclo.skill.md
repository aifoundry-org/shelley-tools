---
name: cyclo
description: Use when you need to deploy, run, observe, debug, or tear down Cyclo — the local-first runtime that runs Git-defined multi-agent teams in Docker against a project, with a credential gateway. Triggers include installing Cyclo, provisioning a provider (OpenAI Codex, OpenRouter), defining or running a team, submitting a task, watching a run, checking token/cost usage, re-tracing what a run did, or stopping instances. Especially relevant when a run risks runaway model spend and needs bounded, safe operation.
---

# cyclo — deploy & operate Cyclo agent teams

## What it is

[Cyclo](https://github.com/glguida/cyclo) runs a Git-defined agent *team*
(roster + role prompts + protocol) inside its own Docker container against a
separate *project* directory, using a durable filesystem job loop. Model traffic
crosses an isolated **credential gateway** container so provider keys/OAuth live
in a Docker volume that team containers never mount; each team gets only a
provider+model-scoped capability.

This tool ships:
- `cyclo-ops` at `/usr/local/bin/cyclo-ops` — an opinionated wrapper that adds
  **safety rails, confirmation, watching, cost, forensics, and teardown** on top
  of the raw `cyclo` CLI. It never hides `cyclo`; drop to `cyclo ...` anytime.
- an installer that can also bootstrap the `cyclo` runtime itself.

Source: the [`shelley-tools`](https://github.com/aifoundry-org/shelley-tools)
repo under `cyclo/`.

## Prerequisites

- Linux host, Python 3.10+, Git, and a **running Docker daemon** the user can
  access. Verify readiness:
  ```sh
  cyclo-ops doctor
  ```
  This checks the bundled job-loop ABI, the gateway API, and the Docker daemon.
- At least one provisioned provider credential (see below) before any run.
- The first `cyclo run`/`cyclo models`/`cyclo gateway` builds two Docker images
  (`cyclo-runtime`, `cyclo-gateway`) and needs network access; it is slow once.

## Core mental model

- **Team** = a Git repo: `team` roster file (`<name> <role> <agent> <provider/model>`),
  `roles/*.md` prompts, `AGENTS.md` shared protocol. Create with `cyclo init
  <dir> --template <t>`; templates: plan-execute-verify, test-driven-repair,
  adversarial-audit. Always `cyclo validate <team>` after editing.
- **Project** = any directory the team edits under `/workspace` in-container.
  ALWAYS use a disposable clone, never a checkout you care about — the agents
  commit to branches `task/<task-id>` and create `.cyclo-worktrees/`.
- **Instance** = one running team↔project binding (`cyclo run`). One container
  + one private network. State lives under
  `$CYCLO_STATE_ROOT/instances/<instance>/` (default `~/.local/state/cyclo`).
- **Task** = a unit of work (a spec markdown). Its initial `-plan` job is
  claimed by an agent; agents may create follow-up jobs.
- **Gateway** = shared credential/proxy container; `cyclo usage` reports
  per-instance token/request counts and HTTP statuses.

## Command reference (cyclo-ops)

```sh
cyclo-ops doctor                         # runtime + Docker health
cyclo-ops providers                      # built-in providers + login routes
cyclo-ops login <provider> [key]         # provision a credential (stdin-safe)
cyclo-ops accounts                       # provisioned gateway accounts
cyclo-ops models [filter]                # list model ids, optional grep filter
cyclo-ops run <team> <project> [name]    # validate + run with safety caps
cyclo-ops task <inst> <task-id> <spec>   # show spec, confirm, submit
cyclo-ops watch <inst> <task-id>         # poll until task terminal
cyclo-ops ls                             # cyclo ps
cyclo-ops cost [inst]                    # usage: all instances, or one
cyclo-ops sleuth <inst> [task-id]        # print a forensic re-trace map
cyclo-ops stop <inst>                    # stop one instance
cyclo-ops stop-all                       # stop all running instances
```

Safety env (exported by `run`, overridable):
`AGENTWS_MAX_JOB_ATTEMPTS` (default 2), `AGENTWS_MAX_CONSECUTIVE_FAILURES`
(default 3), `CYCLO_STATE_ROOT`.

## Recipes

### First-time deploy
```sh
cyclo-ops doctor
cyclo-ops providers
cyclo-ops login openai-codex     # OAuth device code, OR:
cyclo-ops login openrouter       # API-key provider; key read via stdin/prompt, never argv
cyclo-ops models claude          # confirm models are reachable
```

### Run one task safely
```sh
git clone --no-hardlinks <src> /path/to/disposable-project
cyclo-ops run   /path/to/team /path/to/disposable-project my-run
cyclo-ops task  my-run fix-thing /tmp/spec.md    # prints spec, asks to confirm
cyclo-ops watch my-run fix-thing                 # until done/failed
cyclo-ops cost  my-run                            # what it spent
cyclo-ops stop  my-run
```

### Inspect the result (code lives in the PROJECT repo)
Agents commit to branch `task/<task-id>`. The `.cyclo-worktrees/<task>` gitdir
points at the container path `/workspace`, so it looks broken from the host —
read via the branch instead:
```sh
git -C <project> log --oneline <base>..task/<task-id>
git -C <project> show <candidate-commit>
git -C <project> diff --check <base>..task/<task-id>   # whitespace/defects
```

### Re-trace exactly what a run did ("sleuthing")
```sh
cyclo-ops sleuth my-run fix-thing    # prints the map of files/commands to inspect
```
Key artifacts under `$CYCLO_STATE_ROOT/instances/<inst>/`:
`run.json` (manifest), `agentws-state/tasks/<task>/{spec.md,log.md,result.md,state}`,
`agentws-state/jobs/<task>-*/`, `agentws-state/agents/<agent>/{prompt.md,transcript.log,pi-session/*.jsonl}`.
The `transcript.log` is curated; `pi-session/*.jsonl` is the raw source of truth.

## Trust & scope

- Never provision credentials by putting keys on the command line — use
  `cyclo-ops login`, which reads keys via stdin/prompt and shreds temp files.
- Never point a run at a repository you care about; use a disposable clone. The
  primary Cyclo source checkout must never be a run target.
- `git add -A/./--all/*` blind-adds are discouraged in team protocols; specify
  files explicitly.
- Show a task spec to the human before submitting (cyclo-ops task does this).

## Operating lessons (hard-won)

- **Bound everything.** A run with wrong command paths or recursive failure
  notifications can burn millions of tokens fast. The safety caps exist for
  this; do not remove them without reason. Watch runs; stop non-converging ones.
- **One team/task at a time.** Concurrent runs amplify spend and muddy usage
  attribution.
- **Narrow, single-boundary prompts converge; broad multi-boundary objectives
  do not.** Precise defect reports with reproductions beat open feature asks.
  If a prompt crosses more than ~2 trust boundaries, decompose it.
- **Topology tradeoff:** a single planner-engineer agent + an external
  human/Shelley reviewer gives the best quality-to-coordination ratio; large
  4-agent plan/build/critic/verify teams review well but cost many coordination
  turns. Cheap models can make the bigger topology affordable — but very weak
  models may fail the AgentWS protocol handshake (a quality failure, contained
  by the retry cap, not a routing failure).
- **Provider throttling is real.** OpenAI Codex OAuth can return HTTP 429
  account-wide; OpenRouter (an API-key provider) is a good alternative and
  exposes a large multi-family catalog. Model *naming* ("flash"/"mini") is not a
  reliable cost signal — fetch live prices from
  `https://openrouter.ai/api/v1/models` and rank by blended $/1M tokens.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `cyclo: command not found` | Run `install.sh`; ensure `~/.local/bin` on PATH. |
| `doctor` fails on Docker | Daemon not running or user lacks access. Start/enable Docker; add user to `docker` group. |
| First run very slow / network errors | Building `cyclo-runtime`/`cyclo-gateway` images; needs internet once. |
| Job flips to `failed` in seconds, `cyclo cost` shows 429 | Provider throttling. Switch provider/model (e.g. OpenRouter) or wait. |
| Job `failed` but transcript shows a command-path/exit-127 mistake | Team protocol must use absolute `/agentws/bin/...` paths; fix the team's AGENTS.md. |
| Worktree under `.cyclo-worktrees` looks like "not a git repository" | Expected: its gitdir references container `/workspace`. Read the commit via branch `task/<task-id>`. |
| Runaway request count | Stop it: `cyclo-ops stop <inst>`; lower `AGENTWS_MAX_*`; narrow the prompt. |
| Task-result files owned by root (0600) after a container stop | Created in-container as root; `sudo chown` then use the instance's `runtime/bin/task-result` with `TASKS_DIR=/JOBS_DIR=` set. |

## Verifying installation

```sh
which cyclo-ops && which cyclo
cyclo-ops doctor
cyclo-ops providers | head
```
