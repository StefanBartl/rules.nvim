> **Alpha — small, working surface.** The engine, the four check types,
> `:Rules check`/`gate`/`show`/`stats`/`new`/`set`/`retire`/`reinstate`/`move`/`list`/`waive`/`renew`/`unwaive`, `:RulesVault`, and waivers are real and tested.
> Pin a commit if you depend on this.

# rules.nvim

```
               __                       _
   _______  __/ /__  _____  ____ _   __(_)___ ___
  / ___/ / / / / _ \/ ___/ / __ \ | / / / __ `__ \
 / /  / /_/ / /  __(__  ) / / / / |/ / / / / / / /
/_/   \__,_/_/\___/____(_)_/ /_/|___/_/_/ /_/ /_/
                                              .nvim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-alpha-red)
[![wkd](https://img.shields.io/badge/wkd-family-c6ff3d)](https://stefanbartl.github.io/wkd/p/rules/)

> Part of the [wkd](https://stefanbartl.github.io/wkd/) family — see this plugin's [page](https://stefanbartl.github.io/wkd/p/rules/) on the site.

A rule/checklist engine for Neovim. `rules.nvim` reads a set of rules you
point it at, runs whichever of them can be checked mechanically against a
repo, and reports the rest as a worklist — it never pretends to give an
automatic verdict on a rule that actually needs human or agent judgment.

The plugin ships with **no opinions of its own**: no bundled style guide, no
default rule set. What gets checked is entirely a `rulesets` config path you
provide — the same way you'd point ESLint at your own `.eslintrc`.

---

## Table of contents

- [Documentation](#documentation)
- [What it does](#what-it-does)
- [Why no bundled rules](#why-no-bundled-rules)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quickstart](#quickstart)
- [Ruleset format](#ruleset-format)
- [Contributing](#contributing)
- [Feedback](#feedback)
- [License](#license)

---

## Documentation

- [Ruleset format](docs/RULESET-FORMAT.md) — how a rule and its `check` are written.
- [Bindings](docs/BINDINGS.md) — the `:Rules` command and its subcommands, including the form of `:Rules new`, and `:RulesVault` (find a rule, a family or a ruleset in the vault; make a vault).
- [Settings files and the rules-vault](docs/CONFIG.md) — `.rules.json` in a project and in a vault, which place wins, `vault` / `$RULES_VAULT`, `@vault/<name>`.
- [Work list](docs/WORK-LIST.md) — `rules-work-list/1`, one run as JSON for a task tool: verdicts, rule text, waivers, the manual rules as `unchecked`.
- [Agent-run manual rules](docs/AGENT.md) — planned, not built: how the rules with no `check` could be worked by an agent, as proposals a person reviews.
- [Machine contract](docs/CONTRACT.md) — `rules-export/1` (the ruleset as JSON documents for apps, agents and CI) and `rules-ops/1` (create, change, retire and move a rule through the engine). A TypeScript client imports the types in
  [`schemas/rules-export/1/rules-export.d.ts`](schemas/rules-export/1/rules-export.d.ts), generated from the JSON Schema next to
  them: after a change to the schema run `nvim --headless -u NONE -i NONE -n -l scripts/contract-dts.lua --write` and commit the
  result (CI fails on a stale file; [how](docs/CONTRACT.md#typescript-types)).

`:help rules` is the same command reference inside the editor.

---

## What it does

A **rule** is `{id, severity, check?}`. The `check` is optional on purpose:
some rules are fully mechanical (a deprecated-API grep, a required file, a
forbidden config key) and get an automatic pass/fail; most rules in any real
checklist are judgment calls (architecture, error handling, security review)
and get no automated verdict at all — only a worklist entry naming the rule
and linking to its text, meant for a human or an agent session to work
through.

Rules are grouped into **families** by their ID prefix (`SEC-`, `PERF-`, …).
`:Rules check --family=<PREFIX>` runs one family at a time against a path,
reports into the quickfix list plus a readable buffer, and never claims to
have checked everything at once — checking a whole rule catalog against a
whole repo is a multi-hour task in practice, not a single command.

`:Rules stats` gives a structural overview of what's loaded (per-family
totals, automated vs. manual, severity) without running anything. `:Rules
show <id>` jumps straight to one rule's source. `--family=`, a gate's name,
and a rule id all tab-complete against whatever is actually loaded right
now.

For a ruleset in the one-file-per-rule form the commands also write:
`:Rules new <FAMILY>` makes a rule at the next free id (with less than a title
and `severity=` a Markdown form opens, checked up front, with a dry-run preview
before anything is written), `:Rules set <ID> key=value` changes parts of its
file, `:Rules retire <ID>` moves it to `_retired/` (it asks first, and its message names the `:Rules reinstate` line that puts it back where it stood), `:Rules
reinstate <ID> --after=<ID>` brings a retired rule back (asks first; without a place
it stands in no layout, and the command says so), `:Rules
move <ID> --to=<file>#<section>` moves it in a layout, `:Rules list` puts the
rules in the quickfix list. `:Rules waive <ID> reason=...` (with `expires=`, `paths=`), `:Rules renew <ID> expires=...`
and `:Rules unwaive <ID>` (it asks first) write the `.rules-waivers.json` of the project: the findings
of a rule that were seen and accepted (see [Waivers](docs/BINDINGS.md#waivers) and
[Waiving findings](docs/BINDINGS.md#waiving-findings)). They are a thin layer over the write door of the
[machine contract](docs/CONTRACT.md) (`rules-ops/1`): the engine is the only
writer, the open buffers of a changed file are reloaded (a buffer with unsaved
changes is reported, not overwritten). See
[docs/BINDINGS.md](docs/BINDINGS.md#making-changing-retiring-and-moving-rules).

The keys of the `:Rules new` form (`<Space>`, `<CR>`, `<C-s>`, `q`, `<C-q>`, `g?`) can be changed, by action, in
`setup({ keys = { form = { toggle, accept, submit, close, cancel, help } } })`: a key, a list of keys, or `false` for none.
Mistakes are warned about, never ignored; `keys` is a `setup()` option only. See
[docs/CONFIG.md](docs/CONFIG.md#the-keys-of-the-form).

`:RulesVault open DEP-06` goes to the file of a rule, `:RulesVault open DEP` to the folder of a family, `:RulesVault tree lua`
shows a ruleset family by family, `:RulesVault clipboard DEP-06 --link` copies `[DEP-06](path)` (for a finding that
becomes a task), and `:RulesVault create ~/rules-vault` makes a vault: it lists what happens and the one step that is
yours (`vault = ...` in `setup()` or `$RULES_VAULT`), never overwrites a file and never adds a remote. See
[docs/BINDINGS.md](docs/BINDINGS.md#finding-rules-in-the-vault).

## Why no bundled rules

Most rule/lint tools that ship an opinionated default get forked or fought
with immediately. `rules.nvim` is the engine only: rule authoring, loading
and checking. Your own rules — however you already write them down — are a
`rulesets` config entry, a local path. Nothing you write against this plugin
is published by installing it, and nothing here is imposed on you by
installing it either.

It does not replace the ready-made analyses of
[insights.nvim](https://github.com/StefanBartl/insights.nvim) (git conflicts,
unused imports, code metrics) or
[recommender.nvim](https://github.com/StefanBartl/recommender.nvim) (repeated
dotted chains worth aliasing): a `grep` or `lua_predicate` check can cover
similar ground, but with your own IDs, severities and thresholds, and as a
separate pass over the tree with no shared cache.

## Requirements

| | |
| --- | --- |
| Neovim | **0.10+** |
| [lib.nvim](https://github.com/StefanBartl/lib.nvim) | required — the `:Rules` command itself (`usercmd.composer`) |

## Installation

```lua
-- lazy.nvim
{
  "StefanBartl/rules.nvim",
  dependencies = { "StefanBartl/lib.nvim" },
  cmd = { "Rules", "RulesVault" },
  opts = {
    rulesets = { "~/path/to/your/checklists" },
  },
}
```

`cmd = { "Rules", "RulesVault" }`: the whole surface today is two usercommands, `:Rules` (`check`,
`gate`, `show`, `stats`, `catalog`, `new`, `set`, `retire`, `reinstate`, `move`, `list`, `waive`, `renew`, `unwaive`) and
`:RulesVault` (`open`, `clipboard`, `link`, `find`, `grep`, `tree`, `cdx`, `create`), run on
demand — nothing here needs to run at startup. Without `RulesVault` in `cmd`, lazy.nvim
does not know the command until `:Rules` has loaded the plugin.

## Quickstart

Point `rulesets` at a directory (or a single file) of your own Markdown rule
files, each with a fenced ```rule block per rule (see
[Ruleset format](#ruleset-format)).

Then:

```vim
:Rules check --family=DEP
```

Add `--format=json` for machine-readable output (see
[docs/BINDINGS.md](docs/BINDINGS.md) for the headless/CI recipe with a real
exit code), or `--format=work-list` for the work list `rules-work-list/1`: every rule of the run with its verdict, its
text and its waiver, the manual ones as `unchecked`, for a tool that turns them into tasks
([docs/WORK-LIST.md](docs/WORK-LIST.md)).

A project can carry its own defaults in a `.rules.json` at its root (`rulesets`, `gates`, `agent`), and your
rulesets can live in a vault of their own (`setup({ vault = "~/rules-vault" })` or `$RULES_VAULT`; every folder under
`rulesets/` is then loaded, and a project names one with `"@vault/lua"`). `setup()` wins over the project file, which
wins over the vault's file. A file that cannot be read is an error, never "no settings". A `lua_predicate` runs only in a
ruleset you named yourself (`setup()`, your vault); a ruleset that a project file names is not trusted until its folder is
in `setup({ trust = { ... } })`. See [docs/CONFIG.md](docs/CONFIG.md#a-word-on-trust).

Verify your setup any time with:

```vim
:checkhealth rules
```

## Ruleset format

A rule is a Markdown section with a fenced ```rule code block holding a
small Lua table:

````markdown
### `DEP-06` — `vim.tbl_flatten()` is deprecated

```rule
id = "DEP-06",
severity = "recommended",
check = { type = "grep", pattern = "vim%.tbl_flatten%(" },
```

Throws instead of silently corrupting dict-shaped tables. Wrap in `pcall`
for unchecked or mixed structures.
````

Everything outside the fenced block — headings, prose, other fenced blocks,
even old table-based rule text in the same file — is invisible to the
loader, so a ruleset can migrate one rule at a time. Full field reference,
the four `check` types, and why they're Lua patterns rather than regex:
[docs/RULESET-FORMAT.md](docs/RULESET-FORMAT.md).

**One file per rule.** A rule can also be a file of its own
(`_rules/DEP/DEP-06.md`: frontmatter with `id` and `severity`, then the rule as
it reads), so a tool can change one rule without touching any other. The
documents a person reads are then generated from *layouts*
(`:Rules catalog`, `--check` for CI), and `scripts/ruleset.lua migrate` converts
a ruleset of documents into that form and proves the result byte for byte. Both
forms load side by side; see
[Layouts and catalogs](docs/RULESET-FORMAT.md#layouts-and-catalogs) and
[Migrating a ruleset](docs/RULESET-FORMAT.md#migrating-a-ruleset).

## Contributing

Clone the repository and either symlink it or add it to your runtime path.
Run the test suite with `scripts/test.sh` (needs a
[testing.nvim](https://github.com/StefanBartl/testing.nvim) and a `lib.nvim`
checkout — see that script's own header for how it finds them). Pass
`--file <text>` to run only the spec files whose name contains `<text>`.

Pull requests very welcome.

## Feedback

Your feedback is very welcome. Use the
[issue tracker](https://github.com/StefanBartl/rules.nvim/issues) to report
bugs, suggest features or ask usage questions; anything more open-ended fits
a [discussion](https://github.com/StefanBartl/rules.nvim/discussions).

If you find this plugin useful, a star on GitHub supports its development.

## License

MIT — see [LICENSE](LICENSE).
