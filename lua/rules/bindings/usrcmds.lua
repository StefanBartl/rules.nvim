---@module 'rules.bindings.usrcmds'
---@brief The `:Rules <subcommand>` and `:RulesVault <verb>` user commands, built via lib.nvim's composer.

local notify = require("rules.util.notify")

local M = {}

--- Register two argtypes with the shared composer registry so `--family=`
--- and a gate's `<name>` complete against whatever is actually loaded/
--- configured right now, instead of offering nothing. Validation stays
--- permissive (any string passes) -- an unknown family/gate name is already
--- reported by `check_family`/`run_gate` at dispatch time (an empty result
--- set, or `gate.unknown_families`'s warning), so duplicating that check
--- here would just be a second place for the two answers to disagree.
---@return nil
local function register_argtypes()
  local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
  local candidates = require("rules.ui.candidates")

  -- The completions read the scan of the rulesets that the engine keeps (`rules.ui.candidates`): live on every
  -- <Tab>, no parse of the rulesets and no load-error notification per key.
  argtypes.register("RULES_FAMILY", {
    desc = "Family of the rules: the letters before the dash of an id, e.g. DEP",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return argtypes.prefix(candidates.families(), arg_lead)
    end,
  })

  argtypes.register("RULES_PLACE", {
    desc = "Place in a layout: <file>#<section>, or <file> for its top",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return candidates.places(arg_lead)
    end,
  })

  argtypes.register("RULES_RULESET", {
    desc = "Name of a folder of rulesets, as a document names it",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return argtypes.prefix(candidates.ruleset_names(), arg_lead)
    end,
  })

  argtypes.register("RULES_GATE", {
    desc = "Gate from setup({ gates }): a named group of rule families",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      local names = vim.tbl_keys(require("rules.settings").resolve({ project = vim.fn.getcwd() }).gates)
      table.sort(names)
      return argtypes.prefix(names, arg_lead)
    end,
  })

  argtypes.register("RULES_ID", {
    desc = "Exact id of a loaded rule, e.g. DEP-06",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return argtypes.prefix(candidates.ids(), arg_lead)
    end,
  })

  -- the ids `:Rules reinstate` can bring back: retired ones only, an active id is no candidate
  argtypes.register("RULES_RETIRED_ID", {
    desc = "Exact id of a retired rule, e.g. DEP-06",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return argtypes.prefix(candidates.retired_ids(), arg_lead)
    end,
  })

  -- the ids `:Rules renew` and `unwaive` can work on: the rules that have a waiver in the project (its waivers file)
  argtypes.register("RULES_WAIVED_ID", {
    desc = "Exact id of a rule with a waiver in the project, e.g. DEP-06",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead, _, cmd_line)
      return argtypes.prefix(candidates.waived_ids(cmd_line), arg_lead)
    end,
  })

  -- the `--project=` of a waiver verb: a folder, not checked here (the door says when it is none, or outside the working
  -- directory) and not expanded (a `%` or a `$` in a folder name stays as typed)
  argtypes.register("RULES_PROJECT_DIR", {
    desc = "Folder of the project, inside the working directory",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return candidates.project_dirs(arg_lead)
    end,
  })

  argtypes.register("RULES_LAYOUT", {
    desc = "Output path of a layout, e.g. regeln/DEP.md",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return candidates.layouts(arg_lead)
    end,
  })

  argtypes.register("RULES_SECTION", {
    desc = "Heading text of a layout, a blank written as a backslash and a blank",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead)
      return candidates.sections(arg_lead)
    end,
  })
end

