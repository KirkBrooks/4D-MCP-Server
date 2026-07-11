import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { FourDClient } from "./client.js";
import { TransportError, WireError } from "./wire.js";

const SERVER_INFO = { name: "4d-data-mcp", version: "1.0.0" };

const dataclass = z
  .string()
  .describe("Dataclass name, e.g. 'Customer'. Discover names via 4d_get_schema_digest.");

const entityKey = z
  .union([z.string(), z.number()])
  .describe("Primary-key value of the entity.");

const attributes = z
  .array(z.string())
  .optional()
  .describe("Projection: attribute names to return. Omitted = all scalar attributes.");

type ToolResult = {
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
};

function ok(payload: unknown): ToolResult {
  return { content: [{ type: "text", text: JSON.stringify(payload, null, 2) }] };
}

function fail(err: unknown): ToolResult {
  let text: string;
  if (err instanceof WireError) {
    text = `${err.code}: ${err.message}`;
  } else if (err instanceof TransportError) {
    text = `TRANSPORT: ${err.message}`;
  } else {
    text = `TRANSPORT: ${err instanceof Error ? err.message : String(err)}`;
  }
  return { isError: true, content: [{ type: "text", text }] };
}

async function run(call: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await call();
  } catch (err) {
    return fail(err);
  }
}

/**
 * Build the MCP server: one tool per wire-contract action, all delegating to
 * the given FourDClient. Capability enforcement lives entirely on the 4D side;
 * these tools surface its answers (data or error code) to the model.
 */
export function buildServer(client: FourDClient): McpServer {
  const server = new McpServer(SERVER_INFO);

  server.registerTool(
    "4d_get_schema_digest",
    {
      title: "Get 4D schema digest",
      description:
        "Describe the 4D data this token can reach: readable dataclasses (fields, " +
        "primary keys, relations) and the callable actions available to 4d_call_method. " +
        "Call this first to learn the schema.",
      inputSchema: {},
    },
    async () => run(async () => ok((await client.getSchemaDigest()).data)),
  );

  server.registerTool(
    "4d_query_entities",
    {
      title: "Query 4D entities",
      description:
        "Query one dataclass with an optional ORDA filter string and offset pagination. " +
        "Placeholders :1, :2, ... in the filter bind positionally from 'params' " +
        "(injection-safe — always use placeholders for values). Page size is capped " +
        "at 80; the response meta reports count/total/truncated for paging.",
      inputSchema: {
        dataclass,
        filter: z
          .string()
          .optional()
          .describe("4D ORDA query string, e.g. \"name = :1 and active = true\"."),
        params: z
          .array(z.union([z.string(), z.number(), z.boolean()]))
          .optional()
          .describe("Positional values bound to the filter's :1, :2, ... placeholders."),
        orderBy: z.string().optional().describe("e.g. \"name asc\" or \"created desc\"."),
        attributes,
        offset: z.number().int().min(0).optional().describe("Row offset, default 0."),
        limit: z
          .number()
          .int()
          .min(1)
          .optional()
          .describe("Page size, default 80, hard cap 80 (server clamps)."),
      },
    },
    async (args) =>
      run(async () => {
        const res = await client.queryEntities(args);
        return ok({ data: res.data, meta: res.meta });
      }),
  );

  server.registerTool(
    "4d_get_entity",
    {
      title: "Get one 4D entity",
      description: "Fetch a single entity by primary key. Errors NOT_FOUND if the key doesn't resolve.",
      inputSchema: { dataclass, key: entityKey, attributes },
    },
    async (args) => run(async () => ok((await client.getEntity(args)).data)),
  );

  server.registerTool(
    "4d_create_entity",
    {
      title: "Create a 4D entity",
      description:
        "Create one entity from an attribute→value object. Returns the new primary key. " +
        "Requires write capability on the dataclass.",
      inputSchema: {
        dataclass,
        values: z
          .record(z.unknown())
          .describe("Attribute name → value for the new entity."),
      },
    },
    async (args) => run(async () => ok((await client.createEntity(args)).data)),
  );

  server.registerTool(
    "4d_update_entity",
    {
      title: "Update a 4D entity",
      description:
        "Update attributes of one entity by primary key. Requires write capability on the dataclass.",
      inputSchema: {
        dataclass,
        key: entityKey,
        values: z.record(z.unknown()).describe("Attribute name → new value."),
      },
    },
    async (args) => run(async () => ok((await client.updateEntity(args)).data)),
  );

  server.registerTool(
    "4d_delete_entity",
    {
      title: "Delete a 4D entity",
      description:
        "Delete one entity by primary key. Requires write capability on the dataclass. " +
        "Irreversible — be certain of the key first.",
      inputSchema: { dataclass, key: entityKey },
    },
    async (args) => run(async () => ok((await client.deleteEntity(args)).data)),
  );

  server.registerTool(
    "4d_call_method",
    {
      title: "Call a whitelisted 4D action",
      description:
        "Invoke a server-whitelisted business action by its action name (never a raw 4D " +
        "method name). Discover callable actions and their argument specs via " +
        "4d_get_schema_digest's callable_actions. 'args' binds positionally to the " +
        "action's declared parameters.",
      inputSchema: {
        name: z.string().describe("Action name from callable_actions."),
        args: z
          .array(z.unknown())
          .optional()
          .describe("Positional arguments matching the action's declared arg spec."),
      },
    },
    async (args) => run(async () => ok((await client.callMethod(args)).data)),
  );

  return server;
}
