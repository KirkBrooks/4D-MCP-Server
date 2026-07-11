# 4D Data MCP — Half A (external MCP server)

The MCP-facing half of the 4D Data MCP. A Node.js **stdio MCP server** that
exposes one tool per wire-contract action and forwards every call over HTTP to
Half B — the in-4D `POST /mcp` request handler. The wire contract is the source
of truth: `../ai-context/mcp_data_wire_contract.md` (v1).

```
MCP client (Claude Code / Desktop)
        │  stdio (MCP)
        ▼
  4d-data-mcp  (this package)
        │  POST /mcp — JSON envelope {v:1, action, params}, Bearer token
        ▼
  4D web server (Half B handler)
```

## What's here

| File | Role |
|------|------|
| `src/wire.ts` | Contract v1 types, error codes, `WireError` / `TransportError` |
| `src/client.ts` | `FourDClient` — envelope, auth header, response validation, error mapping |
| `src/server.ts` | `buildServer()` — the 7 MCP tools, all delegating to the client |
| `src/index.ts` | Entry point: env config → stdio transport |
| `test/fixture.ts` | Canned Half B stand-in (contract §5) for unit tests |
| `test/unit.test.ts` | 14 tests: envelope, full error taxonomy, tool layer over in-memory MCP |
| `test/integration.test.ts` | 14 tests against a live Half B: discovery, query, CRUD round trip, call_method, gates |
| `test/stdio-smoke.ts` | Spawns `dist/index.js` over real stdio and calls a tool |

## Tools

| Tool | Wire action |
|------|-------------|
| `4d_get_schema_digest` | `get_schema_digest` — dataclasses + callable actions for this token |
| `4d_query_entities` | `query_entities` — ORDA filter with `:1` placeholders, offset paging (cap 80) |
| `4d_get_entity` | `get_entity` |
| `4d_create_entity` | `create_entity` |
| `4d_update_entity` | `update_entity` |
| `4d_delete_entity` | `delete_entity` |
| `4d_call_method` | `call_method` — whitelisted action names only |

Success results are the envelope's `data` as pretty-printed JSON
(`4d_query_entities` returns `{data, meta}` so the model can page). Contract
errors come back as `isError` tool results shaped `CODE: message`
(e.g. `CAP_DENIED: token cannot write Customer`); HTTP/parse failures as
`TRANSPORT: ...`. Capability enforcement lives entirely on the 4D side — this
server holds one token and surfaces whatever Half B allows it.

## Configuration

| Env var | Default | Meaning |
|---------|---------|---------|
| `FOURD_MCP_URL` | `http://localhost:8044/mcp` | Half B endpoint |
| `FOURD_MCP_TOKEN` | — (required) | Bearer token |
| `FOURD_MCP_TIMEOUT_MS` | `30000` | Per-request timeout |

Claude Code registration:

```bash
npm run build
claude mcp add 4d-data \
  --env FOURD_MCP_URL=http://localhost:8044/mcp \
  --env FOURD_MCP_TOKEN=SECRET_FULL \
  -- node /path/to/mcp-server/dist/index.js
```

Or in a `mcpServers` JSON block (Claude Desktop etc.):

```json
{
  "mcpServers": {
    "4d-data": {
      "command": "node",
      "args": ["/path/to/mcp-server/dist/index.js"],
      "env": {
        "FOURD_MCP_URL": "http://localhost:8044/mcp",
        "FOURD_MCP_TOKEN": "SECRET_FULL"
      }
    }
  }
}
```

## Tests

```bash
npm install
npm test                    # unit — no 4D needed (canned fixture server)

# integration — needs a live Half B (see ../4d-mcp-server/test/start_server.sh)
FOURD_MCP_URL=http://localhost:8044/mcp FOURD_MCP_TOKEN=SECRET_FULL \
  npm run test:integration

# real-stdio smoke test
npm run build
FOURD_MCP_URL=http://localhost:8044/mcp FOURD_MCP_TOKEN=SECRET_FULL \
  npx tsx test/stdio-smoke.ts
```

The integration suite assumes the fixture datastore (`Customer`/`Order`) and
the `SECRET_FULL` token (read Customer+Order, write Order, call
`ping`/`order_count`/`echo_upper`). It creates, updates, and deletes its own
Order row and cleans up after itself.
