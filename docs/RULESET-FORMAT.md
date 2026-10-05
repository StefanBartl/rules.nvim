# Ruleset format

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
