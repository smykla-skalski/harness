import AppKit
import HarnessMonitorKit
import SwiftUI

struct DashboardDiagnosticsRouteView: View {
  let store: HarnessMonitorStore
  let selectedRoute: DashboardWindowRoute
  @State private var databaseStatistics: DatabaseStatistics?
  @State private var isDatabaseStatisticsLoading = false
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    let _ = HarnessMonitorPerfTrace.countBodyEval("DashboardDiagnosticsRouteView")
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardDiagnosticsRoot,
      scrollSurfaceLabel: "Diagnostics"
    ) {
      VStack(alignment: .leading, spacing: 24) {
        header
        appAndDaemonSection
        refreshTimingsSection
        cacheSection
        timelineSection
        mcpSection
        recentRecoverableEventsSection
      }
      .frame(maxWidth: 980, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDiagnosticsRoot)
    .task(id: databaseStatisticsTaskKey) {
      await refreshDatabaseStatistics()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
        Label("Diagnostics", systemImage: "stethoscope")
          .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        Spacer()
        diagnosticsActions
      }
      Text(connectionSubtitle)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private var diagnosticsActions: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      Button {
        Task { await store.refreshDiagnostics() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)

      Button {
        Task { await store.reconnect() }
      } label: {
        Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)

      Button {
        copyDiagnostics()
      } label: {
        Label("Copy", systemImage: "doc.on.clipboard")
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    }
  }

  private var appAndDaemonSection: some View {
    DashboardDiagnosticsSection(title: "App and Daemon") {
      InspectorFactGrid(facts: appAndDaemonFacts)
    }
  }

  private var refreshTimingsSection: some View {
    DashboardDiagnosticsSection(title: "Refresh Timings") {
      InspectorFactGrid(facts: refreshTimingFacts)
    }
  }

  private var cacheSection: some View {
    DashboardDiagnosticsSection(title: "Cache and Freshness") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        InspectorFactGrid(facts: cacheFacts)
        if let databaseStatistics {
          DashboardDiagnosticsRecordStrip(
            title: "Cache Records",
            values: [
              "sessions \(databaseStatistics.sessionCount)",
              "agents \(databaseStatistics.agentCount)",
              "tasks \(databaseStatistics.taskCount)",
              "timeline \(databaseStatistics.timelineCount)",
              "transcript \(databaseStatistics.transcriptCount)",
            ]
          )
        } else if isDatabaseStatisticsLoading {
          ProgressView("Loading cache statistics...")
        }
      }
    }
  }

  private var timelineSection: some View {
    DashboardDiagnosticsSection(title: "Timeline") {
      InspectorFactGrid(facts: timelineFacts)
    }
  }

  private var mcpSection: some View {
    DashboardDiagnosticsSection(title: "MCP Registry") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        InspectorFactGrid(facts: mcpFacts)
        Text(store.mcpStatus.detail)
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .textSelection(.enabled)
      }
    }
  }

  @ViewBuilder private var recentRecoverableEventsSection: some View {
    let events = recentRecoverableEvents
    DashboardDiagnosticsSection(title: "Recent Recoverable Events") {
      if events.isEmpty {
        Text("No recent recoverable events")
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(events) { event in
            DashboardDiagnosticsEventRow(event: event)
          }
        }
      }
    }
  }

  private var appAndDaemonFacts: [InspectorFact] {
    let diagnostics = workspaceDiagnostics
    return [
      InspectorFact(title: "Route", value: "Dashboard / \(selectedRoute.title)"),
      InspectorFact(title: "Connection", value: connectionTitle(store.connectionState)),
      InspectorFact(title: "Transport", value: store.connectionMetrics.transportKind.title),
      InspectorFact(title: "Runtime Lane", value: environmentValue("HARNESS_MONITOR_RUNTIME_LANE")),
      InspectorFact(title: "Build Lane", value: environmentValue("HARNESS_MONITOR_BUILD_LANE")),
      InspectorFact(title: "Daemon PID", value: store.health.map { String($0.pid) } ?? "n/a"),
      InspectorFact(title: "Daemon Version", value: store.health?.version ?? "n/a"),
      InspectorFact(
        title: "Wire Version",
        value: store.health.map { String($0.wireVersion) } ?? "n/a"
      ),
      InspectorFact(title: "Daemon Root", value: diagnostics?.daemonRoot ?? "Unavailable"),
      InspectorFact(title: "Manifest", value: diagnostics?.manifestPath ?? "Unavailable"),
    ]
  }

  private var refreshTimingFacts: [InspectorFact] {
    guard let timings = store.lastRefreshTimings else {
      return [
        InspectorFact(title: "Last Full Refresh", value: "Not recorded"),
        InspectorFact(
          title: "Request Latency",
          value: milliseconds(store.connectionMetrics.requestLatencyMs)
        ),
      ]
    }
    return [
      InspectorFact(
        title: "Recorded",
        value: formatTimestamp(timings.recordedAt, configuration: dateTimeConfiguration)
      ),
      InspectorFact(title: "Diagnostics", value: milliseconds(timings.diagnosticsLatencyMs)),
      InspectorFact(title: "Projects", value: milliseconds(timings.projectsLatencyMs)),
      InspectorFact(title: "Sessions", value: milliseconds(timings.sessionsLatencyMs)),
      InspectorFact(title: "Task Board", value: milliseconds(timings.taskBoardItemsLatencyMs)),
      InspectorFact(
        title: "Orchestrator",
        value: milliseconds(timings.taskBoardOrchestratorLatencyMs)
      ),
      InspectorFact(title: "Measured Total", value: milliseconds(timings.totalMeasuredLatencyMs)),
      InspectorFact(
        title: "Average Request",
        value: milliseconds(store.connectionMetrics.averageRequestLatencyMs)
      ),
    ]
  }

  private var cacheFacts: [InspectorFact] {
    let stats = databaseStatistics
    return [
      InspectorFact(title: "Session Data", value: sessionAvailabilityTitle),
      InspectorFact(title: "Persisted Sessions", value: String(store.persistedSessionCount)),
      InspectorFact(title: "Last Snapshot", value: lastSnapshotTitle),
      InspectorFact(title: "App Cache Size", value: stats?.appCacheSizeFormatted ?? "n/a"),
      InspectorFact(title: "Daemon DB Size", value: stats?.daemonDatabaseSizeFormatted ?? "n/a"),
      InspectorFact(title: "App Cache", value: stats?.appCacheStorePath ?? "Unavailable"),
      InspectorFact(title: "Daemon DB", value: stats?.daemonDatabasePath ?? "Unavailable"),
    ]
  }

  private var timelineFacts: [InspectorFact] {
    let window = store.timelineWindow
    return [
      InspectorFact(title: "Selected Session", value: store.selectedSessionID ?? "None"),
      InspectorFact(title: "Rendered Rows", value: String(store.timeline.count)),
      InspectorFact(title: "Total Rows", value: window.map { String($0.totalCount) } ?? "n/a"),
      InspectorFact(title: "Window", value: timelineWindowTitle(window)),
      InspectorFact(title: "Has Older", value: window?.hasOlder == true ? "Yes" : "No"),
      InspectorFact(title: "Has Newer", value: window?.hasNewer == true ? "Yes" : "No"),
    ]
  }

  private var mcpFacts: [InspectorFact] {
    [
      InspectorFact(title: "Status", value: store.mcpStatus.title),
      InspectorFact(title: "Socket", value: store.mcpStatus.socketPath ?? "Unavailable"),
      InspectorFact(title: "Failure", value: store.mcpStatus.failureReason ?? "None"),
      InspectorFact(
        title: "Recovery",
        value: store.mcpStatus.recoverySummary ?? "No active recovery"
      ),
    ]
  }

  private var recentRecoverableEvents: [DashboardDiagnosticsEvent] {
    let connectionEvents =
      store.connectionEvents.compactMap { event -> DashboardDiagnosticsEvent? in
        switch event.kind {
        case .disconnected, .reconnecting, .fallback, .error:
          return DashboardDiagnosticsEvent(
            source: "Connection",
            level: event.kind.title,
            recordedAt: formatTimestamp(
              event.timestamp,
              configuration: dateTimeConfiguration
            ),
            message: event.detail
          )
        case .connected, .info:
          return nil
        }
      }
    let recentEvents = store.diagnostics?.recentEvents ?? [DaemonAuditEvent]()
    let daemonEvents = recentEvents.compactMap { event -> DashboardDiagnosticsEvent? in
      let level = event.level.lowercased()
      guard level != "info" && level != "debug" else { return nil }
      return DashboardDiagnosticsEvent(
        source: "Daemon",
        level: event.level.uppercased(),
        recordedAt: formatTimestamp(
          event.recordedAt,
          configuration: dateTimeConfiguration
        ),
        message: event.message
      )
    }
    return Array((connectionEvents + daemonEvents).prefix(8))
  }

  private var workspaceDiagnostics: DaemonDiagnostics? {
    store.diagnostics?.workspace ?? store.daemonStatus?.diagnostics
  }

  private var connectionSubtitle: String {
    let metrics = store.connectionMetrics
    return [
      connectionTitle(store.connectionState),
      metrics.transportKind.title,
      "request \(milliseconds(metrics.requestLatencyMs))",
      "messages \(metrics.messagesReceived)",
    ]
    .joined(separator: " · ")
  }

  private var databaseStatisticsTaskKey: String {
    [
      store.persistenceError ?? "",
      store.lastPersistedSnapshotAt.map { String($0.timeIntervalSince1970) } ?? "",
      workspaceDiagnostics?.databasePath ?? "",
      String(workspaceDiagnostics?.databaseSizeBytes ?? 0),
    ]
    .joined(separator: "|")
  }

  private var sessionAvailabilityTitle: String {
    switch store.sessionDataAvailability {
    case .live:
      "Live"
    case .persisted(let reason, let sessionCount, _):
      "Persisted (\(sessionCount), \(persistedReasonTitle(reason)))"
    case .unavailable(let reason):
      "Unavailable (\(persistedReasonTitle(reason)))"
    }
  }

  private var lastSnapshotTitle: String {
    guard let lastPersistedSnapshotAt = store.lastPersistedSnapshotAt else {
      return "Never"
    }
    return formatTimestamp(lastPersistedSnapshotAt, configuration: dateTimeConfiguration)
  }

  private func refreshDatabaseStatistics() async {
    isDatabaseStatisticsLoading = true
    let stats = await store.gatherDatabaseStatistics()
    guard !Task.isCancelled else { return }
    databaseStatistics = stats
    isDatabaseStatisticsLoading = false
  }

  private func copyDiagnostics() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(diagnosticsText, forType: .string)
    store.presentSuccessFeedback("Diagnostics copied")
  }

  private var diagnosticsText: String {
    let sections = [
      textSection(title: "App and daemon", facts: appAndDaemonFacts),
      textSection(title: "Refresh timings", facts: refreshTimingFacts),
      textSection(title: "Cache", facts: cacheFacts),
      textSection(title: "Timeline", facts: timelineFacts),
      textSection(title: "MCP", facts: mcpFacts),
    ]
    return sections.joined(separator: "\n\n")
  }

  private func textSection(title: String, facts: [InspectorFact]) -> String {
    ([title] + facts.map { "\($0.title): \($0.value)" }).joined(separator: "\n")
  }

  private func connectionTitle(_ state: HarnessMonitorStore.ConnectionState) -> String {
    switch state {
    case .idle:
      "Idle"
    case .connecting:
      "Connecting"
    case .online:
      "Online"
    case .offline(let reason):
      "Offline: \(reason)"
    }
  }

  private func persistedReasonTitle(
    _ reason: HarnessMonitorStore.PersistedSessionReason
  ) -> String {
    switch reason {
    case .daemonOffline(let detail):
      "daemon offline: \(detail)"
    case .liveDataUnavailable:
      "live data unavailable"
    }
  }

  private func environmentValue(_ key: String) -> String {
    let value = ProcessInfo.processInfo.environment[key]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value, !value.isEmpty else { return "Default" }
    return value
  }

  private func milliseconds(_ value: Int?) -> String {
    guard let value else { return "n/a" }
    return "\(value) ms"
  }

  private func timelineWindowTitle(_ window: TimelineWindowResponse?) -> String {
    guard let window else { return "n/a" }
    return "\(window.windowStart)-\(window.windowEnd)"
  }
}
