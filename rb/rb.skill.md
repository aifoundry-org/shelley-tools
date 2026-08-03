---
name: rb
description: Use when doing web research from this VM and search engines keep CAPTCHA-ing, rate-limiting, or blocking you (Google "unusual traffic" /sorry, Bing/Brave captcha, HTTP 429), or when you need a real, visible, persistent, logged-in browser that a human can watch and take over to clear a challenge. rb routes searches and page fetches through a shared on-VM Chrome over CDP with a noVNC human-takeover view.
---

# rb — shared human-takeover research browser

## What it is

`rb` is a CLI at `/usr/local/bin/rb` that lets Shelley search and read the web
through a **real, visible, persistent Chrome running on this VM**, driven over
the Chrome DevTools Protocol (CDP). A human can watch the same screen and click
through CAPTCHAs / consent walls / logins via a **noVNC** web page — because the
browser is shared and stateful, a cleared site stays cleared for the agent.

Source: [`shelley-tools`](https://github.com/nekkoai/shelley-tools) under `rb/`.

Prefer `rb` over `curl`-scraping search engines or the headless browser tool —
those are exactly what trigger the blocks.

## Prerequisites (installer already did this)

`install.sh` sets up: Xvfb (virtual display), Chrome-for-Testing with a
persistent profile, x11vnc, noVNC, all as systemd units, plus a Playwright venv.
Check readiness:

```sh
curl -s http://127.0.0.1:9222/json/version | head -c 80
```
Returns Chrome JSON → good. If not, run `rb/install.sh` (or
`sudo systemctl restart shared-chrome`).

## Command reference

```sh
rb search "query" [--engine duckduckgo|brave|bing|google] [--n 10]
rb fetch <url> [--max-chars 6000]      # readable article text (URL/TITLE/body)
rb snapshot                            # save screenshot of the shared screen to /tmp/shared_screen.png
rb blocked?                            # exit 0 if the current page looks CAPTCHA'd/blocked
rb wait-unblocked <url> [--timeout 300]# poll until a human clears a challenge
```

`search` prints one line per organic result: `title | url`. It **auto-falls
back** across engines (default order DuckDuckGo → Brave → Bing → Google) when one
is blocked. DuckDuckGo is the default because it is the least gated.

## Recipes

### Standard research loop
```sh
rb search "EuroHPC DARE RISC-V budget" --n 8
# pick a promising URL from the title|url lines
rb fetch "https://…" --max-chars 6000 > /tmp/page.txt
```

### See the page yourself
`rb snapshot` writes `/tmp/shared_screen.png`; read it back with the `read_image`
tool to actually look at the shared screen (consent walls, layouts).

### When you get blocked (exit code 3)
1. Note the noVNC URL `rb` prints (or `echo $RB_NOVNC`, default
   `https://<host>.exe.xyz:6080/vnc.html?autoconnect=true&resize=scale`).
2. Tell the human: "please click the CAPTCHA here: <noVNC URL>" (optionally
   `ask-human "…"` if installed, which emails them).
3. Wait: `rb wait-unblocked "<the url>"`, then re-run your command.

### Persisting logins
The Chrome profile is persistent. If a site needs a login, ask the human to log
in once via the noVNC view; subsequent `rb fetch` calls reuse that session.

## Trust & scope

The browser is a shared, possibly logged-in, human-visible session. Do not
perform destructive or account actions (purchases, deletes, sending messages)
without explicit confirmation. Everything you do is visible to the human in real
time.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cannot connect` / CDP empty | `sudo systemctl restart shared-chrome`; re-check `curl -s 127.0.0.1:9222/json/version`. |
| Google returns `/sorry` | It's IP-flagged. Use default DDG (auto), or have the human click the checkbox once via noVNC. |
| `search` exit 4 (no results) | Page was a consent wall or markup changed — `rb snapshot` and look, or try `--engine`. |
| Bing returns junk/quiz links | Known: Bing sometimes ignores the query & wraps links in redirects. Prefer DDG. |
| Chrome "unsupported flag: --no-sandbox" bar | Harmless (runs as root in the container). Ignore. |
| Reset identity / clear cookies | `sudo systemctl stop shared-chrome && rm -rf <tool>/.browser/profile/* && sudo systemctl start shared-chrome` |

## Verifying installation

```sh
which rb
curl -s http://127.0.0.1:9222/json/version | head -c 60
rb search "hello world" --n 3
```
