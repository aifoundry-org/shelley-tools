#!/usr/bin/env python3
"""rbrowser — drive a remote Chrome over CDP (via SSH reverse tunnel).

Usage:
  rbrowser navigate <url>
  rbrowser click <selector>
  rbrowser type <selector> <text>
  rbrowser screenshot [<path>]     # default: /tmp/rbrowser.png; use --full for full page
  rbrowser eval <js>
  rbrowser text [<selector>]       # innerText of selector or body
  rbrowser html [<selector>]
  rbrowser url                     # current URL
  rbrowser title
  rbrowser tabs                    # list open tabs
  rbrowser tab <index>             # switch to tab by index
  rbrowser newtab [<url>]
  rbrowser close                   # close current tab
  rbrowser back / forward / reload
  rbrowser wait <selector>         # wait for selector

Connects to Chrome DevTools at http://localhost:${RBROWSER_PORT:-9222}
(which should be a reverse SSH tunnel to your local Chrome).
"""
import asyncio, json, os, sys, urllib.request, pathlib
from playwright.async_api import async_playwright

PORT = int(os.environ.get("RBROWSER_PORT", "9222"))
STATE = pathlib.Path(os.environ.get("RBROWSER_STATE", "/tmp/rbrowser.state.json"))

def _load_state():
    if STATE.exists():
        try: return json.loads(STATE.read_text())
        except: pass
    return {}

def _save_state(s):
    STATE.write_text(json.dumps(s))

async def _get_page(browser, want_index=None):
    ctx = browser.contexts[0] if browser.contexts else await browser.new_context()
    pages = ctx.pages
    if not pages:
        return await ctx.new_page()
    state = _load_state()
    if want_index is not None:
        return pages[want_index]
    tid = state.get("target")
    for p in pages:
        try:
            if p.url == tid: return p
        except: pass
    return pages[-1]

def _remember(page):
    try: _save_state({"target": page.url})
    except: pass

async def run(cmd, args):
    async with async_playwright() as pw:
        browser = await pw.chromium.connect_over_cdp(f"http://localhost:{PORT}")
        try:
            if cmd == "tabs":
                ctx = browser.contexts[0]
                for i, p in enumerate(ctx.pages):
                    try: t = await p.title()
                    except: t = "?"
                    print(f"[{i}] {p.url}  — {t}")
                return
            if cmd == "newtab":
                ctx = browser.contexts[0] if browser.contexts else await browser.new_context()
                page = await ctx.new_page()
                if args:
                    await page.goto(args[0])
                _remember(page); print(page.url); return
            if cmd == "tab":
                idx = int(args[0])
                page = await _get_page(browser, want_index=idx)
                await page.bring_to_front()
                _remember(page); print(page.url); return

            page = await _get_page(browser)

            if cmd == "navigate":
                await page.goto(args[0]); _remember(page); print(page.url)
            elif cmd == "click":
                await page.click(args[0]); _remember(page)
            elif cmd == "type":
                await page.fill(args[0], args[1]); _remember(page)
            elif cmd == "screenshot":
                path = args[0] if args and not args[0].startswith("--") else "/tmp/rbrowser.png"
                full = "--full" in args
                await page.screenshot(path=path, full_page=full)
                print(path)
            elif cmd == "eval":
                r = await page.evaluate(args[0])
                print(json.dumps(r, default=str))
            elif cmd == "text":
                sel = args[0] if args else "body"
                print(await page.inner_text(sel))
            elif cmd == "html":
                sel = args[0] if args else "html"
                print(await page.inner_html(sel))
            elif cmd == "url":
                print(page.url)
            elif cmd == "title":
                print(await page.title())
            elif cmd == "close":
                await page.close()
            elif cmd == "back":
                await page.go_back()
            elif cmd == "forward":
                await page.go_forward()
            elif cmd == "reload":
                await page.reload()
            elif cmd == "wait":
                await page.wait_for_selector(args[0])
            else:
                print(__doc__); sys.exit(2)
        finally:
            # Don't close browser — it's the user's real browser!
            pass

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    try:
        # sanity check that the tunnel is up
        urllib.request.urlopen(f"http://localhost:{PORT}/json/version", timeout=3).read()
    except Exception as e:
        print(f"cannot reach Chrome DevTools at localhost:{PORT} — is the SSH tunnel & Chrome running? ({e})", file=sys.stderr)
        sys.exit(1)
    asyncio.run(run(sys.argv[1], sys.argv[2:]))
