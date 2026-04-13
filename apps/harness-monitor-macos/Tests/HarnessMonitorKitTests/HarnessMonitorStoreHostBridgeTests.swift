import Darwin
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor host bridge state")
struct HarnessMonitorStoreHostBridgeTests {
  @Test("Host bridge capability state reports excluded when running bridge omits capability")
  func hostBridgeCapabilityStateReportsExcludedCapability() async {
    let store = await makeBootstrappedStore()
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "codex": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "websocket",
            endpoint: "ws://127.0.0.1:4500"
          )
        ]
      )
    )

    #expect(store.hostBridgeCapabilityState(for: "agent-tui") == .excluded)
    #expect(store.agentTuiUnavailable == true)
  }

  @Test("Host bridge capability state ignores stale excluded issue when the bridge stops")
  func hostBridgeCapabilityStateIgnoresStaleExcludedIssueWhenBridgeStops() async {
    let store = await makeBootstrappedStore()
    store.daemonStatus = sandboxedStatus(hostBridge: HostBridgeManifest())
    store.hostBridgeCapabilityIssues["agent-tui"] = .excluded

    #expect(store.hostBridgeCapabilityState(for: "agent-tui") == .unavailable)
    #expect(store.hostBridgeStartCommand(for: "agent-tui") == "harness bridge start")
  }

  @Test("Host bridge start command narrows to missing capability when running bridge excludes it")
  func hostBridgeStartCommandNarrowsToMissingCapability() async {
    let store = await makeBootstrappedStore()
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "agent-tui": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "unix",
            endpoint: "/tmp/bridge.sock"
          )
        ]
      )
    )

    #expect(
      store.hostBridgeStartCommand(for: "codex") == "harness bridge reconfigure --enable codex")
  }

  @Test("Host bridge start command falls back to bridge start when the bridge is absent")
  func hostBridgeStartCommandFallsBackToStartWhenBridgeIsAbsent() async {
    let store = await makeBootstrappedStore()

    #expect(store.hostBridgeStartCommand(for: "codex") == "harness bridge start")
    #expect(store.hostBridgeStartCommand(for: "agent-tui") == "harness bridge start")
  }

  @Test("Preview store inherits forced bridge issues from process environment")
  func previewStoreInheritsForcedBridgeIssuesFromEnvironment() async {
    setenv("HARNESS_MONITOR_FORCE_BRIDGE_ISSUES", "agent-tui,codex", 1)
    defer { unsetenv("HARNESS_MONITOR_FORCE_BRIDGE_ISSUES") }
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)
    #expect(store.hostBridgeCapabilityIssues["agent-tui"] == .excluded)
    #expect(store.hostBridgeCapabilityIssues["codex"] == .excluded)
  }

  @Test("HARNESS_MONITOR_FORCE_BRIDGE_ISSUES seeds excluded state for listed capabilities")
  func forceBridgeIssuesEnvSeedsExcludedState() {
    let single = HarnessMonitorStore.parseForcedBridgeIssues(
      from: ["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES": "agent-tui"]
    )
    #expect(single == ["agent-tui": .excluded])

    let multiple = HarnessMonitorStore.parseForcedBridgeIssues(
      from: ["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES": "agent-tui,codex"]
    )
    #expect(multiple == ["agent-tui": .excluded, "codex": .excluded])

    let withWhitespace = HarnessMonitorStore.parseForcedBridgeIssues(
      from: ["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES": " agent-tui , codex "]
    )
    #expect(withWhitespace == ["agent-tui": .excluded, "codex": .excluded])

    let emptyValue = HarnessMonitorStore.parseForcedBridgeIssues(
      from: ["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES": ""]
    )
    #expect(emptyValue.isEmpty)

    let missing = HarnessMonitorStore.parseForcedBridgeIssues(from: [:])
    #expect(missing.isEmpty)
  }

  @Test("501 bridge issue marks excluded only when running bridge omits capability")
  func markHostBridgeIssueUsesExcludedForMissingCapability() async {
    let store = await makeBootstrappedStore()
    store.daemonStatus = sandboxedStatus(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "codex": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "websocket",
            endpoint: "ws://127.0.0.1:4500"
          )
        ]
      )
    )

    store.markHostBridgeIssue(for: "agent-tui", statusCode: 501)

    #expect(store.hostBridgeCapabilityState(for: "agent-tui") == .excluded)
    #expect(
      store.hostBridgeStartCommand(for: "agent-tui")
        == "harness bridge reconfigure --enable agent-tui")
  }

}
