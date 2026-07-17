# 4D Data MCP — Half B (in-4D component)

The 4D-side half of the Data MCP. A single `POST /mcp` HTTP request handler
authenticates a Bearer token, gates on capabilities, routes to an ORDA
operation, and returns the wire-contract envelope. Half A (the external MCP
server) talks to this over HTTP. The wire contract is the source of truth:
`ai-context/mcp_data_wire_contract.md`.

Requires **4D 20 R8+** (HTTP request handlers). Ordered-source project.

## What's here

| File | Role |
|------|------|
| `Project/Sources/HTTPHandlers.json` | Registers `POST /mcp` → `MCP_Handler.dispatch` — **standalone only**: 4D loads this file only for the main web server, never for a component's own. Embedded, the same handler is registered programmatically by `MCP_Initialize_Host` |
| `Project/Sources/Classes/MCP_Handler.4dm` | Dispatcher: gate order, envelopes, HTTP adapter |
| `Project/Sources/Classes/MCP_Auth.4dm` | Token → capability object (swappable store) |
| `Project/Sources/Classes/MCP_Schema.4dm` | `get_schema_digest` from ORDA introspection |
| `Project/Sources/Classes/MCP_DataAccess.4dm` | ORDA CRUD + query + `call_method` registry |
| `Project/Sources/Classes/MCP_Test.4dm` | In-4D self-test of the full gate chain |
| `Project/Sources/Methods/MCP_RunHeadlessTests.4dm` | Headless test entry point |
| `Project/Sources/Methods/MCP_Initialize_Host.4dm` | Host startup entry: ensures config, starts the component's own web server on `HTTP_PORT` |
| `Project/Sources/Methods/MCP_StartServer.4dm` | Test entry: seeds fixtures, then runs `MCP_Initialize_Host` (curl) |
| `Project/Sources/Methods/MCP_Build.4dm` | Headless compile entry point for tool4d (`Compile project` from disk; see "Building the component") |
| `Project/Sources/catalog.4DCatalog` | Fixture schema: `Customer`, `Order` (+ relation) |
| `Resources/4D-mcp-config.pref` | Component's default deployment config; copied to the host's `Project/Sources/` on first read (edit it there) |
| `test/run_curl_tests.sh` | Exercises every action over real HTTP |
| `test/start_server.sh` | Launches a live headless 4D for the curl tests |

