# Bindings

## Commands

| Command | Args | Flags | Does |
| --- | --- | --- | --- |
| `:Rules check` | `[path]` (defaults to cwd) | `--family=<PREFIX>` (required), `--format=json` (optional) | Runs every rule in the family against `path`. Default: reports into the quickfix list and a readable buffer. `--format=json` prints the results as JSON instead (`:messages`/stdout) and does not touch quickfix/buffer or quit Neovim — see below for headless/CI use |
| `:Rules gate` | `<name>` (required), `[path]` (defaults to cwd) | `--diff=<git-ref>` (optional), `--format=json` (optional) | Runs every family configured for gate `name` (`setup({ gates = {...} })`) as one combined report. `--diff=<git-ref>` narrows findings to files changed since that ref (`git diff --name-only` + untracked files) — a rule with no findings inside the diff reports as `pass` even if the repo has standing issues elsewhere. `--format=json` behaves like `:Rules check`'s. A configured family matching zero loaded rules (typo, or not migrated yet) warns instead of silently shrinking the gate |
| `:Rules show` | `<id>` (required) | — | Jumps to one rule's source location by its exact id, without running a family check. Errors if no loaded rule has that id |
| `:Rules stats` | — | `--format=json` (optional) | Structural overview of every loaded rule: per-family totals, automated-vs-manual split, severity breakdown. No check runs — pure catalog metadata |
| `:Rules catalog` | `[path]` (default: every folder in `rulesets`) | `--check` (optional) | For a ruleset in the one-file-per-rule form: builds the reading documents from their layouts ([RULESET-FORMAT.md](RULESET-FORMAT.md#layouts-and-catalogs)). A document is written only when its content changed. `--check` writes nothing and warns about every document that is out of date — for CI use `scripts/ruleset.lua catalog --check <folder>` (exit code 1 when one is). Names the rules that are in no layout |
| `:Rules messages` | — | — | Opens this plugin's notify history (toast + `:messages` log, via `lib.nvim.notify.popup`) |
| `:Rules new` | `[<FAMILY> [title...]]` | `severity=`, `text=`, `ruleset=`, `--to=`, `--after=`, `--before=`, `--first`, `--yes`, `--dry` | Makes a rule at the next free id of the family (1 to 12 uppercase letters `A-Z`). With the family, a title and `severity=` the rule is made and opened (a family no rule has yet is asked about first, `--yes` skips the question); with less, the [form](#the-form) opens, filled in with what was given. See [Making, changing, retiring and moving rules](#making-changing-retiring-and-moving-rules) |
| `:Rules set` | `<id>` | `severity=`, `title=`, `text=`, `check=`, `agent=`, `--dry` | Changes parts of a rule's file; everything else in the file stays byte for byte |
| `:Rules retire` | `<id>` | `--by=<id>`, `reason=`, `--yes`, `--dry` | Moves a rule's file to `_retired/` and out of every layout; the id stays taken. Asks first |
| `:Rules move` | `<id>` | `--to=<file>#<section>`, `--after=<id>`, `--before=<id>`, `--first`, `--dry` | Moves the rule's `{{rule ID}}` line within its layout or into another; the rule's own file is not touched |
| `:Rules list` | — | `--family=<PREFIX>`, `--severity=<level>`, `--format=json` | Puts the rules in the quickfix list, each at its source line; `--format=json` prints the `rules.list` document of the [machine contract](CONTRACT.md) |

No default keymaps are bound (the form binds a few keys in its own buffer, see
below). `--family=`, a gate's `<name>`, the `<id>` of `show`, `set`, `retire`
and `move`, `--by=`, `--after=`, `--before=`, the severities, `--ruleset=` and
the places of `--to=` (the layouts, then the headings of one layout) all
tab-complete against whatever is actually loaded/configured right now.

## Making, changing, retiring and moving rules

`new`, `set`, `retire` and `move` are a thin layer over the write door of the
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
:Rules move DEP-06 --to=regeln/DEP.md#Core
:Rules move DEP-06 --to=regeln/DEP.md#Core\ Rules --first
:Rules list --family=DEP --severity=critical
```

- **Words and values.** `key=value` words take a value with spaces: a word that
  is no known `key=` goes on with the value before it (`title=A better title
  severity=critical`). The words after the family of `new` and before the first
  `key=` are the title. `check=` and `agent=` take a JSON object, or nothing to
  remove the key (`null` in the patch); `text=` with nothing is an empty text.
- **The family** of `new` is 1 to 12 uppercase letters `A-Z` (`DEP`, `LUA`): the
  door refuses `Fix`, `dep`, `DEP2` or a longer one with one message
  (`invalid_argument: family must be 1 to 12 uppercase letters A-Z (e.g. DEP)`),
  and the command and the form say the same before they ask anything. That keeps
  a mistyped title (`:Rules new Fix the bug severity=critical` reads `Fix` as the
  family) from making a family, and `dep` from being a second family beside `DEP`
  where the file system does not tell the two folders apart. A family that no rule
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
  bare `--` ends the flags: everything after it is text, `--dry` included
  (`:Rules set DEP-01 text=run with -- --dry now` sets `run with --dry now`).
  The flags go before the `--`; the `--` itself is not part of the text, a
  second `--` is.
- **A place** is one of `--to=<file>#<section>` (`<file>` is the `output` path
  of a layout, `<section>` the text of a heading; `--first` puts the rule at the
  start of the section instead of its end), `--to=<file>` alone (the top of the
  layout), `--after=<id>` or `--before=<id>` (in the layout that holds that
  rule). A blank in a section is written with a backslash before it
  (`#Core\ Rules`); `<Tab>` writes it so. A word that is left over is refused
  with that hint, never taken for something else.
- **`--dry`** is the door's `dry_run`: everything is checked and told, nothing is
  written, no buffer is touched. `set --dry` shows the change as a diff.
- **`retire` asks first** (`No` is the button the dialog starts on; `--yes`
  skips the question). The door is asked with a dry run before the question,
  so a rule that is not there or a `--by=` that does not exist is told without a
  question. A session without a screen to ask on needs `--yes`. A retired rule
  is brought back through the API (`reinstate`), there is no command for it yet.
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
`<C-s>` submits: first the form says what is missing, all at once, as `!` lines
at the top (they go away on the next submit); then the door runs a `dry_run`
and a refusal is shown in the form too; then a question shows what would be
made (id, severity, title, file, place) with `Back to the form` as the answer
the dialog starts on; only `Create the rule` writes, closes the form and opens
the new file. Nothing typed is lost on a refusal.

Keys of the form (buffer-local, `g?` lists them):

| Key | Does |
| --- | --- |
| `<Space>`, `<CR>` | tick or untick the severity under the cursor (one tick), anywhere else the key is what it always is |
| `<C-s>` (normal and insert) | check, dry run, ask, write |
| `q`, `<C-q>` | cancel; asks first when something was typed |
| `g?` | help |

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

A `rulesets` entry is expanded (`~`, `$VAR`/`${VAR}`, `%VAR%`) before it is
checked, so the `~/...` form above works as written. A path that still
resolves to neither a directory nor a readable `.md` file (a typo, an
unset env var, a ruleset that hasn't been cloned yet) is a load error,
notified the same way a malformed rule block is — never a silent zero
rules loaded.

`lua_predicates` (default `true`) controls whether `lua_predicate` checks may
run. Set it to `false` for a ruleset you did not write: each predicate then
reports `error` ("predicate not trusted") instead of running, and every other
check type runs as usual. See [RULESET-FORMAT.md](RULESET-FORMAT.md).

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
instead of quietly doing nothing. A reason is also re-validated on every
load: no newline (it is rendered as one report line), at most 500
characters, and at most 500 entries in the file — each is a load error too.

`:checkhealth rules` cross-checks the current working directory's waivers
against every loaded rule id and warns about any entry that matches
nothing — a rule that was renamed/retired, or a plain typo, left silently
protecting nothing.
