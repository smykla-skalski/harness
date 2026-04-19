# mcp-servers

MCP pieces that let agents drive the Harness Monitor macOS app.

| Path | Language | What it does |
|------|----------|--------------|
| `harness mcp serve` (in `../src/mcp/`) | Rust (part of `harness` CLI) | stdio MCP JSON-RPC server with 8 tools for enumerating Harness Monitor windows and elements, driving the mouse and keyboard, and capturing screenshots. |
| [`harness-monitor-registry/`](harness-monitor-registry/) | Swift (SPM) | App-side actor + POSIX Unix-socket NDJSON listener that the Rust server connects to. Includes a `.trackAccessibility()` SwiftUI view modifier. |

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
|  - cliclick / osascript        |     |
|  - /usr/sbin/screencapture     |     |
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

- Accessibility permission for the process that runs `harness` (for `cliclick` / `harness-monitor-input` / `osascript` to synthesize CGEvents)
- Screen Recording permission for window-scoped screenshots

If neither `harness-monitor-input` (the bundled Swift helper) nor `cliclick` is on the machine, text input still works through `osascript`; mouse input does not.

## Tools

| Tool | Behavior |
|------|----------|
| `list_windows` | Registry `listWindows`: window id, title, role, frame, key/main flags. |
| `list_elements` | Registry `listElements` with optional `windowID` and `kind` filters. |
| `get_element` | Registry `getElement` by `.accessibilityIdentifier`. |
| `move_mouse` | Move cursor to global `(x, y)`. No click. |
| `click` | Left/right click at global `(x, y)`, with optional double-click. Middle-click is not supported. |
| `click_element` | Resolve identifier to frame, click its center. |
| `type_text` | Type Unicode text into the focused window. |
| `screenshot_window` | Capture a window by `windowID` or a display by `displayID`; returns base64 PNG. |

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

3. Regenerate with `apps/harness-monitor-macos/Scripts/generate-project.sh`.

4. Bind the listener at app startup, gated by the Preferences toggle (see that module's README).

5. Tag SwiftUI views with `.trackAccessibility(...)`.

## See also

- `../src/mcp/` - Rust server implementation
- `harness-monitor-registry/` - Swift registry host (app side)
