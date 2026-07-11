# Half B — design notes (non-obvious 4D-side choices)

Decisions and 4D-version quirks discovered while building and verifying Half B
against `tool4d` (4D 20 R10 engine). All were validated by the 30-assertion
headless suite (`MCP_RunHeadlessTests`).

## Architecture

- **`dispatch()` is a thin HTTP adapter; `handle($token; $body)` holds all logic.**
  `dispatch` pulls the Bearer token and parses the JSON body off the
  `4D.IncomingMessage`, then calls `handle`, which returns `{status, env}` and is
  pure (token + body in → descriptor out). This makes the entire gate chain
  unit-testable **without HTTP** — a `4D.IncomingMessage` can't be fabricated in
  code, but `handle` can be called directly. The curl script covers the real
  wire path; the headless suite covers routing/gating/ORDA through `handle`.

- **Result-descriptor convention.** `MCP_DataAccess` / `MCP_Schema` functions
  return `{data, meta?}` on success or `{error:{code,message}}` on failure — never
  raise across the boundary. `MCP_Handler` maps the error `code` to its HTTP
  status via the fixed taxonomy (§4). Any un-trapped 4D error inside gate 6 is
  caught and returned as `INTERNAL` with the 4D message (never a stack).

## 4D-version quirks that shaped the code (important)

1. **Shared singletons must be stateless in this build.** Assigning to a shared
   singleton's `This` property — even plain text, even inside `Use(This)…End use`,
   even in the constructor — raised `-10721 "Not supported value type in a shared
   object"`, which then cascaded to `-10729`. Fix: the singletons hold **no state**.
   Config that would naturally be a property is exposed via a function instead
   (`MCP_DataAccess._HARD_CAP()`, `._registry()`; `MCP_Auth._loadTokens()`).
   Constructors are empty. Stateless shared singletons instantiate and run fine.

2. **Dynamic attribute access on a DataClass:** `ds.Customer[$attr]` and
   `OB Get(ds.Customer; $attr)` both raise `59 "4D was expecting an object"`.
   The datastore double-bracket **`ds[$dcName][$attr]` works.** Both `MCP_Schema`
   and `MCP_DataAccess._projection` enumerate attributes via
   `ds[$name][$key]` for each `$key` in `OB Keys(ds[$name])`.

3. **`OB Instance of($x; 4D.DataClassAttribute)` does not resolve** — the class
   reference raises `317 "A function was expected"`. Avoided entirely: `OB Keys`
   on a DataClass returns *only* attribute names, so we branch on `$attr.kind`
   (`"storage"` / `"relatedEntity"` / `"relatedEntities"`) and skip `Null`.

4. **`tool4d` does not implement the web server** — `WEB SET OPTION`,
   `WEB START SERVER`, `WEB Is server running` all raise `33 "Unimplemented
   command or function"`. So the HTTP/curl path can only be run under full 4D
   (4D Server / desktop). The logic layer was fully verified headless instead.
   The curl suite runs against full 4D headless: `TOOL4D="/Applications/4D 20
   R10/4D copy.app/Contents/MacOS/4D" ./test/start_server.sh`.

5. **`roles.json` with a permission action listed as an empty array blocks
   handler execution.** The project's default `roles.json` carried a datastore
   permission entry with `"execute": []` (all actions empty) — full 4D then
   refused `POST /mcp` with error 1656 *"No permission to execute the dispatch
   function in the MCP_Handler singleton class"* (HTTP 401 with an `__ERROR`
   body). Fix: `"permissions": {"allowed": []}` — an empty allowed list, not an
   entry with empty action arrays. The `exposed` keyword is NOT the fix and is
   explicitly not recommended for request handler functions.

6. **Request handlers cannot see the client IP** (verified empirically, 20 R10):
   `4D.IncomingMessage` has no peer-address property, `Session.info` is
   undefined in web sessions, and `Process activity` is unavailable in the
   handler context. Consequence: no `ALLOWED_IPS` config — IP filtering belongs
   in the web server settings or a reverse proxy. `WEB Is secured connection`
   DOES work inside handlers (basis of `REQUIRE_HTTPS`), and `Session` +
   `Session.storage` are available (scalable sessions).

7. **Per-token rate limiting lives in the component's `Storage`** (fixed
   one-minute window). Singletons are stateless (quirk 1), and each component
   gets its own `Storage`, so `Storage.mcpRate` is invisible to the host.
   Exceeding the cap returns `RATE_LIMITED` (429) — the one code added to the
   contract's original 8-code taxonomy (contract §4 updated).

## Schema digest — sourced from live ORDA, not the catalog file

`get_schema_digest` reads the running datastore (`dataClass.getInfo()` →
`{name, primaryKey, tableNumber}`, plus per-attribute `.kind` / `.type` /
`.relatedDataClass`) rather than parsing `.4DCatalog`. It always reflects the
live structure and needs no file I/O. Output matches contract §3.1. Relation
`kind`: `relatedEntities` → `"one-to-many"`, `relatedEntity` → `"many-to-one"`.

## Fixture catalog — corrected 4D type codes

The `4d-catalog` skill's `TYPE_CODES_TO_SYMBOLIC` map is **wrong for several
codes** (verified against real catalogs with self-describing field names, e.g.
`field_bool`→1, `field_real`→6, `field_blob`→18). The generator initially
produced a boolean field as type 18 (**blob** — values read back `null`) and a
real as type 5 (**int64**). Corrected in `catalog.4DCatalog`: **boolean = `1`,
real = `6`**. (`⚠️ the skill's map needs fixing — 1=bool not int16, 6=real not
float, 5=int64 not real, 18=blob not bool, 21=object not blob.`)

## Query placeholder binding (injection-safe)

`query_entities` binds `filter` values positionally to `:1, :2 …` via ORDA
placeholders — values are **never** string-interpolated. `_query` branches on the
params-collection length and passes items as discrete `.query()` arguments
(`$dc.query($filter; $c[0]; $c[1]; …)`), which guarantees correct positional
binding. Filters with **more than 6** placeholders fall back to passing the whole
collection — the one spot to re-verify if such a filter is ever used (v1 filters
are small). Bad filter / unknown attribute → `QUERY_ERROR`.

## Pagination

`limit` default **and** hard cap are both **80** (matches 4D's internal paging).
Over-80 requests are clamped and `meta.clamped=true`. Offset pagination via
`entitySelection.slice(offset; offset+limit)`. `meta = {count, offset, limit,
total, truncated, clamped}`; `truncated = (offset+count) < total`.

## Contract ambiguities flagged

- **"8 actions"** — the contract (§3.1–3.7) defines **7** action types. Tests
  cover all 7, exercising `call_method` twice (`ping` + `order_count`) = 8
  invocations, which is the most sensible reading of "each of the 8 actions."
- No other contract deviations. Envelopes, gate order, and the error taxonomy
  (code+message only — no `details`/`retryable`) are implemented exactly as
  written.
