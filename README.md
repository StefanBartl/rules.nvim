> **Alpha — small, working surface.** The engine, the four check types,
> `:Rules check`/`gate`/`show`/`stats`, and waivers are real and tested.
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
- [Bindings](docs/BINDINGS.md) — the `:Rules` command and its subcommands.

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

## Why no bundled rules

Most rule/lint tools that ship an opinionated default get forked or fought
with immediately. `rules.nvim` is the engine only: rule authoring, loading
and checking. Your own rules — however you already write them down — are a
`rulesets` config entry, a local path. Nothing you write against this plugin
is published by installing it, and nothing here is imposed on you by
installing it either.

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
  cmd = { "Rules" },
  opts = {
    rulesets = { "~/path/to/your/checklists" },
  },
}
```

`cmd = { "Rules" }`: the whole surface today is one usercommand (`check`,
`gate`, `show`, `stats`), run on demand — nothing here needs to run at
startup.

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
exit code).

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

## Contributing

Clone the repository and either symlink it or add it to your runtime path.
Run the test suite with `scripts/test.sh` (needs a `lib.nvim` and a
`plenary.nvim` checkout — see that script's own header for how it finds
them).

Pull requests very welcome.

## Feedback

Your feedback is very welcome. Use the
[issue tracker](https://github.com/StefanBartl/rules.nvim/issues) to report
bugs, suggest features or ask usage questions; anything more open-ended fits
a [discussion](https://github.com/StefanBartl/rules.nvim/discussions).

If you find this plugin useful, a ⭐ on GitHub supports its development.

## License

MIT — see [LICENSE](LICENSE).
