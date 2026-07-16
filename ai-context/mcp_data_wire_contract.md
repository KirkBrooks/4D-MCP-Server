# 4D Data MCP — Wire Contract v1

The single source of truth for the boundary between **Half A** (the MCP server, outside 4D) and **Half B** (the 4D-side request handler + classes). Both halves build and test against this document independently.

- **Endpoint:** `POST /mcp`
- **Transport:** HTTPS, 4D request handler (`4D 20 R8+`)
- **Content-Type:** `application/json` (both directions)
- **Auth:** `Authorization: Bearer <token>` header on every request
- **Contract version:** `v: 1` in every request and response envelope

---

## 1. Envelope

### Request (every call)

```json
{
  "v": 1,
  "action": "query_entities",
  "params": { }
}
```

| Field    | Type    | Notes                                              |
|----------|---------|----------------------------------------------------|
| `v`      | Integer | Must equal `1`. Mismatch → `BAD_VERSION`.           |
| `action` | Text    | One of the actions in §3. Unknown → `UNKNOWN_ACTION`. |
| `params` | Object  | Action-specific. Missing required keys → `BAD_PARAMS`. |

### Response — success

```json
{
  "v": 1,
  "ok": true,
  "data": { },
  "meta": { }
}
```

`meta` is present only where an action defines it (currently pagination on `query_entities`). Otherwise omitted.

### Response — error

```json
{
  "v": 1,
  "ok": false,
  "error": { "code": "CAP_DENIED", "message": "human-readable" }
}
```

No `details`, no `retryable` — code + message only (per decision).

---

## 2. Auth & capabilities

The Bearer token resolves 4D-side to a **capability object**:

```json
{
  "token_id": "tok_abc",
  "read":  ["Customer", "Order", "Product"],
  "write": ["Order"],
  "call":  ["recalc_totals", "get_open_invoices"]
}
```

- `read` / `write` — arrays of **dataclass names** the token may read / mutate.
- `call` — array of **whitelisted action names** (not 4D method names) the token may invoke via `call_method`.
- Empty array = no access to that verb. Absent key treated as empty array.

**Gate order in the dispatcher, every request:**

0. Deployment gates (Half B config, before the contract gates, verb-agnostic —
   these never depend on which action is requested, so they run before the
   action is even parsed): unreadable config → `INTERNAL`; component disabled
   / HTTPS required → `CAP_DENIED`; oversize body → `BAD_PARAMS`; per-token
   rate cap → `RATE_LIMITED`.
1. Token present & valid → else `AUTH_DENIED` (401).
2. `v == 1` → else `BAD_VERSION` (400).
3. `action` known → else `UNKNOWN_ACTION` (400).
4. `params` well-formed → else `BAD_PARAMS` (400).
5. Capability check for the specific action → else `CAP_DENIED` (403).
   Deployment-level config verb gates (`ALLOW_READ` / `ALLOW_WRITE` /
   `ALLOW_DELETE` / `ALLOW_CALL_METHOD`, `METHOD_WHITELIST`) are checked here,
   ahead of the token's own capability list — they gate on which *verb* is
   being requested, which isn't known until gate 3 resolves the action, so
   they cannot run at gate 0.
6. Execute → success or `NOT_FOUND` / `QUERY_ERROR` / `INTERNAL`.

---

## 3. Actions

### 3.1 `get_schema_digest`

Return the schema digest for dataclasses the token can `read`. Reuses the YAML/JSON digest shape from the `4d-catalog` workflow.

**Capability:** none beyond a valid token; result is filtered to `read` dataclasses.

**Request**
```json
{ "v": 1, "action": "get_schema_digest", "params": {} }
```

**Response `data`**
```json
{
  "dataclasses": [
    {
      "name": "Customer",
      "primaryKey": "ID",
      "fields": [
        { "name": "ID",      "type": "number", "key": true },
        { "name": "name",    "type": "string" },
        { "name": "email",   "type": "string" }
      ],
      "relations": [
        { "name": "orders", "target": "Order", "kind": "one-to-many" }
      ]
    }
  ],
  "callable_actions": [
    {
      "name": "order_count",
      "args": [ { "name": "status", "type": "text", "required": false,
                  "purpose": "filter to one order status" } ],
      "return": "object",
      "purpose": "Count orders, optionally filtered by status"
    }
  ]
}
```

`callable_actions` lists the `call_method` actions this token may call (the intersection of the server's `METHOD_WHITELIST` and the token's `call` capability), as client-facing specs — the underlying host method name is never included. Empty when `call_method` is disabled server-side or the token can call nothing.

---

### 3.2 `query_entities`

Query one dataclass. Offset pagination.

**Capability:** `dataclass` ∈ token `read`, else `CAP_DENIED`.

**Request**
```json
{
  "v": 1,
  "action": "query_entities",
  "params": {
    "dataclass": "Customer",
    "filter": "name = :1 and active = true",
    "params": ["Acme*"],
    "orderBy": "name asc",
    "attributes": ["ID", "name", "email"],
    "offset": 0,
    "limit": 80
  }
}
```

| Param        | Req? | Notes                                                              |
|--------------|------|--------------------------------------------------------------------|
| `dataclass`  | yes  | Must be in token `read`.                                            |
| `filter`     | no   | 4D ORDA query string. Placeholders `:1,:2…` bound from `params`.    |
| `params`     | no   | Positional values for the filter placeholders (injection-safe).    |
| `orderBy`    | no   | e.g. `"name asc"`, `"created desc"`.                                |
| `attributes` | no   | Projection. Omitted → all scalar (non-relation) attributes.        |
| `offset`     | no   | Default `0`.                                                       |
| `limit`      | no   | Default `80`, hard cap `80` (server clamps, sets `meta.clamped`). Matches 4D's internal paging size. |

