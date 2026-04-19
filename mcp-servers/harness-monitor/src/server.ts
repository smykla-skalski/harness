#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";

import {
  AutomationError,
  click,
  moveMouse,
  screenshot,
  typeText,
  type MouseButton,
} from "./automation.js";
import { RegistryClient, RegistryRequestError, RegistryUnavailableError } from "./ipc.js";
import type {
  GetElementResult,
  ListElementsResult,
  ListWindowsResult,
  RegistryElement,
} from "./protocol.js";

const client = new RegistryClient();

const MouseButtonSchema = z.enum(["left", "right", "middle"]);

const ToolSchemas = {
  list_windows: z.object({}).strict(),
  list_elements: z
    .object({
      windowID: z.number().int().optional(),
      kind: z
        .enum([
          "button",
          "toggle",
          "textField",
          "text",
          "link",
          "list",
          "row",
          "tab",
          "menuItem",
          "image",
          "other",
        ])
        .optional(),
    })
    .strict(),
  get_element: z.object({ identifier: z.string().min(1) }).strict(),
  move_mouse: z.object({ x: z.number(), y: z.number() }).strict(),
  click: z
    .object({
      x: z.number(),
      y: z.number(),
      button: MouseButtonSchema.optional(),
      doubleClick: z.boolean().optional(),
    })
    .strict(),
  click_element: z
    .object({
      identifier: z.string().min(1),
      button: MouseButtonSchema.optional(),
      doubleClick: z.boolean().optional(),
    })
    .strict(),
  type_text: z.object({ text: z.string() }).strict(),
  screenshot_window: z
    .object({
      windowID: z.number().int().optional(),
      displayID: z.number().int().optional(),
      includeCursor: z.boolean().optional(),
    })
    .strict(),
};

const ToolDefinitions = [
  {
    name: "list_windows",
    description:
      "List Harness Monitor windows with their CGWindowID, title, role, and frame in global screen coordinates.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false,
    },
  },
  {
    name: "list_elements",
    description:
      "List interactive elements registered by Harness Monitor. Filter by window id or element kind.",
    inputSchema: {
      type: "object",
      properties: {
        windowID: { type: "integer", description: "Only return elements in this window." },
        kind: {
          type: "string",
          enum: [
            "button",
            "toggle",
            "textField",
            "text",
            "link",
            "list",
            "row",
            "tab",
            "menuItem",
            "image",
            "other",
          ],
          description: "Filter by element kind.",
        },
      },
      additionalProperties: false,
    },
  },
  {
    name: "get_element",
    description: "Get the full metadata for a registered element by its accessibility identifier.",
    inputSchema: {
      type: "object",
      properties: {
        identifier: { type: "string", description: "The .accessibilityIdentifier value." },
      },
      required: ["identifier"],
      additionalProperties: false,
    },
  },
  {
    name: "move_mouse",
    description:
      "Move the mouse cursor to global screen coordinates (origin at top-left). No click is performed.",
    inputSchema: {
      type: "object",
      properties: {
        x: { type: "number" },
        y: { type: "number" },
      },
      required: ["x", "y"],
      additionalProperties: false,
    },
  },
  {
    name: "click",
    description:
      "Perform a mouse click at global screen coordinates. Supports left/right buttons and double click.",
    inputSchema: {
      type: "object",
      properties: {
        x: { type: "number" },
        y: { type: "number" },
        button: { type: "string", enum: ["left", "right", "middle"] },
        doubleClick: { type: "boolean" },
      },
      required: ["x", "y"],
      additionalProperties: false,
    },
  },
  {
    name: "click_element",
    description:
      "Resolve an accessibility identifier to an element and click its center in global coordinates.",
    inputSchema: {
      type: "object",
      properties: {
        identifier: { type: "string" },
        button: { type: "string", enum: ["left", "right", "middle"] },
        doubleClick: { type: "boolean" },
      },
      required: ["identifier"],
      additionalProperties: false,
    },
  },
  {
    name: "type_text",
    description:
      "Type the given text into whatever window currently has keyboard focus. Unicode-safe.",
    inputSchema: {
      type: "object",
      properties: { text: { type: "string" } },
      required: ["text"],
      additionalProperties: false,
    },
  },
  {
    name: "screenshot_window",
    description:
      "Capture a PNG screenshot. If windowID is provided, capture that window; otherwise the display. Returns base64 image content.",
    inputSchema: {
      type: "object",
      properties: {
        windowID: { type: "integer" },
        displayID: { type: "integer" },
        includeCursor: { type: "boolean" },
      },
      additionalProperties: false,
    },
  },
] as const;

