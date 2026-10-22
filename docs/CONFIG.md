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
- `trust` comes from `setup()` and a call only (`--trust`, `$RULES_TRUST`): a file must not grant itself trust, see
  [A word on trust](#a-word-on-trust).
- `keys` comes from `setup()` only: the keys of your editor are yours, not a repository's or a vault's. In a file it is an
  unknown key with that hint. See [The keys of the form](#the-keys-of-the-form).

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

The `agent` block is read, checked and merged here; `rules.engine.agent.plan` consumes `scopes`, `batch_size`,
`max_context_bytes` and `deny` (see [AGENT.md](AGENT.md)); `backends` and `models` are for the commands that send a request.
`setup()` takes the same keys (`rulesets`, `gates`, `agent`, `vault`) plus `lua_predicates`, `trust` and `keys`.

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

In a file `[]` and `{}` are two different things, and a value of the wrong one is a shape error, not "valid and empty":
a top-level `[]`, `"rulesets": {}`, `"gates": []` and `"agent": []` are refused. (`setup()` is Lua, where `{}` is both,
and takes either.) A bad field of `agent` in `setup()` drops only that field, with a warning that names it: a `deny` list
survives a `batch_size` that is not a number.

### Unknown keys warn

A key the schema does not know is ignored with a warning and the nearest known key as a hint (the ERR-50 pattern of
`setup()`): `unknown key(s) ignored: ruleset (did you mean rulesets?)`. A key that is known elsewhere but not in this
place says why (`lua_predicates`, `trust` and `keys` are `setup()` options only; `vault` does not belong in a vault's
own file). Each warning is shown once per session.

### The keys of the form

The buffer-local keys of the `:Rules new` form (see [BINDINGS.md](BINDINGS.md#the-form)) are a `setup()` option:

```lua
require("rules").setup({
  keys = {
    form = {
      toggle = "<Space>",        -- tick or untick the severity under the cursor (the default)
      accept = { "<CR>", "t" },  -- a list binds every key of it
      submit = "<C-g>",
      close = "q",
      cancel = false,            -- false: this action has no key
      help = "g?",
    },
  },
})
```

| Action | Default | Does |
| --- | --- | --- |
| `toggle` | `<Space>` | tick or untick the severity under the cursor; anywhere else the key does what it always does |
| `accept` | `<CR>` | the same for a second key |
| `submit` | `<C-s>` (normal and insert mode) | check the form, dry run, ask, write |
| `close` | `q` | cancel; asks first when something was typed |
| `cancel` | `<C-q>` (normal and insert mode) | the same for a second key, also in insert mode |
| `help` | `g?` | list the keys in force |

An action that is not named keeps its default; a key is a string, a list of strings (every one is bound) or `false`. The
form's own hint line and its `g?` list show the keys that are really bound. The usual loud failures of `setup()` apply
(ERR-22, ERR-50): an action this plugin does not have (`keys.form.sumbit (did you mean submit?)`) or a group it does not have
(`keys.menu`) is an unknown option, a value of the wrong type (a number, an empty string or list, a list with a non-string)
is dropped with its dotted key (`keys.form.submit must be a key ...`), and the default stays. Two actions on one key
(`submit = "<Space>"` next to the default `toggle`, in any spelling: `<C-s>` and `<C-S>` are one key) are named at `setup()`
(`keys.form: toggle, submit share the key <Space>`); the keys stay as set and the action the form binds last works (the order
of the table).

### No machine path in a repository

A project file travels between machines, so a path of this machine in it is a mistake. A `rulesets` or `vault` entry
that is absolute, starts with `~`, or starts with an environment variable **warns** (it is still used). Write a path
relative to the file, or `@vault/<name>`.

An entry of `rulesets` that resolves outside the project folder (`../shared`) warns too, and so does a `vault` key in a
project file. The warning names the key and carries no path of this machine in a document. The entry stays usable, but its
rulesets are **not trusted**: see [A word on trust](#a-word-on-trust).

## `.rules-waivers.json`

The other file of a project: the findings it has consciously accepted. It lives in the **checked project** (the root a
`:Rules check` or `gate` is run on), never in a ruleset or the vault: the rulesets say what is wrong, the project says
what it has accepted. How a waived rule shows up in a report is in [BINDINGS.md](BINDINGS.md#waivers); changing the file
through the machine contract (`waive`, `renew`, `remove`) is in [CONTRACT.md](CONTRACT.md#waivers), and in the editor with
`:Rules waive`, `:Rules renew` and `:Rules unwaive` ([BINDINGS.md](BINDINGS.md#waiving-findings): which project they write,
how `paths=` is typed).

A file is one JSON object. Its keys are rule ids, its values one of two forms that may be mixed in one file:

```json
{
  "DEP-01": "every finding is a fixture string of the tests",
  "DEP-04": {
    "reason": "legacy call sites, ticket JIRA-123 tracks the fix",
    "expires": "2026-12-31",
    "paths": ["src/legacy", "docs/**/*.md"]
  }
}
```

| Form | Meaning |
| --- | --- |
| `"reason"` (a text) | no expiry, every path. The only form older versions knew; it stays valid and keeps this meaning. |
| `{ "reason", "expires"?, "paths"? }` | the same, with the two limits below. Any other key is an error. |

- **`reason`** is required in the object form and must say something. One line, no control character, at most 500
  characters (it is rendered as one line of the report).
- **`expires`** is a calendar date, `YYYY-MM-DD`: a real day (`2028-02-29` yes, `2027-02-29` no), no time and no time
  zone. The waiver is valid **through** that day; the day after it is **expired**: the finding flags again, with a line
  that says `waiver expired on <date>` and the reason. "Today" is the date of the machine that runs the check (local
  calendar date); `opts.today` of `rules.api` and `rules.ops`, and `--today=` of `scripts/ruleset.lua check`, give a
  fixed day (a reproducible run, a spec). The clock is one function, `rules.engine.waivers.clock`.
- **`paths`** limit the waiver to findings in those places: a non-empty list (at most 50) of files, folders or globs,
  relative to the project root, written with `/`, no `..`, no absolute path, no `~`. A plain name is that file or
  the folder with that name (and everything under it, `src/legacy` or `src/legacy/`); a glob (`*` inside one folder,
  `**` across folders, `?`, `[ab]`, `{a,b}`; `vim.glob`) must match the whole path, or a folder above the file.
  A name that has glob characters is also taken as the name it is: `pages/[id].tsx` (a dynamic route) waives the
  file of that name, and still matches `pages/i.tsx` and `pages/d.tsx` as the glob it looks like. (A name that is no
  valid glob at all, like `a/{x}.ts`, is refused when the file is read: the engine does not guess.)
  Matched as written (case counts). A finding that is no file at all (a check that errored names the project, not a
  file) is never inside `paths`. A rule with findings both inside and outside stays failing with the ones outside,
  and the report says how many were waived.
- At most 500 waivers in a file. A waiver whose rule id no ruleset has is not an error (the rule may live in a ruleset
  that is not loaded right now): it protects nothing, and `:checkhealth rules` and `scripts/ruleset.lua check --waivers`
  say so.

### A file that cannot be used is an error

Like `.rules.json`: a waivers file that exists and cannot be used (not JSON, a list instead of an object, an unknown
key, a date that is none, a path with `..`, an empty file, a folder in its place) is an error of the run. `:Rules
check`, `:Rules gate` and their headless counterparts (`check_family_json`, `run_gate_json`) stop and say why; the
findings it was meant to hold never come back silently as "no waivers" with a warning on the side. A project without
the file has no waivers, which is not an error.

The file is read the same way everywhere (the engine, the `waivers` document, `check --waivers`, the write door): a
UTF-8 byte order mark at the start (Notepad, Windows PowerShell 5.1 `Set-Content -Encoding UTF8`) is no part of the
JSON, and a file that is a link is read through the link. Only a **write** refuses a link (`forbidden`): it would
replace the link, so edit the file it points to by hand. A write leaves the file canonical, without the mark.

### CI

```bash
nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua check --waivers --project=. <ruleset-folder>
```

exits 1 when the waivers file cannot be used or a waiver in it has **expired**, and prints each one with its date and
reason; a waiver for a rule that is not loaded is a note. `--today=YYYY-MM-DD` judges the expiry as of that day.
`--waivers` needs `--project=<dir>` (or `$RULES_PROJECT`), exit code 2 without.

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
folder`), and so is a vault whose own `.rules.json` cannot be used (not JSON, wrong shape, an entry such as
`@vault/../x`): `vault.root()`, `vault.rulesets()` and `vault.source()` report it, and `:RulesVault` and
`:checkhealth rules` say it. A broken vault file is never read as "no vault file" (that would offer every folder under
`rulesets/`, `draft` included, that the file meant to leave out).

It is an error **where the result depends on the vault**. A call that names its ruleset folder itself
(`rules.lua call ... --ruleset=<folder>`, `ruleset.lua catalog <folder>`, `check <folder>`, `migrate <folder>`) does not
break over a stale `$RULES_VAULT` (a warning says the vault was not usable and not needed). `@vault/<name>`, a call
without rulesets (the vault would give them) and `:RulesVault` still fail loudly.

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
local where, problem = vault.source()   -- "call" | "setup" | "env" | "project" | nil; the problem of the vault, if any
local folders, problem = vault.rulesets() -- { ".../rulesets/lua", ".../rulesets/native" }; {} + the problem if it is broken
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

A ruleset made in a vault that has rulesets already must not hide them. The `.rules.json` that lists only the new ruleset
would, because a list replaces the discovery of the folders under `rulesets/`. So the file is made only when the new
ruleset is the only one; with other rulesets there, none is made (every folder is found without it, the new one too), and
the plan and the result say so. A `.rules.json` that is there is never touched: when it does not list the new ruleset, the
plan and the result say so and name the entry to add (`"rulesets/<name>"`); until it is added, `:RulesVault` and
`check --vault` do not see the new ruleset.

Nothing is written before the whole layout is checked, and a refusal names the folder or file in the way: a file where a
folder is needed (also above the vault folder), a name of more than 255 bytes, a path over the limit of the system (259
bytes on Windows, where Neovim cannot open longer ones even when long paths are on), and a link (symlink or junction) on
the way that leads out of the vault folder or nowhere. A link that stays inside the folder is followed. The check is made
again just before the first file is written.

### The CI of a vault

`.github/workflows/ci.yml` of a new vault is `templates/rules-vault-ci.yml` of this plugin. It only reads (no push, no
commit) and runs on Ubuntu and Windows, with `rules.nvim` and `lib.nvim` checked out below `.deps/`. Four steps, each of
which turns the run red:

| Step | Command | Red when |
| --- | --- | --- |
| line endings | `find rulesets -name '*.md'` read through `tr`, counting CR | a `.md` file below `rulesets/` of the **checkout** has a CR. It looks at the files, not at the text of `.gitattributes` (a comment, or an `eol=lf` for other files, would pass a text search and leave CRLF here). `:RulesVault create` makes `* text=auto eol=lf`, which keeps a Windows checkout LF |
| reading documents | `scripts/ruleset.lua catalog --check rulesets/<name>`, **every folder** below `rulesets/` | a generated document is not what the layouts and rule files make, or that ruleset **on its own** does not load without errors (every load error listed under *loading*, except a clash with another ruleset) |
| loading | `scripts/ruleset.lua check --vault=.` | the rulesets the **vault offers**, all together, have a load error (see the list below) |
| round trip | `scripts/roundtrip.lua rulesets/*/`, **every folder** below `rulesets/` | writing a rule file does not give its bytes back, or a folder does not load without errors (each one alone) |

The **load errors** that turn *loading* red (and, for one ruleset alone, *reading documents* and *round trip*):

- a **duplicate rule id**: two rule files with one id, also in two rulesets (which no ruleset shows alone, so only *loading*
  sees it), and **a live rule and a retired one** (`_retired/<FAMILY>/<ID>.md`) with one id, in one ruleset or in two:
  `duplicate rule id AAA-05: <ruleset>/_rules/AAA/AAA-05.md:7 and <ruleset>/_retired/AAA/AAA-05.md (retired)`. A retired
  rule is never loaded, but its id is taken, for the check and for the next id of `new` alike (`next_id` counts the file
  name and the `id` of the frontmatter of every retired file);
- an invalid `severity`, a key a rule file does not know, a rule file that does not read;
- **a file under `_rules/` that yields no rule**: empty, without a frontmatter, a frontmatter without `id`, or with
  merge-conflict markers (`<<<<<<<`, `=======` or `>>>>>>>` at the start of a line, outside a code fence), which is also
  told for a file that still yields a rule. Only `*.md` files there are rule files; `.gitkeep` and any other type, a
  `README.md` (any case), a layout and a generated document are no fault. Outside `_rules/` a Markdown file without a
  rule is an ordinary document (notes, a README) and a document with ` ```rule ` blocks loads as it always did;
- a **retired file that does not read** (no frontmatter, empty, conflict markers, named for one id and saying another).

**A gap in the numbering is no load error.** `DEP-01` and `DEP-03` with no `DEP-02` appears when a rule is deleted instead of
retired, and a ruleset may leave numbers out on purpose (blocks of ten per topic). So the template's *loading* step does not
mention it, and `check` says nothing about it unless asked:

- `check --gaps` lists, as notes, the numbers every family skips between its smallest and largest id and exits 0:
  `  note: DEP: DEP-02, DEP-05..DEP-07 not taken between DEP-01 and DEP-08`, then `4 number(s) not taken in 1 family(ies)`;
- `check --strict-gaps` lists them as `gap:` lines and exits 1 (`FAILED: 1 family(ies) skip numbers (--strict-gaps)`) when
  there is one. Put it into your own *loading* step if your vault numbers without holes; a load error is reported first and
  wins. All rulesets that are checked together count as one set, so name a folder to leave the others out.

A retired rule keeps its number taken: `retire` instead of deleting the file leaves no gap. On the real rulesets this plugin
was measured against (623 rules in three rulesets) 9 of 23 families have gaps, 172 numbers in all, almost all of them whole
blocks; that is why the flag is opt-in. The details are in
[RULESET-FORMAT.md](RULESET-FORMAT.md#gaps-in-the-numbering). The hint is not part of any document of `rules-export/1`.

`ruleset.lua check [--gaps|--strict-gaps] [--vault=D] [--project=D] [--trust=D] [<folder>]` loads through the snapshot document of `rules-export/1`
and exits 1 on any `load_errors` or on a configured ruleset that is not a folder (the entry and where it was named are in
the message, `ruleset rulesets/gone (the .rules.json of the vault) is not a folder`), 2 on wrong usage or when there is
nothing to check. With `--vault=D` and no folder it checks **every ruleset the vault offers** (its own list, else every
folder under `rulesets/`) whatever a project file or `setup()` names, and warns about the folders under `rulesets/` that
the vault file leaves out: those are **not** part of *loading*; the globs of *reading documents* and *round trip*
cover each of them on its own (so a clash between an unlisted ruleset and another one is not seen). `catalog` and `:Rules
catalog` without a folder treat a configured ruleset that is gone, or is a file, the same way: an error, not a quiet
skip. No `jq`, no other tool than Neovim and bash. The workflow runs the same commands you can run in the vault folder,
with the path of your `rules.nvim` in place of `.deps/rules.nvim`. A freshly made vault (`:RulesVault create`: an empty
ruleset with `.gitkeep` files) is green in all four steps, which a spec holds.

A **private `rules.nvim`** (a fork) cannot be checked out with the token of the vault repository: give the `actions/checkout`
step of `rules.nvim` a `token:` of your own (a personal access token with read access to that repository).

To try the template against your real rulesets (copied, never changed), name their two folders and run the spec that
runs the template's own steps; it arranges the copies as a vault (`rulesets/lua`, `rulesets/native`), expects all green,
then repeats the run with one id made a second time and expects red:

```bash
RULES_REAL_LUA=<folder of the first ruleset> RULES_REAL_NATIVE=<folder of the second ruleset> \
  scripts/test.sh --file vault_ci
```

### Pull before you make a rule

Ids are given under a lock **per machine**. Two machines that each make a rule in one family without a pull in between
make **the same id**. The rule for working with a vault on more than one machine: **pull before you create** (`git pull`
in the vault folder). Three things back it up, none of them replaces it:

- **A warning before the clash.** `:Rules new` and the `new` operation of `rules-ops/1` look, read only and without the
  network, whether the vault is a git repository that lies behind its upstream (`git rev-list --count HEAD..@{u}`, a
  3 second limit; silent when there is no git, no upstream or no vault, and for a ruleset that is not in the vault). If it
  does, the entry of the result carries `warnings` (see [CONTRACT.md](CONTRACT.md#rules-ops1-write)), `:Rules new` shows
  them as a warning after the line that says what was made, and the question of the form shows them before you confirm.
  It is a **warning, not a refusal**: the rule is made. It knows what your last `git fetch` brought home, nothing more;
  the engine never fetches.
- **The engine never pulls, commits or pushes.** That stays with you (or the session), as with `tasks-vault`.
- **A duplicate id fails the check.** It is a load error (`duplicate rule id DEP-07: ...`, both files named), so the CI of
  the vault (above) and `scripts/ruleset.lua check` exit 1 on it, and the editor shows it as a warning when it loads.
  When both machines made the id in the same ruleset, git itself stops the merge with an add/add conflict on the file
  `DEP-07.md`; the check is what catches the cases git lets through: the same id in two rulesets, under two file names,
  or **one machine retired the rule and the other made the id again** (a live `_rules/AAA/AAA-05.md` next to a
  `_retired/AAA/AAA-05.md`: git merges that without a conflict; the check names both files). Renumber or retire one of the
  two, then merge.

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
nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua check --waivers --project=. @vault/lua   # also: no expired waiver in ./.rules-waivers.json
```

| | |
| --- | --- |
| `$RULES_VAULT` | the vault |
| `$RULES_PROJECT` / `--project=<dir>` | the root whose `.rules.json` is read; without it the headless tools read no project file |
| `--vault=<dir>` | the vault (a call, above `setup()` and the environment) |
| `--ruleset=@vault/<name>` | a ruleset of the vault |
| `--trust=<dir>` (repeatable) / `$RULES_TRUST` | folders whose rulesets are trusted, see below; the scripts never run a check themselves |

## A word on trust

A project file chooses which rulesets are loaded, and a ruleset may hold `lua_predicate` checks, which are arbitrary
Lua. A `.rules.json` in a repository you did not write could point at a ruleset in your own repository (or at a vault
of its own) and make `:Rules check` run its Lua in your Neovim. So a `lua_predicate` runs **only in a ruleset that you
named yourself**:

| Trusted | Not trusted |
| --- | --- |
| a ruleset named in `setup({ rulesets })` | **every** ruleset a project `.rules.json` names: a relative path, `../shared`, an absolute path and `@vault/<name>` alike |
| a ruleset of your vault, when the vault comes from `setup({ vault })` or `$RULES_VAULT` (or `--vault=D` of a tool) | the rulesets of a vault that a project `.rules.json` names with its `vault` key |
| a ruleset of a call: `--ruleset=<path>`, `$RULES_RULESETS`, the `rulesets` option of `rules.api` (you typed it) | |
| whatever lies under a folder in `trust` | |

What happens to a rule whose predicate may not run: it is reported as an **error** with the finding `not run: ruleset is
not trusted (...)` (no path of this machine in it), never as `pass`, and it counts for the exit code like any failed
critical rule. The other check types (`grep`, `file_exists`, `json_key_absent`) of that ruleset run as usual.
`:checkhealth rules` lists the rulesets that are not trusted and who named them.

To grant trust, name the folder (a ruleset folder, one above it, or a single file). It is compared by real path: a link is
followed, `/var` and `/private/var` are one folder, and a file that is reached through a link out of a trusted folder is
not trusted.

```lua
require("rules").setup({ trust = { "~/work/shared-rules", "~/work/app/docs/rules" } })
```

```bash
nvim --headless -u NONE -i NONE -n -l scripts/rules.lua call snapshot --project=. --trust=docs/rules
RULES_TRUST=~/work/shared-rules nvim --headless ...   # a list of paths, `;` or `:` separated
```

`trust` exists in `setup()` and as the call options `--trust` / `$RULES_TRUST` only. In a project or vault file it is an
unknown key (with the hint that it is a `setup()` option only): a file must not grant itself trust. A headless run has
no prompt and no memory: without `--trust` or `$RULES_TRUST` the rulesets a project file names stay untrusted.

`lua_predicates = false` in `setup()` still switches every predicate off, trusted or not (the error then says
`lua_predicates is off`). `rules.nvim` itself runs checks only in the editor (`:Rules check`, `:Rules gate`); the
scripts resolve the same settings and accept the same flags, so a tool that runs checks on top of them agrees with the
editor.
