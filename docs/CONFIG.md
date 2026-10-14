# Settings files and the rules-vault

Where `rulesets`, `gates` and the `agent` block come from, in what order, and how a rules-vault is found. The
command reference is [BINDINGS.md](BINDINGS.md); the machine documents are [CONTRACT.md](CONTRACT.md).

## The places, and who wins

`setup()` is one place among several. A project can carry its own defaults in a `.rules.json`, and a vault can carry
the defaults of a person. They combine in one fixed order, highest first (`rules.settings.RANK`, the only place that
decides it):

| Rank | Place | Where |
| --- | --- | --- |
| 1 | call | the options of a headless entry point: `--ruleset`, `--gate`, `$RULES_RULESETS`, `$RULES_GATES`, the `opts` of `rules.api` |
| 2 | `setup()` | `require("rules").setup({ ... })` |
| 3 | project file | `<project>/.rules.json`, in the root being checked |
| 4 | vault file | `<vault>/.rules.json` |
| 5 | defaults | `rules.config.DEFAULTS` |

How two places combine:

- `rulesets` is taken **whole** from the highest place that names it. A list is replaced, never concatenated, so a
  project can take an entry away. An empty list counts as naming them: `"rulesets": []` means "none".
- `gates` is merged **by gate name**: a higher place replaces the gates it names and leaves the others.
- `agent` is merged **field by field**; `agent.scopes` by family. The lists inside it (`backends`, `models`, `deny`,
  `include`) are replaced as a whole.
- `lua_predicates` comes from `setup()` only: a file in a repository must not decide what code may run.

## `.rules.json`

The same schema in a project and in a vault. Paths are relative to the file that holds them.

```json
{
  "rulesets": ["docs/rules", "@vault/lua"],
  "gates": { "release": ["REL"], "review": ["ERR", "LUA", "SEC"] },
  "agent": {
    "backends": ["ollama"],
    "models": ["qwen2.5-coder"],
    "batch_size": 8,
    "max_context_bytes": 60000,
    "deny": [".env*", "*.pem"],
    "scopes": { "LUA": { "include": ["lua/**/*.lua"] } }
  },
  "vault": "../rules-vault"
}
```

| Key | Type | Meaning |
| --- | --- | --- |
| `rulesets` | list of strings | ruleset files or folders; `@vault/<name>` is `<vault>/rulesets/<name>` |
| `gates` | object | gate name to list of family prefixes (`:Rules gate`) |
| `agent.backends` | list of strings | allow-list of backends; empty means local only |
| `agent.models` | list of strings | the models the run dialog offers |
| `agent.batch_size` | whole number >= 1 | rules per request (default 8) |
| `agent.max_context_bytes` | whole number >= 1 | the most file content one request carries (default 60000) |
| `agent.deny` | list of strings | globs of paths that never go into a request |
| `agent.scopes` | object | family to `{ "include": [globs] }`; a family without a scope is not sent |
| `vault` | string | the vault of this project (a project file only; see below) |

The `agent` block is read, checked and merged here; the planner that uses it is described in [AGENT.md](AGENT.md).
`setup()` takes the same keys (`rulesets`, `gates`, `agent`, `vault`) plus `lua_predicates`.

Only the file at the root being checked is read (`:Rules check` uses its `path` argument, else the working directory).
There is no search upwards.

### A file that cannot be used is an error

