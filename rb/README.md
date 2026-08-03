# rb — shared human-takeover research browser

Lets Shelley do **web research that doesn't get CAPTCHA'd**. Instead of scraping
search engines with `curl` or a throwaway headless browser (which is exactly what
gets blocked), `rb` drives a **real, visible, persistent Chrome on the VM** over
the DevTools Protocol. A human can watch the same screen and click through any
CAPTCHA / consent wall / login via a noVNC web page — and because the browser
profile is shared and stateful, a site the human clears stays cleared for the agent.

Contrast with [`rbrowser/`](../rbrowser), which drives the **user's laptop**
Chrome through an SSH reverse tunnel. `rb` runs the browser **on the VM itself**
(no laptop/tunnel needed) and adds a search/fetch CLI plus automatic
CAPTCHA detection + human-handoff.

---

## TL;DR

### On the VM

```sh
git clone git@github.com:nekkoai/shelley-tools.git
cd shelley-tools/rb
./install.sh        # needs sudo (apt + systemd); idempotent
```

This installs Xvfb + Chrome-for-Testing + x11vnc + noVNC as systemd services,
builds a Playwright venv, symlinks `rb` into `/usr/local/bin`, and registers the
Shelley skill so future sessions auto-activate it.

### On your local machine

Nothing to install. Just open the human-takeover view in your browser (printed
by the installer; the default is):

```
https://<vm-host>.exe.xyz:6080/vnc.html?autoconnect=true&resize=scale
```

That's it — you're watching the agent's browser live and can click whenever it
gets stuck on a human check.

---

## Usage

```sh
rb search "EU Chips Act 2.0 status 2026" --n 8     # title | url lines; engine auto-fallback
rb fetch "https://example.com/article" --max-chars 6000   # readable article text
rb snapshot                                        # screenshot the shared screen -> /tmp/shared_screen.png
rb blocked?                                        # exit 0 if the current page is CAPTCHA/blocked
rb wait-unblocked "<url>"                          # poll until a human clears a challenge
```

Options / env:

| Env var | Default | Meaning |
|---|---|---|
| `RB_CDP` | `http://127.0.0.1:9222` | Chrome DevTools endpoint |
| `RB_NOVNC` | `https://<host>.exe.xyz:6080/vnc.html?…` | Human takeover URL (printed on block) |
| `RB_NOVNC_PORT` | `6080` | noVNC web port (also exe.dev-proxied) |
| `RB_SCREENSHOT` | `/tmp/shared_screen.png` | `rb snapshot` output |
| `RB_CHROME_VER` | `146.0.7680.165` | Chrome-for-Testing version (install-time) |

Exit codes: `0` ok · `3` blocked/CAPTCHA (human needed) · `4` no results parsed ·
`5` still blocked after `wait-unblocked` timeout.

### Human hand-off

When a command exits `3`, it prints the noVNC takeover URL. Ask the human to open
it and click the challenge, then `rb wait-unblocked "<url>"` and retry. Once the
human clears a site (or logs in), the persistent profile keeps it working.

## Design notes

- **Why visible, not headless?** Real headed Chrome with a persistent profile and
  cookies looks far less like a bot, and a human can intervene in the *same*
  session — the agent resumes exactly where it was blocked.
- **Chrome-for-Testing**, not the Ubuntu `chromium` snap (which is a stub in
  containers). Pinned version, plain `--remote-debugging-port`.
- **Stack**: Xvfb (virtual display) → Chrome (CDP :9222) → x11vnc (VNC :5900) →
  noVNC/websockify (web :6080). All four are `Restart=always` systemd units.
- Chrome runs as root in the container → needs `--no-sandbox` (harmless warning
  bar). `--password-store=basic` avoids keyring prompts.
- **Trust**: the shared profile may hold logins. Treat it as an extension of the
  human — no destructive/account actions without confirmation.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `curl 127.0.0.1:9222/json/version` fails | `sudo systemctl restart shared-chrome`; check `journalctl -u shared-chrome`. |
| Google `/sorry` "unusual traffic" | IP-flagged. Use default DuckDuckGo, or have the human click the checkbox once via noVNC. |
| Black/blank noVNC screen | `sudo systemctl restart xvfb shared-chrome x11vnc novnc`. |
| Bing returns quiz/junk links | Known behaviour; it ignores the query and redirect-wraps links. Prefer DDG. |
| Reset identity | `sudo systemctl stop shared-chrome && rm -rf .browser/profile/* && sudo systemctl start shared-chrome` |

## What's in this folder

- `install.sh` — idempotent installer (see [repo conventions](../AGENTS.md)).
- `rb` — wrapper launcher (uses the local `.venv`).
- `rb.py` — the CLI implementation (search / fetch / snapshot / blocked? / wait-unblocked).
- `rb.skill.md` — Shelley skill file, auto-registered by `install.sh`.
- `.browser/` — created at install time: Chrome-for-Testing + persistent profile (git-ignored).
