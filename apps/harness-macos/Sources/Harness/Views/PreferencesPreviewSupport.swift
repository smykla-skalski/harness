import HarnessKit

@MainActor
enum PreferencesPreviewSupport {
  static let recentEvents = [
    DaemonAuditEvent(
      recordedAt: "2026-03-31T12:08:43Z",
      level: "info",
      message: "Connected to daemon via server-sent events."
    ),
    DaemonAuditEvent(
      recordedAt: "2026-03-31T12:07:10Z",
      level: "warn",
      message: "Heartbeat jitter exceeded threshold; connection probe rescheduled."
    ),
    DaemonAuditEvent(
      recordedAt: "2026-03-31T12:05:28Z",
      level: "error",
      message: "WebSocket upgrade failed once; recovered on HTTP fallback."
    ),
  ]

  static func makeStore(
    scenario: HarnessPreviewStoreFactory.Scenario = .cockpitLoaded,
    events: [DaemonAuditEvent] = Self.recentEvents,
    lastAction: String = "Diagnostics refreshed from preview fixtures.",
    lastError: String? = nil
  ) -> HarnessStore {
    let store = HarnessPreviewStoreFactory.makeStore(for: scenario)
    let workspaceDiagnostics = makeWorkspaceDiagnostics(
      from: store.daemonStatus?.diagnostics,
      events: events
    )
    let launchAgent =
      store.daemonStatus?.launchAgent
      ?? LaunchAgentStatus(
        installed: false,
        label: "io.harness.daemon",
        path: "/Users/example/Library/LaunchAgents/io.harness.daemon.plist"
      )

    store.diagnostics = DaemonDiagnosticsReport(
      health: store.health,
      manifest: store.daemonStatus?.manifest,
      launchAgent: launchAgent,
      workspace: workspaceDiagnostics,
      recentEvents: events
    )
    store.lastAction = lastAction
    store.lastError = lastError
    return store
  }

}

private extension PreferencesPreviewSupport {
  static func makeWorkspaceDiagnostics(
    from base: DaemonDiagnostics?,
    events: [DaemonAuditEvent]
  ) -> DaemonDiagnostics {
    let template =
      base
      ?? DaemonDiagnostics(
        daemonRoot: "/Users/example/Library/Application Support/harness/daemon",
        manifestPath: "/Users/example/Library/Application Support/harness/daemon/manifest.json",
        authTokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
        authTokenPresent: true,
        eventsPath: "/Users/example/Library/Application Support/harness/daemon/events.jsonl",
        cacheRoot: "/Users/example/Library/Application Support/harness/daemon/cache/projects",
        cacheEntryCount: 4,
        lastEvent: nil
      )

    return DaemonDiagnostics(
      daemonRoot: template.daemonRoot,
      manifestPath: template.manifestPath,
      authTokenPath: template.authTokenPath,
      authTokenPresent: template.authTokenPresent,
      eventsPath: template.eventsPath,
      cacheRoot: template.cacheRoot,
      cacheEntryCount: template.cacheEntryCount,
      lastEvent: events.first ?? template.lastEvent
    )
  }
}
