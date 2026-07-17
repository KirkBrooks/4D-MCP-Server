# TODO — follow-ups from the first live deployment (2026-07-17, HPC4d)

Items called out while bringing the full stack (Claude Code → Half A → Half B
compiled component in HPC4d) live for the first time. None are blocking; the
stack works end-to-end.

## Component (Half B)

- [ ] **Config read / exposure-set recompute cost per request** (adversarial
  review of `eadf28f`, MEDIUM). `getConfig()` re-reads and re-parses the config
  file on every call, and it's called several times per request (dispatch,
  handle, `_projectionNames`, `forbiddenQueryField`, `isExposed`);
  `exposedDataclasses()` iterates `OB Keys(ds)` + `getInfo()` per dataclass each
  time. Stateless singletons rule out instance caching — thread the already-
  loaded `$config` (and a computed exposed-set) through `handle()` into the
  gates and projection instead of re-reading. Also closes a within-request
  live-config race (gates could see different snapshots if the file is edited
  mid-request). Correctness is fine today; this is throughput on large schemas.

- [ ] **`forbiddenQueryField` is a heuristic tokenizer, not a parser.** It
  strips quoted literals and rejects identifiers that resolve to unexposed /
  relation fields. It's conservative (rejects rather than leaks) but a
  determined filter-syntax edge case could get a false reject. If filters get
  richer, consider a real ORDA-filter parse or an allowlist of operators.

- [ ] **Post-start bind probe in `MCP_Initialize_Host`.** After a host project
  reopen within the same 4D instance, `webServer.start()` reported success and
  the "listening" line was logged, but nothing was actually bound on the port
  (stale socket from the previous session; bind is asynchronous). Re-running
  `MCP_Initialize_Host` fixed it. Add a short retry loop or a loopback probe
  after `start()` and log honestly when the port is not actually reachable.
  (design_notes_halfB.md quirk 10.)

- [ ] **Token store needs to leave the source.** Adding `SECRET_HPC_RO`
  required editing `MCP_Auth._loadTokens()` and a full recompile/repackage.
  Fine for fixtures; wrong for deployments. Implement `TOKEN_STORE: "table"`
  (already stubbed in the config) or another host-editable store so a
  deployment can mint/revoke tokens without rebuilding the component.

- [ ] **Server-side aggregation via `METHOD_WHITELIST`.** A monthly-sales
  rollup took 5 paged `query_entities` calls (80-row cap) plus client-side
  summing. Ship a sample whitelisted action (e.g. `sales_by_month`) showing
  the intended pattern for analytics-shaped questions.

## Test harness

- [ ] **`test/start_server.sh` defaults to tool4d, which cannot serve HTTP**
  (web server intentionally disabled — design_notes quirk 4). The default
  `TOOL` path should point at a full 4D binary (headless), with tool4d
  rejected up front with a clear message instead of the opaque
  `[33] Unimplemented command` at startup.

## Deployment hygiene (HPC4d trial install)

- [ ] **`REQUIRE_HTTPS` is `false`** in HPC4d's live config
  (`HPC4d/Project/Sources/4D-mcp-config.pref`) — acceptable for
  localhost-only dev, must be re-enabled (or fronted by TLS) before any
  non-local deployment.

- [ ] **Duplicate Claude Code registration.** `4d-data` is registered in both
  project scope (`.mcp.json`, env-var expansion) and local scope
  (`~/.claude.json`, corrected URL + token). Keep one:
  `claude mcp remove 4d-data -s project` is the simple choice since the
  local-scope entry is the one that works today.
