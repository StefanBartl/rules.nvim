# Bindings

## Commands

| Command | Args | Flags | Does |
| --- | --- | --- | --- |
| `:Rules check` | `[path]` (defaults to cwd) | `--family=<PREFIX>` (required) | Runs every rule in the family against `path`, reports into the quickfix list and a readable buffer |

No default keymaps are bound — `:Rules check --family=<PREFIX>` is the whole
surface for now. See [docs/ROADMAP.md](ROADMAP.md) for `new-project`/
`review`/`release` gates, planned but not yet implemented.
