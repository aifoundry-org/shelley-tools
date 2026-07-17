#!/bin/bash
# Template installer for a shelley-tools tool.
#
# Responsibilities:
#   1. Install runtime deps (venv, npm, apt, etc.).
#   2. Symlink user-facing binaries into /usr/local/bin.
#   3. Register the Shelley skill so future sessions auto-activate it.
#   4. Print any remaining manual steps.
#
# Must be idempotent: running twice does nothing bad.
set -e
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TOOL="$(basename "$HERE")"
cd "$HERE"

# -- 1. runtime deps -----------------------------------------------------
# Example (Python):
#   [ -d .venv ] || python3 -m venv .venv
#   .venv/bin/pip install --quiet --upgrade pip
#   .venv/bin/pip install --quiet -r requirements.txt
#
# Example (Node):
#   command -v npm >/dev/null || { echo 'need npm'; exit 1; }
#   npm install --silent

# -- 2. PATH symlink ------------------------------------------------------
# If your tool ships a launcher script, symlink it. Example:
# TARGET=/usr/local/bin/$TOOL
# if [ -w /usr/local/bin ] || sudo -n true 2>/dev/null; then
#   sudo ln -sf "$HERE/$TOOL" "$TARGET"
#   echo "linked $TARGET -> $HERE/$TOOL"
# else
#   echo "NOTE: run:  sudo ln -sf $HERE/$TOOL $TARGET"
# fi

# -- 3. Shelley skill registration ---------------------------------------
SKILL_SRC="$HERE/${TOOL}.skill.md"
if [ -f "$SKILL_SRC" ] && command -v shelley >/dev/null 2>&1; then
  SKILL_DIR="$HOME/.config/shelley/${TOOL}"
  mkdir -p "$SKILL_DIR"
  cp "$SKILL_SRC" "$SKILL_DIR/SKILL.md"
  echo "registered Shelley skill '${TOOL}' at $SKILL_DIR/SKILL.md"
fi

# -- 4. manual next steps ------------------------------------------------
cat <<EOF

${TOOL} installed. Any local setup the user still needs to do:
  <describe here>
EOF
