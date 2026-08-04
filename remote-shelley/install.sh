#!/usr/bin/env bash
# Install remote-shelley into a Shelley instance.
#
# Responsibilities (per shelley-tools convention):
#   1. Build the proxy binary and install it + config into
#      ~/.config/shelley/remote-shelley/ (the tool's runtime home).
#   2. Symlink the `remote-shelley` CLI into /usr/local/bin (sudo-aware).
#   3. Register the Shelley skill so future sessions auto-activate it.
#   4. Install the systemd proxy unit and the hook payload (new-conversation,
#      chat-message, slash/remote-shelley) into Shelley's hooks dir.
#   5. Print any remaining manual steps.
#
# Idempotent: running twice is safe.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TOOL=remote-shelley
STATE="$HOME/.config/shelley/$TOOL"
HOOKS_DEST="${SHELLEY_HOOKS_DIR:-$HOME/.config/shelley/hooks}"

# -- 1. build + install binary, config, scripts ---------------------------
if ! command -v go >/dev/null 2>&1; then
  echo "FATAL: go toolchain not found (needed to build the proxy)" >&2
  exit 1
fi
mkdir -p "$STATE/bin"
( cd "$HERE" && GOFLAGS=-mod=mod go build -o "$STATE/bin/$TOOL" . )
echo "built $STATE/bin/$TOOL"

# config.env: from example, with light autodetection, preserved if present.
CFG_SRC="$HERE/hooks/config.env.example"
CFG="$HERE/hooks/config.env"
if [ ! -f "$CFG" ]; then
  cp "$CFG_SRC" "$CFG"
  # Default the upstream to a tailnet sibling named aifoundry1 if resolvable.
  if getent hosts aifoundry1 >/dev/null 2>&1; then
    sed -i "s|^REMOTE_SHELLY_UPSTREAM=.*|REMOTE_SHELLY_UPSTREAM=http://aifoundry1:32768|" "$CFG"
  fi
  echo "created $CFG (review it!)"
else
  echo "keeping existing $CFG"
fi
# Copy config + scripts into the runtime home; hooks dir references them.
cp "$CFG" "$STATE/config.env"
mkdir -p "$STATE/scripts"
cp "$HERE/hooks/scripts/"*.sh "$STATE/scripts/"
chmod +x "$STATE/scripts/"*.sh "$HERE/hooks/scripts/"*.sh

# -- 2. CLI symlink ---------------------------------------------------------
chmod +x "$HERE/hooks/$TOOL"
TARGET=/usr/local/bin/$TOOL
if [ -w /usr/local/bin ] || sudo -n true 2>/dev/null; then
  sudo ln -sf "$HERE/hooks/$TOOL" "$TARGET"
  echo "linked $TARGET -> $HERE/hooks/$TOOL"
else
  echo "NOTE: run:  sudo ln -sf $HERE/hooks/$TOOL $TARGET"
fi

# -- 3. Shelley skill registration ------------------------------------------
if command -v shelley >/dev/null 2>&1; then
  SKILL_DIR="$HOME/.config/shelley/$TOOL"
  mkdir -p "$SKILL_DIR"
  cp "$HERE/$TOOL.skill.md" "$SKILL_DIR/SKILL.md"
  echo "registered Shelley skill '$TOOL' at $SKILL_DIR/SKILL.md"
fi

# -- 4. systemd proxy unit + hook payload -----------------------------------
# Template the unit with this machine's user/home (%h doesn't resolve in
# system services, so install-time substitution keeps it portable).
sed -e "s|__RS_USER__|$(id -un)|g" -e "s|__RS_HOME__|$HOME|g" \
  "$HERE/hooks/remote-shelley-proxy.service" | \
  sudo tee /etc/systemd/system/remote-shelley.service >/dev/null
sudo systemctl daemon-reload
echo "installed systemd unit remote-shelley.service (not started)"

chmod +x "$HERE/hooks/new-conversation" "$HERE/hooks/chat-message" \
         "$HERE/hooks/slash/$TOOL" "$HERE/hooks/command-dispatch.py"
mkdir -p "$HOOKS_DEST/slash"
for f in new-conversation chat-message command-dispatch.py; do
  cp "$HERE/hooks/$f" "$HOOKS_DEST/$f"
done
cp "$HERE/hooks/slash/$TOOL" "$HOOKS_DEST/slash/$TOOL"
# config.env must sit next to command-dispatch.py in the hooks dir.
cp "$CFG" "$HOOKS_DEST/config.env"
echo "installed hook payload into $HOOKS_DEST"

# -- 5. manual next steps ----------------------------------------------------
cat <<EOF

$TOOL installed. Next steps:
  1. Review config:  $CFG  (copied to $STATE/config.env and $HOOKS_DEST/config.env)
     Set REMOTE_SHELLY_UPSTREAM to your remote Shelley (e.g. http://<tailscale-host>:32768).
  2. Make sure this VM can reach the remote (e.g. on your tailnet):
       curl -sI http://<remote-host>:<port>/
  3. Try it from the CLI:   $TOOL status
  4. Or just say, in any Shelley conversation:
       remote-shelley http://<remote-host>:<port>
     then '$TOOL keep' to stay, or it auto-restores the local Shelley.
EOF
