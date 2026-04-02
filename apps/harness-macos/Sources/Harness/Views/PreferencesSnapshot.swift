import HarnessKit

struct PreferencesSnapshot {
  let endpoint: String
  let version: String
  let launchAgentState: String
  let launchAgentCaption: String
  let cacheEntryCount: Int
  let projectCount: Int
  let sessionCount: Int
  let startedAt: String?
  let lastError: String?
  let lastAction: String
  let isGeneralActionsLoading: Bool
  let isConnecting: Bool
  let isDiagnosticsRefreshInFlight: Bool
  let metrics: ConnectionMetrics
  let events: [ConnectionEvent]
  let launchAgent: LaunchAgentStatus?
  let tokenPresent: Bool
  let lastEvent: DaemonAuditEvent?
  let paths: PreferencesDiagnosticsPaths
  let recentEvents: [DaemonAuditEvent]

  @MainActor
  init(store: HarnessStore) {
    let effectiveHealth = store.diagnostics?.health ?? store.health
    let daemonDiagnostics = store.daemonStatus?.diagnostics
    let workspaceDiagnostics = store.diagnostics?.workspace ?? daemonDiagnostics
    let launchAgent = store.daemonStatus?.launchAgent
    let fallbackLaunchAgentLabel = launchAgent?.label ?? "Launch agent"
    let launchAgentCaption = launchAgent?.lifecycleCaption ?? fallbackLaunchAgentLabel

    endpoint = effectiveHealth?.endpoint ?? store.daemonStatus?.manifest?.endpoint ?? "Unavailable"
    version = effectiveHealth?.version ?? store.daemonStatus?.manifest?.version ?? "Unavailable"
    launchAgentState = launchAgent?.lifecycleTitle ?? "Manual"
    self.launchAgentCaption = launchAgentCaption.isEmpty ? fallbackLaunchAgentLabel : launchAgentCaption
    cacheEntryCount = workspaceDiagnostics?.cacheEntryCount ?? 0
    projectCount = store.daemonStatus?.projectCount ?? store.projects.count
    sessionCount = store.daemonStatus?.sessionCount ?? store.sessions.count
    startedAt = effectiveHealth?.startedAt ?? store.daemonStatus?.manifest?.startedAt
    lastError = store.lastError
    lastAction = store.lastAction
    isGeneralActionsLoading =
      store.isDaemonActionInFlight
      || store.isDiagnosticsRefreshInFlight
      || store.connectionState == .connecting
    isConnecting = store.connectionState == .connecting
    isDiagnosticsRefreshInFlight = store.isDiagnosticsRefreshInFlight
    metrics = store.connectionMetrics
    events = store.connectionEvents
    self.launchAgent = launchAgent
    tokenPresent =
      workspaceDiagnostics?.authTokenPresent
      ?? false
    lastEvent = workspaceDiagnostics?.lastEvent
    paths = PreferencesDiagnosticsPaths(
      launchAgentPath: launchAgent?.path ?? "Unavailable",
      launchAgentDomain: launchAgent?.domainTarget,
      launchAgentService: launchAgent?.serviceTarget,
      manifestPath: workspaceDiagnostics?.manifestPath ?? "Unavailable",
      authTokenPath: workspaceDiagnostics?.authTokenPath ?? "Unavailable",
      eventsPath: workspaceDiagnostics?.eventsPath ?? "Unavailable",
      cacheRoot: workspaceDiagnostics?.cacheRoot ?? "Unavailable"
    )
    recentEvents = Array((store.diagnostics?.recentEvents ?? []).prefix(10))
  }

  func accessibilityValue(
    themeMode: HarnessThemeMode,
    selectedSection: PreferencesSection
  ) -> String {
    [
      "mode=\(themeMode.rawValue)",
      "section=\(selectedSection.rawValue)",
      "preferencesChrome=native",
    ].joined(separator: ", ")
  }
}
