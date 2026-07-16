# rbrowser — control your local Chrome from a remote VM

A tiny CLI that gives Shelley (running on an exe.dev VM, or any remote host)
full control of a **real** Chrome browser running on **your** machine —
navigation, clicks, form input, screenshots, JS eval, tab management.

Under the hood it speaks Chrome's built-in **DevTools Protocol** (CDP) via
[Playwright](https://playwright.dev). The remote side reaches your Chrome
through a plain **SSH reverse tunnel**. No browser extension, no third-party
service, no exposed ports on your machine.

```
┌─ your laptop ───────┐          ┌─ exe.dev VM ─────────┐
│  Chrome                │          │                       │
│  (--remote-debugging-  │          │  rbrowser CLI         │
│   port=9222)           │          │  (Playwright + CDP)   │
│           127.0.0.1:9222 <── ssh ── -R ── localhost:9222  │
└──────────────────────┘          └───────────────────────┘
```

---

## TL;DR — local setup

### 1. Launch Chrome with remote debugging (on your laptop)

Quit Chrome first, then relaunch with a **dedicated profile** and the debug port:

**macOS:**
```sh
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --remote-allow-origins=* \
  --user-data-dir=$HOME/chrome-remote-profile
```

**Linux:**
```sh
google-chrome --remote-debugging-port=9222 --remote-allow-origins=* \
  --user-data-dir=$HOME/chrome-remote-profile
```

**Windows (PowerShell):**
```powershell
& 'C:\Program Files\Google\Chrome\Application\chrome.exe' `
  --remote-debugging-port=9222 --remote-allow-origins=* `
  --user-data-dir=$HOME\chrome-remote-profile
```

A dedicated `--user-data-dir` keeps it isolated from your normal browsing.
The DevTools port binds to `127.0.0.1` only — it's not exposed to your LAN.
Only the SSH tunnel can reach it.

### 2. Open a reverse SSH tunnel to the remote VM

```sh
ssh -N -R 9222:localhost:9222 <vm-name>.exe.xyz
```

…or, better, add to `~/.ssh/config`:

```
Host <vm-name>.exe.xyz
  RemoteForward 9222 localhost:9222
  ServerAliveInterval 30
  ExitOnForwardFailure yes
```

Then any regular `ssh <vm-name>.exe.xyz` establishes the tunnel automatically.

### 3. Install `rbrowser` on the VM (one-time)

```sh
git clone git@github.com:nekkoai/shelley-tools.git
cd shelley-tools/rbrowser
./install.sh
sudo ln -sf $PWD/rbrowser /usr/local/bin/rbrowser
```

### 4. Verify

From the VM:
```sh
curl -s localhost:9222/json/version   # should show Chrome version
rbrowser navigate https://example.com
rbrowser screenshot /tmp/shot.png
```

---

## Usage (on the VM)

```sh
rbrowser navigate <url>              # go to URL
rbrowser url                         # current URL
rbrowser title                       # page title
rbrowser screenshot [<path>] [--full]
rbrowser click <selector>            # CSS selector
rbrowser type <selector> <text>      # fills an input
rbrowser text [<selector>]           # innerText (default: body)
rbrowser html [<selector>]           # innerHTML
rbrowser eval <js>                   # returns JSON result
rbrowser wait <selector>             # wait for selector to appear
rbrowser back / forward / reload
rbrowser tabs                        # list open tabs [i] url — title
rbrowser tab <index>                 # switch to tab by index
rbrowser newtab [<url>]              # open a new tab
rbrowser close                       # close current tab
```

### Environment variables

| Var | Default | Meaning |
|---|---|---|
| `RBROWSER_PORT` | `9222` | Local port on the VM where the tunnel terminates. |
| `RBROWSER_STATE` | `/tmp/rbrowser.state.json` | Which page was last targeted (URL). |

---

## Design notes & gotchas

- **`--remote-allow-origins=*` is required** on modern Chrome (>= 111);
  without it CDP rejects the WebSocket handshake with `403 origin`.
- The CLI **never closes** the browser itself — it's your real Chrome.
  It only closes individual tabs when you ask it to.
- "Current tab" is tracked in `RBROWSER_STATE`. If the URL changed under
  you (e.g. you navigated manually), the CLI falls back to the last tab.
- If you want the tunnel to survive network hiccups, use `autossh -M 0`:
  `autossh -M 0 -N -R 9222:localhost:9222 <vm>.exe.xyz`
- The remote side can see whatever Chrome sees — including your logged-in
  sessions in that profile. Keep the `--user-data-dir` profile scoped to
  what you want Shelley to be able to access.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cannot reach Chrome DevTools at localhost:9222` | Chrome or tunnel isn't up. `curl localhost:9222/json/version` from the VM. |
| CDP rejects connection / 403 | Add `--remote-allow-origins=*` to Chrome launch flags. |
| Element not found by selector | Try `rbrowser wait <sel>` first, or use `rbrowser eval` to inspect the DOM. |
| Selector matches but click doesn't work | Some SPAs bind synthetic events; try dispatching via `rbrowser eval`. |
| Tunnel keeps dropping | Use `autossh` or add `ServerAliveInterval 30` to your SSH config. |

## What's in this folder

- `rbrowser` — shell wrapper that dispatches to the Python entry point.
- `rbrowser.py` — the actual CLI (Playwright-based).
- `install.sh` — creates a Python venv and installs Playwright.
- `rbrowser.skill.md` — a Shelley skill file that another agent session can
  read to get full context on how to use rbrowser.
