# Agent-run manual rules (planned)

Status: a plan, with its first three steps built. The parser, the sandboxed
block evaluation and the two pure engine functions `plan` and `validate`
(items 1 to 3 below) exist; the store and the commands (items 4 and 5) do not,
so nothing sends a request yet. None of it changes what `:Rules check` and
`:Rules gate` report.

A rule with no `check` is a `manual` result: a worklist entry for "a human or
an agent session". This page is what "an agent session" would concretely be,
seen from this plugin. The whole design, spanning four repositories, is in
`RULES_AGENT_CONCEPT.md`, kept with the author's working notes outside the
repositories; this page lists only what would change **here**.

## The line that does not move

An agent's answer is a proposal, never a verdict:

- a proposal never changes `check_family_json`'s exit code and is never counted
  as a pass;
- only an explicit accept by a person writes a verdict record or a waiver;
- the agent's answer is never itself `verified` — one actor must not both
  propose and verify.

## What would change in this plugin

1. ~~Parser (`engine/parser.lua`).~~ **Built (P0).** It keeps the rule's own
   text (`text`), its heading (`title`) and the section above it (`section`),
   and validates an optional `agent = { question, include, max_files }` field.
   A block without it behaves exactly as before: measured against the real
   corpus (430 rules, 69 files), the old and the new parser find the same
   rules and every one of the 32 checked rules gets the same status. See
   [RULESET-FORMAT.md](RULESET-FORMAT.md).
2. ~~Block evaluation.~~ **Built (P0).** A block body is evaluated in an empty
   environment, under an instruction budget. `lua_predicate` runs only where the
   host trusts predicates (`setup({ lua_predicates = ... })`, or a per-rule
   function for a host with its own trust list) and only in a ruleset the user
   named himself: a ruleset a project `.rules.json` names is not trusted unless
   its folder is in `setup({ trust })`, `--trust` or `$RULES_TRUST`
   ([CONFIG.md](CONFIG.md#a-word-on-trust)). A headless or agent run has no prompt:
   without `--trust` nothing a project file names runs Lua.
3. ~~`engine/agent/plan.lua` and `engine/agent/validate.lua`.~~ **Built.** Pure
   functions with no `vim.api` and no network; sending a request is the host's
   job (see "The two functions" below).
4. A verdict store next to `.rules-waivers.json`, written only by an accept.
5. Commands: `:Rules agent <id> | --family=<PREFIX> --manual` (with `--dry-run`
   to print the plan and a size estimate without sending anything) and
   `:Rules review`. The transport is `ai.nvim`'s provider registry, as a soft
   dependency — no second transport lives in this plugin.

A manual rule that names no files to look in and has no `check` to derive leads
from is not sent; it stays `manual`, with the reason. Asking a model about
architecture with no code attached returns a confident answer built on nothing.

## The two functions

`require("rules.engine.agent.plan").plan(rules, root, opts)` decides, for every
rule **without a `check`**, which files an agent would look at and which rules
share a request. `opts.agent` is the merged `agent` block ([CONFIG.md](CONFIG.md));
absent fields take their defaults. It returns `{ batches, skipped, denied }`.

- **Scope.** The rule's own `agent.include`, else the `include` of its family in
  `agent.scopes`, else none. A rule with none is not sent: it is in `skipped` as
  `manual`, reason `no scope to look in`. So is a rule whose scope matches no file.
- **Deny.** Dropped inside `plan`, so it holds in every host. A built-in list
  (`.env*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `*.kdbx`,
  `id_rsa*` and the other SSH keys, `.netrc`, `.npmrc`, `.pypirc`,
  `.git-credentials`, `credentials.json`) plus `agent.deny`; the built-in list cannot
  be switched off. A glob without a `/` names a file or directory at any depth, one
  with a `/` is relative to the root, and a directory that matches denies everything
  below it. Case is ignored (`KEY.PEM` is a key on NTFS and APFS), and a symbolic link
  is never sent, whatever its name: a link called `notes.txt` can point at a key.
  `denied` lists what a scope reached and the list removed.
- **Size.** A rule whose files add up to more than `agent.max_context_bytes` is not
  cut down; it is in `skipped` as `unclear`, reason `context exceeds limit`. The
  `max_files` of a rule caps its list on purpose, and its batch entry says so
  (`truncated = { total, kept }`).
- **Batches.** Rules that look at exactly the same files share a request, at most
  `agent.batch_size` (8). Rules are ordered by id and files by path, so one tree
  always gives one plan.

`require("rules.engine.agent.validate").validate(rule, text, root, { sent = files })`
turns the raw answer into a **proposal** for one rule. The answer is JSON (one
fenced block is allowed, nothing else around it):

```json
{ "results": [
  { "rule": "DEP-01", "verdict": "violation",
    "checked": ["lua/a.lua"],
    "findings": [ { "file": "lua/a.lua", "line": 12, "quote": "require(\"x\")", "why": "..." } ] }
] }
```

`verdict` is `violation`, `compliant` or `unclear`. Every finding is looked up in the
file as it is now: its quote must occur literally (outer whitespace and line endings
aside) within 3 lines of `line`, in a file that was sent (a symbolic link is not read),
and be at least 4 bytes long (`end` would be found anywhere); a finding that fails is
dropped and listed in `dropped`. The result carries `status`, `findings`, `checked`,
`unchecked` (the sent files the answer does not name: a `compliant` that leaves some
says less than it seems to), `dropped`, `reason`, and always `proposed = true`,
`verified = false`.

What does not hold up is `unclear`, never a guess: text that is not this JSON (the raw
text is attached as `raw`), a rule the answer leaves out or names twice, a `checked`
entry that was not sent, a `violation` none of whose findings survive, a `compliant`
that names no file it looked at or comes with findings. `sent` is required: without
the list of files the request carried, the answer cannot be judged.

Neither function touches `check_family`, and a proposal is never counted as a pass.

## Why the engine has to run without Neovim

The desktop app in `docmap-desktop` does not need Neovim and should keep not
needing it, so it would run this engine inside `documentation.nvim`'s
standalone build, under its `vim` shim. Measured against this repository, the
`engine/`, `config/` and `init.lua` layers call about a dozen `vim.fn.*` and
`vim.fs.*` helpers the shim does not have yet; the report and command layers
stay Neovim-only.
