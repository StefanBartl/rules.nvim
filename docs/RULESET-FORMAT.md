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

A rule's **family** is its ID's leading letters (`"DEP"` for `"DEP-01"`) —
there is no separate family field. `:Rules check --family=<PREFIX>` matches
on this.

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
`(rule) -> boolean` to `runner.check_family`/`gate.run` (the rule carries its
`source_file`), so one trusted file does not trust every file.

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
given, must be the id's leading letters. Any other key is an error (a typo such
as `severtiy` is not silently ignored). A file with an `id` or a `severity`
in a frontmatter is a rule file; a file whose frontmatter has neither is an
ordinary document.

**Under the frontmatter**, one blank line and then the rule as it reads: the
heading that names it, the prose, a `---` that frames it. `title` and `text` are
read from there exactly as for a document (`text` ends at the next heading;
`section` is not set: which section a rule sits in is the layout's business).
A heading or `#` line inside a fence is not a heading.

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
same limits apply to the id (at most 100 bytes, no control character, and here
also no `"` or `\`), so a rule means the same in either form. An *empty* block
(` ```rule ` and ` ``` ` with nothing between) is valid: it marks where the
block sits in the generated document when the rule file is written by hand with
prose above it.

A rule file has at most one block. Duplicates are found across both forms: an id
in a document and in a rule file is a `duplicate rule id` error, the first wins.

`source_file` is the rule file; `source_line` is the line of the block, or of
the heading when there is none (`:Rules show` jumps there).

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

`output` is the path of the document, relative to the ruleset folder, with `/`;
it must stay inside it, name a `.md` file and not be a layout itself. The body
is the document as it reads, and two kinds of **whole-line** tokens are
replaced; everything else (headings, introductions, separators, notes) is
copied as written:

| Token | Becomes |
| --- | --- |
| `{{rule ID}}` | the rule as it reads in the document: its heading and text, and a ` ```rule ` block with `id` and `severity` put back in (and the rest of the block, if the file has one). The order of the tokens is the order in the document; a rule file carries no order. A rule placed twice, or an id with no rule file, is an error and nothing is written |
| `{{toc}}` | the table of contents of the finished document |

A rule file without a block gets one: right under its heading and the blank
lines below it. A rule file *with* a block keeps it where it is.

**Table of contents.** One line per heading from level 2 on, each a link to its
anchor, without the title (level 1) and without the heading called "Table of
content". A repeated anchor gets `-1`, `-2`. The existing rulesets spell it in
different ways, so the token has parameters (`{{toc max=2 base=0 unicode=1}}`):

| Parameter | Default | Meaning |
| --- | --- | --- |
| `max` | 4 | deepest level listed (2 to 6) |
| `base` | 2 | indentation, in spaces, of level 2 |
| `step` | 2 | further indentation per level |
| `unicode` | 0 | 1: the anchor keeps letters of every alphabet and turns every space into a hyphen (the renderers' way); 0: ASCII only, runs of spaces and hyphens become one hyphen |
| `underscore` | 1 | 0: an anchor drops `_` (only with `unicode = 0`) |

**The generated document** starts with one line,
`<!-- GENERATED by rules.nvim from <layout>: do not edit ... -->`. The loader
skips a file that starts with it, so a document and the rule files it was made
from never load as duplicates; a layout is skipped too. Edit the layout or the
rule files and generate again.

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
compares with the original text; any difference (a CRLF file, a block that does
not start with the `id` and `severity` lines, a block with no heading above it,
no blank line around the block, an id twice) makes it refuse that document and
write nothing at all. The hand-kept table of contents is replaced by `{{toc}}`
with the parameters that give exactly those lines; if none do, the generated
table differs, and the number of lines that change is printed. After writing, it
generates the documents from the new files and checks that they are what it
wrote. Run it on a clean git tree: the old documents are replaced by the
generated ones, and `git diff` shows the change.

What stays: the text of every document apart from the blocks (introductions, the
notes in `>` quotes, separators) moves into the layout unchanged. Whether the
migration notes belong in the ruleset at all is a decision for its author; with
the rule files and the layout in place it is a plain edit of the layout.

To prove nothing changed in effect: load the ruleset before and after
(`rules.engine.migrate.compare` does: same ids, severity, `check`, `agent`, text
and title for every rule) and run the gates before and after; both give the same
results.