/* Generated from schemas/rules-export/1/rules-export.schema.json by scripts/contract-dts.lua. Do not edit. */

/**
 * rules-export/1
 *
 * Every document rules.nvim hands to a machine (read only). One of the kinds below, told apart by `kind`. A reader ignores fields it does not know: inside one version the contract only grows. The golden files next to this schema are the documents the engine writes.
 */
export type RulesExport = Hello | Snapshot | List | Rule | NextId | Sources | Waivers | Result | Error;

/**
 * rules.error: what went wrong, in a code that is stable.
 */
export type Error = Head & {
  code: "invalid_argument" | "not_found" | "unsupported_schema" | "payload_too_large" | "io" | "internal";
  kind: "rules.error";
  message: string;
  retryable: boolean;
};

export type Head = {
  /**
   * hash of the document without generated_at and engine
   */
  digest?: string;
  engine: {
    git: string;
    nvim: string;
    version: string;
  };
  /**
   * UTC, YYYY-MM-DDTHH:MM:SSZ; not part of the digest
   */
  generated_at: string;
  kind: string;
  plugin: "rules.nvim";
  /**
   * what the source looked like; present on documents that come from a scan
   */
  rev?: string;
  schema: 1;
  source: {
    /**
     * the last part of the first ruleset path; never a path of this machine
     */
    id: string;
  };
};

/**
 * rules.hello: what this engine is and can do. Reads no rule.
 */
export type Hello = Head & {
  capabilities: string[];
  enums: {
    severity?: string[];
  };
  kind: "rules.hello";
  limits: {
    doc_bytes?: number;
    list_items?: number;
    request_bytes?: number;
  };
  /**
   * the operations of rules-ops/1 the engine knows
   */
  ops?: string[];
  /**
   * false when the engine has the write door (`ops`)
   */
  read_only: boolean;
  schemas: number[];
};

/**
 * rules.list: a page of rules, in id order.
 */
export type List = Head & {
  digest: unknown;
  items: RuleSummary[];
  kind: "rules.list";
  limit: number;
  offset: number;
  rev: unknown;
  total: number;
};

/**
 * rules.next_id: the next free id of a family, or of every family.
 */
export type NextId = Head & {
  /**
   * whose ids were looked at; `retired` joins when rules-ops/1 defines retiring
   */
  basis: ("loaded" | "retired")[];
  digest: unknown;
  items: {
    count?: number;
    family?: string;
    highest?: number;
    /**
     * absent where the next id would be longer than an id may be (100 bytes)
     */
    next?: string;
  }[];
  kind: "rules.next_id";
  rev: unknown;
};

/**
 * rules.result: the answer of the write door (rules-ops/1), one entry per operation.
 */
export type Result = Head & {
  client_op_id?: string;
  digest: unknown;
  dry_run: boolean;
  kind: "rules.result";
  /**
   * true only if every entry is
   */
  ok: boolean;
  results: {
    /**
     * set: the values the patch replaced, in the shape of a patch; renew: the expiry (and reason) it replaced, as the fields of a renew; remove: the waiver that was dropped (reason, expires, paths)
     */
    before?: { [k: string]: unknown };
    /**
     * the documents made again after the write
     */
    catalog?: {
      errors?: number;
      written?: number;
    };
    changed_ids: string[];
    /**
     * dry run of set, waive, renew, remove: the file text before and after
     */
    diff?: { [k: string]: unknown };
    error?: {
      /**
       * invalid_argument, not_found, conflict (details: expected, actual), locked, forbidden (the waivers file is a link), payload_too_large, io, rollback_incomplete (details: not_restored), internal
       */
      code?: string;
      details?: { [k: string]: unknown };
      message?: string;
      retryable?: boolean;
    };
    etag_after?: string;
    etag_before?: string;
    id?: string;
    /**
     * the operation that undoes this one
     */
    inverse?: { [k: string]: unknown };
    n: number;
    ok: boolean;
    op: "new" | "set" | "retire" | "reinstate" | "move" | "waive" | "renew" | "remove";
    /**
     * created, changed, unchanged, retired, reinstated, moved, waived, renewed, removed, would_*, conflict, failed
     */
    outcome?: string;
    placed?: {
      layout?: string;
    };
    /**
     * things to know that did not stop the operation; absent when there are none. new: the rules-vault is behind its upstream, so another machine may make the same id. waive, renew: expires is before today, so the waiver is expired from the start
     */
    warnings?: string[];
  }[];
};

