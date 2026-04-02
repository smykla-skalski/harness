import HarnessKit
import SwiftUI

struct PreferencesView: View {
  let store: HarnessStore
  @Binding var themeMode: HarnessThemeMode
  @State private var selectedSection: PreferencesSection = .general

  init(
    store: HarnessStore,
    themeMode: Binding<HarnessThemeMode>,
    selectedSection: PreferencesSection = .general
  ) {
    self.store = store
    _themeMode = themeMode
    _selectedSection = State(initialValue: selectedSection)
  }

  private var effectiveHealth: HealthResponse? { store.diagnostics?.health ?? store.health }

  private var cacheEntryCount: Int {
    store.diagnostics?.workspace.cacheEntryCount
      ?? store.daemonStatus?.diagnostics.cacheEntryCount
      ?? 0
  }

  private var effectiveLastEvent: DaemonAuditEvent? {
    store.diagnostics?.workspace.lastEvent
      ?? store.daemonStatus?.diagnostics.lastEvent
  }

  private var effectiveTokenPresent: Bool {
    store.diagnostics?.workspace.authTokenPresent
      ?? store.daemonStatus?.diagnostics.authTokenPresent
      ?? false
  }

  private var launchAgentState: String {
    store.daemonStatus?.launchAgent.lifecycleTitle ?? "Manual"
  }

  private var launchAgentCaption: String {
    let fallback = store.daemonStatus?.launchAgent.label ?? "Launch agent"
    let caption = store.daemonStatus?.launchAgent.lifecycleCaption ?? fallback
    return caption.isEmpty ? fallback : caption
  }

  private var generalActionsAreLoading: Bool {
    store.isDaemonActionInFlight
      || store.isDiagnosticsRefreshInFlight
      || store.connectionState == .connecting
  }

  private var preferencesAccessibilityValue: String {
    [
      "mode=\(themeMode.rawValue)",
      "section=\(selectedSection.rawValue)",
      "preferencesChrome=native",
    ].joined(separator: ", ")
  }

  private var endpoint: String {
    effectiveHealth?.endpoint
      ?? store.daemonStatus?.manifest?.endpoint
      ?? "Unavailable"
  }

  private var version: String {
    effectiveHealth?.version
      ?? store.daemonStatus?.manifest?.version
      ?? "Unavailable"
  }

  private var sessionCount: Int {
    store.daemonStatus?.sessionCount ?? store.sessions.count
  }

  private var diagnosticsPaths: PreferencesDiagnosticsPaths {
    PreferencesDiagnosticsPaths(
      launchAgentPath: store.daemonStatus?.launchAgent.path ?? "Unavailable",
      launchAgentDomain: store.daemonStatus?.launchAgent.domainTarget,
      launchAgentService: store.daemonStatus?.launchAgent.serviceTarget,
      manifestPath:
        store.diagnostics?.workspace.manifestPath
        ?? store.daemonStatus?.diagnostics.manifestPath
        ?? "Unavailable",
      authTokenPath:
        store.diagnostics?.workspace.authTokenPath
        ?? store.daemonStatus?.diagnostics.authTokenPath
        ?? "Unavailable",
      eventsPath:
        store.diagnostics?.workspace.eventsPath
        ?? store.daemonStatus?.diagnostics.eventsPath
        ?? "Unavailable",
      cacheRoot:
        store.diagnostics?.workspace.cacheRoot
        ?? store.daemonStatus?.diagnostics.cacheRoot
        ?? "Unavailable"
    )
  }

  private var recentEvents: [DaemonAuditEvent] {
    Array((store.diagnostics?.recentEvents ?? []).prefix(10))
  }

