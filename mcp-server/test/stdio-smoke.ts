/**
 * Stdio smoke test — spawns the built server (dist/index.js) exactly as an MCP
 * client (Claude Code, Claude Desktop) would, lists tools, and calls one.
 *
 *   npm run build && FOURD_MCP_URL=... FOURD_MCP_TOKEN=... npx tsx test/stdio-smoke.ts
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const url = process.env.FOURD_MCP_URL ?? "http://localhost:8044/mcp";
const token = process.env.FOURD_MCP_TOKEN ?? "SECRET_FULL";

const transport = new StdioClientTransport({
  command: process.execPath,
  args: ["dist/index.js"],
  env: { ...process.env, FOURD_MCP_URL: url, FOURD_MCP_TOKEN: token } as Record<string, string>,
});

const client = new Client({ name: "stdio-smoke", version: "0.0.0" });
await client.connect(transport);

const { tools } = await client.listTools();
console.log(`tools (${tools.length}):`, tools.map((t) => t.name).join(", "));

const result = await client.callTool({ name: "4d_call_method", arguments: { name: "ping", args: ["stdio"] } });
const first = (result.content as Array<{ text: string }>)[0];
console.log("ping over stdio →", first.text);

await client.close();