export type Retired = {
  family: string;
  id: string;
  reason?: string;
  replaced_by?: string;
  /**
   * the date it was retired, YYYY-MM-DD
   */
  retired?: string;
  source: string;
};

/**
 * rules.rule: one rule with its text, its check and the etag of its file.
 */
export type Rule = Head & {
  digest: unknown;
  kind: "rules.rule";
  rev: unknown;
  rule: RuleSummary & {
    agent?: { [k: string]: unknown };
    /**
     * the check as data, without functions
     */
    check?: { [k: string]: unknown };
    text: string;
  };
};

export type RuleSummary = {
  check_type?: string;
  /**
   * false when the check holds a Lua function: it cannot be written as data and a client must not write it back
   */
  editable: boolean;
  /**
   * the version of the FILE the rule lives in
   */
  etag: string;
  /**
   * rule: the rule is a file of its own (one file per rule), the form rules-ops/1 writes; file: a document that holds rules, any change to it changes every etag in it, and rules-ops/1 does not write it
   */
  etag_scope: "rule" | "file";
  /**
   * the id up to the first '-' when only letters come before it
   */
  family: string;
  has_agent: boolean;
  has_check: boolean;
  id: string;
  line: number;
  section: string;
  severity: Severity;
  /**
   * <ruleset folder>/<path inside it>, with /
   */
  source: string;
  title: string;
};

export type Severity = "critical" | "recommended" | "nice-to-have";

/**
 * rules.snapshot: families with counters, every rule, the sources, the gates, what failed to load.
 */
export type Snapshot = Head & {
  counts: {
    families?: number;
    files?: number;
    rules?: number;
  };
  digest: unknown;
  families: {
    count?: number;
    critical?: number;
    family?: string;
    nice_to_have?: number;
    recommended?: number;
    with_check?: number;
  }[];
  gates: {
    families?: string[];
    name?: string;
    rules?: number;
    /**
     * families of the gate that match no loaded rule
     */
    unknown?: string[];
  }[];
  kind: "rules.snapshot";
  load_errors: string[];
  retired?: Retired[];
  rev: unknown;
  rules: RuleSummary[];
  sources: SourceFile[];
};

export type SourceFile = {
  etag: string;
  path: string;
  rules: number;
};

/**
 * rules.sources: the files the rules come from, with the etag of each.
 */
export type Sources = Head & {
  digest: unknown;
  items: SourceFile[];
  kind: "rules.sources";
  load_errors: string[];
  rev: unknown;
};

export type Waiver = {
  /**
   * expires is before `today` of the document: the waiver suppresses nothing
   */
  expired: boolean;
  /**
   * a real calendar date; the waiver is valid through that day. Absent: no expiry
   */
  expires?: string;
  id: string;
  /**
   * a loaded rule has this id; false: the waiver protects nothing (the rule was retired or renamed)
   */
  known: boolean;
  /**
   * files, folders or globs relative to the project root, with /. Absent: every path
   */
  paths?: string[];
  reason: string;
};

/**
 * rules.waivers: the waivers of a project (its .rules-waivers.json), each with whether it is expired and whether its rule is loaded.
 */
export type Waivers = Head & {
  counts: {
    expired?: number;
    total?: number;
    unknown?: number;
  };
  digest: unknown;
  /**
   * the version of the waivers FILE; a project without one has the etag of an empty file. What `if_match` of waive, renew and remove compares against
   */
  etag: string;
  /**
   * false when the project has no waivers file
   */
  exists: boolean;
  /**
   * in id order
   */
  items: Waiver[];
  kind: "rules.waivers";
  rev: unknown;
  /**
   * the day expiry was judged against (the day of the machine, or the `today` the engine was given)
   */
  today: string;
};
