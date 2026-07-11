import {
  TransportError,
  WIRE_VERSION,
  WireAction,
  WireError,
  WireResponse,
  WireSuccess,
  isErrorCode,
} from "./wire.js";

export interface FourDClientOptions {
  /** Full URL of the 4D-side endpoint, e.g. http://localhost:8044/mcp */
  url: string;
  /** Bearer token sent on every request. */
  token: string;
  /** Per-request timeout in milliseconds. Default 30000. */
  timeoutMs?: number;
  /** Injectable fetch for tests. Defaults to global fetch. */
  fetchImpl?: typeof fetch;
}

/**
 * Thin HTTP client for the v1 wire contract. One method per contract action;
 * all of them funnel through `request()`, which owns the envelope, auth
 * header, and error mapping.
 *
 * Throws WireError for contract errors ({ok:false} envelopes) and
 * TransportError for everything that never produced a valid envelope.
 */
export class FourDClient {
  private readonly url: string;
  private readonly token: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: FourDClientOptions) {
    this.url = options.url;
    this.token = options.token;
    this.timeoutMs = options.timeoutMs ?? 30_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async request<T = unknown>(
    action: WireAction,
    params: Record<string, unknown> = {},
  ): Promise<WireSuccess<T>> {
    let response: Response;
    try {
      response = await this.fetchImpl(this.url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.token}`,
        },
        body: JSON.stringify({ v: WIRE_VERSION, action, params }),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      throw new TransportError(`POST ${this.url} failed: ${detail}`);
    }

    let body: unknown;
    try {
      body = await response.json();
    } catch {
      throw new TransportError(
        `POST ${this.url} returned HTTP ${response.status} with a non-JSON body`,
      );
    }

    const envelope = this.assertEnvelope(body, response.status);
    if (!envelope.ok) {
      throw new WireError(envelope.error.code, envelope.error.message);
    }
    return envelope as WireSuccess<T>;
  }

  getSchemaDigest() {
    return this.request("get_schema_digest");
  }

  queryEntities(params: Record<string, unknown>) {
    return this.request("query_entities", params);
  }

  getEntity(params: Record<string, unknown>) {
    return this.request("get_entity", params);
  }

  createEntity(params: Record<string, unknown>) {
    return this.request("create_entity", params);
  }

  updateEntity(params: Record<string, unknown>) {
    return this.request("update_entity", params);
  }

  deleteEntity(params: Record<string, unknown>) {
    return this.request("delete_entity", params);
  }

  callMethod(params: Record<string, unknown>) {
    return this.request("call_method", params);
  }

  private assertEnvelope(body: unknown, httpStatus: number): WireResponse {
    if (typeof body !== "object" || body === null) {
      throw new TransportError(
        `peer replied HTTP ${httpStatus} with a non-object JSON body`,
      );
    }
    const env = body as Record<string, unknown>;
    if (env.v !== WIRE_VERSION) {
      throw new TransportError(
        `peer replied with wire version ${JSON.stringify(env.v)}; this client speaks v${WIRE_VERSION}`,
      );
    }
    if (env.ok === true) {
      if (!("data" in env)) {
        throw new TransportError("success envelope is missing 'data'");
      }
      return env as unknown as WireResponse;
    }
    if (env.ok === false) {
      const error = env.error as Record<string, unknown> | undefined;
      if (
        typeof error !== "object" ||
        error === null ||
        !isErrorCode(error.code) ||
        typeof error.message !== "string"
      ) {
        throw new TransportError(
          `error envelope has a malformed 'error' member (HTTP ${httpStatus})`,
        );
      }
      return env as unknown as WireResponse;
    }
    throw new TransportError(
      `peer envelope has no boolean 'ok' member (HTTP ${httpStatus})`,
    );
  }
}
