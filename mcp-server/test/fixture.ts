/**
 * Static fixture server standing in for Half B (contract §5: "the 4D side can
 * be mocked with a static fixture server returning canned data/error bodies").
 *
 * It enforces the outer gates for realism (Bearer token, v==1, known action)
 * and returns canned bodies per action. Tests can override any action's reply
 * with `respond()` and inspect what the client sent via `requests`.
 */
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

export const FIXTURE_TOKEN = "FIXTURE_TOKEN";

const KNOWN_ACTIONS = new Set([
  "get_schema_digest",
  "query_entities",
  "get_entity",
  "create_entity",
  "update_entity",
  "delete_entity",
  "call_method",
]);

const CANNED: Record<string, unknown> = {
  get_schema_digest: {
    v: 1,
    ok: true,
    data: {
      dataclasses: [
        {
          name: "Customer",
          primaryKey: "ID",
          fields: [
            { name: "ID", type: "number", key: true },
            { name: "name", type: "string" },
            { name: "email", type: "string" },
          ],
          relations: [{ name: "orders", target: "Order", kind: "one-to-many" }],
        },
      ],
      callable_actions: [
        {
          name: "order_count",
          args: [{ name: "status", type: "text", required: false, purpose: "filter" }],
          return: "object",
          purpose: "Count orders",
        },
      ],
    },
  },
  query_entities: {
    v: 1,
    ok: true,
    data: [{ ID: 1, name: "Acme Co", email: "a@acme.test" }],
    meta: { count: 1, offset: 0, limit: 80, total: 1, truncated: false, clamped: false },
  },
  get_entity: { v: 1, ok: true, data: { ID: 1, name: "Acme Co", email: "a@acme.test" } },
  create_entity: { v: 1, ok: true, data: { key: 5012, created: true } },
  update_entity: { v: 1, ok: true, data: { key: 5012, updated: true } },
  delete_entity: { v: 1, ok: true, data: { key: 5012, deleted: true } },
  call_method: { v: 1, ok: true, data: { name: "order_count", result: { count: 3 } } },
};

export interface CapturedRequest {
  authorization: string | undefined;
  contentType: string | undefined;
  body: Record<string, unknown>;
}

export interface FixtureServer {
  url: string;
  requests: CapturedRequest[];
  /** Override the reply for one action: { status, body } or a raw body string. */
  respond(action: string, status: number, body: unknown | string): void;
  reset(): void;
  close(): Promise<void>;
}

export async function startFixture(): Promise<FixtureServer> {
  const requests: CapturedRequest[] = [];
  const overrides = new Map<string, { status: number; body: unknown | string }>();

  const server: Server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      let body: Record<string, unknown> = {};
      try {
        body = JSON.parse(raw);
      } catch {
        /* leave empty; falls through to BAD_PARAMS below */
      }
      requests.push({
        authorization: req.headers.authorization,
        contentType: req.headers["content-type"],
        body,
      });

      const send = (status: number, payload: unknown | string) => {
        res.writeHead(status, { "Content-Type": "application/json" });
        res.end(typeof payload === "string" ? payload : JSON.stringify(payload));
      };
      const wireError = (status: number, code: string, message: string) =>
        send(status, { v: 1, ok: false, error: { code, message } });

      const action = String(body.action ?? "");
      const override = overrides.get(action);
      if (override) return send(override.status, override.body);

      if (req.headers.authorization !== `Bearer ${FIXTURE_TOKEN}`) {
        return wireError(401, "AUTH_DENIED", "missing or invalid token");
      }
      if (body.v !== 1) return wireError(400, "BAD_VERSION", "v must be 1");
      if (!KNOWN_ACTIONS.has(action)) {
        return wireError(400, "UNKNOWN_ACTION", `unknown action '${action}'`);
      }
      send(200, CANNED[action]);
    });
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;

  return {
    url: `http://127.0.0.1:${port}/mcp`,
    requests,
    respond(action, status, body) {
      overrides.set(action, { status, body });
    },
    reset() {
      overrides.clear();
      requests.length = 0;
    },
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}
