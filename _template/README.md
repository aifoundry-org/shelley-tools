# <tool-name>

One-paragraph pitch: what does this tool let Shelley do that it couldn't
before, and how does it work at a high level?

---

## TL;DR

### On the VM

```sh
git clone git@github.com:nekkoai/shelley-tools.git
cd shelley-tools/<tool-name>
./install.sh
```

### On your local machine (if applicable)

Describe anything the user must do on their laptop — launch a helper, open
an SSH tunnel, install a browser extension, etc. Keep it copy-pasteable.

---

## Usage

Command reference, examples, env vars.

## Design notes

Why the architecture is what it is. Trust boundaries. Gotchas.

## Troubleshooting

| Symptom | Fix |
|---|---|
| … | … |

## What's in this folder

- `install.sh` — idempotent installer (see [repo conventions](../AGENTS.md)).
- `<tool>.skill.md` — Shelley skill file, auto-registered by `install.sh`.
- … — code, scripts, config.

## Starting a new tool from this template

```sh
cp -r _template <new-tool>
mv <new-tool>/toolname.skill.md <new-tool>/<new-tool>.skill.md
# then edit README.md, install.sh, and the skill file.
```