All four production classes are **shared singletons** and **stateless** — see
`design_notes_halfB.md` for why (this 4D build rejects mutable state on a shared
singleton's `This`).

## Building the component

**Compile before you build.** `Settings/buildApp.4DSettings` has
`BuildCompiled=False`, so Build Application packages whatever compiled code
already sits in `Project/DerivedData/CompiledCode/` — it does **not**
recompile. Edit source, skip Compile, and the build silently ships stale code.
In the IDE: Compile, then Build. Headless: run `MCP_Build` under tool4d
(compiles from disk; `BUILD APPLICATION` is a silent no-op under tool4d, so
packaging must be done outside 4D — swap the fresh `CompiledCode/` into the
`.4DZ`, copy `Libraries/lib4d-arm64.dylib` into the `.4dbase`, re-sign with
`codesign --force --deep -s -`).

## Installing the component

Compile this project and drop the component into the host's `Components/`
folder, then call `MCP_Initialize_Host` from the host's startup
(`On Startup` / `On Server Startup`). That method:

1. Ensures `4D-mcp-config.pref` exists in the host's `Project/Sources/`
   (copies the component's default on first read — same path `getConfig()` uses).
2. Starts the **component's own web server** (`WEB Server` object) on the
   config's `HTTP_PORT` (default 8044; set `0` to skip and serve `/mcp` from
   the host's web server instead), registering the `/mcp` handler
   **programmatically** in the `start()` settings — required because 4D only
   loads `HTTPHandlers.json` for the main web server, never for a component's
   (design_notes quirk 8). Returns `{success; port; message}`.

Known wrinkle: after closing/reopening the host project within one 4D
instance, the start can report success without the port actually being bound;
re-run `MCP_Initialize_Host` if `/mcp` refuses connections (quirk 10,
TODO.md).

The component's classes stay internal — no exposure to the host is needed;
`MCP_Initialize_Host` (shared) is the only entry point. The host's dataclasses
are reached via `ds`; the bundled `catalog.4DCatalog` (Customer/Order) is only
a fixture for the tests.

### Calling it from the host

In the host's `On Startup` (or `On Server Startup`) database method:

```4d
// On Startup
var $mcp : Object
$mcp:=MCP_Initialize_Host

Case of
	: (Not(Bool($mcp.success)))
		// Config unreadable/malformed, or the web server refused to start
		// (port in use, ...). Already logged to stdout by the component;
		// decide here whether that's fatal for your app.
		ALERT("MCP server failed to start: "+String($mcp.message))

	: ($mcp.port=0)
		// HTTP_PORT<=0 in 4D-mcp-config.pref — deliberate opt-out; /mcp is
		// expected to be served by the host's own web server instead.

	Else
		// Up and listening: POST http://localhost:<$mcp.port>/mcp
End case
```

The call is idempotent — if the component's web server is already running it
returns `{success: True; message: "MCP web server already running"}` — so it's
safe to call again (e.g. from an admin "restart MCP" menu item). Every outcome
is also appended (JSONL, via the `log_worker` worker) to
`Logs/4d_mcp_server_log_YYYYMMDD` in the host's Logs folder, so failed starts
are easy to find without digging through system logs.

Alternatively, lift the pieces into your app directly: copy the five `MCP_*`
classes, merge `HTTPHandlers.json` (a JSON array — add the `/mcp` entry), and
start a web server.

## Configuring a token

v1 backs tokens with an in-memory object in `MCP_Auth._loadTokens()`. Each entry
maps a raw Bearer string to a capability object:

```4d
$t["SECRET_FULL"]:=New object(\
    "token_id"; "tok_full"; \
    "read";  New collection("Customer"; "Order"); \  // dataclasses this token may read
    "write"; New collection("Order"); \              // dataclasses it may mutate
    "call";  New collection("ping"; "order_count"))  // whitelisted actions it may call
```

- Absent verb array = no access to that verb.
- `attributes` projection is a **client convenience, not a security boundary** —
  gating is at the dataclass level only (contract §6).

**Swapping the store:** replace only `_loadTokens()` with a table lookup
(e.g. `ds.MCP_Token.query(...)`) that returns the same shape. Nothing else changes.

## Registering a callable action (`call_method`)

The client names an **action_name**, never a 4D method name. The map lives in
the deployment config (`METHOD_WHITELIST` in `4D-mcp-config.pref`) — each entry
exposes one HOST project method:

```json
"my_action": {
  "method": "UTIL_MyHostMethod",
  "args": [ { "name": "status", "type": "text", "required": false,
              "purpose": "filter to one order status" } ],
  "return": "object",
  "purpose": "What this action does — surfaced to clients via get_schema_digest"
}
```

The wire's `args` is a collection bound **positionally** to the host method's
parameters (`EXECUTE METHOD`); the spec's `name` is documentation, position is
what binds; optional args are trailing-only. The host method takes typed
positional params and returns a JSON-serializable value:

```4d
#DECLARE($status : Text) : Object
return New object("count"; ds.Order.query("status = :1"; $status).length)
```

Gate 4 validates arity and types against the spec (`BAD_PARAMS`); anything not
in the map is unreachable (`CAP_DENIED`); a host method that throws → `INTERNAL`
with the 4D message (never a stack). Tokens discover what they may call — spec
included, host method name stripped — via `get_schema_digest.callable_actions`.
The bundled fixtures (`MCP_Fixture_Ping` / `MCP_Fixture_OrderCount` /
`MCP_Fixture_EchoUpper`) are ordinary host methods registered this way; drop
them (and their whitelist entries) when embedding.

## Running the tests

### Logic tests (headless, no web server) — verifies the whole gate chain

```bash
tool4d --project Project/4d-mcp-server.4DProject --opening-mode interpreted \
  --startup-method MCP_RunHeadlessTests --create-data --data /tmp/mcp/data.4DD
cat test_report.json     # { total, passed, failed, cases:[...] }
```

83 assertions cover all 8 action invocations, the full error taxonomy, capability
gating, the deployment-config verb gates (ENABLED, ALLOW_READ/WRITE/DELETE,
ALLOW_CALL_METHOD + METHOD_WHITELIST), the transport gates (REQUIRE_HTTPS,
MAX_BODY_SIZE, per-token rate limit), placeholder binding, pagination clamp,
and CRUD round-trips. dispatch()'s wire path (transport gates, rate limiting,
request/audit logs, host hooks) is additionally exercised over real HTTP by
the curl suite. This calls
the pure `MCP_Handler.handle($token; $body)` seam, so no HTTP is needed.

### HTTP tests (real wire path) — needs full 4D (not tool4d)

`tool4d` does **not** implement the web server, so the curl tests must run against
a real 4D (4D Server or 4D desktop). Start the server, then curl:

```bash
./test/start_server.sh          # full 4D with web server on :8044 (seeds fixtures)
# in another shell:
./test/run_curl_tests.sh        # 17 checks: 8 happy paths + error taxonomy
```

`run_curl_tests.sh` exercises every action with a Bearer token and JSON body and
asserts the HTTP status + response envelope for each.
