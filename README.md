# 4D Data MCP

An [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server for 4D databases. It lets an MCP client — Claude Code, Claude Desktop, or any other MCP-capable tool — discover a 4D application's schema, query and modify its data through ORDA, and call whitelisted project methods, all gated by per-token capabilities enforced inside 4D.

The system is built as two cooperating halves joined by a versioned HTTP wire contract:

```
MCP client (Claude Code / Claude Desktop / ...)
        │  stdio (MCP protocol)
        ▼
Half A — mcp-server/            Node.js stdio MCP server
        │  POST /mcp — JSON envelope {v:1, action, params}, Bearer token
        ▼
Half B — 4d-mcp-server/         4D component: HTTP handler + ORDA
        │
        ▼
   Host 4D application's datastore (ds)
```

## How the two halves work together

**Half A** (`mcp-server/`) is a thin Node.js translator. It speaks MCP over stdio to the client and exposes one tool per wire action (`4d_get_schema_digest`, `4d_query_entities`, `4d_get_entity`, `4d_create_entity`, `4d_update_entity`, `4d_delete_entity`, `4d_call_method`). Every tool call is wrapped in a JSON envelope and forwarded as `POST /mcp` with a Bearer token. It holds no logic of its own beyond envelope construction, response validation, and error mapping — it surfaces exactly what Half B allows.

**Half B** (`4d-mcp-server/`) is a 4D component installed in the host application. Its `POST /mcp` handler authenticates the Bearer token, resolves it to a capability object (which dataclasses it may read/write, which actions it may call), applies the deployment-config gates (enable flags, HTTPS requirement, body-size limit, rate limiting, table exposure), then routes to the matching ORDA operation against the host's `ds`. All security enforcement lives here, on the 4D side.

The contract between them — envelope shape, the eight actions, the error taxonomy, pagination rules — is specified in **`ai-context/mcp_data_wire_contract.md` (v1)**, which is the source of truth for both halves. Either half can be tested against it independently: Half A's unit tests run against a canned fixture standing in for 4D, and Half B's curl suite exercises the real HTTP path without any MCP client.

A typical session: the client calls `4d_get_schema_digest` to learn which dataclasses and callable actions its token can see, then queries/creates/updates entities or invokes whitelisted methods. Contract errors come back as typed codes (`CAP_DENIED`, `BAD_PARAMS`, `NOT_FOUND`, ...) so the model can react sensibly.

## Repository layout

| Path | What it is |
|------|-----------|
| `mcp-server/` | Half A — Node.js/TypeScript stdio MCP server ([README](mcp-server/README.md)) |
| `4d-mcp-server/` | Half B — 4D component project ([README](ai-context/README_halfB.md)) |
| `4d-mcp-server_Build/` | Built component output |
| `ai-context/` | Wire contract, design notes, per-half docs |

## Installation & setup

### Half B — the 4D component

Requires **4D 20 R8+** (HTTP request handlers).

1. **Compile, then build.** In the 4D IDE: run Compile on `4d-mcp-server`, then Build Application. The build settings have `BuildCompiled=False`, so building without compiling first silently packages stale code. (Headless alternative: run `MCP_Build` under tool4d — see the [Half B README](ai-context/README_halfB.md#building-the-component) for the packaging steps tool4d can't do itself.)

2. **Install into the host.** Drop the built component into the host application's `Components/` folder.

3. **Start it at host startup.** Call `MCP_Initialize_Host` from the host's `On Startup` / `On Server Startup` database method:

   ```4d
ARRAY TEXT($names; 0)
COMPONENT LIST($names)
var $mcp : Object
var $f : 4D.Function

If (Find in array($names; "4d-mcp-server")>0)
	$f:=Formula from string("MCP_Initialize_Host")
	$mcp:=$f.call()
End if 
   ```

   The `COMPONENT LIST` guard plus `Formula from string` indirection means the host compiles and runs cleanly even when the component is not installed (or later removed) — a direct call to `MCP_Initialize_Host` would fail to compile without it.

   On first run this copies the default deployment config `4D-mcp-config.pref` into the host's `Project/Sources/`, then starts the component's own web server on the config's `HTTP_PORT` (default **8044**; set `0` to serve `/mcp` from the host's main web server instead). The call is idempotent and safe to re-run.

4. **Configure tokens and exposure.** Edit `4D-mcp-config.pref` in the host's `Project/Sources/`:
   - Table exposure and verb gates (`ENABLED`, `ALLOW_READ/WRITE/DELETE`, `ALLOW_CALL_METHOD`).
   - `METHOD_WHITELIST` — maps client-facing action names to host project methods for `4d_call_method`.

   Tokens map a Bearer string to a capability object (readable/writable dataclasses, callable actions); v1 defines them in `MCP_Auth._loadTokens()`, swappable for a table-backed store. See the [Half B README](ai-context/README_halfB.md) for the exact shapes.

### Half A — the Node MCP server

Requires **Node 18.17+**.

```bash
cd mcp-server
npm install
npm run build
```

Configuration is via environment variables:

| Env var | Default | Meaning |
|---------|---------|---------|
| `FOURD_MCP_URL` | `http://localhost:8044/mcp` | Half B endpoint |
| `FOURD_MCP_TOKEN` | — (required) | Bearer token |
| `FOURD_MCP_TIMEOUT_MS` | `30000` | Per-request timeout |

Register with Claude Code:

```bash
claude mcp add 4d-data \
  --env FOURD_MCP_URL=http://localhost:8044/mcp \
  --env FOURD_MCP_TOKEN=YOUR_TOKEN \
  -- node /path/to/mcp-server/dist/index.js
```

Or in an `mcpServers` JSON block (Claude Desktop and similar):

```json
{
  "mcpServers": {
    "4d-data": {
      "command": "node",
      "args": ["/path/to/mcp-server/dist/index.js"],
      "env": {
        "FOURD_MCP_URL": "http://localhost:8044/mcp",
        "FOURD_MCP_TOKEN": "YOUR_TOKEN"
      }
    }
  }
}
```

### Verifying the setup

With the host 4D app running (Half B up on port 8044):

```bash
# Half B alone, over real HTTP:
cd 4d-mcp-server && ./test/run_curl_tests.sh

# Half A against the live Half B:
cd mcp-server
FOURD_MCP_URL=http://localhost:8044/mcp FOURD_MCP_TOKEN=SECRET_FULL \
  npm run test:integration
```

Half A's unit tests (`npm test`) and Half B's logic tests (`MCP_RunHeadlessTests` under tool4d) need no running server at all.

## Documentation

- **Wire contract (source of truth):** [`ai-context/mcp_data_wire_contract.md`](ai-context/mcp_data_wire_contract.md)
- **Half A details:** [`mcp-server/README.md`](mcp-server/README.md)
- **Half B details:** [`ai-context/README_halfB.md`](ai-context/README_halfB.md)
- **Design notes:** [`ai-context/design_notes_halfB.md`](ai-context/design_notes_halfB.md)
