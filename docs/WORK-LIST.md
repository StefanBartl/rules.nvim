# The work list `rules-work-list/1`

One run of a family or a gate, as a JSON document a task tool (tasks.nvim) turns into tasks: every rule of the run with
its verdict, its text and its waiver. A rule without a `check` (manual, or one an agent would work) is in it too, as
`unchecked` work with its text, so it can become a task without anybody opening the rule file.

It is not the ruleset catalog: that is `rules-export/1` ([CONTRACT.md](CONTRACT.md)). The work list says what one run
found in one target.

## Getting it

```vim
:Rules check --family=ERR --format=work-list
:Rules gate review --format=work-list
:Rules gate review --diff=main --format=work-list
```

Headless (never quits Neovim; the exit code is the one of `--format=json`: `1` when a `critical` rule failed):

```lua
local json, code, doc, err = require("rules").check_family_work_list("ERR", vim.fn.getcwd())
local json, code, doc, err = require("rules").run_gate_work_list("review", vim.fn.getcwd(), "main")
```

`json` is the canonical text (sorted keys, no whitespace: the same run gives the same bytes), `doc` the same document as
a Lua table. On an error (a broken `.rules.json` or `.rules-waivers.json`, an unknown gate, a failing `--diff`) all three
are `nil` and `err` says why. `:Rules stats` is not affected.

## The document

```json
{
  "schema": "rules-work-list",
  "schema_version": 1,
  "generated_at": "2026-10-17T12:00:00Z",
  "rulesets": [{ "name": "@vault/lua", "source": "E:/repos/rules-vault/rulesets/lua", "origin": "project" }],
  "target": { "path": "E:/repos/my.nvim", "commit": "6f09dcb…" },
  "scope": { "kind": "gate", "gate": "review", "families": ["ERR", "LUA"], "diff": "main" },
  "entries": [ … ]
}
```

| Field | Meaning |
|---|---|
| `schema` | always `"rules-work-list"` |
| `schema_version` | `1`; raised when a field is removed, renamed or changes its meaning. A new optional field does not raise it: a reader ignores fields it does not know |
| `generated_at` | when the run was made, UTC, `YYYY-MM-DDTHH:MM:SSZ` |
| `rulesets` | the rulesets of the run (a project may load several): `name` as it was named (`@vault/lua`, a folder name), `source` its folder or file, `origin` where it was named (`call`, `setup`, `project`, `vault`) |
| `target.path` | the folder that was checked, `/`-separated |
| `target.commit` | the commit checked out there; absent when it is no git work tree |
| `scope` | `{ kind = "family", family }` or `{ kind = "gate", gate, families, diff? }` |
| `entries` | one per rule of the run, in the order of the run |

### An entry

```json
{
  "rule_id": "ERR-03",
  "family": "ERR",
  "severity": "critical",
  "kind": "automated",
  "status": "fail",
  "ruleset": "@vault/lua",
  "title": "`ERR-03` — pcall results are checked",
  "section": "1. Errors",
  "description": "A pcall whose result nobody looks at hides the error it caught.",
  "source": { "file": "E:/repos/rules-vault/rulesets/lua/regeln/ERR.md", "line": 41 },
  "findings": [{ "file": "lua/x.lua", "line": 12, "text": "pcall(f)" }],
  "waiver": { "reason": "vendored code", "paths": ["vendor/**"], "suppressed": 2 }
}
```

| Field | Meaning |
|---|---|
| `rule_id`, `family` | the id and its leading letters |
| `severity` | `critical`, `recommended` or `nice-to-have` |
| `kind` | `automated` (the rule has a `check`) or `manual` (it has none) |
| `status` | `pass`, `fail`, `waived` or `unchecked` (see below) |
| `ruleset` | the `name` of the ruleset the rule lives in; absent when no ruleset of the run holds its file |
| `title` | the heading that names the rule, `""` when it has none |
| `section` | the heading above it; absent when there is none |
| `description` | the prose under the rule block, `""` when there is none |
| `source` | the rule's file and line |
| `findings` | the places the check found: `file` relative to `target.path` when it lies inside it, `line`, `text` (the line). Empty for a pass, a manual rule and a check that could not run. For a waived rule they are the findings the waiver covers |
| `error` | only for an automated rule whose check could not run: why |
| `waiver` | only when the rule has one that matters for this run: `reason`, `expires` (the last valid day, when set), `paths` (when limited to paths); `suppressed` (how many findings a waiver limited to paths held back, the rest stay `findings` and the status stays `fail`); `expired: true` (it ran out and suppresses nothing) |

### `status`

| Status | When |
|---|---|
| `pass` | the check ran and found nothing (inside the diff, for a gate with `diff`) |
| `fail` | the check found something no waiver covers |
| `waived` | the check found something and a waiver covers all of it |
| `unchecked` | nobody judged the rule: it is manual (`kind = "manual"`, never counted by the exit code), or its check could not run (`error` says why; a `critical` one makes the exit code `1`, as with `--format=json`). Never a pass |

## For a consumer

- One task per entry whose status is `fail` or `unchecked` is the natural mapping; `rule_id` plus `target.path` is a
  stable key for "this task exists already".
- `title`, `section` and `description` are enough to write the task; `source` is where to read more.
- A `waived` entry and a `waiver` with `expired: true` are worth showing: a waiver that ran out is work again.
