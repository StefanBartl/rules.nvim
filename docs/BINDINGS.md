# Bindings

## Commands

| Command | Args | Flags | Does |
| --- | --- | --- | --- |
| `:Rules check` | `[path]` (defaults to cwd) | `--family=<PREFIX>` (required), `--format=json` (optional) | Runs every rule in the family against `path`. Default: reports into the quickfix list and a readable buffer. `--format=json` prints the results as JSON instead (`:messages`/stdout) and does not touch quickfix/buffer or quit Neovim — see below for headless/CI use |
| `:Rules gate` | `<name>` (required), `[path]` (defaults to cwd) | `--diff=<git-ref>` (optional), `--format=json` (optional) | Runs every family configured for gate `name` (`setup({ gates = {...} })`) as one combined report. `--diff=<git-ref>` narrows findings to files changed since that ref (`git diff --name-only` + untracked files) — a rule with no findings inside the diff reports as `pass` even if the repo has standing issues elsewhere. `--format=json` behaves like `:Rules check`'s. A configured family matching zero loaded rules (typo, or not migrated yet) warns instead of silently shrinking the gate |
| `:Rules show` | `<id>` (required) | — | Jumps to one rule's source location by its exact id, without running a family check. Errors if no loaded rule has that id |
| `:Rules stats` | — | `--format=json` (optional) | Structural overview of every loaded rule: per-family totals, automated-vs-manual split, severity breakdown. No check runs — pure catalog metadata |
| `:Rules catalog` | `[path]` (default: every folder in the settings' `rulesets`, or of the vault; `@vault/<name>` names one) | `--check` (optional) | For a ruleset in the one-file-per-rule form: builds the reading documents from their layouts ([RULESET-FORMAT.md](RULESET-FORMAT.md#layouts-and-catalogs)). A document is written only when its content changed. `--check` writes nothing and warns about every document that is out of date — for CI use `scripts/ruleset.lua catalog --check <folder>` (exit code 1 when one is). Names the rules that are in no layout |
| `:Rules messages` | — | — | Opens this plugin's notify history (toast + `:messages` log, via `lib.nvim.notify.popup`) |
| `:Rules new` | `[<FAMILY> [title...]]` | `severity=`, `text=`, `ruleset=`, `--to=`, `--after=`, `--before=`, `--first`, `--yes`, `--dry` | Makes a rule at the next free id of the family (1 to 12 uppercase letters `A-Z`, or a family the ruleset has, spelled as there). With the family, a title and `severity=` the rule is made and opened (a family no rule has yet is asked about first, `--yes` skips the question); with less, the [form](#the-form) opens, filled in with what was given. See [Making, changing, retiring and moving rules](#making-changing-retiring-and-moving-rules) |
| `:Rules set` | `<id>` | `severity=`, `title=`, `text=`, `check=`, `agent=`, `--dry` | Changes parts of a rule's file; every line it was not asked to change stays byte for byte (see [what `set` leaves alone](#making-changing-retiring-and-moving-rules)) |
| `:Rules retire` | `<id>` | `--by=<id>`, `reason=`, `--yes`, `--dry` | Moves a rule's file to `_retired/` and out of every layout; the id stays taken. Asks first |
| `:Rules reinstate` | `<id>` (a retired one) | `--after=<id>`, `--before=<id>`, `--section=<heading>`, `--first`, `--layout=<file>`, `--yes`, `--dry` | Brings a retired rule back: its file returns from `_retired/` and the id is in use again. A place puts it into a layout; without one it stands in no layout (where it stood is not recorded) and the command says so. Asks first |
| `:Rules move` | `<id>` | `--to=<file>#<section>`, `--after=<id>`, `--before=<id>`, `--first`, `--dry` | Moves the rule's `{{rule ID}}` line within its layout or into another; the rule's own file is not touched |
| `:Rules list` | — | `--family=<PREFIX>`, `--severity=<level>`, `--format=json` | Puts the rules in the quickfix list, each at its source line; `--format=json` prints the `rules.list` document of the [machine contract](CONTRACT.md) |
| `:RulesVault` | — | — | Shows the vault in use (where it was named, its rulesets, whether it is a clean git repository). See [Finding rules in the vault](#finding-rules-in-the-vault) |
| `:RulesVault open` | `[<ruleset>\|<ID>\|<FAMILY>] [<part>]` | — | Opens the rule file of an id, the folder of a family in the explorer, or a part of a ruleset (`rules` by default, `layouts`, `catalogs`, `all`) |
| `:RulesVault clipboard` | `[<ruleset>\|<ID>\|<FAMILY>] [<part>]` | `--rel`, `--link` | Copies the path to the `+` register; `--rel` relative to the folder of the current file; `--link` as a Markdown link, `[DEP-06](path)` |
| `:RulesVault link` | `[<ruleset>\|<ID>\|<FAMILY>] [<part>]` | — | Inserts a Markdown link at the cursor, relative to the current file (the clipboard when the buffer cannot take text) |
| `:RulesVault find` | `[<ruleset>\|<ID>\|<FAMILY>] [<part>]` | — | Picks a file by name (pickers.nvim) in the ruleset, the family or the part; for an id: in its ruleset, for the id |
| `:RulesVault grep` | `[<ruleset>\|<ID>\|<FAMILY>] [<part>]` | — | Searches the content of the files, the same roots as `find` |
| `:RulesVault tree` | `[<ruleset>\|<ID>\|<FAMILY>]` | — | Shows a ruleset as a tree: family, then rules, with counts per family and a `[retired]` marker |
| `:RulesVault cdx` | `[<ruleset>\|<ID>\|<FAMILY>] [<part>]` | `--rel` | Copies a prompt for an agent session to the `+` register (the same thin path as `:TasksVault cdx`) |
| `:RulesVault create` | `[<dir>] [<name>]` | `--git`, `--yes`, `--force` | Makes a rules vault: lists what happens and the step that is left to you, asks, then makes the missing files. Never overwrites a file, never adds a remote |

**In a vault on more than one machine: pull before you create** (`git pull` in the vault). Ids are given under a lock per
machine, so two machines that make a rule in one family without a pull in between make the same id. When the vault is a git
repository that lies behind its upstream (what the last `git fetch` knows; the engine never fetches), `:Rules new` makes the
rule and adds a **warning** to the messages, and the form's question shows it before you confirm; a duplicate id is a load
error that fails the vault's CI. The engine never pulls, commits or pushes. See [CONFIG.md](CONFIG.md#pull-before-you-make-a-rule).

No default keymaps are bound (the form binds a few keys in its own buffer, see
below). `--family=`, a gate's `<name>`, the `<id>` of `show`, `set`, `retire`
and `move`, `--by=`, `--after=`, `--before=`, the severities, `--ruleset=` and
the places of `--to=` (the layouts, then the headings of one layout) all
tab-complete against whatever is actually loaded/configured right now. The `<id>` of
`reinstate` completes to the **retired** rules only (an active id is no candidate), its
`--layout=` to the layouts and its `--section=` to the headings of all layouts. The
first word of a `:RulesVault` verb completes to the rulesets of the vault, the
parts, and the ids (retired ones too) and families **of the vault's rulesets**
(the ones the command resolves a word in, not whatever `setup({ rulesets })`
loads). The second word offers the parts only behind a ruleset: a rule id, a
family or a part word alone takes none, and the command refuses one there.

## Finding rules in the vault

`:RulesVault <verb> [<ruleset>|<ID>|<FAMILY>] [<part>]` is the counterpart of
`:TasksVault`: it navigates to where the rules are. It reads and points; it
writes nothing but the scaffold of `create`. A rule is made by `:Rules new`
and changed by `:Rules set`, so there is no `new` and no `paste` here. The
vault is found as [CONFIG.md](CONFIG.md#the-rules-vault) says
(`setup({ vault })`, `$RULES_VAULT`, the project file); the rulesets are the
ones the vault offers, `rules.vault.rulesets()`.

```vim
:RulesVault open DEP-06                 " the rule file (a retired rule too: _retired/)
:RulesVault open DEP                    " the folder of the family
:RulesVault open lua layouts            " a part of a ruleset
:RulesVault clipboard DEP-06 --link     " [DEP-06](/path/to/DEP-06.md)
:RulesVault link DEP-06                 " the same at the cursor, relative to this file
:RulesVault grep DEP-06                 " who names the rule: searched in its ruleset
:RulesVault tree native
:RulesVault create ~/rules-vault lua --git
```

- **What a word is.** The first word is read in this order, one reading each: a
  ruleset of the vault (its folder name), a part (`rules`, `layouts`,
  `catalogs`, `all`, taken for the ruleset of the buffer), a rule id, a family.
  A word that is a part and also the name of a ruleset means the ruleset. A
  word that is none is an error that lists the rulesets and suggests the
  spelling it has (`dep-06`: did you mean `DEP-06`?). Ids and families are
  exact, and an exact one beats a ruleset of the same name in another case:
  `DEP` is the family even where a ruleset `dep` exists, on every system. Only
  when nothing matches exactly does the name of a ruleset ignore case, and only
  where the file system does (Windows, macOS). A rule id or a family takes no
  part.
- **Without a word** the ruleset is the one the current buffer lies in
  (compared by real path), the only one of the vault, or a pick.
- **Parts.** `rules` is `_rules/` (the ruleset folder itself for a ruleset that
  keeps its rules in documents), `layouts` is `_layouts/`, `catalogs` are the
  generated reading documents (the `output` of the layouts: files, so `find`
  and `grep` refuse them), `all` is the ruleset folder.
- **`open`** puts a rule file in a buffer at its heading, a folder in the
  explorer (`:Filetree open`, else the editor's own), a generated document in a
  buffer. When there are several (a family with a folder in two rulesets, two
  generated documents) you pick one. The path is opened as it is: a `%` or `#`
  in a folder name (`a#b`) is not taken for the current or the alternate file.
- **`clipboard` and `link`** use forward slashes on every system. A link target
  with a blank or a parenthesis is wrapped in `<...>`.
- **`tree`** prints the ruleset family by family with the counts of rules and
  retired rules, in the report window `:Rules stats` uses. A retired rule is
  marked `[retired]` and names the rule that replaced it. A family or an id
  shows that family in every ruleset that has it.
- **`cdx`** copies a prompt that names the path and says rules are changed
  through the engine (`:Rules new/set/retire/move`). Neovim has no generic way
  to start an agent session, so it is the clipboard, like `:TasksVault cdx`.
- **No vault.** Every verb but `create` says so once
  (`no vault is configured: ... -- :RulesVault create <dir> makes one`) and
  does nothing else. A vault that is named but is not a folder is an error that
  says where it was named (`$RULES_VAULT: the vault is not a folder`).

### `create`

`:RulesVault create [<dir>] [<name>] [--git] [--yes] [--force]` makes the
folder of a vault and, in it, only what is missing; **a file that is there is
never overwritten** (it is listed as kept). With no `<dir>` it asks for one. The
name of the first ruleset is `default` unless given (letters, digits, `.`, `_`,
`-`; no Windows device name). On Windows a folder completed with `<Tab>` ends
with a backslash (`sub\`): when `sub` is a folder and `sub lua` is not, the blank
typed after it starts the next word, so `create sub\ lua` is the folder `sub` and
the ruleset `lua`. In every other case `\ ` is a blank in the name (`my\ vault`).

| Made | |
| --- | --- |
| `README.md` | what the vault is, its layout, how it is worked with |
| `.rules.json` | `{"rulesets": ["rulesets/<name>"], "gates": {}}`, paths relative to the file. Made only when the new ruleset is the only one; in a vault with rulesets none is made (they are all found without it), and a file that is there stays and is reported when it does not list the new ruleset |
| `.gitattributes` | `* text=auto eol=lf` |
| `.gitignore` | editors, `.deps/` |
| `.github/workflows/ci.yml` | from `templates/rules-vault-ci.yml` of this plugin: on Ubuntu and Windows: no CR in the checked-out `.md` files below `rulesets/`, `catalog --check` for every folder below `rulesets/`, the rulesets the vault offers load together without errors (`scripts/ruleset.lua check`: a duplicate id, also between a live and a retired rule, an invalid severity, a file under `_rules/` that is no rule), the round trip for every folder; see [CONFIG.md](CONFIG.md#the-ci-of-a-vault) |
| `rulesets/<name>/_rules/.gitkeep`, `_layouts/.gitkeep` | the first ruleset (no placeholder in a folder that has files) |

It **says first what happens and what is left to you** and asks (`No` is the
button the dialog starts on; `--yes` skips the question; a session without a
screen needs `--yes`). The list ends with a step that is marked and is yours:

```
  >>> 4. REQUIRED, and done by you afterwards <<<
       Write the path into the setup of rules.nvim:
           vault = "/home/me/rules-vault",
       (or set $RULES_VAULT). Without this step rules.nvim will NOT find
       the vault. Nothing is read from it until then.
```

The same step is said again when it is done, and the line is put in the `+`
register. The vault is not used for the session: this step makes rules.nvim
find it.

- **Nothing is written before the layout is checked.** A file where a folder
  is needed, a name over 255 bytes, a path over the limit (259 bytes on
  Windows) and a link (symlink, junction) on the way that leads out of the
  vault folder are refused with the name of the one in the way, before the
  first file. See [CONFIG.md](CONFIG.md#making-a-vault).
- `--git` runs `git init` in the folder, and only then. A folder that is a
  repository already, or lies inside another one, gets none. There is **never a
  remote**, a commit, a push or a call to GitHub: that is yours (the privacy of
  the repository included).
- A vault is **in use** already (`setup()`, `$RULES_VAULT`)? `create` stops and
  says so; `--force` makes another one. The folder of the vault in use is
  filled in without it. A vault that is named but whose folder is missing is not
  in use: `create` at that path is the way to make it.

## Making, changing, retiring and moving rules

`new`, `set`, `retire`, `reinstate` and `move` are a thin layer over the write door of the
machine contract, [`rules-ops/1`](CONTRACT.md#rules-ops1-write) (the same door
an app or an agent uses): the command line is turned into one operation, the
door does the work and answers, the answer is told. The commands check nothing
of a rule themselves: a severity that is none, a title that is too long, an id
that is not there, a layout that does not exist is what the door answers, word
for word (`invalid_argument: severity must be one of ...`). The door only
writes a ruleset in the one-file-per-rule form ([RULESET-FORMAT.md](RULESET-FORMAT.md)).

```vim
:Rules new DEP Use vim.uv instead of vim.loop severity=critical --after=DEP-01
:Rules set DEP-06 severity=recommended title=A better title
:Rules set DEP-06 check={"type":"grep","pattern":"vim%.loop"}
:Rules set DEP-06 check=
:Rules retire DEP-03 --by=DEP-09 reason=superseded by DEP-09
:Rules reinstate DEP-03 --after=DEP-02
:Rules reinstate DEP-03 --section=Core\ Rules --layout=regeln/DEP.md --first
:Rules move DEP-06 --to=regeln/DEP.md#Core
:Rules move DEP-06 --to=regeln/DEP.md#Core\ Rules --first
:Rules list --family=DEP --severity=critical
```

- **Words and values.** `key=value` words take a value with spaces: a word that
  is no known `key=` goes on with the value before it (`title=A better title
  severity=critical`). The words after the family of `new` and before the first
  `key=` are the title. `check=` and `agent=` take a JSON object, or nothing to
  remove the key (`null` in the patch); `text=` with nothing is an empty text.
- **The family** of `new` is 1 to 12 uppercase letters `A-Z` (`DEP`, `LUA`), or a
  family the ruleset has already, exactly as it is spelled there (a ruleset may
  have `Dep-01` or `lint-04`: the format allows letters of any case, and `new` goes on
  numbering them). The door refuses `Fix`, `dep`, `DEP2` or a longer one, when the
  ruleset has no family of exactly that spelling, with one message
  (`invalid_argument: family must be 1 to 12 uppercase letters A-Z (e.g. DEP), or a
  family the ruleset has, spelled as there`), and the command and the form say the
  same before they ask anything. That keeps a mistyped title
  (`:Rules new Fix the bug severity=critical` reads `Fix` as the family) from making
  a family, and `dep` from being a second family beside `Dep`, where the file system
  does not tell the two folders apart. A family that no rule
  has yet, loaded or retired, is a **new family**: the command asks before it
  makes the first rule (`--yes` skips the question, `--dry` asks nothing, a session
  without a screen needs `--yes`), and the question of the form shows it
  (`NEWF (NEW: no rule of any ruleset has it yet)`).
- **`key=` words may stand anywhere.** The family of `new` and the id of `set`,
  `retire` and `move` are the first word that is no known `key=`; a `key=` word
  before it takes that one word as its value
  (`:Rules new severity=critical DEP Add the check`,
  `:Rules new text=Hello DEP Wrong title severity=critical`). Only the words
  after the family or id make the title or go on with a value, so put a value
  of several words after it. A word that is a known `key=` always starts the
  next value, it cannot be part of one.
- **A value comes out as typed.** The line is read from the argument string, not
  from Neovim's `<f-args>`: a run of blanks, a backslash before a blank
  (`text=C:\Users\x\ end`) and a pair of backslashes are in the value exactly
  as typed (Neovim's `<f-args>` would make the blanks one, drop the backslash
  before a blank and halve the pairs). What stays Neovim's: a flag's own value
  (`--to=regeln/DEP.md#Core\ Rules`: `\ ` is a blank, `\\` a backslash), and a
  line cannot hold a newline.
- **A word with two dashes is a flag, also in a value.** `text=run with --dry
  now` is a dry run, and an unknown `--word` is refused (`unknown flag`). A
  bare `--` **ends the flags** only where it is meant to: right behind the first
  word (the family or the id), or in front of a word that starts with a dash.
  Everything after it is text, `--dry` included, and the `--` itself is not part of
  the text (`:Rules set DEP-01 -- text=run with --dry now` and `:Rules set DEP-01
  text=run with -- --dry now` both set `run with --dry now`); a second `--` is.
  Anywhere else a `--` is a word of the text, kept as typed, and the flags go on:
  `:Rules set DEP-01 text=Use this -- not that --dry` sets (as a dry run) `Use this --
  not that`, as does `check={"type":"grep","pattern":"a -- b"}` for the pattern
  `a -- b`. No character of a value is dropped without this rule saying so.
- **A place** is one of `--to=<file>#<section>` (`<file>` is the `output` path
  of a layout, `<section>` the text of a heading; `--first` puts the rule at the
  start of the section instead of its end; in a section with no rule yet both
  mean behind its introduction text), `--to=<file>` alone (the top of the
  layout), `--after=<id>` or `--before=<id>` (in the layout that holds that
  rule). A blank in a section is written with a backslash before it
  (`#Core\ Rules`); `<Tab>` writes it so. A word that is left over is refused
  with that hint, never taken for something else.
- **What `set` leaves alone.** Only the parts named are changed, line by line: a
  `check=` or `agent=` writes that field again on one line and leaves every other
  line of the file, the other field of the block with its key order and layout
  included, as it was. The exceptions are said, never silent: a block with a
  comment or a Lua function is refused for `check=`/`agent=` (edit it by hand),
  and a block whose fields share a line (`check = { ... }, agent = { ... },`) or
  start with the separator (`, agent = { ... }`) is written again from its
  table, the keys in order of their names (so is a block that gives the key
  twice when the key is removed; when it is set, the last one is replaced).
- **`--dry`** is the door's `dry_run`: everything is checked and told, nothing is
  written, no buffer is touched. `set --dry` shows the change as a diff.
- **`retire` asks first** (`No` is the button the dialog starts on; `--yes`
  skips the question). The door is asked with a dry run before the question,
  so a rule that is not there or a `--by=` that does not exist is told without a
  question. A session without a screen to ask on needs `--yes`.
- **`reinstate` is the way back from `retire`** and goes the same way: the door is
  asked with a dry run first (a rule that is not retired, an id that is loaded again, a
  place that does not exist is told, word for word, without a question), `--dry`
  stops there, `--yes` skips the question. It is `reinstate` of
  [`rules-ops/1`](CONTRACT.md#rules-ops1-write) and nothing else: the file returns to
  where it came from (`was:` in its frontmatter), the id is in use again.
  - **The place** is one of `--after=<id>`, `--before=<id>` (in the layout that holds
    that rule; `--layout=<file>` names the layout when several hold it) or
    `--section=<heading>` with `--layout=<file>` (`--first`: the start of the
    section, not its end; a blank in the heading is written with a backslash before
    it). It is handed to the door as typed: two places, `--section` without
    `--layout`, `--first` without a section or a layout that does not exist are what
    the door answers (`invalid_argument: ...`). Note that this is `--section=` and
    `--layout=`, not the `--to=<file>#<section>` of `new` and `move`.
  - **Without a place** the command does not guess one. Where the rule stood is not
    on disk: only the answer of the `retire` carried it (`inverse`, for an app or an
    agent), and the file of a retired rule keeps no layout. So the rule comes back in
    **no layout**; the question says so, and the command says it again afterwards
    (`DEP-03 stands in no layout: ...`), naming the flags and `:Rules move` to put
    it in one. `:Rules catalog` names a rule that is in no layout.
  - **The open buffers** are looked after as for every write: an unmodified buffer
    of the layout, or of the rule's file (left open by the `retire`), is reloaded; a
    buffer with unsaved changes is a conflict and left as it is; the buffer of the
    removed `_retired/` file is named and left open.
- **The open buffers of the ruleset** are looked after around every write: an
  unmodified buffer of a file that changed (the rule, a layout, a generated
  document) is reloaded; a buffer with **unsaved changes** is left as it is and
  named as a conflict (the file on disk changed under it: `:edit!` takes the
  file's version, `:write!` the buffer's); the buffer of a retired rule is left
  open and named. A file the write did not change is never touched. A buffer
  that cannot be reloaded (a window with `'winfixbuf'`, an autocmd that fails
  `BufReadPre`) keeps its old text and is set `modified` and `readonly`, so `:w`
  cannot put the old text (or an empty one) over the new file; it is named, and
  `:edit!` reads the file again. An autocmd that fails only after the read
  (`BufReadPost`) leaves a buffer that holds the new file: it counts as reloaded.
- `list` shows the title without the id in front of it, which is the id column.

### The form

`:Rules new` with less than family, title and `severity=` opens a Markdown form
in a scratch buffer (`rules://rule-new`), filled in with the family, title,
severity, text and place the command line gave:

```markdown
# New rule
Family: DEP
Title: One line that names the rule
Place: after DEP-03

## severity (one)
- [ ] critical
- [x] recommended
- [ ] nice-to-have

## text
The prose of the rule, as long as it needs.
```

Family, Title and one severity are required; Place is optional (`after <ID>`,
`before <ID>`, `<file>#<section>` or `<file>`), a `Ruleset:` line appears when
several rulesets are configured, and everything below `## text` is the prose.
The prose goes on as typed: the form (like the engine) neither joins nor wraps
lines. Wrapping Markdown safely needs to know lists, tables, quotes, fences and
code spans, and the buffer is a Neovim buffer, so `gq` and `'textwidth'` do it
where you want it. `<C-s>` submits: first the form says what is missing, all at once, as `!` lines
at the top (they go away on the next submit); then the door runs a `dry_run`
and a refusal is shown in the form too; then a question shows what would be
made (id, severity, title, file, place) with `Back to the form` as the answer
the dialog starts on; only `Create the rule` writes, closes the form and opens
the new file. Nothing typed is lost on a refusal.

Keys of the form (buffer-local, `g?` lists the keys in force). These are the
defaults; `setup({ keys = { form = { ... } } })` changes every one of them:

| Action | Key | Does |
| --- | --- | --- |
| `toggle`, `accept` | `<Space>`, `<CR>` | tick or untick the severity under the cursor (one tick), anywhere else the key is what it always is |
| `submit` | `<C-s>` (normal and insert) | check, dry run, ask, write |
| `close`, `cancel` | `q`, `<C-q>` (`cancel` also in insert mode) | cancel; asks first when something was typed |
| `help` | `g?` | help |

```lua
require("rules").setup({
  keys = { form = { submit = "<C-g>", toggle = { "<Space>", "x" }, help = false } },
})
```

An action takes a key, a list of keys (every one is bound) or `false` (no key
for it); an action that is not named keeps its default. The hint under the
title of the form and `g?` show the keys that are really bound (`-` for an
action with none). Unknown actions (`keys.form.sumbit (did you mean
submit?)`), values of the wrong type and two actions on one key are warned about
at `setup()`, never ignored silently; `keys` is a `setup()` option only (in a
`.rules.json` it is an unknown key). See [CONFIG.md](CONFIG.md#the-keys-of-the-form).

`:Rules check`/`gate`/`stats`'s readable-buffer report reuses a still-open
report window (any tab) instead of opening a fresh tab on every call — a
repeated run replaces that window's content in place. Navigating the
window away from the report (e.g. `:e` another file in it) makes the next
run open a new tab again rather than hijacking it.

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

Gates (and `rulesets`) can also come from a `.rules.json` in the project root or in a
[vault](CONFIG.md): `setup()` wins over the project file, which wins over the vault's file,
gate by gate. The project for `:Rules check` and `:Rules gate` is their `path` argument
(default: the working directory).

A `rulesets` entry is expanded (`~`, `$VAR`/`${VAR}`, `%VAR%`) before it is
checked, so the `~/...` form above works as written. A path that still
resolves to neither a directory nor a readable `.md` file (a typo, an
unset env var, a ruleset that hasn't been cloned yet) is a load error,
notified the same way a malformed rule block is — never a silent zero
rules loaded.

`lua_predicates` (default `true`) controls whether `lua_predicate` checks may
run. Set it to `false` for a ruleset you did not write: each predicate then
reports `error` ("predicate not trusted") instead of running, and every other
check type runs as usual. A predicate also runs only in a ruleset you named
yourself (`setup({ rulesets })`, your vault, a command line): a ruleset that a
project `.rules.json` names reports `error` with `not run: ruleset is not trusted`
unless its folder is in `setup({ trust = { ... } })` (headless: `--trust=<dir>`,
`$RULES_TRUST`). See [CONFIG.md](CONFIG.md#a-word-on-trust) and
[RULESET-FORMAT.md](RULESET-FORMAT.md).

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
  "DEP-04": "legacy call site, ticket JIRA-123 tracks the actual fix",
  "DEP-01": {
    "reason": "fixture strings of the tests, not real calls",
    "expires": "2026-12-31",
    "paths": ["TESTS", "docs/**/*.md"]
  }
}
```

A waived rule that would otherwise fail or error reports as **waived**
instead — visible in the buffer report with its reason (and its last day and
its paths when it has them), excluded from the quickfix worklist, and never
counted by `check_family_json`'s exit code. A waiver for a rule that currently
passes has no effect; it just sits unused until the rule fails again. This is
deliberately different from deleting the rule or the ruleset entry: the record
that a specific finding was seen and accepted survives.

The file format (the short form, the object form, `expires`, `paths`, the caps)
is in [CONFIG.md](CONFIG.md#rules-waiversjson). In short:

- **`expires`** (`YYYY-MM-DD`) is the last day the waiver counts. The day after,
  it is **expired**: the finding is not waived any more and flags again, and the
  report says `waiver expired on <date> (<reason>): renew it or remove it` under
  the rule (also under a rule that passes now: the waiver is still there to be
  renewed or removed). `:Rules check` and `:Rules gate` also notify how many
  waivers of the project expired, whatever family they were run for.
  `check_family_json` carries it as `expired_waiver` (`reason`, `expires`) of
  the entry, and a waived entry has `waiver_expires` and `waiver_paths`.
- **`paths`** limit the waiver to findings in those files or folders (globs
  allowed). A finding outside them still flags; the ones inside are counted
  (`partial_waiver` in JSON, `N more finding(s) waived in …` in the report).

A `.rules-waivers.json` that cannot be used — not an object (a list), a value
that is neither a reason text nor an object, an unknown key, a date that is no
real calendar date, a path with `..`, an unparseable or empty file — is an
**error of the run**, not a warning followed by "no waivers": `:Rules check`
and `:Rules gate` stop and name the file's problem, `check_family_json` and
`run_gate_json` return the text as their error. Same reasoning as
`docs/RULESET-FORMAT.md`'s check primitives: a malformed input fails loudly
instead of quietly doing nothing. A reason is also re-validated on every
load: no newline (it is rendered as one report line), at most 500
characters, and at most 500 entries in the file.

The date a run counts as today is the machine's (local calendar date).
Specs and reproducible CI runs fix it: `rules.engine.waivers.clock` is the one
seam, `opts.today` of `rules.api`/`rules.ops` and `--today=` of
`scripts/ruleset.lua check` override it per call.

`:checkhealth rules` cross-checks the current working directory's waivers
against every loaded rule id and warns about any entry that matches
nothing — a rule that was renamed/retired, or a plain typo, left silently
protecting nothing — and about any waiver that has expired.

### In CI

A project that wants an expired waiver to fail its pipeline runs

```sh
nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua check --waivers --project=. <ruleset-folder>
```

which exits 1 when the waivers file cannot be used or a waiver has expired
(`CONFIG.md` has the details). Changing the file is not a text edit by hand:
`waive`, `renew` and `remove` of [`rules-ops/1`](CONTRACT.md#waivers) check the
request, take a lock, write the file canonically and answer with an `inverse`.
