import Foundation
import HarnessMonitorRegistry

// Minimal manual-test harness: boots an AccessibilityRegistry with fixture
// windows and elements, binds the unix-socket listener at the given path, then
// sleeps so an MCP client can drive it. Usage:
//
//   harness-monitor-registry-host <socket-path> [--seed default|empty]
//
// Exits on SIGINT/SIGTERM.

let args = CommandLine.arguments
guard args.count >= 2 else {
  FileHandle.standardError.write(
    Data("usage: harness-monitor-registry-host <socket-path> [--seed default|empty]\n".utf8)
  )
  exit(64)
}

let socketPath = args[1]
let seed: String = {
  if let idx = args.firstIndex(of: "--seed"), idx + 1 < args.count {
    return args[idx + 1]
  }
  return "default"
}()

nonisolated(unsafe) var hostRegistry: AccessibilityRegistry?
nonisolated(unsafe) var hostListener: RegistryListener?

@MainActor
func bootstrap() async {
  let registry = AccessibilityRegistry()
  hostRegistry = registry

  if seed == "default" {
    await registry.registerWindow(
      RegistryWindow(
        id: 1001,
        title: "Harness Monitor",
        role: "AXWindow",
        frame: RegistryRect(x: 100, y: 100, width: 1200, height: 800),
        isKey: true,
        isMain: true
      )
    )
    await registry.registerWindow(
      RegistryWindow(
        id: 1002,
        title: "Preferences",
        role: "AXWindow",
        frame: RegistryRect(x: 200, y: 200, width: 860, height: 620)
      )
    )
    await registry.registerElement(
      RegistryElement(
        identifier: "sidebar.search",
        label: "Search sessions",
        value: "",
        hint: "Type to filter sessions",
        kind: .textField,
        frame: RegistryRect(x: 120, y: 140, width: 200, height: 28),
        windowID: 1001
      )
    )
    await registry.registerElement(
      RegistryElement(
        identifier: "toolbar.refresh",
        label: "Refresh",
        kind: .button,
        frame: RegistryRect(x: 1120, y: 116, width: 32, height: 32),
        windowID: 1001
      )
    )
    await registry.registerElement(
      RegistryElement(
        identifier: "toolbar.start-daemon",
        label: "Start daemon",
        kind: .button,
        frame: RegistryRect(x: 1160, y: 116, width: 32, height: 32),
        windowID: 1001,
        enabled: false
      )
    )
    await registry.registerElement(
      RegistryElement(
        identifier: "prefs.theme.picker",
        label: "Theme",
        value: "auto",
        kind: .other,
        frame: RegistryRect(x: 280, y: 260, width: 240, height: 22),
        windowID: 1002
      )
    )
  }

  let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ?? "test-host"
  let bundleID = Bundle.main.bundleIdentifier ?? "io.harnessmonitor.test-host"

  let dispatcher = RegistryRequestDispatcher(registry: registry) {
    PingResult(
      protocolVersion: registryProtocolVersion,
      appVersion: appVersion,
      bundleIdentifier: bundleID
    )
  }
  let listener = RegistryListener(dispatcher: dispatcher)
  hostListener = listener

  do {
    try await listener.start(at: socketPath)
  } catch {
    FileHandle.standardError.write(Data("listener start failed: \(error)\n".utf8))
    exit(1)
  }

  let stdoutLine = "harness-monitor-registry-host listening on \(socketPath)\n"
  FileHandle.standardOutput.write(Data(stdoutLine.utf8))
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { exit(0) }
sigintSource.resume()
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { exit(0) }
sigtermSource.resume()

Task { await bootstrap() }
dispatchMain()
