import HarnessKit
import SwiftUI

struct PreferencesView: View {
  let store: HarnessStore
  @Binding var themeMode: HarnessThemeMode
  @State private var selectedSection: PreferencesSection = .general

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
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .toolbar(removing: .title)
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
      } header: {
        Text("Appearance")
      } footer: {
        Text("Applies to every Harness window on this Mac.")
      }

      Section("Actions") {
        PreferencesActionButtons(
          isLoading: isLoading,
          reconnect: { await store.reconnect() },
          refreshDiagnostics: {
            await store.refreshDiagnostics()
          },
          startDaemon: { await store.startDaemon() },
          installLaunchAgent: {
            await store.installLaunchAgent()
          },
          requestRemoveLaunchAgentConfirmation: {
            store.requestRemoveLaunchAgentConfirmation()
          }
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
              .font(.caption)
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