**Response**
```json
{
  "v": 1,
  "ok": true,
  "data": [
    { "ID": 1, "name": "Acme Co", "email": "a@acme.test" }
  ],
  "meta": { "count": 1, "offset": 0, "limit": 80, "total": 1, "truncated": false, "clamped": false }
}
```

- `count` — rows returned this page.
- `total` — full selection length (`.length`).
- `truncated` — `true` if `offset + count < total` (more pages exist).
- `clamped` — `true` if requested `limit` exceeded the hard cap.

Bad `filter` / unknown attribute → `QUERY_ERROR`.

---

### 3.3 `get_entity`

Single entity by primary key.

**Capability:** `dataclass` ∈ token `read`.

**Request**
```json
{ "v": 1, "action": "get_entity",
  "params": { "dataclass": "Customer", "key": 1, "attributes": ["ID","name","email"] } }
```

**Response `data`** — the entity object, or `NOT_FOUND` if the key doesn't resolve.
```json
{ "ID": 1, "name": "Acme Co", "email": "a@acme.test" }
```

---

### 3.4 `create_entity`

**Capability:** `dataclass` ∈ token `write`.

**Request**
```json
{ "v": 1, "action": "create_entity",
  "params": { "dataclass": "Order", "values": { "customerID": 1, "total": 0 } } }
```

**Response `data`**
```json
{ "key": 5012, "created": true }
```

Validation failure (stamp, required attr, unique) → `QUERY_ERROR` with 4D's message.

---

### 3.5 `update_entity`

**Capability:** `dataclass` ∈ token `write`.

**Request**
```json
{ "v": 1, "action": "update_entity",
  "params": { "dataclass": "Order", "key": 5012, "values": { "total": 250 } } }
```

**Response `data`**
```json
{ "key": 5012, "updated": true }
```

Missing key → `NOT_FOUND`. Optimistic-lock / validation failure → `QUERY_ERROR`.

---

### 3.6 `delete_entity`

**Capability:** `dataclass` ∈ token `write`.

**Request**
```json
{ "v": 1, "action": "delete_entity",
  "params": { "dataclass": "Order", "key": 5012 } }
```

**Response `data`**
```json
{ "key": 5012, "deleted": true }
```

Missing key → `NOT_FOUND`. Blocked by trigger/relation → `QUERY_ERROR`.

---

### 3.7 `call_method`

Invoke a **whitelisted host method**. The client names an *action name*, never a 4D method name. The 4D-side deployment config (`METHOD_WHITELIST`) holds the map `{ action_name → {method, args, return, purpose} }`, where `method` is a host project method executed via `EXECUTE METHOD`; anything not in the map is unreachable, and `method` never crosses the wire.

`args` on the wire is a **collection, bound positionally** to the host method's parameters (4D method params are positional). The whitelist entry's `args` spec is ordered — each `{name, type, required, purpose}` with `type` ∈ `text|number|boolean|object|collection`; `name` is documentation for the client, position is what binds. Optional args are trailing-only. Arity/type violations against the spec → `BAD_PARAMS` (gate 4, before capability). Callable actions and their specs are discoverable per-token via `get_schema_digest.callable_actions` (§3.1).

**Capability:** `name` ∈ token `call` **and** `name` ∈ `METHOD_WHITELIST`, else `CAP_DENIED`.

**Request**
```json
{ "v": 1, "action": "call_method",
  "params": { "name": "get_open_invoices", "args": [1] } }
```

**Response `data`** — whatever the host method returns (must be JSON-serializable), wrapped:
```json
{ "name": "get_open_invoices", "result": { "invoices": [ ] } }
```

Host method throws → `INTERNAL` (message from the 4D error), not the raw stack.

---

## 4. Error codes (fixed set)

| Code             | HTTP | Meaning                                             |
|------------------|------|-----------------------------------------------------|
| `AUTH_DENIED`    | 401  | Missing/invalid/expired token.                      |
| `BAD_VERSION`    | 400  | `v` absent or ≠ 1.                                   |
| `UNKNOWN_ACTION` | 400  | `action` not in §3.                                 |
| `BAD_PARAMS`     | 400  | Required param missing or wrong type.               |
| `CAP_DENIED`     | 403  | Token lacks capability for this action/dataclass.   |
| `NOT_FOUND`      | 404  | Entity key / method name doesn't resolve.           |
| `QUERY_ERROR`    | 422  | Valid request, 4D rejected it (filter/validation).  |
| `RATE_LIMITED`   | 429  | Token exceeded the server's per-minute request cap. Retry after the current minute window. |
| `INTERNAL`       | 500  | Unexpected 4D-side failure.                         |

No codes outside this set. `message` is human-readable and safe to surface to the model; it must not leak stack traces or connection internals.

---

## 5. Testability guarantees

- **Half B in isolation:** every action is exercisable with `curl` — a Bearer token and a JSON body, no MCP server required.
- **Half A in isolation:** the envelope is fully specified, so the 4D side can be mocked with a static fixture server returning canned `data`/`error` bodies.
- **Version pinning:** both halves assert `v == 1` and reject mismatches, so a future v2 can't silently talk to a v1 peer.

---

## 6. Open items (deferred past v1)

- Cursor pagination (v1 is offset-only).
- Field-level projection *capability* limits (v1 gates at dataclass level; `attributes` is a client convenience, not a security boundary — do not rely on it to hide fields).
- Batch/transaction envelope (multiple mutations atomically).
- Relation traversal in `query_entities` (v1 returns scalar attributes only).
