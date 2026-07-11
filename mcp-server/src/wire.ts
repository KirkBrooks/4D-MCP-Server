/**
 * Wire contract v1 types — the boundary with Half B (the in-4D handler).
 * Source of truth: ai-context/mcp_data_wire_contract.md
 */

export const WIRE_VERSION = 1 as const;

export const ERROR_CODES = [
  "AUTH_DENIED",
  "BAD_VERSION",
  "UNKNOWN_ACTION",
  "BAD_PARAMS",
  "CAP_DENIED",
  "NOT_FOUND",
  "QUERY_ERROR",
  "RATE_LIMITED",
  "INTERNAL",
] as const;

export type WireErrorCode = (typeof ERROR_CODES)[number];

export type WireAction =
  | "get_schema_digest"
  | "query_entities"
  | "get_entity"
  | "create_entity"
  | "update_entity"
  | "delete_entity"
  | "call_method";

export interface WireRequest {
  v: typeof WIRE_VERSION;
  action: WireAction;
  params: Record<string, unknown>;
}

export interface WireSuccess<T = unknown> {
  v: typeof WIRE_VERSION;
  ok: true;
  data: T;
  meta?: Record<string, unknown>;
}

export interface WireFailure {
  v: typeof WIRE_VERSION;
  ok: false;
  error: { code: WireErrorCode; message: string };
}

export type WireResponse<T = unknown> = WireSuccess<T> | WireFailure;

/** The 4D side rejected the request with a contract error code. */
export class WireError extends Error {
  readonly code: WireErrorCode;

  constructor(code: WireErrorCode, message: string) {
    super(message);
    this.name = "WireError";
    this.code = code;
  }
}

/**
 * The HTTP exchange itself failed, or the peer's reply was not a valid v1
 * envelope (unreachable host, non-JSON body, wrong wire version, ...).
 */
export class TransportError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TransportError";
  }
}

export function isErrorCode(value: unknown): value is WireErrorCode {
  return typeof value === "string" && (ERROR_CODES as readonly string[]).includes(value);
}
