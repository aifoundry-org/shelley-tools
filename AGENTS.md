# Repo convention for Shelley

This repo hosts tools that extend Shelley. Every top-level directory (other
than the meta ones: `_template/`, docs, etc.) is a **tool** and MUST follow
these rules:

1. **`install.sh`** — idempotent installer. Responsibilities:
   1. Install runtime dependencies (venv, npm, apt, …).
   2. Symlink any user-facing binary into `/usr/local/bin` (sudo‑aware).
   3. **Register the Shelley skill**: copy `<tool>.skill.md` to
      `~/.config/shelley/<tool>/SKILL.md`. Guard the copy on
      `command -v shelley`.
   4. Print any manual next steps (e.g. local‑machine setup).

   Running `install.sh` twice must be safe.

2. **`<tool>.skill.md`** — the Shelley skill file with YAML front-matter:

   ```markdown
   ---
   name: <tool>
   description: Use when …
   ---
   ```

   The description is what Shelley matches on for auto-activation — make it
   action-oriented and specific.

3. **`README.md`** — human docs with a **TL;DR** section at the top covering
   both VM-side (`./install.sh`) and any local-machine setup.

4. **Top-level [`README.md`](./README.md) table** — add a one-liner for the
   new tool.

Start new tools by copying [`_template/`](./_template/).

When you (Shelley) add or modify a tool, verify these invariants before
committing.
