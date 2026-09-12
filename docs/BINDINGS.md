# Bindings

## Commands

| Command | Args | Flags | Does |
| --- | --- | --- | --- |
| `:Rules check` | `[path]` (defaults to cwd) | `--family=<PREFIX>` (required), `--format=json` (optional) | Runs every rule in the family against `path`. Default: reports into the quickfix list and a readable buffer. `--format=json` prints the results as JSON instead (`:messages`/stdout) and does not touch quickfix/buffer or quit Neovim — see below for headless/CI use |

No default keymaps are bound — `:Rules check --family=<PREFIX>` is the whole
surface for now. See [docs/ROADMAP.md](ROADMAP.md) for `new-project`/
`review`/`release` gates, planned but not yet implemented.

## Headless/CI use

`:Rules check --format=json` is safe to run interactively (it never quits
Neovim), but a CI script needs a real exit code too. Use the programmatic API
directly instead of the usercmd:

```sh
nvim --headless -u minimal_init.lua -c "
  lua local json, code = require('rules').check_family_json('DEP', vim.fn.getcwd())
  print(json)
  vim.cmd('cquit ' .. code)
"
```

`check_family_json(family_prefix, path)` returns `(json, exit_code, results)`.
`exit_code` is `1` only if a **critical**-severity rule failed or its check
errored; `recommended`/`nice-to-have` findings and `manual` rules (no `check`
field, no automated verdict) never affect it.
