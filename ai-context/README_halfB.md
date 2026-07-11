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
| `Project/Sources/HTTPHandlers.json` | Registers `POST /mcp` → `MCP_Handler.dispatch` |
| `Project/Sources/Classes/MCP_Handler.4dm` | Dispatcher: gate order, envelopes, HTTP adapter |
| `Project/Sources/Classes/MCP_Auth.4dm` | Token → capability object (swappable store) |
| `Project/Sources/Classes/MCP_Schema.4dm` | `get_schema_digest` from ORDA introspection |
| `Project/Sources/Classes/MCP_DataAccess.4dm` | ORDA CRUD + query + `call_method` registry |
| `Project/Sources/Classes/MCP_Test.4dm` | In-4D self-test of the full gate chain |
| `Project/Sources/Methods/MCP_RunHeadlessTests.4dm` | Headless test entry point |
| `Project/Sources/Methods/MCP_StartServer.4dm` | Seeds fixtures + starts web server (curl) |
| `Project/Sources/catalog.4DCatalog` | Fixture schema: `Customer`, `Order` (+ relation) |
| `test/run_curl_tests.sh` | Exercises every action over real HTTP |
| `test/start_server.sh` | Launches a live headless 4D for the curl tests |

All four production classes are **shared singletons** and **stateless** — see
`design_notes_halfB.md` for why (this 4D build rejects mutable state on a shared
singleton's `This`).

## Installing the component

This is delivered as an ordered-source 4D project. To use it inside another 4D
app you can either open this project directly, or lift the pieces into your app:

1. Copy the five `MCP_*` classes into your project's `Project/Sources/Classes/`.
   (`MCP_Test` is optional — it's the self-test.)
2. Merge `HTTPHandlers.json` into your project's `Project/Sources/HTTPHandlers.json`
   (it's a JSON array — add the `/mcp` entry).
3. Your datastore supplies the dataclasses. The bundled `catalog.4DCatalog`
   (Customer/Order) is only a fixture for the tests — drop it when embedding.
4. Start the web server (`WEB START SERVER`, or enable it in the project
   settings). HTTP request handlers activate with the web server.

## Configuring a token

v1 backs tokens with an in-memory object in `MCP_Auth._loadTokens()`. Each entry
maps a raw Bearer string to a capability object:

```4d
$t["SECRET_FULL"]:=New object(\
    "token_id"; "tok_full"; \
    "read";  New collection("Customer"; "Order"); \  // dataclasses this token may read
    "write"; New collection("Order"); \              // dataclasses it may mutate
    "call";  New collection("ping"; "order_count"))  // registered actions it may call
```

- Absent verb array = no access to that verb.
- `attributes` projection is a **client convenience, not a security boundary** —
  gating is at the dataclass level only (contract §6).

**Swapping the store:** replace only `_loadTokens()` with a table lookup
(e.g. `ds.MCP_Token.query(...)`) that returns the same shape. Nothing else changes.

## Registering a callable action (`call_method`)

The client names an **action_name**, never a 4D method name. The map lives in
`MCP_DataAccess._registry()`:

```4d
return New object("ping"; "action_ping"; "order_count"; "action_order_count")
```

Add `"my_action"; "action_myThing"`, then implement `Function action_myThing($args : Object) : Object`
in `MCP_DataAccess`. Anything not in the registry is unreachable (`CAP_DENIED`).
A registered function that throws → `INTERNAL` with the 4D message (never a stack).

## Running the tests

### Logic tests (headless, no web server) — verifies the whole gate chain

```bash
tool4d --project Project/4d-mcp-server.4DProject --opening-mode interpreted \
  --startup-method MCP_RunHeadlessTests --create-data --data /tmp/mcp/data.4DD
cat test_report.json     # { total, passed, failed, cases:[...] }
```

30 assertions cover all 8 action invocations, the full error taxonomy, capability
gating, placeholder binding, pagination clamp, and CRUD round-trips. This calls
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
