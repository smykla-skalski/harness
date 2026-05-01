# mcp-servers

MCP pieces that let agents drive the Harness Monitor macOS app.

| Path | Language | What it does |
|------|----------|--------------|
| `harness mcp serve` (in `../src/mcp/`) | Rust (part of `harness` CLI) | stdio MCP JSON-RPC server with 11 tools for enumerating Harness Monitor windows and elements, driving the mouse and keyboard, semantically pressing registered controls, scrolling registered targets, dragging between registered targets, and capturing screenshots. `list_elements` and `get_element` consult the app-side registry first and fall back to the bundled AX query helper when needed. |
| [`harness-monitor-registry/`](harness-monitor-registry/) | Swift (SPM) | App-side actor + POSIX Unix-socket NDJSON listener that the Rust server connects to. Includes `.trackWindow(...)` for scene-root auto-harvest, `.trackAccessibility(...)` for explicit per-view registration, and the bundled `harness-monitor-input` helper for input, screenshots, and AX fallback queries. |

The old Node.js implementation under `harness-monitor/` was replaced by the native Rust server to drop the Node.js runtime dependency. The JSON wire protocol to the Swift host is unchanged.

## Architecture

```
Claude Code / MCP client
        |
        | stdio (MCP JSON-RPC 2.0, protocol version 2025-11-25)
        v
+--------------------------------+
| harness mcp serve (Rust)       |
|  - tools/list                  |
|  - tools/call                  |
|  - NDJSON over Unix socket ----+-----+
|  - harness-monitor-input       |     |
|  - cliclick (legacy fallback)  |     |
+--------------------------------+     |
                                       |
                                       v
                           $HOME/Library/Group Containers/
                           Q498EB36N4.io.harnessmonitor/
                           mcp.sock
                                       ^
                                       |
+---------------------------------------+
| Harness Monitor.app (Swift)           |
|  - HarnessMonitorRegistry             |
|      AccessibilityRegistry actor      |
|      RegistryListener (POSIX accept)  |
|  - .trackAccessibility(...) on views  |
+---------------------------------------+
```

## Wiring to Claude Code

Add to your repo or user `.mcp.json`:

```json
{
  "mcpServers": {
    "harness-monitor": {
      "command": "harness",
      "args": ["mcp", "serve"]
    }
  }
}
```

Point `--socket` at a custom path for unsandboxed dev:

```json
{
  "mcpServers": {
    "harness-monitor": {
      "command": "harness",
      "args": ["mcp", "serve", "--socket", "/tmp/mcp.sock"]
    }
  }
}
```

Override the socket via environment instead:

```
HARNESS_MONITOR_MCP_SOCKET=/tmp/mcp.sock harness mcp serve
```

Override the input helper binary:

```
HARNESS_MONITOR_INPUT_BIN=/path/to/harness-monitor-input harness mcp serve
```

The server requires:

- Accessibility permission for the process that runs `harness` (for `harness-monitor-input` / `cliclick` to synthesize CGEvents and query the AX tree)
- Screen Recording permission for window-scoped screenshots

If neither `harness-monitor-input` (the bundled Swift helper) nor `cliclick` is on the machine, input tools fail closed until one of those backends is available.

## Tools

| Tool | Behavior |
|------|----------|
| `list_windows` | Registry `listWindows`: window id, title, role, frame, key/main flags. |
| `list_elements` | Registry `listElements` with optional `windowID` and `kind` filters. If the registry returns an empty success, the server asks `harness-monitor-input list-elements` for the live macOS Accessibility tree and keeps the empty success if the helper cannot add data. Fresh window-scoped queries without a `kind` filter also do a short bounded registry retry before returning that final empty success. |
| `get_element` | Registry `getElement` by `.accessibilityIdentifier`. On `not-found` or registry transport failure, the server asks `harness-monitor-input get-element` for the live Accessibility tree. |
| `move_mouse` | Move cursor to global `(x, y)`. No click. |
| `click` | Left/right click at global `(x, y)`, with optional double-click. Middle-click is not supported. |
| `click_element` | Resolve identifier to frame, then click its center in global coordinates. This is a physical click, so whatever app is frontmost at that point receives it. |
| `press_element` | Resolve identifier, then ask `harness-monitor-input perform-action` to semantically activate the live accessibility element without moving the mouse or requiring Harness Monitor to be frontmost. The helper treats `press` as an activation intent (`AXPress` first, then compatible action names such as menu/show/open confirmations when needed) and retries once without a window filter if a scoped window match has gone stale. |
| `scroll` | Resolve identifier to frame, then scroll at its center by `deltaX` / `deltaY`. |
| `drag_drop` | Resolve source/destination identifiers to frames, then drag from one center to the other. |
| `type_text` | Type Unicode text into the focused window. |
| `screenshot_window` | Capture Harness Monitor windows only. `outputPath` is required and must point to a directory where PNG files will be written. When `windowID` is provided it is revalidated against the live registry window set; otherwise the server captures the current registry window set for that same app run, optionally narrowed to `displayID`. The tool response returns full absolute paths for every saved screenshot. |

Coordinates are in global screen space, origin at top-left (matching `CGEvent`).

## Integrating the Swift registry host into Harness Monitor

The Swift host is implemented as a sibling SPM package so the app's `project.yml` / `pbxproj` can stay untouched while unrelated work settles. To wire it in:

1. Add the package as a local dependency in `apps/harness-monitor-macos/project.yml`:

   ```yaml
   packages:
     HarnessMonitorRegistry:
       path: ../../mcp-servers/harness-monitor-registry
   ```

2. Depend on the product from `HarnessMonitorKit`:

   ```yaml
   targets:
     HarnessMonitorKit:
       dependencies:
         - package: HarnessMonitorRegistry
           product: HarnessMonitorRegistry
   ```

3. Regenerate with `mise run monitor:macos:generate`.

4. Bind the listener at app startup, gated by the Preferences toggle (see that module's README).

5. Attach `.trackWindow(...)` at each tracked scene root so the app publishes window metadata and auto-harvested controls. Use `.trackAccessibility(...)` only for explicit per-view registration when a view needs precise manual metadata.

## See also

- `../src/mcp/` - Rust server implementation
- `harness-monitor-registry/` - Swift registry host (app side)
