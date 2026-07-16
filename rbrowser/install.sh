#!/bin/bash
# Installer for rbrowser:
#  - creates a Python venv with Playwright
#  - symlinks rbrowser into /usr/local/bin (if writable/sudoable)
#  - registers a Shelley skill so future sessions auto-activate it
set -e
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE"

# 1. venv + playwright
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet playwright

# 2. PATH symlink
TARGET=/usr/local/bin/rbrowser
if [ -w /usr/local/bin ] || sudo -n true 2>/dev/null; then
  sudo ln -sf "$HERE/rbrowser" "$TARGET"
  echo "linked $TARGET -> $HERE/rbrowser"
else
  echo "NOTE: /usr/local/bin not writable. Run:  sudo ln -sf $HERE/rbrowser $TARGET"
fi

# 3. Shelley skill
if command -v shelley >/dev/null 2>&1; then
  SKILL_DIR="$HOME/.config/shelley/rbrowser"
  mkdir -p "$SKILL_DIR"
  cp "$HERE/rbrowser.skill.md" "$SKILL_DIR/SKILL.md"
  echo "registered Shelley skill 'rbrowser' at $SKILL_DIR/SKILL.md"
fi

echo
echo "rbrowser installed. Next: on your LOCAL machine, launch Chrome with"
echo "  --remote-debugging-port=9222 --remote-allow-origins=* --user-data-dir=\$HOME/chrome-remote-profile"
echo "and open a reverse tunnel:  ssh -N -R 9222:localhost:9222 <this-vm>.exe.xyz"
echo "Then verify:  curl -s localhost:9222/json/version"
