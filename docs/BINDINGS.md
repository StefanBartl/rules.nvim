# Bindings

## Commands

| Command | Args | Flags | Does |
| --- | --- | --- | --- |
| `:Rules check` | `[path]` (defaults to cwd) | `--family=<PREFIX>` (required), `--format=json` (optional) | Runs every rule in the family against `path`. Default: reports into the quickfix list and a readable buffer. `--format=json` prints the results as JSON instead (`:messages`/stdout) and does not touch quickfix/buffer or quit Neovim — see below for headless/CI use |
| `:Rules gate` | `<name>` (required), `[path]` (defaults to cwd) | `--diff=<git-ref>` (optional), `--format=json` (optional) | Runs every family configured for gate `name` (`setup({ gates = {...} })`) as one combined report. `--diff=<git-ref>` narrows findings to files changed since that ref (`git diff --name-only` + untracked files) — a rule with no findings inside the diff reports as `pass` even if the repo has standing issues elsewhere. `--format=json` behaves like `:Rules check`'s. A configured family matching zero loaded rules (typo, or not migrated yet) warns instead of silently shrinking the gate |
| `:Rules show` | `<id>` (required) | — | Jumps to one rule's source location by its exact id, without running a family check. Errors if no loaded rule has that id |
| `:Rules stats` | — | `--format=json` (optional) | Structural overview of every loaded rule: per-family totals, automated-vs-manual split, severity breakdown. No check runs — pure catalog metadata |

No default keymaps are bound. `--family=`, a gate's `<name>`, and `:Rules
show`'s `<id>` all tab-complete against whatever is actually loaded/
configured right now.

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

## Gates

A gate is a named bundle of rule families, run together as one report — the
one place in this plugin that checks more than one family at once, because a
gate is a bundle *you* chose on purpose, not the whole-catalog sweep
`:Rules check` deliberately never offers. This plugin ships no gates of its
own (same "no bundled opinions" reasoning as everywhere else) — define them
in `setup()`:

```lua
require("rules").setup({
  rulesets = { "~/path/to/your/checklists" },
  gates = {
    new_project = { "NEW" },
    release = { "REL" },
    review = { "ERR", "LUA", "PRIN", "PERF", "UI", "SEC" },
  },
})
```

```vim
:Rules gate release
:Rules gate review --diff=main
```

`--diff=<git-ref>` scopes to that diff (tracked changes + untracked new
files). A finding whose file the diff never touched is dropped, and a rule
left with zero findings reports `pass` — a diff-scoped gate answers "did
this change introduce a problem", not "does this repo have any standing
problems" (that's what an unscoped gate, or `:Rules check`, is for). A
finding that isn't tied to one specific file (e.g. a repo-wide `git status`
check) can never be "inside" a diff, so `--diff` always reports it `pass` —
scope a rule like that to an unscoped gate instead.

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

`:checkhealth rules` cross-checks the current working directory's waivers
against every loaded rule id and warns about any entry that matches
nothing — a rule that was renamed/retired, or a plain typo, left silently
protecting nothing.
