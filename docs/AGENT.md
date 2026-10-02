# Agent-run manual rules (planned)

Status: a plan, with its first step built. The parser and the sandboxed block
evaluation (items 1 and 2 below) exist; the agent itself (items 3 to 5) does
not. None of it changes what `:Rules check` and `:Rules gate` report.

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
   function for a host with its own trust list).
3. `engine/agent/plan.lua` and `engine/agent/validate.lua`, pure functions with
   no `vim.api` and no network. `plan(rules, root)` returns requests batched
   per scope: several rules that look at the same files share one request, the
   scope is set per family in `.rules.json` or `setup()` and can be overridden
   per rule. `validate(rule, text, root)` parses the answer and checks every
   quoted line
   against the tree as it is now, dropping what does not occur there. Sending
   the request is the host's job.
4. A verdict store next to `.rules-waivers.json`, written only by an accept.
5. Commands: `:Rules agent <id> | --family=<PREFIX> --manual` (with `--dry-run`
   to print the plan and a size estimate without sending anything) and
   `:Rules review`. The transport is `ai.nvim`'s provider registry, as a soft
   dependency — no second transport lives in this plugin.

A manual rule that names no files to look in and has no `check` to derive leads
from is not sent; it stays `manual`, with the reason. Asking a model about
architecture with no code attached returns a confident answer built on nothing.

## Why the engine has to run without Neovim

The desktop app in `docmap-desktop` does not need Neovim and should keep not
needing it, so it would run this engine inside `documentation.nvim`'s
standalone build, under its `vim` shim. Measured against this repository, the
`engine/`, `config/` and `init.lua` layers call about a dozen `vim.fn.*` and
`vim.fs.*` helpers the shim does not have yet; the report and command layers
stay Neovim-only.
