# Ruleset format

A ruleset comes in two forms, which load side by side in one run:

- **documents**: many rules in one Markdown file, each with a fenced `rule`
  block (this page, up to [One file per rule](#one-file-per-rule));
- **one file per rule**: each rule is its own file, and the documents a person
  reads are generated from *layouts*
  ([One file per rule](#one-file-per-rule), [Layouts and catalogs](#layouts-and-catalogs)).
  [Migrating](#migrating-a-ruleset) converts the one into the other and proves
  that nothing is lost.

## Documents

A ruleset is one or more Markdown files. Each rule is a normal Markdown
section with one fenced code block tagged `rule` somewhere in it:

````markdown
### `DEP-06` — `vim.tbl_flatten()` is deprecated

```rule
id = "DEP-06",
severity = "recommended",
check = { type = "grep", pattern = "vim%.tbl_flatten%(" },
```

Throws instead of silently corrupting dict-shaped tables. Wrap in `pcall` for
unchecked or mixed structures.
````

Everything outside the fenced block — headings, prose, other fenced blocks,
legacy table-based rule text — is invisible to the loader. That is
deliberate: a file half in an old format and half in this one still loads
correctly, picking up only the entries that have actually been converted.

## The block itself

The block's content is a Lua table-constructor *body*, evaluated as
`load("return {" .. body .. "}")`. That means normal Lua table syntax,
including the field separator: a comma (or semicolon) after every field,
same as any Lua table literal.

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | a stable string, never reused once a rule is retired; at most 100 bytes, no control characters |
| `severity` | yes | `"critical"` \| `"recommended"` \| `"nice-to-have"` |
| `check` | no | see below — omit it entirely for a rule with no automated check |
| `agent` | no | a hint for an agent working a rule that has no `check` — see below |

A rule's **family** is its ID up to the first `-` when only letters come before
it (`"DEP"` for `"DEP-01"`); an ID with anything else there (`DEP2-01`, `DEP01`)
is a family of its own. A block has no separate family field.
`:Rules check --family=<PREFIX>` matches on this.

## What the parser adds

The block cannot say where it sits or what is written under it, so the parser
reads that from the Markdown around it:

| Field | Value |
| --- | --- |
| `text` | the prose under the block, up to the next heading or the next rule block, without the blank lines and `---` rules that only frame it. `""` when there is none |
| `title` | the heading the rule sits under, when that heading names the rule (`` #### `DEP-06` — … ``). Otherwise `nil` |
| `section` | the heading above the rule's own title; when the nearest heading does not name the rule, that heading itself. This is what a catalog groups by |
| `source_file`, `source_line` | where the block starts |

A `#` line inside another fenced block (a shell comment in an example) is not
a heading. These fields belong to the parser: a block that sets one of them has
it overwritten.

## The `agent` field

```lua
agent = {
  question  = "Does any exported function here take more than 5 positional parameters?",
  include   = { "lua/**/*.lua" },
  max_files = 20,
},
```

Optional, and only a hint — it changes nothing about `:Rules check`. `question`
replaces the generic "does the code comply with the rule text", `include` says
where to look, `max_files` caps how many files one request carries. An invalid
`agent` (an unknown key, an empty `question`, an `include` that is not a list of
strings, a `max_files` that is not a positive integer, a `question` over 4000 bytes,
an `include` with more than 50 entries or an entry over 200 bytes) is **dropped and
reported**, and the rule itself stays: losing a rule from a gate over a typo in
an optional hint would be the worse failure.

## A ruleset is code

A ruleset is Lua, and a folder you did not write is a stranger's Lua. Two
things follow, and they are different in kind:

- **A block body is evaluated in an empty environment.** It cannot call
  `os.execute`, `io.open`, `require` or anything on `vim`; a body that tries
  fails as a malformed block, reported like any other, and the rest of the file
  still loads. This is a boundary on *what* a ruleset can do, not on *how much*
  it can use: string methods stay reachable through a literal, so a hostile
  ruleset can still allocate memory. What it cannot do is touch the disk, a
  process or the network — and a loop that never ends is stopped by an
  instruction budget.
- **A `lua_predicate` is arbitrary code that runs later, with the real
  environment.** `setup({ lua_predicates = false })` refuses to run any: each
  one reports `error` with `predicate not trusted`, visibly, rather than
  dropping out of the run. The default is `true` — your own rulesets in your
  own Neovim. Everything that is not a predicate (`grep`, `file_exists`,
  `file_absent`, `json_key_absent`, rules with no check) runs either way.

A host that keeps its own trust list can pass `lua_predicates` as a function
`(rule) -> boolean, reason?` to `runner.check_family`/`gate.run` (the rule carries its
`source_file`), so one trusted file does not trust every file; the reason, when given,
is what the `error` says. `rules.nvim` passes such a function itself: a predicate runs
only in a ruleset that the user named (not one that a project `.rules.json` names, unless
it is in `trust`), and says `not run: ruleset is not trusted` otherwise
([CONFIG.md](CONFIG.md#a-word-on-trust)).

## `check` types

| `type` | Fields | What it does |
| --- | --- | --- |
| `grep` | `pattern` (Lua pattern) or `patterns` (list, any-of), `unless` (optional), `include` or `includes` (optional, default `"%.lua$"`), `excludes` (optional) | flags every line under the checked path matching `pattern`/one of `patterns`, unless it also matches `unless` |
| `file_exists` / `file_absent` | `path` (relative) or `paths` (list, any-of); a `*` makes it a glob | a required/forbidden file or directory |
| `json_key_absent` | `path`, `key` (dotted, e.g. `"workspace.library"`) | fails if the key is set in the JSON file; passes if the file or the key is missing |
| `lua_predicate` | `fn(root) -> ok, findings_or_message` | anything the above can't express |

**Why Lua patterns, not regex.** Lua patterns have no `|` alternation — a
pattern like `"foo%(|bar%("` does not mean "foo( or bar("; `|` is a literal
character there, and that pattern would silently match almost nothing. Use
`patterns` (a list) instead of trying to cram alternation into one pattern —
that mistake is documented in this project's own history and is exactly what
`patterns` exists to make unnecessary.

**Which files a `grep` reads.** `include` is one Lua pattern matched against
the file path; `includes` is a list of them, for a rule that spans file types
(`includes = { "%.md$", "%.txt$", "%.lua$" }`) — the same reason `patterns`
exists. Once either is given, the `"%.lua$"` default no longer applies; an
empty `includes = {}` counts as not given, so the default applies again.
`excludes` is a list of path patterns whose files are skipped entirely, for a
whole class of call site that is never the hazard the rule means
(`excludes = { "/TESTS/" }`). `unless` works per line, `excludes` per file.

**Globs in `file_exists` / `file_absent`.** A path containing `*` is matched
against the files under the checked root: `*` stays inside one path segment,
a `**` segment spans any number of directories, none included.
`path = "lua/*/health.lua"` is how a catalog written for every repo names a
file whose module directory differs per plugin; `paths` takes several
candidates, globbed or not, and any one of them satisfies the check. Things
to know: a glob sees files, not directories, and does not go into symlinked
directories (a junction or symlink that stands in for a module directory is
not found by a glob, though a literal path through it is); it does not look
inside `.git`, `.deps` or `.claude`; it is case-sensitive on every platform,
unlike a literal path on a case-insensitive filesystem; `\` counts as a
separator and `.` or an empty segment is ignored, as in a literal path, but
`..` is not resolved. The root itself is never read as a pattern, which is what
a `lua_predicate` calling `vim.fn.glob(root .. "/…")` gets wrong on a root
containing `[`.

**A malformed check spec reports `error`, not a crash.** A missing or
wrong-typed required field (`file_exists`/`file_absent` with no `path`/
`paths`, `json_key_absent` with no `path` or `key`) fails only the one rule
with an `error` status naming the check type — it never aborts the rest of
the family run.

**`grep` findings are candidates, not verdicts.** A `grep` check finding a
hit means "this line matches the pattern", not "this line is definitely
wrong" — a rule author decides, per rule, whether that gap matters enough to
still ship the check (see the `DEP-05` entry in an example ruleset: an empty
`check` is a legitimate, deliberate choice when a mechanical check would have
a high false-positive rate against real code).

## A rule with no `check` at all

The majority of any real rule catalog is judgment calls — architecture,
error handling, security review that needs to read the surrounding code, not
just grep it. Omit `check` entirely for those. `:Rules check` never invents
a pass/fail for a rule like this; it lists it as a worklist entry (ID, title,
source location) instead, for a human or an agent session to work through.

## One file per rule

A rule is a file of its own, so a tool can create, change or retire exactly one
rule without touching the text of any other (`tasks.nvim` keeps tasks the same
way). Convention for where it lives: `<FAMILY>/<ID>.md` under a folder of the
ruleset, `_rules/` by default (`_rules/DEP/DEP-06.md`); the loader reads every
`.md` file under a `rulesets` path, so the place is yours to choose.

One place is not free: **a `.md` file under a folder named `_rules` is a rule file, and
one that yields no rule is an error**, not a file that is passed over. That is an empty
file (or blanks only), a file without a frontmatter, a frontmatter with neither `id` nor
`severity` that holds no ` ```rule ` block, and a file with merge-conflict markers
(`<<<<<<<`, `=======` or `>>>>>>>` at the start of a line, outside a code fence; told
even when the file still yields a rule). This is what a bad merge or a lost write
leaves behind, and a ruleset that silently has one rule less is worse than one that
says so. Not a fault there: files that are not `.md` (`.gitkeep`), a `README.md` (any
case), a layout and a generated document. Anywhere else a Markdown file without a rule
is an ordinary document (notes, a README), and a document with ` ```rule ` blocks loads
as it always did, also under `_rules/`. `:Rules check`, `scripts/ruleset.lua check`,
`catalog --check` and `scripts/roundtrip.lua` all report such a file as a load error.

````markdown
---
id: DEP-06
severity: recommended
family: DEP
---

#### `DEP-06` — `vim.tbl_flatten()` is deprecated

Throws instead of silently corrupting dict-shaped tables. Wrap in `pcall`
for unchecked or mixed structures.
````

The **frontmatter** (flat `key: value` lines) holds `id` and `severity`, the
two things every rule has; they have one home. `family` is optional and, when
given, must be the rule's family as defined [above](#the-block-itself) (`DEP` for
`DEP-06`, but `DEP2-01` for `DEP2-01`): it is what `:Rules check --family=`
matches, so a frontmatter that says otherwise would promise a rule that the run
never reaches, and is an error. Any other key is an error (a typo such as
`severtiy` is not silently ignored), and so is a key written twice, a line that is
no `key: value` and a NUL byte anywhere in the file. A file with an `id` or a
`severity` in a frontmatter is a rule file; a file whose frontmatter has neither is
an ordinary document. The opening `---` may carry trailing blanks, like the closing
one. A frontmatter that starts with `id:` or `severity:` and is never closed, or is
closed by a mistyped line (`----`, `--`), is an error as well, not a document that
happens to start with a thematic break: a rule file with a fault is told, never
skipped. Every one of these errors names the line it sits on.

The **id** is also the file name (`<FAMILY>/<ID>.md`, which the migration builds
from it), so in a rule file it is limited to letters, digits, `-`, `_` and `.`, at
most 100 bytes, with no `..` and no `.` at its start or end. An id such as `A/B`,
`A:1` or `..` is an error, not a path. Every id of the shipped rulesets (`DEP-06`,
`LUA-01`) is well within it.

**Under the frontmatter**, one blank line and then the rule as it reads: the
heading that names it, the prose, a `---` that frames it. `title` and `text` are
read from there exactly as for a document (`text` ends at the next heading;
`section` is not set: which section a rule sits in is the layout's business).
With a block, the heading that names the rule is the nearest one above it; without
one, the first. A heading or `#` line inside a fence is not a heading, and a block
inside a longer fence (a ` ````markdown ` example) leaves that fence open for the
text below it, as in a document.

A ` ```rule ` **block** is only there when the rule says more than `id` and
`severity`: a `check`, an `agent`, anything else a block may hold. Write it
without the two identity lines:

````markdown
#### `DEP-06` — `vim.tbl_flatten()` is deprecated

```rule
check = { type = "grep", pattern = "vim%.tbl_flatten%(" },
```

Throws instead of silently corrupting dict-shaped tables.
````

If the block does repeat `id` or `severity`, they must agree with the
frontmatter: a rule file that says `DEP-06` above and `DEP-07` below is an error
for that file, there is no silent choice. The block is evaluated in the same
empty environment as in a document, `agent` is validated the same way, and the
id has the same bound (at most 100 bytes, within the narrower set of characters
above), so a rule means the same in either form. An *empty* block
(` ```rule ` and ` ``` ` with nothing between) is valid: it marks where the
block sits in the generated document when the rule file is written by hand with
prose above it.

A rule file has at most one block. Duplicates are found across both forms: an id
in a document and in a rule file is a `duplicate rule id` error, the first wins.

`source_file` is the rule file; `source_line` is the line of the block, or of
the heading when there is none (`:Rules show` jumps there).

### Retired rules

A rule that is retired (`rules-ops/1` `retire`, see [CONTRACT.md](CONTRACT.md))
moves to `<ruleset>/_retired/<FAMILY>/<ID>.md` with some facts added to its
frontmatter (`status: retired`, `retired`, `was`, `replaced_by`, `reason`). The
loader does not run a `_retired/` folder, so the rule is no longer run, in no
gate, in no document; its id stays taken, and `next_id` counts it. Bringing it
back (`reinstate`) puts the file where it was.

The check reads the ids of that folder too (without loading the rules): **a live rule
with the id of a retired one is a `duplicate rule id` error**, in one ruleset and across
rulesets (`duplicate rule id AAA-05: <live file>:<line> and <retired file> (retired)`),
and so is one id retired twice. That is the case git merges without a conflict: one
machine made AAA-05 and retired it, the other did not pull and made AAA-05 again. The id
of a retired file is the one in its name; when its frontmatter says another one, that is
told, and both are taken. A retired file that does not read (empty, no frontmatter with
an `id`, merge-conflict markers) is a load error as well; a `README.md` or a file that is
not `.md` in `_retired/` is none.

## Layouts and catalogs

With a rule per file there is no document to read top to bottom. The documents
are **generated**, like `TASKS.md`, from a *layout*:

````markdown
---
kind: layout
output: regeln/LUA_NVIM.md
---
# Rules for Lua

## Table of content

{{toc}}

## Using lib.nvim

Introduction that belongs to this section.

{{rule LUA-01}}
{{rule LUA-02}}
````

`output` is the path of the document, relative to the ruleset folder, with `/`.
It must name a `.md` file inside that folder, and it must be a name that is
valid on every system: none of `\ : * ? " < > |`, no empty part (`a//b`), no part
that ends in a space or a dot. It must stay inside the folder for real: a
symlink or junction on the way that leads out of it is refused (a link that
stays inside is fine), and nothing is created behind it. And it must not be a
file the generator would destroy: a layout (itself or another), a rule file, a
document with rules, or the `output` of another layout (the first layout, in
path order, gets it; each other one is an error). A layout that breaks one of
these gets the status `error`, nothing is written for it, and the exit code is 1.

The body is the document as it reads, and two kinds of **whole-line** tokens are
replaced; everything else (headings, introductions, separators, notes) is
copied as written. Whitespace after a token is ignored (editors leave it there);
whitespace before it makes the line text. A `{{toc ...}}` line is at most 256
bytes.

| Token | Becomes |
| --- | --- |
| `{{rule ID}}` | the rule as it reads in the document: its heading and text, and a ` ```rule ` block with `id` and `severity` put back in (and the rest of the block, if the file has one). The order of the tokens is the order in the document; a rule file carries no order. A rule placed twice, or an id with no rule file, is an error and nothing is written |
| `{{toc}}` | the table of contents of the finished document |

A rule file without a block gets one: right under its heading and the blank
lines below it. A rule file *with* a block keeps it where it is.

The generator copies the lines of a rule file as they are, so what separates two
rules in a document is in the rule file: a blank line, `---` and a blank line at
its end (what the shipped rulesets and `rules-ops/1` `new` write; a document
without dividers has rule files without). The generator adds nothing of its own.

**Rules added through the layout.** `rules-ops/1` puts a `{{rule ID}}` line into
a section by its heading: behind the last rule token of the section, or in front
of the first one. A section with no rule token has only an introduction, which is
not a rule, so the new token goes behind it (also for "first"), between one blank
line before and one after; the introduction stays above the rules.

**Table of contents.** One line per heading from level 2 on, each a link to its
anchor, without the title (level 1) and without the heading called "Table of
content". A repeated anchor gets `-1`, `-2`. The existing rulesets spell it in
different ways, so the token has parameters (`{{toc max=2 base=0 unicode=1}}`):

| Parameter | Default | Meaning |
| --- | --- | --- |
| `max` | 4 | deepest level listed (2 to 6) |
| `base` | 2 | indentation, in spaces, of level 2 |
| `step` | 2 | further indentation per level |
| `unicode` | 0 | 1: the anchor keeps the letters and digits of every alphabet, also those without case (`日本語`, `हिन्दी`, `١٢٣`), and turns every space into a hyphen (the renderers' way); punctuation, symbols and emoji go. 0: ASCII only, runs of spaces and hyphens become one hyphen |
| `underscore` | 1 | 0: an anchor drops `_` (only with `unicode = 0`) |

**The generated document** starts with one line,
`<!-- GENERATED by rules.nvim from <layout>: do not edit ... -->`. The loader
skips a file that starts with it, so a document and the rule files it was made
from never load as duplicates; a layout is skipped too. Edit the layout or the
rule files and generate again.

Only a generated document is ever replaced. If the `output` exists, is not empty
and does not start with that line (a README, notes somebody wrote), the layout
is an error (`exists and is not a generated document`), with `--check` as well,
and the file stays as it is. Delete or move it to let the layout take its place.
To replace it on purpose, call `require("rules").catalog(path, { adopt = true })`;
that is the only thing `adopt` changes (a layout, a rule file or a document with
rules is never replaced). The migration does not need it: it writes the
generated document over the old one itself.

```vim
:Rules catalog                 " every folder of setup({ rulesets })
:Rules catalog ~/Checklists    " one folder
:Rules catalog --check         " write nothing; report documents that are out of date
```

For CI (exit code 0 when everything is up to date, 1 otherwise):

```sh
nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua catalog --check <folder>
```

A document is written only when its content changed. Line endings are ignored
in the comparison, and an existing CRLF document stays CRLF. The run also names
the rules that are in no layout (they are in no reading document). The same call
is `require("rules").catalog(path, { check = true })`, which returns
`(results, errors, exit_code)`.

**Links.** A document is generated at the path the old one had, with the same
headings and the same anchors, so links into it from elsewhere (to the file or to
`#anchor`) stay valid. A *relative* link inside the text of a rule is copied as
written: it is right in the generated document, and one folder level deeper in the
rule file. A rule text that needs to be readable from both places should link to
something stable.

## Migrating a ruleset

`scripts/ruleset.lua migrate` converts a ruleset of documents (every `.md` file
with ` ```rule ` blocks) into rule files and layouts:

```sh
nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua migrate <folder>          # only look
nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua migrate --write <folder>  # do it
```

It never converts a document it cannot give back **byte for byte**. For each
document it builds the rule files and the layout, renders them in memory and
compares with the original text; any difference makes it refuse that document
(with the line of the first difference) and write nothing at all. A document is
refused for:

* a CRLF file, or one that does not end with a newline;
* a block that does not start with the `id` and `severity` lines, a block with no
  heading above it, no blank line around the block, an id twice;
* an id the rule file reader does not take (it becomes the file name: letters,
  digits, `-`, `_` and `.` only, so an id cannot lead out of its folder);
* a byte order mark or a frontmatter at the top: the `GENERATED` header has to
  be line 1 and would push it down, so it would stop being one (two `---` lines
  around prose are a thematic break and are fine);
* a ` ```rule ` line inside another fenced block, such as an example in a
  ` ````markdown ` fence: the loader reads it as a rule, the migration could not
  place it, and it would be lost. A fence of four or more backticks that holds no
  such line is one fence, as for the loader.

A refused document is listed as `refused` and its problems are printed; nothing
of it is converted. The hand-kept table of contents is replaced by `{{toc}}`
with the parameters that give exactly those lines; if none do, the generated
table differs, and the number of lines that change is printed (a real line diff:
a line that is new counts once, not once for every line after it).

**Options.** `--rules-dir=D` and `--layouts-dir=D` name the folders for the rule
files and the layouts (default `_rules` and `_layouts`). A name is written as a
relative path below the ruleset; `./x`, `x/` and `x\y` mean `x`, `x` and `x/y`.
An absolute name, a drive, a `.` or `..` part, or a character a Windows file name
cannot hold is refused before anything is written. The script knows exactly
`--write`, `--rules-dir` and `--layouts-dir` for `migrate`, and `--check` for
`catalog` (`scripts/ruleset.lua check`, which loads all rulesets together and
exits 1 on any load error such as a duplicate id, takes only `--vault` and
`--project`); an unknown flag, a typo (`--chek`), a value on a flag that takes none
(`--write=true`, `catalog --check=1`) or no value on one that needs it is wrong
usage: exit code 2, and nothing is done (a misspelt `--check` must not write the
documents it was meant to check). A path that is not a folder is a problem (exit
code 1), not an empty migration.

**Writing.** With `--write` it first checks that every document can be replaced
and that no target is there already, is the same file as another one (`A-1` and
`a-1` are one on Windows and macOS) or lies outside the ruleset (a symlink or
junction on the way is followed to see where the write would land). Then it
writes the rule files and the layouts, and the documents last: until a document
is replaced, its rules would load twice. After writing, it generates the
documents from the new files and checks that each document it replaced is what
the generator makes; a document that no layout the check reaches produces (a
layout in a folder the walk skips, such as `.deps`) counts as not checked. If a
write fails, or that check fails for a document it replaced, **everything the
run wrote is taken back**: the new files and the folders made for them are
removed, the replaced documents are put back, and the report says so. Fix the
cause and run it again. Trouble elsewhere in the ruleset (another layout with
an error, a rule file that does not load) is reported but is not the migration's
to undo. Run it on a clean git tree: the old documents are replaced by the
generated ones, and `git diff` shows the change.

What stays: the text of every document apart from the blocks (introductions, the
notes in `>` quotes, separators) moves into the layout unchanged. Whether the
migration notes belong in the ruleset at all is a decision for its author; with
the rule files and the layout in place it is a plain edit of the layout.

To prove nothing changed in effect: load the ruleset before and after
(`rules.engine.migrate.compare` does: same ids, severity, `check`, `agent`, text
and title for every rule) and run the gates before and after; both give the same
results.