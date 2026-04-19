# harness-monitor-mcp

MCP server that lets agents drive the Harness Monitor macOS app - enumerate windows and accessibility elements, move and click the mouse, type text, and capture screenshots.

The server ships as a Node.js stdio MCP server. It talks to the running Harness Monitor app over a Unix domain socket exposed by an in-process `AccessibilityRegistry`. Mouse, keyboard, and screenshot operations run in the MCP server process using macOS system tools (`cliclick`, `osascript`, `screencapture`).

## Tools

| Tool | What it does | Backing mechanism |
|------|--------------|-------------------|
| `list_windows` | Returns `CGWindowID`, title, role, and frame for each Harness Monitor window. | IPC to app |
| `list_elements` | Returns registered interactive elements. Filter by `windowID` or `kind`. | IPC to app |
| `get_element` | Full metadata for an element by `.accessibilityIdentifier`. | IPC to app |
| `move_mouse` | Move cursor to screen `(x, y)`. No click. | `cliclick` |
| `click` | Click at `(x, y)` with optional `button` and `doubleClick`. | `cliclick` |
| `click_element` | Resolve an identifier to its frame and click the center. | IPC + `cliclick` |
| `type_text` | Type text into the focused window. Unicode-safe. | `cliclick` (fallback `osascript`) |
| `screenshot_window` | Capture a window (`windowID`) or display. Returns PNG. | `/usr/sbin/screencapture` |

All coordinates are in global screen space, origin at top-left (matching `CGEvent`). Elements publish frames via `GeometryReader` + `CoordinateSpace.global`.

## Prerequisites

- macOS 26+ (the app itself targets macOS 26 and uses `MACOSX_DEPLOYMENT_TARGET = 26.0`)
- Node.js 20+
- `cliclick` - `brew install cliclick` (required for mouse and preferred for keyboard)
- Accessibility permission granted to whichever process runs this MCP server (Claude Code, iTerm, etc.) - System Settings -> Privacy & Security -> Accessibility
- Screen Recording permission if you use `screenshot_window` with a `windowID`

## Build

```bash
cd mcp-servers/harness-monitor
npm install
npm run build
npm test
```

`npm test` compiles and runs the IPC framing tests against a stub Unix-socket server.

## Wire up to Claude Code

Add to `.mcp.json` at the repo root (or user settings):

```json
{
  "mcpServers": {
    "harness-monitor": {
      "command": "node",
      "args": ["/absolute/path/to/harness/mcp-servers/harness-monitor/dist/server.js"],
      "env": {}
    }
  }
}
```

## Socket location

Default: `~/Library/Group Containers/Q498EB36N4.io.harnessmonitor/harness-monitor-mcp.sock`

This lives inside the app-group container so the sandboxed Harness Monitor daemon and the unsandboxed MCP server both see the same path. Override with `HARNESS_MONITOR_MCP_SOCKET=<path>` for testing or when running the app unsandboxed.

## Protocol

NDJSON over a Unix domain socket. One JSON object per line in each direction.

Request:

```json
{"id": 7, "op": "listElements", "windowID": 1234, "kind": "button"}
```

Response:

```json
{"id": 7, "ok": true, "result": {"elements": [...]}}
```

Error:

```json
{"id": 7, "ok": false, "error": {"code": "not-found", "message": "no element with identifier 'foo'"}}
```

See `src/protocol.ts` for the full request/response contract.

## Permissions and entitlements

The MCP server process needs:

- **Accessibility** - for `cliclick` and `osascript` to synthesize mouse/keyboard events
- **Screen Recording** - for window screenshots with a `windowID`

The Harness Monitor app side needs its socket listener allowed to bind inside the app-group container - no extra entitlement beyond the existing app-group membership. The listener uses `Network.framework` with a `.unix(path:)` endpoint.

## Development

Build once, then run the server against the live app:

```bash
npm run build
# in another terminal, launch Harness Monitor.app normally
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | node dist/server.js
```

Use the MCP Inspector for a better UX:

```bash
npx @modelcontextprotocol/inspector node dist/server.js
```

## Layout

```
mcp-servers/harness-monitor/
├── package.json
├── tsconfig.json
├── README.md
└── src/
    ├── server.ts       # MCP stdio server + tool dispatch
    ├── ipc.ts          # Unix-socket NDJSON client
    ├── ipc.test.ts     # framing and error-path tests
    ├── protocol.ts     # shared request/response types
    └── automation.ts   # cliclick/osascript/screencapture wrappers
```

## Swift integration (pending)

The MCP server expects an `AccessibilityRegistry` inside `HarnessMonitor.app` that:

1. Binds an `NWListener` on `.unix(path:)` at `$GROUP_CONTAINER/harness-monitor-mcp.sock`
2. Tracks elements registered via a `.trackAccessibility()` view modifier (GeometryReader-backed frame capture)
3. Accepts NDJSON requests and answers with the types in `src/protocol.ts`

See `docs/harness-monitor-mcp-swift-integration.md` (pending) for the Swift side.
