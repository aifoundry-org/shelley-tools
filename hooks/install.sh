#!/usr/bin/env bash
# Install shelley-command-hooks into a Shelley instance.
#
# The natural hookup: symlink Shelley's hooks directory
# (~/.config/shelley/hooks) at this repo's hooks/ directory. Shelley then finds
# new-conversation, chat-message and slash/<cmd> executables directly, and
# `git pull` in this repo updates the live behavior with no re-install.
#
# On first run it also creates hooks/config.env (gitignored) from the example,
# auto-filling values detected from this machine. Review it afterwards.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/hooks"
DEST="${SHELLEY_HOOKS_DIR:-$HOME/.config/shelley/hooks}"
CFG="$SRC/config.env"

# --- 1. config.env ----------------------------------------------------------
if [ ! -f "$CFG" ]; then
  cp "$SRC/config.env.example" "$CFG"
  # Best-effort autodetection of this machine's specifics.
  detect() { # detect KEY value  -> set KEY=value in config.env if value nonempty
    local key="$1" val="$2"
    [ -n "$val" ] || return 0
    sed -i "s|^$key=.*|$key=$val|" "$CFG"
  }
  # Repo: prefer a sibling shelley checkout, else leave the example default.
  for cand in "$HOME/src/shelley" "$HOME/shelley"; do
    [ -d "$cand/.git" ] && { detect SHELLEY_REPO "$cand"; break; }
  done
  # Live binary from the running service's ExecStart, if discoverable.
  live="$(systemctl show -p ExecStart shelley.service 2>/dev/null | grep -oE '/[^ ]*/shelley' | head -1 || true)"
  detect SHELLEY_LIVE_BIN "$live"
  detect SHELLEY_SVC_USER "$(id -un)"
  detect SHELLEY_STATE_DIR "$HOME/.config/shelley"
  echo "created $CFG (autodetected where possible \u2014 review it!)"
else
  echo "keeping existing $CFG"
fi

# --- 2. executable bits (git may not preserve them on some checkouts) --------
chmod +x "$SRC/command-dispatch.py" "$SRC/new-conversation" "$SRC/chat-message" \
         "$SRC/scripts/"*.sh "$SRC/slash/"* 2>/dev/null || true

# --- 3. symlink Shelley's hooks dir at this repo's hooks/ --------------------
mkdir -p "$(dirname "$DEST")"
if [ -L "$DEST" ]; then
  cur="$(readlink -f "$DEST")"
  if [ "$cur" = "$SRC" ]; then
    echo "already linked: $DEST -> $SRC"
  else
    ln -sfn "$SRC" "$DEST"
    echo "re-pointed symlink: $DEST -> $SRC (was $cur)"
  fi
elif [ -e "$DEST" ]; then
  bak="$DEST.bak.$(date +%Y%m%d-%H%M%S)"
  mv "$DEST" "$bak"
  echo "backed up existing $DEST -> $bak"
  ln -s "$SRC" "$DEST"
  echo "linked: $DEST -> $SRC"
else
  ln -s "$SRC" "$DEST"
  echo "linked: $DEST -> $SRC"
fi

echo
echo "Done. Verify config: $CFG"
echo "Test:  echo '{\"message\":\"rebase v1.2.3\"}' | $DEST/chat-message"