The rule of the plugin: input that cannot be fully trusted is never turned into "no settings" (see
`NOTES/DESIGN-DECISIONS.md` in the author's notes). A `.rules.json` that is there but unreadable, not JSON, not an
object, larger than 1 MiB or has a value of the wrong shape is refused **as a whole**, with a message that names the
file and the key:

```
/work/app/.rules.json: agent.batch_size must be a whole number of 1 or more, got a string
```

`:Rules check` and `:Rules gate` stop with that message instead of running with other settings; `:checkhealth rules`
shows it; the contract answers an `invalid_argument` document. A **missing** file is not an error.

### Unknown keys warn

A key the schema does not know is ignored with a warning and the nearest known key as a hint (the ERR-50 pattern of
`setup()`): `unknown key(s) ignored: ruleset (did you mean rulesets?)`. A key that is known elsewhere but not in this
place says why (`lua_predicates` is a `setup()` option only; `vault` does not belong in a vault's own file). Each
warning is shown once per session.

### No machine path in a repository

A project file travels between machines, so a path of this machine in it is a mistake. A `rulesets` or `vault` entry
that is absolute, starts with `~`, or starts with an environment variable **warns** (it is still used). Write a path
relative to the file, or `@vault/<name>`.

## The rules-vault

A vault is a folder (a repository of its own) that holds the rulesets of a person, one folder each:

```
rules-vault/
  .rules.json            optional: rulesets, gates, agent (same schema)
  rulesets/
    lua/                 a ruleset: the name in `source` is `lua`
    native/
```

### Finding it

The first of these that names a vault wins. **Nothing is guessed**: without any of them there is no vault, which is a
normal state (the vault is optional), not an error.

1. the `vault` option of a call (`--vault=<dir>` of the scripts)
2. `setup({ vault = "<dir>" })`
3. `$RULES_VAULT`
4. `vault` in the `.rules.json` of the project (to choose a different vault for one project)

A vault that is named but is not a folder is an error that says where it was named (`$RULES_VAULT: the vault is not a
folder`).

### What a vault gives

- **Every folder under `<vault>/rulesets/` is a ruleset**, sorted by name (hidden folders such as `.git` are skipped).
  This is the default for `rulesets` when nothing higher names them.
- The vault's own `.rules.json` may **narrow or extend** that: its `rulesets` list replaces the discovery, and may name
  other folders relative to the file.
- Entries of `rulesets` in `setup()` or a project file may **name the vault**: `"@vault/lua"` is
  `<vault>/rulesets/lua`. A name cannot leave `rulesets/` (`..`, separators, a drive are refused). Without a vault
  that is an error that says how to get one. This is how a project picks its rulesets without a machine path in a
  file that lives in its repository.
- `gates` and `agent` of the vault file are the lowest places: a project or `setup()` overrides them by name.

`source` in the documents of `rules-export/1` stays the ruleset's folder name (`lua`, `native`), never a path of this
machine. A vault with two rulesets yields the same documents as passing both folders explicitly.

### Lua API

```lua
local vault = require("rules.vault")
local root, message = vault.root()      -- "/home/me/rules-vault"; nil + "no vault is configured: ..." without one
local where = vault.source()            -- "call" | "setup" | "env" | "project" | nil
local folders = vault.rulesets()        -- { ".../rulesets/lua", ".../rulesets/native" }
local state = vault.git_state(root)     -- { repo, clean, changes, inside?, error? } | nil without git
```

`opts.project` (default: the working directory) is the root whose `.rules.json` may name the vault. The
`:RulesVault` command ([BINDINGS.md](BINDINGS.md#finding-rules-in-the-vault)) takes its `roots` from here:
`vault.rulesets()` are its rulesets, `vault.root()` and its message say what it reports when there is no vault.
`vault.is_none(message)` tells "nothing names a vault" (a normal state) from a vault that is named but unusable.

### Making a vault

`:RulesVault create <dir> [<name>] [--git] [--yes]` makes the folder, `README.md`, a `.rules.json` with
`{"rulesets": ["rulesets/<name>"], "gates": {}}`, `.gitattributes`, `.gitignore`, `.github/workflows/ci.yml` and the first
ruleset, and only what is missing: a file that is there is never touched. It lists first what happens, and the one step it
cannot do for you: setting `vault = "<dir>"` in `setup()` or `$RULES_VAULT`, which is how the vault is found (see
"Finding it"). It never adds a remote or reaches GitHub; `git init` happens only with `--git`.

### The CI of a vault

`.github/workflows/ci.yml` of a new vault is `templates/rules-vault-ci.yml` of this plugin. It only reads (no push, no
commit) and runs on Ubuntu and Windows, with `rules.nvim` and `lib.nvim` checked out below `.deps/`. Four steps, each of
which turns the run red:

| Step | Command | Red when |
| --- | --- | --- |
| line endings | `grep -q 'eol=lf' .gitattributes` | the vault has no `.gitattributes` with `eol=lf` (the byte-for-byte checks need one line ending; a Windows checkout would otherwise be CRLF) |
| reading documents | `scripts/ruleset.lua catalog --check rulesets/<name>`, each ruleset | a generated document is not what the layouts and rule files make |
| loading | `scripts/ruleset.lua check --vault=.` | **all rulesets together** have a load error: a **duplicate rule id** (also one id in two rulesets, which no single ruleset shows), an invalid `severity`, a rule file that does not read |
| round trip | `scripts/roundtrip.lua rulesets/*/` | writing a rule file does not give its bytes back |

`ruleset.lua check [--vault=D] [--project=D] [<folder>]` loads through the snapshot document of `rules-export/1` and
exits 1 on any `load_errors`, 2 on wrong usage or when there is nothing to check. No `jq`, no other tool than Neovim and
bash. The workflow runs the same commands you can run in the vault folder, with the path of your `rules.nvim` in place
of `.deps/rules.nvim`.

A **private `rules.nvim`** (a fork) cannot be checked out with the token of the vault repository: give the `actions/checkout`
step of `rules.nvim` a `token:` of your own (a personal access token with read access to that repository).

To try the template against your real rulesets (copied, never changed), name their two folders and run the spec that
runs the template's own steps; it arranges the copies as a vault (`rulesets/lua`, `rulesets/native`), expects all green,
then repeats the run with one id made a second time and expects red:

```bash
RULES_REAL_LUA=~/WKDBooks/Development/wkdbook-Lua/Checklists RULES_REAL_NATIVE=~/WKDBooks/Development/wkdbook-native/Checklists \
  scripts/test.sh --file vault_ci
```

### `:checkhealth rules`

Shows whether a project file and a vault file were loaded (and from where), every problem and warning, the vault, where
its value came from, the rulesets it offers, which place `rulesets`, `gates` and the `agent` settings came from, and
whether the vault is a git repository and clean. The git check is read-only (`git rev-parse`, `git status
--porcelain --no-optional-locks`, no network, a 5 second timeout) and says nothing when git is not installed.

## Headless tools

`scripts/rules.lua`, the persistent host and `scripts/ruleset.lua` resolve the vault the same way, so `$RULES_VAULT`
works without Neovim being configured:

```bash
RULES_VAULT=~/rules-vault nvim --headless -u NONE -i NONE -n -l scripts/rules.lua call snapshot
nvim --headless -u NONE -i NONE -n -l scripts/rules.lua list --format=json --vault=~/rules-vault --project=. --family=DEP
nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua catalog --check @vault/lua   # or no folder: every ruleset
nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua check --vault=~/rules-vault   # all rulesets load, no duplicate id
```

| | |
| --- | --- |
| `$RULES_VAULT` | the vault |
| `$RULES_PROJECT` / `--project=<dir>` | the root whose `.rules.json` is read; without it the headless tools read no project file |
| `--vault=<dir>` | the vault (a call, above `setup()` and the environment) |
| `--ruleset=@vault/<name>` | a ruleset of the vault |

## A word on trust

A project file chooses which rulesets are loaded, and a ruleset may hold `lua_predicate` checks, which are arbitrary
Lua. `lua_predicates` stays a `setup()` option on purpose, so a repository cannot switch it on, but with the default
(`true`) a `.rules.json` that points at a ruleset inside a repository you do not trust makes `:Rules check` run its
predicates. Set `lua_predicates = false` where you check code you did not write.
