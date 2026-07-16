#!/bin/bash
# Installer for rbrowser: creates a Python venv with Playwright.
set -e
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$HERE"
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet playwright
echo "rbrowser installed at $HERE/rbrowser"
echo "Symlink into your PATH, e.g.:  sudo ln -sf $HERE/rbrowser /usr/local/bin/rbrowser"
