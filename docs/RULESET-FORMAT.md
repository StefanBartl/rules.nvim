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
| `id` | yes | a stable string, never reused once a rule is retired |
| `severity` | yes | `"critical"` \| `"recommended"` \| `"nice-to-have"` |
| `check` | no | see below — omit it entirely for a rule with no automated check |

A rule's **family** is its ID's leading letters (`"DEP"` for `"DEP-01"`) —
there is no separate family field. `:Rules check --family=<PREFIX>` matches
on this.

## `check` types

| `type` | Fields | What it does |
| --- | --- | --- |
| `grep` | `pattern` (Lua pattern) or `patterns` (list, any-of), `unless` (optional), `include` (optional, default `"%.lua$"`) | flags every line under the checked path matching `pattern`/one of `patterns`, unless it also matches `unless` |
| `file_exists` / `file_absent` | `path` (relative) | a required/forbidden file or directory |
| `json_key_absent` | `path`, `key` (dotted, e.g. `"workspace.library"`) | fails if the key is set in the JSON file; passes if the file or the key is missing |
| `lua_predicate` | `fn(root) -> ok, findings_or_message` | anything the above can't express |

**Why Lua patterns, not regex.** Lua patterns have no `|` alternation — a
pattern like `"foo%(|bar%("` does not mean "foo( or bar("; `|` is a literal
character there, and that pattern would silently match almost nothing. Use
`patterns` (a list) instead of trying to cram alternation into one pattern —
that mistake is documented in this project's own history and is exactly what
`patterns` exists to make unnecessary.

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
