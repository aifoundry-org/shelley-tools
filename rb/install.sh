#!/bin/bash
# Installer for rb — the shared human-takeover research browser.
#
# Sets up (idempotently) on an exe.dev VM:
#   1. OS deps: Xvfb, x11vnc, noVNC/websockify, Playwright venv.
#   2. Chrome-for-Testing (real Chromium, no snap) + persistent profile.
#   3. systemd units: xvfb / shared-chrome / x11vnc / novnc, started + enabled.
#   4. Symlink `rb` into /usr/local/bin and register the Shelley skill.
#
# Running twice is safe. Re-running also refreshes the skill + binary symlink.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TOOL="rb"
cd "$HERE"

STATE="$HERE/.browser"            # runtime state: chrome + profile
CHROME_VER="${RB_CHROME_VER:-146.0.7680.165}"
DISPLAY_NUM="${RB_DISPLAY_NUM:-99}"
NOVNC_PORT="${RB_NOVNC_PORT:-6080}"
VNC_PORT="${RB_VNC_PORT:-5900}"
CDP_PORT="${RB_CDP_PORT:-9222}"
SCREEN="${RB_SCREEN:-1600x1000x24}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then SUDO="sudo"; else
    echo "NOTE: need sudo for apt/systemd/symlink. Re-run with sudo access." >&2
  fi
fi

# -- 1. OS deps ------------------------------------------------------------
echo "== installing OS packages =="
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq xvfb x11vnc websockify novnc fonts-liberation unzip curl >/dev/null

# -- 2. Chrome-for-Testing + profile ---------------------------------------
mkdir -p "$STATE/profile"
if [ ! -x "$STATE/chrome-linux64/chrome" ]; then
  echo "== downloading Chrome-for-Testing $CHROME_VER =="
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/cft.zip" \
    "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_VER}/linux64/chrome-linux64.zip"
  unzip -q "$tmp/cft.zip" -d "$STATE"
  rm -rf "$tmp"
fi
CHROME="$STATE/chrome-linux64/chrome"
"$CHROME" --version || true

# -- 3. systemd units --------------------------------------------------------
write_unit() { # name, content
  echo "$2" | $SUDO tee "/etc/systemd/system/$1" >/dev/null
}

write_unit xvfb.service "[Unit]
Description=rb: virtual X display :${DISPLAY_NUM}
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :${DISPLAY_NUM} -screen 0 ${SCREEN} -ac +extension RANDR
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target"

# Chrome runs as root (systemd) in the container -> needs --no-sandbox.
write_unit shared-chrome.service "[Unit]
Description=rb: shared visible Chromium (CDP :${CDP_PORT}, human-takeover)
After=xvfb.service
Requires=xvfb.service
[Service]
Type=simple
Environment=DISPLAY=:${DISPLAY_NUM}
ExecStart=${CHROME} --no-sandbox --no-first-run --no-default-browser-check --disable-session-crashed-bubble --hide-crash-restore-bubble --start-maximized --remote-debugging-address=127.0.0.1 --remote-debugging-port=${CDP_PORT} --user-data-dir=${STATE}/profile --password-store=basic --ozone-platform=x11 https://www.google.com
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target"

write_unit x11vnc.service "[Unit]
Description=rb: x11vnc on :${DISPLAY_NUM} (VNC :${VNC_PORT})
After=xvfb.service
Requires=xvfb.service
[Service]
Type=simple
ExecStart=/usr/bin/x11vnc -display :${DISPLAY_NUM} -forever -shared -rfbport ${VNC_PORT} -localhost -nopw -noxdamage -quiet
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target"

write_unit novnc.service "[Unit]
Description=rb: noVNC web UI on :${NOVNC_PORT}
After=x11vnc.service
Requires=x11vnc.service
[Service]
Type=simple
ExecStart=/usr/bin/websockify --web /usr/share/novnc ${NOVNC_PORT} localhost:${VNC_PORT}
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target"

echo "== (re)starting display + browser + vnc + novnc =="
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now xvfb x11vnc novnc shared-chrome >/dev/null 2>&1 || true
sleep 3

# -- 4. Playwright venv -------------------------------------------------------
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet playwright

# -- 5. PATH symlink -----------------------------------------------------------
TARGET=/usr/local/bin/$TOOL
if [ -w /usr/local/bin ] || $SUDO -n true 2>/dev/null; then
  $SUDO ln -sf "$HERE/$TOOL" "$TARGET"
  echo "linked $TARGET -> $HERE/$TOOL"
else
  echo "NOTE: run:  sudo ln -sf $HERE/$TOOL $TARGET"
fi

# -- 6. Shelley skill registration ---------------------------------------------
if command -v shelley >/dev/null 2>&1; then
  SKILL_DIR="$HOME/.config/shelley/$TOOL"
  mkdir -p "$SKILL_DIR"
  cp "$HERE/rb.skill.md" "$SKILL_DIR/SKILL.md"
  echo "registered Shelley skill '$TOOL' at $SKILL_DIR/SKILL.md"
fi

# -- 7. status + next steps -----------------------------------------------------
HOST="$(hostname)"
cat <<EOF

rb installed.
  Agent CLI : rb search "query" --n 8   |   rb fetch <url>   |   rb blocked?
  Human UI  : https://${HOST}.exe.xyz:${NOVNC_PORT}/vnc.html?autoconnect=true&resize=scale
  CDP       : http://127.0.0.1:${CDP_PORT}/json/version

Verify:
  curl -s http://127.0.0.1:${CDP_PORT}/json/version | head -c 80
  rb search "hello world" --n 3

Manage:
  sudo systemctl restart shared-chrome        # bounce the browser
  sudo systemctl stop shared-chrome && rm -rf $STATE/profile/* && sudo systemctl start shared-chrome   # reset identity
EOF
