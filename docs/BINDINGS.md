# Bindings

## Commands

| Command | Args | Flags | Does |
| --- | --- | --- | --- |
| `:Rules check` | `[path]` (defaults to cwd) | `--family=<PREFIX>` (required), `--format=json` (optional) | Runs every rule in the family against `path`. Default: reports into the quickfix list and a readable buffer. `--format=json` prints the results as JSON instead (`:messages`/stdout) and does not touch quickfix/buffer or quit Neovim — see below for headless/CI use |

No default keymaps are bound — `:Rules check --family=<PREFIX>` is the whole
surface for now. `new-project`/`review`/`release` gates are designed but not
implemented yet.

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
errored; `recommended`/`nice-to-have` findings, `manual` rules (no `check`
field, no automated verdict) and `waived` rules (see below) never affect it.

## Waivers

A `.rules-waivers.json` at the root you check (`{ "path" }` in `:Rules check
[path]`, cwd by default) records consciously accepted findings so a re-run
doesn't keep flagging them:

```json
{
  "DEP-04": "legacy call site, ticket JIRA-123 tracks the actual fix"
}
```

A waived rule that would otherwise fail or error reports as **waived**
instead — visible in the buffer report with its reason, excluded from the
quickfix worklist, and never counted by `check_family_json`'s exit code. A
waiver for a rule that currently passes has no effect; it just sits unused
until the rule fails again. This is deliberately different from deleting the
rule or the ruleset entry: the record that a specific finding was seen and
accepted survives.

A `.rules-waivers.json` that isn't a `{"RULE-ID": "reason"}` object — a list,
or a value that isn't a string — is a load error, notified the same way a
bad ruleset file is, not a silent zero-waivers file. Same reasoning as
`docs/RULESET-FORMAT.md`'s check primitives: a malformed input fails loudly
instead of quietly doing nothing.
