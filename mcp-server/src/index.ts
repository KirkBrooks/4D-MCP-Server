#!/usr/bin/env node
/**
 * 4D Data MCP — Half A entry point.
 *
 * Env:
 *   FOURD_MCP_URL    endpoint URL (default http://localhost:8044/mcp)
 *   FOURD_MCP_TOKEN  Bearer token (required)
 *   FOURD_MCP_TIMEOUT_MS  per-request timeout (default 30000)
 */
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { FourDClient } from "./client.js";
import { buildServer } from "./server.js";

const url = process.env.FOURD_MCP_URL ?? "http://localhost:8044/mcp";
const token = process.env.FOURD_MCP_TOKEN;
const timeoutMs = Number(process.env.FOURD_MCP_TIMEOUT_MS ?? "30000");

if (!token) {
  console.error("4d-data-mcp: FOURD_MCP_TOKEN is required (Bearer token for the 4D endpoint)");
  process.exit(1);
}
if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
  console.error("4d-data-mcp: FOURD_MCP_TIMEOUT_MS must be a positive number");
  process.exit(1);
}

const client = new FourDClient({ url, token, timeoutMs });
const server = buildServer(client);

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`4d-data-mcp: serving MCP over stdio, forwarding to ${url}`);
