# mcp-servers

MCP servers that expose Harness tooling to agents.

| Path | Language | What it does |
|------|----------|--------------|
| [`harness-monitor/`](harness-monitor/) | TypeScript (Node.js) | stdio MCP server with 8 tools for enumerating Harness Monitor windows and elements, driving the mouse and keyboard, and capturing screenshots. |
| [`harness-monitor-registry/`](harness-monitor-registry/) | Swift (SPM) | App-side actor + POSIX Unix-socket NDJSON listener that the TypeScript server connects to. Includes a `.trackAccessibility()` SwiftUI view modifier. |

## Architecture

```
Claude Code / MCP client
        |
        | stdio (MCP JSON-RPC)
        v
+--------------------------------+
| harness-monitor (Node)         |
|  - tools/list                  |
|  - tools/call                  |
|  - NDJSON over Unix socket ----+-----+
|  - cliclick / osascript        |     |
|  - screencapture               |     |
+--------------------------------+     |
                                       |
                                       v
                           /Library/Group Containers/
                           Q498EB36N4.io.harnessmonitor/
                           harness-monitor-mcp.sock
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

## Integrating the Swift package into Harness Monitor

The package lives as a sibling SPM package so the app's `project.yml`/`pbxproj` can stay untouched while unrelated WIP settles. To wire it in:

1. Add the package as a local dependency to `apps/harness-monitor-macos/project.yml` under `packages:`

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

4. Launch the listener at app startup (see `mcp-servers/harness-monitor-registry/README.md` for the snippet).

5. Tag views with `.trackAccessibility(...)`.

## Wiring to Claude Code

Add to your repo or user `.mcp.json`:

```json
{
  "mcpServers": {
    "harness-monitor": {
      "command": "node",
      "args": ["/abs/path/harness/mcp-servers/harness-monitor/dist/server.js"]
    }
  }
}
```

The MCP server requires Accessibility permission (for `cliclick`/`osascript`) and Screen Recording permission (for window-scoped screenshots).
