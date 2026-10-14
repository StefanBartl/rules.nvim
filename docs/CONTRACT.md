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
are files under `<ruleset>/_retired/<FAMILY>/<ID>.md`: the loader does not read
that folder, so a retired rule is never run and never in a gate.

### `load_errors`

A duplicate id across rulesets, an unparseable block: the rule is not in the
document and the message is here, with the ruleset's name instead of its path.
Two rulesets that share an id load only one of them and report the other as a
duplicate; an id is unique across every ruleset that is loaded together (the
native apps' release family is `NREL` for that reason, `REL` is the Lua one).

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
| `new` | `family` (1 to 12 uppercase letters `A-Z`; anything else is `invalid_argument: family must be 1 to 12 uppercase letters A-Z (e.g. DEP)`), `title`, `severity`, `text`?, `check`?, `agent`?, a place?, `ruleset`? | Creates `<ruleset>/_rules/<FAMILY>/<ID>.md` with the next free id (loaded and retired ids count) under the ruleset's lock. With a place the rule also goes into a layout. `inverse`: `retire`. |
| `set` | `id`, `patch` { `severity`?, `title`?, `text`?, `check`?, `agent`? }, `if_match`? | Changes parts of the rule's file by editing lines: everything else (other prose, line endings, the final newline, a `check` or `agent` the patch does not name) stays byte for byte; a block whose fields share a line is written again from its table. `null` for `check` or `agent` removes it. `inverse`: `set` with the values before. |
| `retire` | `id`, `replaced_by`?, `reason`?, `if_match`? | Moves the file to `_retired/` (the id stays taken) and takes the rule out of every layout that holds it. `inverse`: `reinstate` with `places`, one entry for each layout the rule stood in. |
| `reinstate` | `id`, a place? or `places`? | Brings a retired rule back to the file it came from. `places` (`{ "regeln/DEP.md": { "after": "DEP-01" } }`, keyed by the `output` of the layout, goes alone) puts it back into each of those layouts. `inverse`: `retire`. |
| `move` | `id`, a place | Moves the `{{rule ID}}` line of the rule within a layout or to another one; the rule's file is not touched. `inverse`: `move` back. |

A **place** is `after` or `before` (an id that stands in a layout; the layout
is the one that holds it, or the one named by `layout`), `section` (a heading
text) with `layout` (the `output` path of the layout, `regeln/DEP.md`) and
optionally `first`, or `top` with `layout` (the start of the layout: before
the first rule that stands above every heading, else under the frontmatter).

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
```

`--ruleset=<path>` (repeatable, default `$RULES_RULESETS`; `@vault/<name>` is a ruleset of the vault) and
`--gate=<name>=<FAM,FAM>` (repeatable, default `$RULES_GATES`). Without them the
rulesets and gates come from the places in [CONFIG.md](CONFIG.md): `--vault=<dir>`
(else `$RULES_VAULT`) with every folder under its `rulesets/`, and the `.rules.json` of
`--project=<dir>` (else `$RULES_PROJECT`; no project, no project file). The document goes
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
settings files ([CONFIG.md](CONFIG.md)). The process ends when its stdin ends.

The engine keeps its scan of the rulesets while no `.md` file of them changes
(size and modification time; a file changed within the last two seconds is
never trusted), so a question costs milliseconds, not a parse of the ruleset.

### Lua

```lua
local text, code = require("rules.api").call("rule", '{"params":{"id":"DEP-06"}}', { rulesets = { dir } })
```

`opts` is `{ rulesets?, gates?, vault?, project? }`; what it leaves out comes from
`setup()`, the project file and the vault ([CONFIG.md](CONFIG.md)).

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

`TESTS/settings_spec.lua` and `TESTS/vault_spec.lua`: the settings files, the rank, the vault, and that a
vault with two rulesets gives the documents of the same two folders passed one by one (also through the command
line and the host).
