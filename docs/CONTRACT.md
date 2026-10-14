# Machine contract: `rules-export/1`

The read-only contract of rules.nvim: what the engine tells an app, an agent or
CI about a ruleset, in documents with a stable shape. It is built on
`lib.nvim.contract.*` (head, canonical bytes, error codes, request checks, line
protocol), the same base as `tasks-export/1` of tasks.nvim. The write side
(`rules-ops/1`) is separate and not built yet.

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

### `etag` and `etag_scope`

Every rule carries the `etag` of the **file** it lives in (`sha256:` and 16 hex
digits of its bytes): what a later write compares against. `etag_scope = "rule"`
means the rule is the only one in its file (the one-file-per-rule form);
`"file"` means a document with many rules, where a change to any rule changes
the etag of all of them.

### `editable`

A `check` that holds a Lua function (a `lua_predicate`) cannot be written as
data. It is sent without the function and the rule has `editable = false`; a
client shows it read only ("open in Neovim") and never writes it back.

### `next_id`

`basis` says whose ids were looked at: `["loaded"]` today. The ids of retired
rules join (`"retired"`) when `rules-ops/1` defines retiring. The width of the
number follows the family (at least two digits).

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

## Entry points

### Command line

```bash
nvim --headless -u NONE -i NONE -n -l scripts/rules.lua call snapshot --ruleset=/path/to/Checklists
nvim --headless -u NONE -i NONE -n -l scripts/rules.lua call rule --params='{"id":"DEP-06"}' --ruleset=...
nvim --headless -u NONE -i NONE -n -l scripts/rules.lua list --format=json --family=DEP --ruleset=...
```

`--ruleset=<path>` (repeatable, default `$RULES_RULESETS`) and
`--gate=<name>=<FAM,FAM>` (repeatable, default `$RULES_GATES`). The document goes
to stdout. Exit code: 0 an answer, 1 an error document, 2 wrong usage or no
lib.nvim.

### Persistent engine

`scripts/rules-host.lua` answers the same documents over a line protocol on
stdin and stdout (`ready\t1`, then `<id>\t<method>\t<params>` lines; see
`lib.nvim/lua/lib/nvim/contract/host/README.md`). The rulesets and gates come
from `$RULES_RULESETS` (paths separated by `;`) and `$RULES_GATES`
(`name=FAM,FAM;name=FAM`). The process ends when its stdin ends.

The engine keeps its scan of the rulesets while no `.md` file of them changes
(size and modification time; a file changed within the last two seconds is
never trusted), so a question costs milliseconds, not a parse of the ruleset.

### Lua

```lua
local text, code = require("rules.api").call("rule", '{"params":{"id":"DEP-06"}}', { rulesets = { dir } })
```

`opts` is `{ rulesets?, gates? }`; without it the answer comes from `setup()`.

## Tests

`TESTS/contract_spec.lua`: the documents against a fixture ruleset, the error
paths, determinism, no machine path, the host and the golden files. To rewrite
the golden files after a deliberate change, create
`schemas/rules-export/1/golden/.update`, run the specs once, delete the marker
and review the diff.
