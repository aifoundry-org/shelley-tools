---
name: rbrowser
description: Use when you need to control the user's real Chrome browser from this VM — e.g. navigate to a site, click something, fill a form, take a screenshot of what the user sees, extract text/HTML, or interact with a site that requires the user's logged-in session. rbrowser drives Chrome via the DevTools Protocol tunneled through SSH.
---

# rbrowser — remote Chrome control

## What it is

`rbrowser` is a CLI installed at `/usr/local/bin/rbrowser` on this VM that talks
to **the user's local Chrome** over the Chrome DevTools Protocol (CDP). CDP is
tunneled over an SSH **reverse forward** (`ssh -R 9222:localhost:9222`).

Source lives in the [`shelley-tools`](https://github.com/nekkoai/shelley-tools)
repo under `rbrowser/`.

## Prerequisites (the user must have done this)

Before you can use `rbrowser`, the user needs:

1. Chrome launched with `--remote-debugging-port=9222 --remote-allow-origins=*`
   and a dedicated `--user-data-dir`.
2. A reverse SSH tunnel open: `ssh -N -R 9222:localhost:9222 <vm>.exe.xyz`.

Check readiness before doing anything else:

```sh
curl -s localhost:9222/json/version
```

If that returns Chrome/version JSON, you're good. If it fails, ask the user to
follow the TL;DR in `shelley-tools/rbrowser/README.md`.

## Command reference

```sh
rbrowser navigate <url>              # go to URL (waits for load)
rbrowser url                         # print current URL
rbrowser title                       # print page title
rbrowser screenshot [<path>] [--full]  # default /tmp/rbrowser.png; --full = full page
rbrowser click <selector>            # CSS selector
rbrowser type <selector> <text>      # fill an input (uses Playwright .fill)
rbrowser text [<selector>]           # innerText (default: body)
rbrowser html [<selector>]           # innerHTML
rbrowser eval <js>                   # eval JS, return JSON
rbrowser wait <selector>             # wait for element
rbrowser back / forward / reload
rbrowser tabs                        # list [index] url — title
rbrowser tab <index>                 # switch to tab N
rbrowser newtab [<url>]              # open new tab
rbrowser close                       # close current tab
```

Env vars: `RBROWSER_PORT` (default 9222), `RBROWSER_STATE` (default
`/tmp/rbrowser.state.json`, tracks last active tab URL).

## Working effectively — recipes

### View screenshots yourself

After `rbrowser screenshot /tmp/x.png` (or `--full`), read it back with
the `read_image` tool to actually see what the user sees. You cannot describe
the page accurately without doing this.

### Locating elements when a click doesn't work

1. Dump inputs / links / buttons via `rbrowser eval`:
   ```sh
   rbrowser eval 'Array.from(document.querySelectorAll("input")).map(i=>({ph:i.placeholder,id:i.id,name:i.name})).slice(0,20)'
   rbrowser eval 'Array.from(document.querySelectorAll("a")).slice(0,30).map(a=>({t:a.textContent.trim().slice(0,50),h:a.href}))'
   ```
2. Prefer stable selectors: `#id`, `[data-testid=...]`, `input[name=...]`.
3. Highlighted matches on search-result pages are often wrapped in `<mark>`;
   the actual clickable element is a parent. Use
   `document.querySelectorAll("mark")[0].closest("a,button,[role=link]")`.

### Triggering keyboard events (Enter, etc.)

`rbrowser type` uses `.fill()` which does NOT submit forms. To press Enter:

```sh
rbrowser eval 'const el=document.querySelector("#my-input"); const e=new KeyboardEvent("keydown",{key:"Enter",code:"Enter",keyCode:13,which:13,bubbles:true}); el.dispatchEvent(e); true'
```

Many SPAs listen on `keydown`; some need `keypress` or `keyup` too.

### Scrolling / reading a long page

For a full-page snapshot: `rbrowser screenshot /tmp/x.png --full`. To scroll to
bottom (some pages lazy-load): `rbrowser eval 'window.scrollTo(0,document.body.scrollHeight)'`.

To just grab the full text of the page rather than screenshot it:
```sh
rbrowser eval 'document.body.innerText'
```
(cheap, fast, no image tokens.)

### Dismissing modals / cookie banners / subscribe popups

Common patterns: `button[aria-label="Close"]`, `[role=dialog] button`, or
inspect via `rbrowser eval 'document.querySelectorAll("[role=dialog] button").length'`.

### Handling multi-tab flows

`rbrowser` remembers the last-touched URL in `RBROWSER_STATE`. If the user
switches tabs manually or if navigation opens a new tab, use `rbrowser tabs`
followed by `rbrowser tab <n>` to re-anchor.

### Extracting structured data

Text extraction is often more efficient than screenshots for content-heavy
pages:
```sh
rbrowser text 'main' > /tmp/page.txt
# Then read /tmp/page.txt with head/grep/etc.
```

## Trust & scope

The user's Chrome profile is whatever session they launched with. That profile
may be logged into sensitive services (PitchBook, banking, email). Treat the
browser as an extension of the user — don't perform destructive actions
(delete, purchase, send message) without explicit confirmation.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `cannot reach Chrome DevTools at localhost:9222` | Tunnel or Chrome not running. Ask user to check both. |
| CDP handshake 403 | Chrome missing `--remote-allow-origins=*`. |
| Element found in DevTools but not by rbrowser | Might be in an iframe or shadow DOM. Use `rbrowser eval` to reach into it. |
| Click fires but nothing happens | React/Vue apps may need real events; dispatch via `rbrowser eval` with `bubbles:true`. |
| Screenshot looks blank/white | Page not fully loaded. `rbrowser wait <selector>` first, or `sleep 2`. |

## Verifying installation

```sh
which rbrowser
curl -s localhost:9222/json/version | head -c 100
rbrowser navigate https://example.com && rbrowser title
```