--- Create the `:Rules` and `:RulesVault` verbs.
---@return nil
function M.setup()
  register_argtypes()
  -- after RULES_ID and RULES_FAMILY: its <Tab> offers those, and the rulesets of the vault
  require("rules.ui.vault_routes").register_types()
  local composer = require("lib.nvim.bindings.usercmd.composer")

  local routes = {
    {
      path = { "check" },
      args = { { name = "path", type = "DIR", optional = true } },
      flags = {
        { name = "family", type = "RULES_FAMILY", desc = "Rule family to sweep, e.g. DEP for DEP-01 (required)" },
        {
          name = "format",
          type = "STRING",
          values = { "json", "work-list" },
          desc = "Print JSON, or the work list rules-work-list/1 (no quickfix, no buffer)",
        },
      },
      desc = "Sweep one rule family (--family=PREFIX) across PATH (default: cwd), --format=json|work-list: machine-readable",
      run = function(ctx)
        if not ctx.flags.family then
          notify.error(":Rules check needs --family=<PREFIX>, e.g. --family=DEP")
          return
        end
        if ctx.flags.format == "json" or ctx.flags.format == "work-list" then
          local rules = require("rules")
          local run = ctx.flags.format == "json" and rules.check_family_json or rules.check_family_work_list
          local json, _, _, err = run(ctx.flags.family, ctx.args.path)
          if err then
            notify.error(err)
          else
            print(json)
          end
        else
          require("rules").check_family(ctx.flags.family, ctx.args.path)
        end
      end,
    },
    {
      path = { "gate" },
      args = {
        { name = "name", type = "RULES_GATE" },
        { name = "path", type = "DIR", optional = true },
      },
      flags = {
        { name = "diff", type = "STRING", desc = "Only findings in files changed since this git ref (plus untracked)" },
        {
          name = "format",
          type = "STRING",
          values = { "json", "work-list" },
          desc = "Print JSON, or the work list rules-work-list/1 (no quickfix, no buffer)",
        },
      },
      desc = "Run a configured gate (setup({ gates = {...} })), --diff=<git-ref> to scope to that diff",
      run = function(ctx)
        if not ctx.args.name then
          notify.error(":Rules gate needs a name, e.g. :Rules gate release")
          return
        end
        if ctx.flags.format == "json" or ctx.flags.format == "work-list" then
          local rules = require("rules")
          local run = ctx.flags.format == "json" and rules.run_gate_json or rules.run_gate_work_list
          local json, _, _, err = run(ctx.args.name, ctx.args.path, ctx.flags.diff)
          if err then
            notify.error(err)
          else
            print(json)
          end
        else
          require("rules").run_gate(ctx.args.name, ctx.args.path, ctx.flags.diff)
        end
      end,
    },
    {
      path = { "show" },
      args = { { name = "id", type = "RULES_ID" } },
      desc = "Jump to one rule's source location by id, e.g. :Rules show DEP-06",
      run = function(ctx)
        local rule = require("rules").find_rule(ctx.args.id)
        if not rule then
          notify.error(("no loaded rule with id %q"):format(ctx.args.id))
          return
        end

        -- ERR-01: `:edit` is a filesystem boundary that genuinely fails
        -- (the source file moved/deleted since the ruleset was loaded, a
        -- swapfile, an autocmd vetoing the edit) -- a raw Vim error (E37)
        -- must not surface in place of this plugin's own notify style.
        local edit_ok, edit_err = pcall(vim.cmd.edit, vim.fn.fnameescape(rule.source_file))
        if not edit_ok then
          notify.error(("could not open %s: %s"):format(rule.source_file, edit_err))
          return
        end

        local cursor_ok, cursor_err = pcall(vim.api.nvim_win_set_cursor, 0, { rule.source_line, 0 })
        if not cursor_ok then
          notify.warn(("opened %s but could not jump to line %d: %s"):format(rule.source_file, rule.source_line, cursor_err))
        end
      end,
    },
    {
      path = { "stats" },
      flags = {
        {
          name = "format",
          type = "STRING",
          values = { "json" },
          desc = "Print the stats as JSON instead of opening the overview",
        },
      },
      desc = "Structural overview of every loaded rule: per-family totals, automated-vs-manual, severity -- no check run",
      run = function(ctx)
        local stats = require("rules").stats()
        if ctx.flags.format == "json" then
          print(vim.json.encode(stats))
        else
          require("rules.report.stats").open(stats)
        end
      end,
    },
    {
      path = { "catalog" },
      args = { { name = "path", type = "DIR", optional = true, desc = "Ruleset folder (default: every folder in rulesets)" } },
      flags = {
        { name = "check", bool = true, desc = "Only report documents that are out of date, write nothing" },
      },
      desc = "Build the reading documents of a one-file-per-rule ruleset from its layouts; --check for CI",
      run = function(ctx)
        ---Build (or check) and tell what came of it. Returns the documents that are out of date.
        ---@param check boolean
        ---@return string[] stale
        local function report(check)
          local results, errors, code = require("rules").catalog(ctx.args.path, { check = check })
          local counts = { written = 0, unchanged = 0, stale = 0, error = 0 }
          local stale = {}
          for _, result in ipairs(results) do
            counts[result.status] = counts[result.status] + 1
            for _, problem in ipairs(result.problems) do
              notify.error(problem)
            end
            if result.status == "stale" then
              stale[#stale + 1] = result.output
              notify.warn(("%s is out of date -- run :Rules catalog"):format(result.output))
            end
            for _, id in ipairs(result.unused or {}) do
              notify.warn(("rule %s is in no layout"):format(id))
            end
          end
          for _, err in ipairs(errors) do
            notify.warn(err)
          end
          local summary = ("catalog: %d written, %d unchanged, %d stale, %d with errors"):format(
            counts.written,
            counts.unchanged,
            counts.stale,
            counts.error
          )
          if code == 0 then
            notify.info(summary)
          else
            notify.warn(summary)
          end
          return stale
        end

        local check = ctx.flags.check == true
        local stale = report(check)
        -- `--check` only reports (it is what a CI runs); a person at the editor is asked whether to make them now
        if check and #stale > 0 and #vim.api.nvim_list_uis() > 0 then
          local question = ("%d generated document(s) out of date:\n%s\n\nMake them again now?"):format(
            #stale,
            table.concat(stale, "\n")
          )
          require("rules.ui.confirm").yesno(question, "make them again", function(accepted)
            if accepted then
              report(false)
            end
          end)
        end
      end,
    },
    {
      path = { "messages" },
      desc = "Open this plugin's notify history (toast + :messages log)",
      run = function()
        require("lib.nvim.notify.popup").show_history("rules")
      end,
    },
  }
  -- new, set, retire, reinstate, move, list, waive, renew, unwaive: the thin layer over `rules-ops/1` (`rules.ui.routes`)
  vim.list_extend(routes, require("rules.ui.routes").routes())

  composer.verb("Rules", {
    desc = "rules.nvim: check rules against a repo, make, change, retire and move them, waive findings",
    routes = routes,
  })

  -- open, clipboard, link, find, grep, tree, cdx, create: finding the rules in the vault (`rules.ui.vault_routes`)
  composer.verb("RulesVault", {
    desc = "The rules vault: open, copy, link, search and show its rulesets, rules and families; create a vault",
    routes = require("rules.ui.vault_routes").routes(),
    default = function(ctx)
      require("rules.ui.vault_cmd").status(ctx)
    end,
  })
end

return M
