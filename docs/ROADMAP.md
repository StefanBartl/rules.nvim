# Roadmap

## v1

- [x] Engine: ruleset loader, ID-collision check across loaded rulesets
- [x] Check primitives: `grep` (with `patterns` any-of), `file_exists`/`file_absent`, `json_key_absent`, `lua_predicate`
- [x] Fenced `rule`-block parser (Markdown → rule table via `load()`)
- [ ] Gates: `new_project`, `review` (`--diff=<git-ref>`, defaults to diff-scoped), `release`
- [x] `:Rules check --family=<PREFIX> [path]`
- [x] Report: quickfix list + readable buffer with severity icons and a link back to the rule
- [x] `:checkhealth rules`
- [x] `--format=json` for headless/CI use, non-zero exit on a critical finding
- [x] One pilot rule family (`DEP-*`, 7 rules), fully wired end to end in
      `Checklists/regeln/LUA_NVIM.md` and checked against this plugin's own
      source as the first real dry run

Not yet done from the above: the three gates. Deferred until a second rule
family exists to exercise them against, rather than built speculatively
against only `DEP-*`. `--format=json` didn't need that — it only serializes
the same `check_family` results the buffer/quickfix reports already render,
so it carries no risk of over-fitting to one family's shape.

## Deliberately not in v1

- No bundled opinionated rule set — see the README's "Why no bundled rules"
- No auto-fix. A finding is a report line and a quickfix entry, never an edit
- No native (C/C++/Rust/Go) helper binary — the slow part of rule-checking in
  practice is human/agent judgment on non-mechanical rules, not compute; a
  native binary would not speed up the part that is actually slow
- No LuaLS-diagnostics family. That job already belongs to LuaLS + luacheck;
  duplicating it here would just be a second, competing path to the same data

## Later, if the format proves out

- `:Rules migrate-legacy-row <file>` — one-time helper turning an existing
  table-row rule into a heading + fenced `rule` block + prose stub
- A waiver mechanism: a per-repo file recording `{rule_id: reason}` for
  consciously accepted exceptions, so a re-run doesn't re-flag them
- A stable `--format=json` consumer integration (e.g. a documentation browser
  rendering a family's report as one more tab) — depends on another plugin,
  not core to this one
