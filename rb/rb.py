#!/usr/bin/env python3
"""
rb — search & fetch the web through the SHARED visible human-takeover browser.

Why: search engines captcha/rate-limit curl and headless automation, but a real
visible Chrome with a persistent profile (and a human who can click a CAPTCHA
once via noVNC) gets through. Route agent web research through this.

The human watches / takes over at the noVNC URL printed by `install.sh`
(settable via RB_NOVNC). The agent drives the same browser over CDP.

Usage:
  rb search "EU Chips Act 2.0 status 2026" [--engine duckduckgo|brave|bing|google] [--n 10]
  rb fetch https://example.com/article [--max-chars 6000]
  rb snapshot                      # save a screenshot of the shared screen
  rb wait-unblocked URL            # poll until a human clears a CAPTCHA
  rb blocked?                      # exit 0 if current page looks blocked, else 1

Search results print as:  <title> | <url>
Fetch prints readable article text (main-content heuristics), cut to --max-chars.

Exit codes: 0 ok · 3 blocked/CAPTCHA (human needed) · 4 no results · 5 still blocked after wait.

Env: RB_CDP, RB_NOVNC, RB_NOVNC_PORT, RB_HOST, RB_SCREENSHOT.
Requires: playwright (created by install.sh). Chrome CDP at 127.0.0.1:9222.
"""
import asyncio, sys, re, os, argparse, time, socket

CDP = os.environ.get("RB_CDP", "http://127.0.0.1:9222")
NOVNC_PORT = os.environ.get("RB_NOVNC_PORT", "6080")
_host = os.environ.get("RB_HOST", socket.gethostname())
NOVNC = os.environ.get(
    "RB_NOVNC",
    f"https://{_host}.exe.xyz:{NOVNC_PORT}/vnc.html?autoconnect=true&resize=scale",
)
SCREENSHOT = os.environ.get("RB_SCREENSHOT", "/tmp/shared_screen.png")

BLOCK_SIGNS = [
    "unusual traffic", "verify you are human", "verify that you are not a robot",
    "i'm not a robot", "are you a robot", "captcha", "recaptcha", "challenge-platform",
    "please complete the security check", "access denied", "error 429", "too many requests",
    "rate limit", "cloudflare", "checking your browser", "prove you are human",
]

SEARCH_URLS = {
    "google":     "https://www.google.com/search?q={q}&num={n}",
    "bing":       "https://www.bing.com/search?q={q}&count={n}",
    "brave":      "https://search.brave.com/search?q={q}",
    "duckduckgo": "https://duckduckgo.com/?q={q}&ia=web",
}

# CSS selectors for organic results per engine
RESULT_SEL = {
    "google":     "a:has(h3)",
    "bing":       "li.b_algo h2 a",
    "brave":      "a[href].h",
    "duckduckgo": "article a[href]",
}

from urllib.parse import quote

async def get_page(pw):
    browser = await pw.chromium.connect_over_cdp(CDP)
    ctx = browser.contexts[0] if browser.contexts else await browser.new_context()
    page = ctx.pages[0] if ctx.pages else await ctx.new_page()
    return browser, page

def looks_blocked(text, html=""):
    t = (text + " " + html).lower()
    return any(s in t for s in BLOCK_SIGNS)

async def page_text(page):
    try:
        return (await page.inner_text("body"))[:4000]
    except Exception:
        return ""

async def notify_blocked(page):
    body = await page_text(page)
    if looks_blocked(body):
        print(f"\n*** PAGE LOOKS BLOCKED/CAPTCHA'D ***", file=sys.stderr)
        print(f"*** Human, please click it through: {NOVNC}", file=sys.stderr)
        print(f"*** Then re-run, or: rb wait-unblocked '{page.url}'", file=sys.stderr)
        return True
    return False

async def _try_search(page, engine, query, n):
    """Returns list of {t,u} or None if blocked/empty."""
    url = SEARCH_URLS[engine].format(q=quote(query), n=n)
    await page.goto(url, wait_until="domcontentloaded", timeout=45000)
    await page.wait_for_timeout(2500)
    if looks_blocked(await page_text(page), ""):
        return None
    try:
        await page.wait_for_selector(RESULT_SEL[engine], timeout=8000)
    except Exception:
        pass
    results = await page.eval_on_selector_all(
        RESULT_SEL[engine],
        "els => els.map(a => ({t: (a.innerText||'').trim().split('\\n')[0], u: a.href})).filter(r => r.t && r.u && r.u.startsWith('http'))"
    )
    seen, out = set(), []
    for r in results:
        if r["u"] in seen or any(b in r["u"] for b in ("google.com/search", "bing.com/search", "duckduckgo.com", "brave.com/search")):
            continue
        seen.add(r["u"]); out.append(r)
        if len(out) >= n:
            break
    return out or None

