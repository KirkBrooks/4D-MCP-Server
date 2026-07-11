/**
 * Integration suite — drives the real MCP tool layer against a live Half B.
 * Needs a running 4D with the /mcp handler (see 4d-mcp-server/test/start_server.sh).
 *
 *   FOURD_MCP_URL=http://localhost:8044/mcp FOURD_MCP_TOKEN=SECRET_FULL \
 *     node --test --import tsx test/integration.test.ts
 *
 * Assumes the fixture datastore (Customer/Order) and the SECRET_FULL token
 * (read Customer+Order, write Order, call ping/order_count/echo_upper).
 */
import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { FourDClient } from "../src/client.js";
import { buildServer } from "../src/server.js";
import { WireError } from "../src/wire.js";

const URL_ = process.env.FOURD_MCP_URL ?? "http://localhost:8044/mcp";
const TOKEN = process.env.FOURD_MCP_TOKEN ?? "SECRET_FULL";

let mcp: Client;

function text(result: { content?: unknown }): string {
  const content = result.content as Array<{ type: string; text: string }>;
  return content[0]?.text ?? "";
}

async function call(name: string, args: Record<string, unknown> = {}) {
  const result = await mcp.callTool({ name, arguments: args });
  return { isError: result.isError === true, text: text(result) };
}

before(async () => {
  // Fail fast with a clear message if the 4D server isn't up.
  const probe = new FourDClient({ url: URL_, token: TOKEN, timeoutMs: 5000 });
  try {
    await probe.getSchemaDigest();
  } catch (err) {
    throw new Error(
      `live 4D endpoint not reachable at ${URL_} — start it first (test/start_server.sh). ` +
        `Underlying: ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  const server = buildServer(new FourDClient({ url: URL_, token: TOKEN }));
  mcp = new Client({ name: "integration-client", version: "0.0.0" });
  const [ct, st] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(st), mcp.connect(ct)]);
});

after(async () => {
  await mcp?.close();
});

describe("live: discovery", () => {
  it("get_schema_digest exposes the fixture dataclasses and callable actions", async () => {
    const res = await call("4d_get_schema_digest");
    assert.equal(res.isError, false, res.text);
    const digest = JSON.parse(res.text);
    const names = digest.dataclasses.map((d: { name: string }) => d.name);
    assert.ok(names.includes("Customer") && names.includes("Order"), `got ${names}`);
    const actions = digest.callable_actions.map((a: { name: string }) => a.name);
    assert.ok(actions.includes("ping"), `got ${actions}`);
  });
});

describe("live: query", () => {
  it("queries Customer with a bound placeholder filter", async () => {
    const res = await call("4d_query_entities", {
      dataclass: "Customer",
      filter: "ID >= :1",
      params: [0],
      orderBy: "ID asc",
      limit: 5,
    });
    assert.equal(res.isError, false, res.text);
    const parsed = JSON.parse(res.text);
    assert.ok(Array.isArray(parsed.data));
    assert.equal(typeof parsed.meta.total, "number");
    assert.ok(parsed.meta.limit <= 80);
  });

  it("clamps limit to the hard cap and reports it in meta", async () => {
    const res = await call("4d_query_entities", { dataclass: "Customer", limit: 500 });
    assert.equal(res.isError, false, res.text);
    const parsed = JSON.parse(res.text);
    assert.equal(parsed.meta.limit, 80);
    assert.equal(parsed.meta.clamped, true);
  });

  it("bad filter surfaces QUERY_ERROR", async () => {
    const res = await call("4d_query_entities", {
      dataclass: "Customer",
      filter: "noSuchAttribute = :1",
      params: ["x"],
    });
    assert.equal(res.isError, true);
    assert.match(res.text, /^QUERY_ERROR: /);
  });
});

describe("live: CRUD round trip on Order", () => {
  let key: number;

  it("creates", async () => {
    const res = await call("4d_create_entity", {
      dataclass: "Order",
      values: { customerID: 1, total: 12.5, status: "open" },
    });
    assert.equal(res.isError, false, res.text);
    const created = JSON.parse(res.text);
    assert.equal(created.created, true);
    key = created.key;
    assert.ok(key !== undefined && key !== null);
  });

  it("reads it back", async () => {
    const res = await call("4d_get_entity", { dataclass: "Order", key });
    assert.equal(res.isError, false, res.text);
    const entity = JSON.parse(res.text);
    assert.equal(entity.total, 12.5);
    assert.equal(entity.status, "open");
  });

  it("updates", async () => {
    const res = await call("4d_update_entity", {
      dataclass: "Order",
      key,
      values: { total: 250 },
    });
    assert.equal(res.isError, false, res.text);
    assert.equal(JSON.parse(res.text).updated, true);

    const check = await call("4d_get_entity", { dataclass: "Order", key });
    assert.equal(JSON.parse(check.text).total, 250);
  });

  it("deletes", async () => {
    const res = await call("4d_delete_entity", { dataclass: "Order", key });
    assert.equal(res.isError, false, res.text);
    assert.equal(JSON.parse(res.text).deleted, true);
  });

  it("get after delete is NOT_FOUND", async () => {
    const res = await call("4d_get_entity", { dataclass: "Order", key });
    assert.equal(res.isError, true);
    assert.match(res.text, /^NOT_FOUND: /);
  });
});

describe("live: call_method", () => {
  it("ping round-trips", async () => {
    const res = await call("4d_call_method", { name: "ping", args: ["hello"] });
    assert.equal(res.isError, false, res.text);
    const data = JSON.parse(res.text);
    assert.equal(data.name, "ping");
    assert.equal(data.result.pong, true);
  });

  it("missing required arg surfaces BAD_PARAMS", async () => {
    const res = await call("4d_call_method", { name: "echo_upper", args: [] });
    assert.equal(res.isError, true);
    assert.match(res.text, /^BAD_PARAMS: /);
  });

  it("non-whitelisted action surfaces CAP_DENIED", async () => {
    const res = await call("4d_call_method", { name: "not_a_real_action" });
    assert.equal(res.isError, true);
    assert.match(res.text, /^CAP_DENIED: /);
  });
});

describe("live: auth and capability gates", () => {
  it("wrong token yields AUTH_DENIED at the client layer", async () => {
    const bad = new FourDClient({ url: URL_, token: "WRONG_TOKEN", timeoutMs: 5000 });
    await assert.rejects(
      bad.getSchemaDigest(),
      (err: unknown) => err instanceof WireError && err.code === "AUTH_DENIED",
    );
  });

  it("writing a read-only dataclass yields CAP_DENIED", async () => {
    const res = await call("4d_create_entity", {
      dataclass: "Customer",
      values: { name: "Should Not Exist" },
    });
    assert.equal(res.isError, true);
    assert.match(res.text, /^CAP_DENIED: /);
  });
});
