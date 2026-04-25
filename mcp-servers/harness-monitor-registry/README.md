# HarnessMonitorRegistry

Swift package that exposes Harness Monitor's accessibility elements to the `harness-monitor-mcp` Node server over a Unix domain socket.

## What's inside

- `AccessibilityRegistry` - Swift actor holding a dictionary of `RegistryElement` and `RegistryWindow` values. Thread-safe by construction.
- `RegistryRequestDispatcher` - transport-agnostic handler that turns a `RegistryRequest` into a `RegistryResponse`. Unit tested without sockets.
- `RegistryListener` - POSIX-socket-based NDJSON server. `NWListener` does not expose a filesystem-socket listen path reliably, so accept() runs on a dedicated `DispatchQueue` and each connection is driven by a `DispatchSource.makeReadSource` + non-blocking `recv()` loop.
- `NDJSONLineBuffer` - byte-oriented framing for the wire.
- `RegistryWireCodec` - JSON codec for the envelope format the Node server expects.
- `.trackAccessibility(...)` - SwiftUI view modifier that captures a view's frame via `GeometryReader` + `CoordinateSpace.global` and registers it with a registry. Frame updates flow through a `PreferenceKey`, so moves during layout are picked up automatically.
- `harness-monitor-input` executable - CGEvent-backed input-synthesis CLI that replaces the external `cliclick` dependency. Subcommands: `move`, `click`, `type`, `position`, `check`.
- `harness-monitor-registry-host` executable - manual-test harness that seeds the registry with fixture windows and elements and runs the listener at a given socket path.

## Why a separate package

Shipping as a local SPM package keeps the Rust-first `harness` repo free of `project.yml`/`pbxproj` churn and lets the MCP plumbing be tested in isolation. The package can be linked into `HarnessMonitorKit` as a local SPM dependency when the surrounding work-in-progress around XcodeGen settles.

## Xcode workflow

`Package.swift` is the source of truth for this module. The repo builds and tests it through SwiftPM, and any `.xcodeproj` that appears under this directory is a local ignored Xcode artifact rather than managed project metadata.

If you want to inspect or edit the package in Xcode, open `Package.swift` (or the package directory) instead of relying on `HarnessMonitorRegistry.xcodeproj`. That local project can drift from the manifest and omit targets such as `HarnessMonitorRegistryHost` and `HarnessMonitorInputTool`.

## Build and test

```bash
cd mcp-servers/harness-monitor-registry
swift build
swift test
```

`swift test` runs both the unit tests and an integration test that binds a real Unix socket, connects to it over POSIX, and round-trips two requests.

## Using the modifier

```swift
import HarnessMonitorRegistry
import SwiftUI

struct SessionControls: View {
  @State private var registry = AccessibilityRegistry()

  var body: some View {
    HStack {
      Button("Start", action: start)
        .trackAccessibility(
          "session.controls.start",
          kind: .button,
          label: "Start session",
          registry: registry
        )
      Button("Stop", action: stop)
        .trackAccessibility(
          "session.controls.stop",
          kind: .button,
          label: "Stop session",
          registry: registry
        )
    }
  }

  private func start() {}
  private func stop() {}
}
```

The identifier you pass also becomes the view's `.accessibilityIdentifier`, so on-device XCUITest queries and the MCP server look at the same value.

## Launching the listener

Typically at app startup:

```swift
import HarnessMonitorRegistry
import SwiftUI

@main
struct HarnessMonitorApp: App {
  @State private var registry = AccessibilityRegistry()

  var body: some Scene {
    WindowGroup("Harness Monitor") { ContentView(registry: registry) }
      .task { await startRegistryListener() }
  }

  private func startRegistryListener() async {
    let dispatcher = RegistryRequestDispatcher(registry: registry) {
      PingResult(
        protocolVersion: registryProtocolVersion,
        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown"
      )
    }
    let listener = RegistryListener(dispatcher: dispatcher)
    let socketPath = appGroupSocketPath() ?? fallbackSocketPath()
    do {
      try await listener.start(at: socketPath)
    } catch {
      Logger(subsystem: "io.harnessmonitor", category: "mcp-registry")
        .error("failed to start MCP listener: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func appGroupSocketPath() -> String? {
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: registryAppGroupIdentifier) else {
      return nil
    }
    return container.appendingPathComponent(registrySocketFilename).path
  }

  private func fallbackSocketPath() -> String {
    NSTemporaryDirectory() + registrySocketFilename
  }
}
```

## Protocol

NDJSON in both directions. Requests:

```json
{"id": 1, "op": "ping"}
{"id": 2, "op": "listWindows"}
{"id": 3, "op": "listElements", "windowID": 42, "kind": "button"}
{"id": 4, "op": "getElement", "identifier": "session.controls.start"}
```

Success response:

```json
{"id": 2, "ok": true, "result": {"windows": [...]}}
```

Failure response:

```json
{"id": 4, "ok": false, "error": {"code": "not-found", "message": "..."}}
```

Error codes:
- `invalid-argument` - missing or empty argument
- `invalid-json` - request could not be decoded
- `not-found` - identifier not registered

## Layout

```
mcp-servers/harness-monitor-registry/
├── Package.swift
├── README.md
├── Sources/
│   └── HarnessMonitorRegistry/
│       ├── AccessibilityRegistry.swift
│       ├── RegistryListener.swift
│       ├── RegistryProtocol.swift
│       ├── RegistryRequestDispatcher.swift
│       ├── RegistryTypes.swift
│       └── TrackAccessibilityModifier.swift
└── Tests/
    └── HarnessMonitorRegistryTests/
        ├── AccessibilityRegistryTests.swift
        ├── NDJSONLineBufferTests.swift
        ├── RegistryListenerIntegrationTests.swift
        └── RegistryRequestDispatcherTests.swift
```
