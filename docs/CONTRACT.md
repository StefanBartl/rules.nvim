# Machine contract: `rules-export/1` and `rules-ops/1`

The contract of rules.nvim: what the engine tells an app, an agent or CI about
a ruleset (`rules-export/1`, read) and how it takes a change (`rules-ops/1`,
write, below), in documents with a stable shape. It is built on
`lib.nvim.contract.*` (head, canonical bytes, error codes, request checks, line
protocol), the same base as `tasks-export/1` of tasks.nvim. The engine is the
only writer: an app or an agent never edits a rule file itself.

Schema: [`schemas/rules-export/1/rules-export.schema.json`](../schemas/rules-export/1/rules-export.schema.json).
Golden files (the exact bytes the engine writes for a fixture ruleset):
[`schemas/rules-export/1/golden/`](../schemas/rules-export/1/golden/).
TypeScript types: [`schemas/rules-export/1/rules-export.d.ts`](../schemas/rules-export/1/rules-export.d.ts), see
[TypeScript types](#typescript-types).

## TypeScript types

`schemas/rules-export/1/rules-export.d.ts` is **generated** from `rules-export.schema.json` and never edited by hand:
`RulesExport` is the union of every document (`Hello`, `Snapshot`, `List`, `Rule`, `NextId`, `Sources`, `Waivers`,
`Result`, `Error`, told apart by `kind`), and the pieces they share are types of their own (`Head`, `RuleSummary`,
`Severity`, `Waiver`, ...). `Result` is the answer of the write door, the `rules-ops/1` document the schema covers; the
request of `rules-ops/1` is not in the schema and so not in the types.

```bash
nvim --headless -u NONE -i NONE -n -l scripts/contract-dts.lua --write   # after a change to the schema; commit the diff
nvim --headless -u NONE -i NONE -n -l scripts/contract-dts.lua --check   # exit 1 when the file is stale (the default)
```

The generator (`scripts/contract/dts.lua`, driven by `scripts/contract-dts.lua`) is a small Lua program that nvim
runs: no Node and no package in this repository, unlike `tasks-export/1` of tasks.nvim, which uses
`json-schema-to-typescript`. It maps the subset of JSON Schema this schema uses (`type`, `enum`, `const`, `$ref` to
`#/$defs/...`, `oneOf` / `anyOf` as a union, `allOf` as an intersection, `properties`, `required`,
`additionalProperties`, `items`; `title` and `description` become comments; `pattern`, `minimum`, `maxItems` and the like
change no type). **A keyword outside that subset stops the generator** with its name and its place in the schema
(`unsupported keyword 'prefixItems' at #/$defs/x/properties/y`), exit code 1: a type is never `any`. If the schema grows
such a keyword, extend the generator first.

How the types read:

- An object that lists its properties is **closed**: no index signature, so a typo in a field name is a type error. A
  reader at run time still ignores fields it does not know ([Rules the documents keep](#rules-the-documents-keep));
  the type just does not promise any. An object without properties (`check`, `inverse`, `diff`, `details`) is a
  dictionary, `{ [k: string]: unknown }`.
- A field is optional (`name?:`) unless the schema lists it in `required`. A document is a **`Head &` something**, and
  `required` of the part may name a field only the head declares (`digest`, `rev`): it is then written `digest: unknown`
  and, in the intersection with the head's `digest?: string`, comes out as a required string.
- Keys are sorted, LF only, one final newline: the same schema always gives the same bytes. The header names the schema it
  came from.
- The file is the one the schema generates now, or CI is red: `TESTS/contract_dts_spec.lua` compares it (in process and
  through the command line, which also proves the exit codes) and the `tests` job of `.github/workflows/ci.yml` has the
  step `Contract declarations are current`. A client checks its own use against the golden files: every document in
  `schemas/rules-export/1/golden/` is a valid value of its type (checked once with `tsc`, not in this repository's CI).

## Rules the documents keep

- **No path of this machine.** A file is `<ruleset folder>/<path inside it>`; the
  root inside a message becomes the ruleset's name.
- **Canonical bytes**: sorted keys, same document, same bytes. `digest` is the hash
  of the document without `generated_at` and `engine`, so two runs on an unchanged
  source have the same digest.
- **At most 8 MiB** per document; a bigger one is the error `payload_too_large`
  (ask for a page or one family).
- **Never throws.** Every failure is a `rules.error` document with a stable `code`
  (`invalid_argument`, `not_found`, `unsupported_schema`, `payload_too_large`,
  `io`, `internal`) and `retryable`.
- **A reader ignores fields it does not know**; a request with an unknown
  parameter is refused (`invalid_argument`), a higher `schema` is
  `unsupported_schema`.

## Methods

A request is `{ "schema": 1, "params": { ... } }`; `schema` and `params` may be
left out. At most 256 KiB.

| Method | Parameters | Answer (`kind`) |
| --- | --- | --- |
| `hello` | none | `rules.hello`: schemas, capabilities, limits, enums. Reads no rule. |
| `snapshot` | none | `rules.snapshot`: counts, families (with severity counters), every rule (summary), sources, gates, `load_errors`. |
| `list` | `family`, `severity`, `limit` (1..500, default 100), `offset` | `rules.list`: a page of rule summaries in id order. |
| `rule` | `id` (required) | `rules.rule`: one rule with `text`, `check` and the `etag` of its file. |
| `next_id` | `family` (letters) | `rules.next_id`: the next free id of a family, or of every family. |
| `sources` | none | `rules.sources`: the files, each with its `etag`. |
| `waivers` | `project` | `rules.waivers`: the waivers of a project, each with `expired` and `known`, see [Waivers](#waivers). |
| `rulesets` | none | `rules.rulesets`: the loaded rulesets (`name`, `folder`, `in_vault`; an empty one too) and the `archived` folder names of the vault, see [Rulesets](#rulesets). No path. |
| `ops` | `client_op_id`, `dry_run`, `ops` (flat: the fields are the request's own) | `rules.result`: one entry per operation, see [rules-ops/1](#rules-ops1-write). |

### `etag` and `etag_scope`

Every rule carries the `etag` of the **file** it lives in (`sha256:` and 16 hex
digits of its bytes): what a later write compares against. `etag_scope = "rule"`
means the rule is a file of its own (the one-file-per-rule form, the only one
`rules-ops/1` writes); `"file"` means a document that holds rules, where a
change to the document changes the etag of every rule in it.

### `editable`

A `check` that holds a Lua function (a `lua_predicate`) cannot be written as
data. It is sent without the function and the rule has `editable = false`; a
client shows it read only ("open in Neovim") and never writes it back.

### `next_id`

`basis` says whose ids were looked at: the loaded rules and the retired ones
(`["loaded", "retired"]`). An id is never given twice, so a retired rule keeps
its number. The width of the number follows the family (at least two digits).
An id may have any number of digits (up to the 100 bytes an id may have) and
`next` stays exact; `highest` is a JSON integer and is held at 2^53 - 1
(9007199254740991) where the real number is larger. Where the next id would be
longer than 100 bytes, the family has no id left and the item has no `next`.

### `retired`

`snapshot.retired` lists the rules that were retired (`id`, `family`,
`source`, and `replaced_by`, `retired` (the date) and `reason` when given). They
are files under `<ruleset>/_retired/<FAMILY>/<ID>.md`: the loader does not run
that folder, so a retired rule is never run and never in a gate. It does read the
ids there: a live rule with the id of a retired one is a `duplicate rule id` entry
of `load_errors`, and `next_id` counts the same files (the id of the file name, and
that of the frontmatter when it is another one).

### `load_errors`

A duplicate id across rulesets, an unparseable block: the rule is not in the
document and the message is here, with the ruleset's name instead of its path.
Two rulesets that share an id load only one of them and report the other as a
duplicate; an id is unique across every ruleset that is loaded together (the
native apps' release family is `NREL` for that reason, `REL` is the Lua one).

A gap in the numbering of a family (`DEP-01`, `DEP-03`) is **not** a load error and is in no
document: it is a hint the engine keeps apart (`rules.contract.gaps`), which
`scripts/ruleset.lua check --gaps` shows ([RULESET-FORMAT.md](RULESET-FORMAT.md#gaps-in-the-numbering)).

A ruleset goes by the last part of its path (`Checklists`); only when two
rulesets would get the same name, the folder above is added
(`wkdbook-Lua/Checklists`). A name is never taken from higher up than that, so
a document does not carry a folder of the machine (a user name).
Two rulesets that still share a name (two checkouts with the same folder names)
are told apart by a number in the order of the configuration: the first keeps
the name, the next ones are `Checklists#2`, `Checklists#3`. A ruleset that is
listed twice, or spelled another way (a trailing slash, `/./`, another case on
Windows and macOS), is one ruleset: it is named, counted and scanned once.

## rules-ops/1 (write)

A request is `{ "schema": 1, "client_op_id": "c-81f2", "dry_run": false,
"ops": [ { "op": "set", "id": "DEP-06", "patch": { "severity": "critical" } } ] }`,
at most 100 operations. The **whole request is checked first** (an unknown
operation or field, a wrong type): then nothing runs. After that every
operation runs on its own; one that fails does not stop the others, and `ok`
is true only if all entries are. `dry_run` checks everything and writes nothing.

| Operation | Fields | What it does |
| --- | --- | --- |
| `new` | `family` (1 to 12 uppercase letters `A-Z`, or a family the ruleset has already, in exactly its spelling (`Dep-01` goes on with `Dep-02`); anything else is `invalid_argument: family must be 1 to 12 uppercase letters A-Z (e.g. DEP), or a family the ruleset has, spelled as there`), `title`, `severity`, `text`?, `check`?, `agent`?, a place?, `ruleset`? | Creates `<ruleset>/_rules/<FAMILY>/<ID>.md` with the next free id (loaded and retired ids count) under the ruleset's lock. With a place the rule also goes into a layout. `text` is stored as given: the engine neither wraps nor joins lines (a client that wants lines of 78 columns wraps before it asks; `:Rules new` and its form send the text as typed). The file ends with the divider `---` between blank lines, as the rule files of the shipped rulesets do (see "The divider" below). `inverse`: `retire`. The entry may carry `warnings` (see below). |
| `set` | `id`, `patch` { `severity`?, `title`?, `text`?, `check`?, `agent`? }, `if_match`? | Changes parts of the rule's file by editing lines: everything else (other prose, line endings, the final newline, a `check` or `agent` the patch does not name) stays byte for byte; a block whose fields share a line, or whose fields start with the separator (comma-first style), is written again from its table, and so is a block that gives the key twice when the key is removed (when it is set, the last one, which is the one that counts, is replaced). `null` for `check` or `agent` removes it. `inverse`: `set` with the values before. |
| `retire` | `id`, `replaced_by`?, `reason`?, `if_match`? | Moves the file to `_retired/` (the id stays taken) and takes the rule out of every layout that holds it. `inverse`: `reinstate` with `places`, one entry for each layout the rule stood in. |
| `reinstate` | `id`, a place? or `places`? | Brings a retired rule back to the file it came from. `places` (`{ "regeln/DEP.md": { "after": "DEP-01" } }`, keyed by the `output` of the layout, goes alone) puts it back into each of those layouts. `inverse`: `retire`. |
| `move` | `id`, a place | Moves the `{{rule ID}}` line of the rule within a layout or to another one; the rule's file is not touched. `inverse`: `move` back. |
| `waive` | `id`, `reason`, `expires`?, `paths`?, `project`?, `if_match`? | Adds the waiver of a project's `.rules-waivers.json` (not a ruleset file). `inverse`: `remove`. See [Waivers](#waivers). |
| `renew` | `id`, `expires` or `no_expiry`, `reason`?, `project`?, `if_match`? | Gives a waiver a new last day. `inverse`: `renew` back. |
| `remove` | `id`, `project`?, `if_match`? | Drops a waiver. `inverse`: `waive` with the old values. |
| `create_ruleset` | `name` | Makes a ruleset in the vault: `rulesets/<name>/_rules/.gitkeep` and `_layouts/.gitkeep`, and adds `rulesets/<name>` to the `rulesets` list of the vault's `.rules.json` when that file has a list that does not offer it. `name`: letters, digits, `.`, `_`, `-`, starting with a letter or digit, no Windows device name. A folder of that name in any letter case is `conflict`. `inverse`: `archive_ruleset`. See [Rulesets](#rulesets). |
| `archive_ruleset` | `name` | MOVES `rulesets/<name>` to `archive/rulesets/<name>` and takes it out of the `.rules.json` list. Never deletes. The last ruleset of the vault is not archived (`invalid_argument`); a name already in the archive is `conflict`. `inverse`: `restore_ruleset`. |
| `restore_ruleset` | `name` | Moves `archive/rulesets/<name>` back and lists it again. `inverse`: `archive_ruleset`. |

A **place** is `after` or `before` (an id that stands in a layout; the layout
is the one that holds it, or the one named by `layout`), `section` (a heading
text) with `layout` (the `output` path of the layout, `regeln/DEP.md`) and
optionally `first` and `nth`, or `top` with `layout` (the start of the layout:
before the first rule that stands above every heading, else under the
frontmatter). Four more fields refine a place and are what `retire` and `move`
answer with (`inverse`): `nth` (a whole number from 1, with `section` only: the
n-th heading of that text, when several have it; the first by default), `line`
(a whole number from 1, with `section` only and not with `first`: the token goes
behind the n-th line of the section, its heading being line 1; the line must lie
inside the section and outside a fenced code block or an HTML comment), `around`
(a text, with `line` only: the fingerprint, `sha256:` and 16 hex digits, of the
line the token goes behind and the next line that is not blank; when the layout
no longer has those two lines there, the place is refused instead of putting the
token into the middle of the author's text) and `gap` (`{ "above": n, "below":
m }`, 0 to 100 each: the blank lines that stood directly above and below the
token, which the token is then put back between, exactly). `line` and `around`
are optional and new; an `inverse` without them means what it meant before, and
a `line` without `around` is put behind that line unchecked.

- **Where in a section.** A section is a heading up to the next heading of the
  same or a higher level. With rules in it, the token goes behind the last of
  them (those of its subsections included), or in front of the first one of its
  own text, the lines before its first subheading, with `first`. A section
  **without a rule of its own** has an introduction (the text under the heading,
  up to the next heading of any level); that is not a rule, so the token goes
  behind it, for the end and for `first` alike (for `first` also when only a
  subsection holds rules), with one blank line in front of the token and one
  behind it (blank lines the author left in front of the next heading, or at the
  end of the layout, stay behind the token). In the last section of a layout the
  token goes at the very end. The headings and the introductions keep their
  order and are never touched.
- **What is a heading or a token.** A line outside the frontmatter, outside a
  fenced code block (three or more backticks or tildes, up to three spaces of
  indentation, closed by the same character at least as long; never closed: to the
  end) and outside an HTML comment (`<!--` to `-->`, over several lines). A `#` or
  `{{rule ID}}` line inside one is no heading and no token for a place, for
  finding or for taking out. The generator fills every whole-line token, also
  one in a fence or a comment; the editor refuses to put an id a second time
  that stands there.
- **Undoing.** Taking a token out takes a blank line left doubled by it, and the
  blank line before a token at the very end of the layout, with it, so `new`
  followed by its `inverse` leaves the layout as it was (one exception: into a
  section whose heading follows its introduction with no blank line in between,
  `new` writes a blank line behind the token that taking it out leaves). `retire`
  records where the token stood (`after` the rule above it in its section, else
  `section` + `first`, else `before` the rule below it, else the end of its
  section, else `section` + `line` + `around` (a token between two pieces of the
  author's text: `Intro`, token, `More`; refused when that text has changed
  since); `top` above every heading; `nth` where the heading
  is not the first of its text; `gap` where the way `new` puts a token in would not
  write the blank lines it had), so `reinstate` gives the layout back byte for
  byte. Above every heading there is no `line`: a token that stands there between
  two pieces of text comes back behind the rule above it, else at the top.
- **The divider.** A rule file ends with a blank line, `---` and a blank line;
  the generator copies the lines of a rule file as they are, so this is what
  keeps the rules of a document apart. `new` writes it itself: a `text` that
  ends with `---` (with or without blank lines after it) is not given a second
  one, any other text gets it, and so does a rule without a text. A caller does
  not have to know the convention, and the divider is no part of the `text`
  that reads back. A divider line at the end of the text (`---`, `***`, `___`) that
  stands right under a line of text gets a blank line in front of it, else the
  line above would be a heading (`foo` over `---`). CR LF line ends in a `text` are
  line ends (a lone CR is still a control character and refused): the file is
  written with LF, or with the CR LF of the file that is changed, never both. A
  `set` of `text` to nothing leaves one blank line in front of the divider, the
  file of a rule made without a text. The generator does not add dividers: the rulesets differ
  (some documents have none), and a generated document must stay byte for byte
  what the rule files and the layout say.
- **Warnings.** An entry of `new` (also in a `dry_run`) may carry `warnings`, a list of texts: things to know that did not
  stop the operation (`waive` and `renew` have one of their own, see [Waivers](#waivers)). For `new` there is one: the rules-vault the ruleset lies in is a git repository that is behind its
  upstream (`git rev-list --count HEAD..@{u}`, read only, no network, a short timeout), so another machine may make the same
  id: *pull before you create*. The field is absent when there is nothing to say, and always absent without git, without an
  upstream or for a ruleset outside the vault. It is additive: `schema` stays `1`, no golden file changes (the fixtures are no
  git repository), a client that does not know it ignores it. The engine never pulls, fetches or commits; a duplicate id is a
  `load_errors` entry of the `snapshot` document, not a warning of the write.
- **Compare-and-set.** `if_match` is the `etag` the client saw. A file that is
  another version is a `conflict` entry with `details.expected` and
  `details.actual`; nothing is written.
- **One writer.** Every operation takes the lock of the ruleset
  (`<ruleset>/.rules-ops`); a held lock is `locked` (retryable).
- **A step back.** An operation that touches several files puts them back when
  a later step fails. What could not be put back is named
  (`rollback_incomplete`, `details.not_restored`).
- **Checked before it is written.** The new text is read back with the loader's
  own parser and compared with what was asked for: a text with a heading in it
  (it would end the text of the rule), an invalid `agent`, a check that does
  not read back is refused (`invalid_argument`), never written.
- **Not every rule.** A rule in a document (`etag_scope = "file"`) is not
  written: migrate it first (`scripts/ruleset.lua migrate`). A rule whose
  check holds a Lua function is not patched in `check` or `agent`, nor a block
  with a comment; the prose and the severity of such a rule can still change.
- **The documents.** After a write the generated documents (`catalog`) are made
  again, once; each changed entry says how many were written and how many had
  an error, for its own ruleset. A ruleset whose operation started to write is
  made again also when the operation failed after it started to write (a step
  back that fails leaves files half changed).

## Rulesets

`create_ruleset`, `archive_ruleset` and `restore_ruleset` change the **vault** (which rulesets it holds), not a ruleset's rules.
They work in the vault the engine was started with (`$RULES_VAULT`, `setup({ vault })`) and name a ruleset by its folder
name only: no path comes from the request and none is echoed. An entry of these operations has `ruleset` (the folder name)
and no `id`, and `changed_ids` is empty. A request needs at least one ruleset to be loaded, so the first ruleset of a
vault is made with `:RulesVault create`, not here.

The vault's `.rules.json` is edited as text: only the `rulesets` list changes, the rest of the file stays byte for byte.
A file without a list offers every folder under `rulesets/`, and is not touched. A `.rules.json` the engine cannot read refuses the
whole request before anything moves. One writer at a time over the vault (a hidden lock file beside the vault's `.rules.json`,
removed again); an operation that fails half way puts back what it moved. Archived rulesets lie under `archive/rulesets/` in the vault:
outside `rulesets/`, so no scan reads them, and still inside the repository, so git keeps their history.

## Waivers

The waivers of a project (`.rules-waivers.json`, format in [CONFIG.md](CONFIG.md#rules-waiversjson)) are read by
`waivers` and written by `waive`, `renew` and `remove`. They live in the **checked project**, not in a ruleset: the
operations do not take the lock of a ruleset, do not touch a rule or a layout, and make no catalog.

### The project

`project` (a field of each waiver operation, a parameter of `waivers`) is the folder whose `.rules-waivers.json` is meant.
Left out, it is the project the engine was configured with (`opts.project`, `--project=<dir>`, `$RULES_PROJECT`, in the
editor the working directory); with none, the request is `invalid_argument`. A given project is checked:

- it has no `..` and no control character; a relative one starts at the configured project (and needs one);
- it is a folder that exists (`not_found`), and is taken by its **real path**, so a link, a short Windows name or `/var`
  against `/private/var` is the same folder;
- with a configured project it must be that project or a folder inside it (`invalid_argument`): a request does not
  reach further than the engine was pointed;
- it is never inside a ruleset (`invalid_argument`): a waiver belongs to the project that is checked, not to a ruleset.
  A ruleset that **is** the configured project (a vault checking itself), or a project that holds the rulesets, is fine.

No answer names the project: messages say "the project" and "the waivers file", never a path of this machine.

### The file

- Written **canonically**: sorted keys, two spaces, LF and a final newline. A waiver with only a reason is written as
  the short text (`"DEP-01": "reason"`), any other as an object. The file is written again whole, so an entry nobody
  touched keeps its **meaning** (and its form) but may change its layout and its place; it is a rewrite, not a patch.
- Atomic (a temporary file beside it, renamed over it) and under a lock of its own, a hidden
  `.rules-waivers.json.lock` beside the file (`lib.nvim` `with_lock`); a held lock is `locked` (`retryable`). A lock
  or write failure says so without the path.
- `if_match` is the `etag` of the **file**; a project without one has the etag of an empty file
  (`sha256:e3b0c44298fc1c14`), so "create it only if nobody did" works. The `rules.waivers` document carries the current
  `etag`.
- A file that exists and cannot be used (not JSON, an unknown key, a bad date, an empty file, a folder) is
  `invalid_argument` and is **not** touched; a link where the file belongs is `forbidden` (the write would replace the
  link).
- At most 500 waivers in a file (`payload_too_large` beyond that).

### The operations

| Operation | Fields | What it does |
| --- | --- | --- |
| `waive` | `id`, `reason`, `expires`?, `paths`?, `project`?, `if_match`? | Adds the waiver of a rule. The rule must be **loaded** (an id no ruleset has is `invalid_argument`; the trust gate does not matter, a waiver runs no code). `reason`: required, says something, one line, no control character, at most 500 characters. `expires`: `YYYY-MM-DD`, a real day. `paths`: a list of 1 to 50 distinct paths (see CONFIG.md). A waiver that is there already is `invalid_argument` (renew or remove it); the very same one again is `unchanged`. `inverse`: `remove`. |
| `renew` | `id`, `expires` or `no_expiry: true`, `reason`?, `project`?, `if_match`? | Gives a waiver a new last day (or none) and optionally a new reason; the `paths` stay. `expires` or `no_expiry` is required, not both. No waiver for the id: `not_found`. Renewing an expired waiver is what it is for. The same values again are `unchanged`. `before`: `{ expires }` or `{ no_expiry: true }`, and `reason` when it changed. `inverse`: `renew` with those. |
| `remove` | `id`, `project`?, `if_match`? | Drops the waiver; the rule does not have to exist (a waiver of a retired rule is removed this way). No waiver: `not_found`. The last waiver leaves a file with `{}`. `before`: the waiver (`reason`, `expires`?, `paths`?). `inverse`: `waive` with those values (it needs the rule to be loaded again). |

An entry has `etag_before` and `etag_after` (of the file), `changed_ids` (the rule id), the `before` and `inverse` above,
and with `dry_run` the outcome `would_waive`, `would_renew` or `would_remove` and `diff` (`before` and `after`, the whole
file text), and nothing written. Outcomes: `waived`, `renewed`, `removed`, `unchanged`, `conflict`, `failed`. `inverse`
carries `if_match` (the etag after) and **no `project`**: send it with the same `project` as the request it undoes (or
none, for the configured one); the `if_match` stops a replay against another folder.

Errors: `invalid_argument` (a bad id, reason, date, path or project, an unknown rule for `waive`, a file that cannot be
used, a waiver there already), `not_found` (no waiver to renew or remove; a project that is not a folder), `conflict`
(`details.expected`, `details.actual`), `locked` (retryable), `forbidden` (a write, and the file is a link; reads follow it), `payload_too_large`,
`io`.

**A date in the past** is not refused: `waive` or `renew` with an `expires` before today succeeds and the entry carries a
`warnings` text (the waiver is expired from the start and suppresses nothing). The `inverse` of a `renew` or a `remove` of
an expired waiver has to be able to put that date back. The editor commands `:Rules waive`, `renew` and `unwaive` are this door and
nothing else ([BINDINGS.md](BINDINGS.md#waiving-findings)); they show the warning at warn level.

### `waivers` (read)

`waivers` { `project`? } answers `rules.waivers`: `today` (the day the expiry is judged against), `etag` and `exists` (of the
file), `counts` (`total`, `expired`, `unknown`) and `items` in id order: `id`, `reason`, `expires`?, `paths`?, `expired`
(the last day is before `today`) and `known` (a loaded rule has the id; false: the waiver protects nothing). A file that
cannot be used is an error document, never an empty list. A report of a check (`check_family_json`, `run_gate_json`)
marks the same fact per rule: `expired_waiver`, `waiver_expires`, `waiver_paths`, `partial_waiver`
([BINDINGS.md](BINDINGS.md#waivers)); `scripts/ruleset.lua check --waivers --project=<dir>` exits 1 on an expired waiver
(CI).

"Today" is the machine's local calendar date; `opts.today` (`YYYY-MM-DD`) of `rules.api` and `rules.ops` fixes it for a
reproducible run (a bad value is `invalid_argument`).

## Entry points

### Neovim

`:Rules new`, `set`, `retire`, `move` and `list` are a thin layer over `rules-ops/1` and `rules-export/1`
(`rules.write`, `rules.ui.cmd`, [BINDINGS.md](BINDINGS.md#making-changing-retiring-and-moving-rules)): a command line
or the Markdown form becomes one operation of the door, `dry_run` first where the user is asked, the answer is told as it
is. The editor has no write logic of its own; after a write it reloads the open buffers of the files that changed and
reports one with unsaved changes as a conflict.

### Command line

```bash
nvim --headless -u NONE -i NONE -n -l scripts/rules.lua call snapshot --ruleset=/path/to/Checklists
nvim --headless -u NONE -i NONE -n -l scripts/rules.lua call rule --params='{"id":"DEP-06"}' --ruleset=...
nvim --headless -u NONE -i NONE -n -l scripts/rules.lua list --format=json --family=DEP --ruleset=...
# not a document: where the file of a rule is, two plain lines (the file, the ruleset it came from), for a program on
# this machine; the name in `source` cannot be turned back into a place by a client. A client puts the id after `--`:
# a rule id may look like a flag, and what follows `--` is always the id
nvim --headless -u NONE -i NONE -n -l scripts/rules.lua locate --ruleset=... -- DEP-06
```

`--ruleset=<path>` (repeatable, default `$RULES_RULESETS`; `@vault/<name>` is a ruleset of the vault) and
`--gate=<name>=<FAM,FAM>` (repeatable, default `$RULES_GATES`). Without them the
rulesets and gates come from the places in [CONFIG.md](CONFIG.md): `--vault=<dir>`
(else `$RULES_VAULT`) with every folder under its `rulesets/`, and the `.rules.json` of
`--project=<dir>` (else `$RULES_PROJECT`; no project, no project file), and `--trust=<dir>`
(repeatable, also `$RULES_TRUST`; see [CONFIG.md](CONFIG.md#a-word-on-trust)). The document goes
to stdout. Exit code: 0 an answer, 1 an error document, 2 wrong usage or no
lib.nvim. A `--limit` or `--offset` that is not a whole number (`2.5`, `inf`,
`nan`) is an `invalid_argument` error document, exit code 1; text that is no
number at all is wrong usage, exit code 2.

### Persistent engine

`scripts/rules-host.lua` answers the same documents over a line protocol on
stdin and stdout (`ready\t1`, then `<id>\t<method>\t<params>` lines; see
`lib.nvim/lua/lib/nvim/contract/host/README.md`). The rulesets and gates come
from `$RULES_RULESETS` (paths separated by `;`) and `$RULES_GATES`
(`name=FAM,FAM;name=FAM`), else from `$RULES_VAULT`, `$RULES_PROJECT` and the
settings files ([CONFIG.md](CONFIG.md)); `$RULES_TRUST` lists the folders to trust (the host runs no check itself, see
[A word on trust](CONFIG.md#a-word-on-trust)). The process ends when its stdin ends.

The engine keeps its scan of the rulesets while no `.md` file of them changes
(size and modification time; a file changed within the last two seconds is
never trusted), so a question costs milliseconds, not a parse of the ruleset.

### Lua

```lua
local text, code = require("rules.api").call("rule", '{"params":{"id":"DEP-06"}}', { rulesets = { dir } })
```

`opts` is `{ rulesets?, gates?, vault?, project?, trust?, today? }`; what it leaves out comes from
`setup()`, the project file and the vault ([CONFIG.md](CONFIG.md)). `trust` is a list of
folders (`--trust=<dir>` of the scripts, `$RULES_TRUST` for every entry point): the
contract itself runs no check, the option only tells which rulesets are trusted for a
tool that does ([CONFIG.md](CONFIG.md#a-word-on-trust)). It adds no field to a document.

A vault with two rulesets yields the same documents as passing both folders
explicitly; `source` stays the ruleset's folder name (`lua`, `native`), never a
path of this machine. A settings file that cannot be used (not JSON, a value of
the wrong shape) or a vault that is no folder is an `invalid_argument` document
whose message names the kind of file (`project .rules.json`, `vault .rules.json`,
`$RULES_VAULT`) and the key, with no path.

## Tests

`TESTS/contract_spec.lua`: the documents against a fixture ruleset, the error
paths, determinism, no machine path, the host and the golden files. To rewrite
the golden files after a deliberate change, create
`schemas/rules-export/1/golden/.update`, run the specs once, delete the marker
and review the diff.

`TESTS/contract_dts_spec.lua`: the generator of the TypeScript types on small schemas, what it refuses by name, and the
committed `rules-export.d.ts` against the schema ([TypeScript types](#typescript-types)).

`TESTS/settings_spec.lua` and `TESTS/vault_spec.lua`: the settings files, the rank, the vault, and that a
vault with two rulesets gives the documents of the same two folders passed one by one (also through the command
line and the host).