  var body: some View {
    NavigationSplitView {
      PreferencesSidebarList(selection: $selectedSection)
        .navigationSplitViewColumnWidth(
          min: PreferencesChromeMetrics.sidebarMinWidth,
          ideal: PreferencesChromeMetrics.sidebarIdealWidth,
          max: PreferencesChromeMetrics.sidebarMaxWidth
        )
    } detail: {
      detailContent
    }
    .navigationSplitViewStyle(.balanced)
    .navigationTitle(selectedSection.title)
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.preferencesRoot)
    .overlay {
      PreferencesOverlayMarkers(
        title: selectedSection.title,
        preferencesAccessibilityValue: preferencesAccessibilityValue
      )
    }
    .accessibilityFrameMarker(HarnessAccessibility.preferencesPanel)
  }
}

private extension PreferencesView {
  @ViewBuilder var detailContent: some View {
    switch selectedSection {
    case .general:
      PreferencesGeneralSection(
        themeMode: $themeMode,
        endpoint: endpoint,
        version: version,
        launchAgentState: launchAgentState,
        launchAgentCaption: launchAgentCaption,
        cacheEntryCount: cacheEntryCount,
        sessionCount: sessionCount,
        startedAt: effectiveHealth?.startedAt ?? store.daemonStatus?.manifest?.startedAt,
        lastError: store.lastError,
        lastAction: store.lastAction,
        isLoading: generalActionsAreLoading,
        reconnect: reconnect,
        refreshDiagnostics: refreshDiagnostics,
        startDaemon: startDaemon,
        installLaunchAgent: installLaunchAgent,
        removeLaunchAgent: removeLaunchAgent
      )
    case .connection:
      PreferencesConnectionSection(
        isConnecting: store.connectionState == .connecting,
        isDiagnosticsRefreshInFlight: store.isDiagnosticsRefreshInFlight,
        reconnect: reconnect,
        refreshDiagnostics: refreshDiagnostics,
        metrics: store.connectionMetrics,
        events: store.connectionEvents
      )
    case .diagnostics:
      PreferencesDiagnosticsSection(
        launchAgent: store.daemonStatus?.launchAgent,
        tokenPresent: effectiveTokenPresent,
        projectCount: store.daemonStatus?.projectCount ?? store.projects.count,
        sessionCount: store.daemonStatus?.sessionCount ?? store.sessions.count,
        lastEvent: effectiveLastEvent,
        paths: diagnosticsPaths,
        recentEvents: recentEvents
      )
    }
  }

  func reconnect() async {
    await store.reconnect()
  }

  func refreshDiagnostics() async {
    await store.refreshDiagnostics()
  }

  func startDaemon() async {
    await store.startDaemon()
  }

  func installLaunchAgent() async {
    await store.installLaunchAgent()
  }

  func removeLaunchAgent() async {
    store.requestRemoveLaunchAgentConfirmation()
  }
}

private struct PreferencesOverlayMarkers: View {
  let title: String
  let preferencesAccessibilityValue: String

  var body: some View {
    ZStack {
      Color.clear
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityIdentifier(HarnessAccessibility.preferencesTitle)
      AccessibilityTextMarker(
        identifier: HarnessAccessibility.preferencesState,
        text: preferencesAccessibilityValue
      )
    }
  }
}

#Preview("Preferences Window - General") {
  @Previewable @State var themeMode: HarnessThemeMode = .auto

  PreferencesView(
    store: PreferencesPreviewSupport.makeStore(),
    themeMode: $themeMode,
    selectedSection: .general
  )
  .frame(width: 980, height: 680)
}

#Preview("Preferences Window - Connection") {
  @Previewable @State var themeMode: HarnessThemeMode = .auto

  PreferencesView(
    store: PreferencesPreviewSupport.makeStore(),
    themeMode: $themeMode,
    selectedSection: .connection
  )
  .frame(width: 980, height: 680)
}

#Preview("Preferences Window - Diagnostics") {
  @Previewable @State var themeMode: HarnessThemeMode = .auto

  PreferencesView(
    store: PreferencesPreviewSupport.makeStore(),
    themeMode: $themeMode,
    selectedSection: .diagnostics
  )
  .frame(width: 980, height: 680)
}
