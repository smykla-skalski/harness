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
    let fallback =
      store.daemonStatus?.launchAgent.label
      ?? "Launch agent"
    let caption =
      store.daemonStatus?.launchAgent.lifecycleCaption
      ?? fallback
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

  static func launchAgentCaption(for store: HarnessStore) -> String {
    let fallback = store.daemonStatus?.launchAgent.label ?? "Launch agent"
    let caption = store.daemonStatus?.launchAgent.lifecycleCaption ?? fallback
    return caption.isEmpty ? fallback : caption
  }

  static func cacheEntryCount(for store: HarnessStore) -> Int {
    store.diagnostics?.workspace.cacheEntryCount
      ?? store.daemonStatus?.diagnostics.cacheEntryCount
      ?? 0
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

private extension PreferencesView {
  @ViewBuilder var detailContent: some View {
    switch selectedSection {
    case .general:
      PreferencesGeneralSection(
        store: store,
        themeMode: $themeMode,
        effectiveHealth: effectiveHealth,
        launchAgentState: launchAgentState,
        launchAgentCaption: launchAgentCaption,
        cacheEntryCount: cacheEntryCount,
        isLoading: generalActionsAreLoading
      )
    case .connection:
      PreferencesConnectionSection(store: store)
    case .diagnostics:
      PreferencesDiagnosticsSection(
        store: store,
        effectiveTokenPresent: effectiveTokenPresent,
        effectiveLastEvent: effectiveLastEvent
      )
    }
  }
}

// MARK: - Overlay markers

private struct PreferencesOverlayMarkers: View {
  let title: String
  let preferencesAccessibilityValue: String

  var body: some View {
    ZStack {
      Color.clear
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesTitle
        )
      AccessibilityTextMarker(
        identifier: HarnessAccessibility.preferencesState,
        text: preferencesAccessibilityValue
      )
    }
  }
}

// MARK: - General

private struct PreferencesGeneralSection: View {
  let store: HarnessStore
  @Binding var themeMode: HarnessThemeMode
  @AppStorage(HarnessTextSize.storageKey)
  private var textSizeIndex = HarnessTextSize.defaultIndex
  let effectiveHealth: HealthResponse?
  let launchAgentState: String
  let launchAgentCaption: String
  let cacheEntryCount: Int
  let isLoading: Bool

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

  var body: some View {
    Form {
      Section {
        Picker("Mode", selection: $themeMode) {
          ForEach(HarnessThemeMode.allCases) {
            Text($0.label).tag($0)
          }
        }
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesThemeModePicker
        )
        Picker("Text size", selection: $textSizeIndex) {
          ForEach(
            Array(HarnessTextSize.scales.enumerated()), id: \.offset
          ) { index, level in
            Text(level.label).tag(index)
          }
        }
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesTextSizePicker
        )
      } header: {
        Text("Appearance")
      } footer: {
        Text("Applies to every Harness window on this Mac.")
      }

      Section("Actions") {
        PreferencesActionButtons(
          store: store,
          isLoading: isLoading
        )
      }

      Section("Overview") {
        LabeledContent("Endpoint", value: endpoint)
          .textSelection(.enabled)
          .accessibilityIdentifier(
            HarnessAccessibility.preferencesMetricCard(
              "Endpoint"
            )
          )
        LabeledContent("Version", value: version)
          .textSelection(.enabled)
          .accessibilityIdentifier(
            HarnessAccessibility.preferencesMetricCard("Version")
          )
        LabeledContent("Launchd") {
          VStack(alignment: .trailing, spacing: 2) {
            Text(launchAgentState)
            Text(launchAgentCaption)
              .scaledFont(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesMetricCard("Launchd")
        )
        LabeledContent("Cached Sessions") {
          Text("\(cacheEntryCount)")
        }
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesMetricCard(
            "Cached Sessions"
          )
        )
        LabeledContent("Live Sessions") {
          Text("\(sessionCount)")
        }
      }

      PreferencesStatusSection(
        startedAt: effectiveHealth?.startedAt
          ?? store.daemonStatus?.manifest?.startedAt,
        lastError: store.lastError,
        lastAction: store.lastAction
      )
    }
    .preferencesDetailFormStyle()
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

#Preview("Preferences General Section") {
  @Previewable @State var themeMode: HarnessThemeMode = .dark
  let store = PreferencesPreviewSupport.makeStore()

  PreferencesGeneralSection(
    store: store,
    themeMode: $themeMode,
    effectiveHealth: store.diagnostics?.health ?? store.health,
    launchAgentState: store.daemonStatus?.launchAgent.lifecycleTitle ?? "Manual",
    launchAgentCaption: PreferencesPreviewSupport.launchAgentCaption(for: store),
    cacheEntryCount: PreferencesPreviewSupport.cacheEntryCount(for: store),
    isLoading: false
  )
  .frame(width: 720)
}