async def cmd_search(args):
    from playwright.async_api import async_playwright
    engines = [args.engine] + [e for e in ("duckduckgo", "brave", "bing", "google") if e != args.engine]
    async with async_playwright() as pw:
        browser, page = await get_page(pw)
        last_blocked = False
        for eng in engines:
            try:
                out = await _try_search(page, eng, args.query, args.n)
            except Exception as e:
                print(f"[{eng}] error: {e}", file=sys.stderr)
                out = None
            if out:
                for r in out:
                    print(f"{r['t']} | {r['u']}")
                await browser.close()
                return
            print(f"[{eng}] blocked/no results, trying next engine...", file=sys.stderr)
            last_blocked = True
        await page.screenshot(path=SCREENSHOT)
        if last_blocked:
            print(f"\n*** ALL ENGINES BLOCKED. Human: {NOVNC}", file=sys.stderr)
        await browser.close()
        sys.exit(3 if last_blocked else 4)

async def cmd_fetch(args):
    from playwright.async_api import async_playwright
    async with async_playwright() as pw:
        browser, page = await get_page(pw)
        await page.goto(args.url, wait_until="domcontentloaded", timeout=45000)
        await page.wait_for_timeout(2000)
        if await notify_blocked(page):
            await page.screenshot(path=SCREENSHOT)
            await browser.close()
            sys.exit(3)
        # extract main-ish content
        text = await page.evaluate("""() => {
            const sels = ['article','main','[role=main]','.article','.content','.post','.entry-content'];
            for (const s of sels) { const el = document.querySelector(s); if (el && el.innerText.length > 400) return el.innerText; }
            return document.body ? document.body.innerText : '';
        }""")
        text = re.sub(r"\n{3,}", "\n\n", text).strip()
        print(f"URL: {page.url}\nTITLE: {await page.title()}\n---")
        print(text[:args.max_chars])
        if len(text) > args.max_chars:
            print(f"\n...[truncated {len(text)-args.max_chars} chars]")
        await browser.close()

async def cmd_snapshot(args):
    from playwright.async_api import async_playwright
    async with async_playwright() as pw:
        browser, page = await get_page(pw)
        await page.screenshot(path=SCREENSHOT)
        print(SCREENSHOT)
        await browser.close()

async def cmd_blocked(args):
    from playwright.async_api import async_playwright
    async with async_playwright() as pw:
        browser, page = await get_page(pw)
        b = looks_blocked(await page_text(page))
        print("blocked" if b else "clear")
        await browser.close()
        sys.exit(0 if b else 1)

async def cmd_wait(args):
    from playwright.async_api import async_playwright
    deadline = time.time() + args.timeout
    async with async_playwright() as pw:
        browser, page = await get_page(pw)
        while time.time() < deadline:
            if not looks_blocked(await page_text(page)):
                print("unblocked")
                await browser.close()
                return
            await page.wait_for_timeout(3000)
            try:
                await page.reload(wait_until="domcontentloaded", timeout=20000)
            except Exception:
                pass
        print("still blocked after timeout")
        await browser.close()
        sys.exit(5)

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("search"); s.add_argument("query"); s.add_argument("--engine", default="duckduckgo", choices=list(SEARCH_URLS)); s.add_argument("--n", type=int, default=10)
    f = sub.add_parser("fetch"); f.add_argument("url"); f.add_argument("--max-chars", type=int, default=6000)
    sub.add_parser("snapshot")
    sub.add_parser("blocked?")
    w = sub.add_parser("wait-unblocked"); w.add_argument("url"); w.add_argument("--timeout", type=int, default=300)
    args = ap.parse_args()
    {"search": cmd_search, "fetch": cmd_fetch, "snapshot": cmd_snapshot, "blocked?": cmd_blocked, "wait-unblocked": cmd_wait}[args.cmd]
    asyncio.run({"search": cmd_search, "fetch": cmd_fetch, "snapshot": cmd_snapshot, "blocked?": cmd_blocked, "wait-unblocked": cmd_wait}[args.cmd](args))

if __name__ == "__main__":
    main()
