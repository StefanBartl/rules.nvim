> **Planning stage — no code yet.** This repository holds the concept and will
> be implemented in a dedicated session. The engine, commands and rule format
> described below are a plan, not a working plugin. Nothing here is stable.

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
![Status](https://img.shields.io/badge/status-planning-lightgrey)

A rule/checklist engine for Neovim. `rules.nvim` reads a set of rules you point
it at, runs whichever of them can be checked mechanically against a repo, and
reports the rest as a worklist — it never pretends to give an automatic verdict
on a rule that actually needs human or agent judgment.

The plugin ships with **no opinions of its own**: no bundled style guide, no
default rule set. What gets checked is entirely a `rulesets` config path you
provide — the same way you'd point ESLint at your own `.eslintrc`.

---

## Table of contents

- [What it does](#what-it-does)
- [Why no bundled rules](#why-no-bundled-rules)
- [Planned shape](#planned-shape)
- [Contributing](#contributing)
- [License](#license)

---

## What it does

A **rule** is `{id, severity, check?}`. The `check` is optional on purpose:
some rules are fully mechanical (a deprecated-API grep, a required file, a
forbidden config key) and get an automatic pass/fail; most rules in any real
checklist are judgment calls (architecture, error handling, security review)
and get no automated verdict at all — only a worklist entry naming the rule and
linking to its text, meant for a human or an agent session to work through.

Rules are grouped into **families** by their ID prefix (`SEC-`, `PERF-`, …) and
into **gates** bound to a moment (new project, review, release). A dry-run
checks one family or one gate at a time against a path, reports into the
quickfix list plus a readable buffer, and never claims to have checked
everything at once — checking a whole rule catalog against a whole repo is a
multi-hour task in practice, not a single command.

## Why no bundled rules

Most rule/lint tools that ship an opinionated default get forked or fought with
immediately. `rules.nvim` is the engine only: rule authoring, loading and
checking. Your own rules — however you already write them down — are a
`rulesets` config entry, a local path. Nothing you write against this plugin
is published by installing it, and nothing here is imposed on you by
installing it either.

## Planned shape

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

```
:Rules new-project                     -- walk the "new project" gate
:Rules review [--diff=<git-ref>]       -- walk the "review" gate, diff-scoped by default
:Rules release                         -- walk the "release" gate
:Rules check --family=<PREFIX> [path]  -- sweep one rule family across a tree
```

Rules are authored as plain Markdown with a small fenced `rule` block per
entry, so a rule stays a normal, readable document and a machine-checkable
fact at the same time:

````markdown
### `DEP-01` — `vim.loop` without a fallback

```rule
id = "DEP-01"
severity = "recommended"
check = { type = "grep", pattern = "vim%.loop%.", unless = "vim%.uv or vim%.loop" }
```

Since Neovim 0.10 the uv API is `vim.uv`. Repos with a floor below 0.10 need
the `vim.uv or vim.loop` fallback; below that floor the rule does not apply.
````

None of this is implemented yet — see [docs/ROADMAP.md](docs/ROADMAP.md).

## Contributing

Nothing to build against yet. Once the initial engine lands, this section will
describe how to run the plugin locally and where the test suite lives.

## License

MIT — see [LICENSE](LICENSE).
