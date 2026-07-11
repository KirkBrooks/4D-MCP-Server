/**
 * Unit suite — exercises Half A against the canned fixture server (no 4D).
 *   node --test --import tsx test/unit.test.ts
 */
import assert from "node:assert/strict";
import { after, before, beforeEach, describe, it } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { FourDClient } from "../src/client.js";
import { buildServer } from "../src/server.js";
import { TransportError, WireError } from "../src/wire.js";
import { FIXTURE_TOKEN, startFixture, type FixtureServer } from "./fixture.js";

let fixture: FixtureServer;

before(async () => {
  fixture = await startFixture();
});
after(async () => {
  await fixture.close();
});
beforeEach(() => {
  fixture.reset();
});

function makeClient(overrides: Partial<{ url: string; token: string }> = {}) {
  return new FourDClient({
    url: overrides.url ?? fixture.url,
    token: overrides.token ?? FIXTURE_TOKEN,
    timeoutMs: 2000,
  });
}

describe("FourDClient envelope", () => {
  it("sends a v1 envelope with Bearer auth and JSON content type", async () => {
    const client = makeClient();
    await client.queryEntities({ dataclass: "Customer", limit: 10 });

    assert.equal(fixture.requests.length, 1);
    const req = fixture.requests[0];
    assert.equal(req.authorization, `Bearer ${FIXTURE_TOKEN}`);
    assert.match(req.contentType ?? "", /^application\/json/);
    assert.deepEqual(req.body, {
      v: 1,
      action: "query_entities",
      params: { dataclass: "Customer", limit: 10 },
    });
  });

  it("defaults params to an empty object", async () => {
    await makeClient().getSchemaDigest();
    assert.deepEqual(fixture.requests[0].body.params, {});
  });

  it("returns data and meta from a success envelope", async () => {
    const res = await makeClient().queryEntities({ dataclass: "Customer" });
    assert.deepEqual(res.data, [{ ID: 1, name: "Acme Co", email: "a@acme.test" }]);
    assert.equal((res.meta as Record<string, unknown>).total, 1);
  });
});

describe("FourDClient error mapping", () => {
  it("maps {ok:false} envelopes to WireError with the contract code", async () => {
    const client = makeClient({ token: "WRONG" });
    await assert.rejects(
      client.getSchemaDigest(),
      (err: unknown) => err instanceof WireError && err.code === "AUTH_DENIED",
    );
  });

  it("maps every contract error code", async () => {
    for (const [code, status] of [
      ["BAD_VERSION", 400],
      ["UNKNOWN_ACTION", 400],
      ["BAD_PARAMS", 400],
      ["CAP_DENIED", 403],
      ["NOT_FOUND", 404],
      ["QUERY_ERROR", 422],
      ["RATE_LIMITED", 429],
      ["INTERNAL", 500],
    ] as const) {
      fixture.respond("get_entity", status, {
        v: 1,
        ok: false,
        error: { code, message: `msg for ${code}` },
      });
      await assert.rejects(
        makeClient().getEntity({ dataclass: "Customer", key: 1 }),
        (err: unknown) =>
          err instanceof WireError && err.code === code && err.message === `msg for ${code}`,
      );
    }
  });

  it("throws TransportError on a non-JSON body", async () => {
    fixture.respond("get_entity", 502, "<html>bad gateway</html>");
    await assert.rejects(
      makeClient().getEntity({ dataclass: "Customer", key: 1 }),
      TransportError,
    );
  });

  it("throws TransportError on a wire-version mismatch", async () => {
    fixture.respond("get_entity", 200, { v: 2, ok: true, data: {} });
    await assert.rejects(
      makeClient().getEntity({ dataclass: "Customer", key: 1 }),
      (err: unknown) => err instanceof TransportError && /wire version 2/.test(err.message),
    );
  });

  it("throws TransportError on a malformed error envelope", async () => {
    fixture.respond("get_entity", 400, { v: 1, ok: false, error: { code: "NOT_A_CODE" } });
    await assert.rejects(
      makeClient().getEntity({ dataclass: "Customer", key: 1 }),
      TransportError,
    );
  });

  it("throws TransportError when the host is unreachable", async () => {
    const client = makeClient({ url: "http://127.0.0.1:1/mcp" });
    await assert.rejects(client.getSchemaDigest(), TransportError);
  });
});

describe("MCP tool layer", () => {
  async function connectedPair() {
    const server = buildServer(makeClient());
    const client = new Client({ name: "test-client", version: "0.0.0" });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    return { server, client };
  }

  function resultText(result: { content?: unknown }): string {
    const content = result.content as Array<{ type: string; text: string }>;
    return content[0]?.text ?? "";
  }

  it("registers one tool per wire action", async () => {
    const { client, server } = await connectedPair();
    const { tools } = await client.listTools();
    assert.deepEqual(
      tools.map((t) => t.name).sort(),
      [
        "4d_call_method",
        "4d_create_entity",
        "4d_delete_entity",
        "4d_get_entity",
        "4d_get_schema_digest",
        "4d_query_entities",
        "4d_update_entity",
      ],
    );
    await client.close();
    await server.close();
  });

  it("returns schema digest data as JSON text", async () => {
    const { client, server } = await connectedPair();
    const result = await client.callTool({ name: "4d_get_schema_digest", arguments: {} });
    const parsed = JSON.parse(resultText(result));
    assert.equal(parsed.dataclasses[0].name, "Customer");
    assert.equal(parsed.callable_actions[0].name, "order_count");
    await client.close();
    await server.close();
  });

  it("query tool wraps data with meta for pagination", async () => {
    const { client, server } = await connectedPair();
    const result = await client.callTool({
      name: "4d_query_entities",
      arguments: { dataclass: "Customer", filter: "name = :1", params: ["Acme*"] },
    });
    const parsed = JSON.parse(resultText(result));
    assert.equal(parsed.meta.total, 1);
    assert.equal(parsed.data[0].name, "Acme Co");
    // and the wire request carried the filter through unchanged
    const wire = fixture.requests.at(-1)!;
    assert.equal((wire.body.params as Record<string, unknown>).filter, "name = :1");
    await client.close();
    await server.close();
  });

  it("surfaces wire errors as isError results with the contract code", async () => {
    fixture.respond("delete_entity", 403, {
      v: 1,
      ok: false,
      error: { code: "CAP_DENIED", message: "token cannot write Customer" },
    });
    const { client, server } = await connectedPair();
    const result = await client.callTool({
      name: "4d_delete_entity",
      arguments: { dataclass: "Customer", key: 1 },
    });
    assert.equal(result.isError, true);
    assert.equal(resultText(result), "CAP_DENIED: token cannot write Customer");
    await client.close();
    await server.close();
  });

  it("surfaces transport failures as isError results", async () => {
    const server = buildServer(makeClient({ url: "http://127.0.0.1:1/mcp" }));
    const client = new Client({ name: "test-client", version: "0.0.0" });
    const [ct, st] = InMemoryTransport.createLinkedPair();
    await Promise.all([server.connect(st), client.connect(ct)]);
    const result = await client.callTool({ name: "4d_get_schema_digest", arguments: {} });
    assert.equal(result.isError, true);
    assert.match(resultText(result), /^TRANSPORT: /);
    await client.close();
    await server.close();
  });
});
