# Design discussion — forum post on 4D MCP Server architecture

**Status:** in progress, resume later.
**Goal:** Kirk is writing a forum post reviewing the architecture decisions made
while building this MCP server for 4D. This session reviewed the first decision
for accuracy.

## Decision under discussion: not using the 4D REST stack

Kirk's draft framing (verified accurate against `mcp_data_wire_contract.md` and
`design_notes_halfB.md`):

- We opted **not** to use 4D's built-in REST server (`/rest`, the ORDA REST API)
  and wrote our own 4D-side code for the MCP server to talk to.
- What the REST stack would have provided for free: built-in authentication
  (`ds.authentify` / force-login), 4D session management, the
  privileges/permissions system (`roles.json`), and a ready-made ORDA-over-HTTP
  surface.

### Refinement agreed for the post

We did **not** write our own web server or transport — Half B still runs on 4D's
web server, as a custom HTTP request handler (`POST /mcp`, `4D.IncomingMessage`,
4D 20 R8+). What we replaced is the **REST API layer**, not the server. Instead
of exposing ORDA generically, we defined a narrow wire contract of exactly
7 actions (schema digest, query, get/create/update/delete entity, whitelisted
`call_method`) with:

- **Capability tokens instead of 4D sessions** — Bearer token resolves to
  `{read: [...], write: [...], call: [...]}` per dataclass, checked in a fixed
  six-gate chain on every request. Stateless, which suits an MCP client better
  than session cookies.
- **Closed error taxonomy** — 8 codes, code+message only, no stack leakage.
- **Hard allowlist for method execution** — `call_method` maps action names to
  registered class functions; nothing else in the project is reachable. The
  generic REST stack's default surface is much broader.
- **Testability as a design driver** — the contract let Half A (MCP server) and
  Half B (4D) be built and tested independently; the 4D logic layer is testable
  without HTTP because `handle()` is pure and `dispatch()` is a thin adapter.

### Recommended framing for the post

Not "we skipped the REST stack's conveniences" but **"we traded a broad,
general-purpose surface for a narrow, auditable one."** The built-in REST API
exposes the datastore generically and gates with sessions/privileges; an MCP
integration wanted a minimal contract where everything reachable is explicitly
enumerated.

### Misc

- Typo to fix in the draft: "MPC server" → "MCP server".

## Next steps when resuming

- Continue through the remaining architecture decisions Kirk wants to cover in
  the post (this was only the first one).
- Reference docs: `ai-context/mcp_data_wire_contract.md` (wire contract v1),
  `ai-context/design_notes_halfB.md` (4D-side decisions and quirks).
- When drafting the actual post, use the `strategic-comms` skill.