const server = new Server(
  { name: "harness-monitor-mcp", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: ToolDefinitions.map((tool) => ({ ...tool })),
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const name = request.params.name;
  const args = request.params.arguments ?? {};

  try {
    switch (name) {
      case "list_windows":
        ToolSchemas.list_windows.parse(args);
        return await handleListWindows();
      case "list_elements": {
        const parsed = ToolSchemas.list_elements.parse(args);
        return await handleListElements(parsed);
      }
      case "get_element": {
        const parsed = ToolSchemas.get_element.parse(args);
        return await handleGetElement(parsed.identifier);
      }
      case "move_mouse": {
        const parsed = ToolSchemas.move_mouse.parse(args);
        await moveMouse(parsed.x, parsed.y);
        return jsonResponse({ ok: true });
      }
      case "click": {
        const parsed = ToolSchemas.click.parse(args);
        await click(
          parsed.x,
          parsed.y,
          parsed.button ?? "left",
          parsed.doubleClick ?? false,
        );
        return jsonResponse({ ok: true });
      }
      case "click_element": {
        const parsed = ToolSchemas.click_element.parse(args);
        return await handleClickElement(parsed);
      }
      case "type_text": {
        const parsed = ToolSchemas.type_text.parse(args);
        await typeText(parsed.text);
        return jsonResponse({ ok: true });
      }
      case "screenshot_window": {
        const parsed = ToolSchemas.screenshot_window.parse(args);
        const options: {
          windowID?: number;
          displayID?: number;
          includeCursor?: boolean;
        } = {};
        if (parsed.windowID !== undefined) options.windowID = parsed.windowID;
        if (parsed.displayID !== undefined) options.displayID = parsed.displayID;
        if (parsed.includeCursor !== undefined) options.includeCursor = parsed.includeCursor;
        const result = await screenshot(options);
        return {
          content: [
            {
              type: "image",
              data: result.bytes.toString("base64"),
              mimeType: "image/png",
            },
          ],
        };
      }
      default:
        return errorResponse(`Unknown tool: ${name}`);
    }
  } catch (err) {
    return errorResponse(formatError(err));
  }
});

async function handleListWindows() {
  const result = await client.request<ListWindowsResult>({
    id: client.nextRequestId(),
    op: "listWindows",
  });
  return jsonResponse(result);
}

async function handleListElements(
  args: z.infer<typeof ToolSchemas.list_elements>,
) {
  const request: {
    id: number;
    op: "listElements";
    windowID?: number;
    kind?: RegistryElement["kind"];
  } = { id: client.nextRequestId(), op: "listElements" };
  if (args.windowID !== undefined) request.windowID = args.windowID;
  if (args.kind !== undefined) request.kind = args.kind;
  const result = await client.request<ListElementsResult>(request);
  return jsonResponse(result);
}

async function handleGetElement(identifier: string) {
  const result = await client.request<GetElementResult>({
    id: client.nextRequestId(),
    op: "getElement",
    identifier,
  });
  return jsonResponse(result);
}

async function handleClickElement(
  args: z.infer<typeof ToolSchemas.click_element>,
) {
  const result = await client.request<GetElementResult>({
    id: client.nextRequestId(),
    op: "getElement",
    identifier: args.identifier,
  });
  const frame = result.element.frame;
  const centerX = frame.x + frame.width / 2;
  const centerY = frame.y + frame.height / 2;
  await click(
    centerX,
    centerY,
    (args.button ?? "left") as MouseButton,
    args.doubleClick ?? false,
  );
  return jsonResponse({ ok: true, clicked: { x: centerX, y: centerY } });
}

function jsonResponse(payload: unknown) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(payload, null, 2) }],
  };
}

function errorResponse(message: string) {
  return {
    content: [{ type: "text" as const, text: message }],
    isError: true,
  };
}

function formatError(err: unknown): string {
  if (err instanceof RegistryUnavailableError) {
    return err.message;
  }
  if (err instanceof RegistryRequestError) {
    return `Registry error (${err.code}): ${err.message}`;
  }
  if (err instanceof AutomationError) {
    return `Automation error (${err.code}): ${err.message}`;
  }
  if (err instanceof z.ZodError) {
    return `Invalid arguments: ${err.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ")}`;
  }
  if (err instanceof Error) {
    return err.message;
  }
  return String(err);
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  // Surface fatal errors on stderr so the harness can diagnose.
  process.stderr.write(`harness-monitor-mcp fatal: ${formatError(err)}\n`);
  client.close();
  process.exit(1);
});
