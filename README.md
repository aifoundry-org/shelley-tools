# shelley-tools

A collection of tools that extend the capabilities of [Shelley](https://exe.dev/docs/shelley/intro),
the exe.dev coding agent. Each subdirectory is a self-contained tool that gives
Shelley a new superpower — controlling a remote browser, driving other services,
reaching resources outside its VM, etc.

## Tools in this repo

| Tool | What it does |
|---|---|
| [`rbrowser/`](./rbrowser) | Lets Shelley drive **your** local Chrome (navigate, click, type, screenshot) via Chrome DevTools Protocol tunneled over SSH. No browser extension required. |

## Layout

Each tool lives in its own top-level directory and includes:
- A `README.md` with a **TL;DR** setup section and full usage docs.
- Any scripts, code, or configuration needed on the VM.
- A skill file (`*.skill.md`) that another Shelley session can read to get full
  context on how to use the tool.

## Adding a new tool

1. Create a new top-level directory named after the tool.
2. Add a `README.md` with a TL;DR at the top.
3. Add a `*.skill.md` file that a fresh Shelley session can read to bootstrap
   its understanding of the tool.
4. Update this top-level README with a one-liner in the table above.

## License

Apache 2.0 — see [LICENSE](./LICENSE).
