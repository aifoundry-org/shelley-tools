#!/bin/bash
# Installer for the `cyclo` shelley-tool.
#
# Responsibilities (per shelley-tools convention):
#   1. Ensure the Cyclo runtime itself is available (pip-install into a venv if
#      the `cyclo` command is missing).
#   2. Symlink the `cyclo-ops` operations wrapper into /usr/local/bin.
#   3. Register the Shelley skill so future sessions auto-activate it.
#   4. Print remaining manual steps (provider credential provisioning).
#
# Idempotent: running twice is safe.
set -e
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TOOL="$(basename "$HERE")"   # "cyclo"
cd "$HERE"

# -- 1. Cyclo runtime -----------------------------------------------------
# Cyclo needs: Linux, Python 3.10+, Git, and a Docker daemon the user can use.
if ! command -v docker >/dev/null 2>&1; then
  echo "WARNING: docker not found. Cyclo needs a running Docker daemon." >&2
fi

if command -v cyclo >/dev/null 2>&1; then
  echo "cyclo already installed: $(command -v cyclo) ($(cyclo --version 2>/dev/null))"
else
  echo "cyclo command not found; installing into a dedicated venv..."
  CYCLO_VENV="${CYCLO_VENV:-$HOME/.venvs/cyclo}"
  CYCLO_SRC="${CYCLO_SRC:-}"
  python3 -m venv "$CYCLO_VENV"
  "$CYCLO_VENV/bin/pip" install --quiet --upgrade pip
  if [ -n "$CYCLO_SRC" ] && [ -f "$CYCLO_SRC/pyproject.toml" ]; then
    echo "  installing from source checkout: $CYCLO_SRC"
    "$CYCLO_VENV/bin/pip" install --quiet "$CYCLO_SRC"
  else
    # Published distribution name is cyclo-agent; fall back to a git clone if
    # the index has no wheel yet.
    if ! "$CYCLO_VENV/bin/pip" install --quiet 'cyclo-agent==0.1.0' 2>/dev/null; then
      echo "  PyPI install failed; cloning source from GitHub..."
      TMP="$(mktemp -d)"
      git clone --depth 1 https://github.com/glguida/cyclo.git "$TMP/cyclo"
      "$CYCLO_VENV/bin/pip" install --quiet "$TMP/cyclo"
      rm -rf "$TMP"
    fi
  fi
  mkdir -p "$HOME/.local/bin"
  ln -sf "$CYCLO_VENV/bin/cyclo" "$HOME/.local/bin/cyclo"
  echo "  linked $HOME/.local/bin/cyclo -> $CYCLO_VENV/bin/cyclo"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "  NOTE: add $HOME/.local/bin to PATH";; esac
fi

# -- 2. PATH symlink for the ops wrapper ---------------------------------
TARGET=/usr/local/bin/cyclo-ops
if [ -w /usr/local/bin ] || sudo -n true 2>/dev/null; then
  sudo ln -sf "$HERE/cyclo-ops" "$TARGET"
  echo "linked $TARGET -> $HERE/cyclo-ops"
else
  echo "NOTE: /usr/local/bin not writable. Run:  sudo ln -sf $HERE/cyclo-ops $TARGET"
fi

# -- 3. Shelley skill registration ---------------------------------------
SKILL_SRC="$HERE/${TOOL}.skill.md"
if [ -f "$SKILL_SRC" ] && command -v shelley >/dev/null 2>&1; then
  SKILL_DIR="$HOME/.config/shelley/${TOOL}"
  mkdir -p "$SKILL_DIR"
  cp "$SKILL_SRC" "$SKILL_DIR/SKILL.md"
  echo "registered Shelley skill '${TOOL}' at $SKILL_DIR/SKILL.md"
fi

# -- 4. Manual next steps ------------------------------------------------
cat <<'EOF'

cyclo tool installed. Remaining setup:

  1. Verify the runtime + Docker:
       cyclo-ops doctor

  2. See available providers and their login routes:
       cyclo-ops providers

  3. Provision at least one credential (kept in a Docker volume, never in a
     team container). Examples:
       cyclo-ops login openai-codex          # OAuth device flow
       cyclo-ops login openrouter            # prompts for API key (stdin-safe)

  4. List the models your credentials unlock:
       cyclo-ops models claude

Then run a team safely with bounded retries:
     cyclo-ops run <team-dir> <project-dir> <instance-name>
     cyclo-ops task <instance-name> <task-id> <spec.md>
     cyclo-ops watch <instance-name> <task-id>
EOF
