import HarnessKit
import SwiftUI

private enum PreferencesSection: String, CaseIterable, Identifiable, Hashable {
  case general
  case connection
  case diagnostics

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .connection: "Connection"
    case .diagnostics: "Diagnostics"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .connection: "bolt.horizontal.circle"
    case .diagnostics: "stethoscope"
    }
  }
}

struct PreferencesView: View {
  @Bindable var store: HarnessStore
  @Binding var themeMode: HarnessThemeMode
  @Binding var themeStyle: HarnessThemeStyle
  @State private var selectedSection: PreferencesSection? = .general
  @State private var backHistory: [PreferencesSection] = []
  @State private var forwardHistory: [PreferencesSection] = []
  @State private var suppressHistoryRecording = false

  private var effectiveHealth: HealthResponse? {
    store.diagnostics?.health ?? store.health
  }
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
    let fallback = store.daemonStatus?.launchAgent.label
      ?? "Launch agent"
    let caption = store.daemonStatus?.launchAgent.lifecycleCaption
      ?? fallback
    return caption.isEmpty ? fallback : caption
  }
  private var generalActionsAreLoading: Bool {
    store.isDaemonActionInFlight
      || store.isDiagnosticsRefreshInFlight
      || store.connectionState == .connecting
  }
  private var preferencesAccessibilityValue: String {
    let chrome = harnessChromeAccessibilityValue(for: themeStyle)
    return [
      "style=\(themeStyle.rawValue)",
      "mode=\(themeMode.rawValue)",
      "section=\(currentSection.rawValue)",
      "preferencesChrome=\(chrome)",
    ].joined(separator: ", ")
  }
  private var currentSection: PreferencesSection {
    selectedSection ?? .general
  }

  var body: some View {
    NavigationSplitView {
      PreferencesSidebar(selection: $selectedSection)
        .navigationSplitViewColumnWidth(
          min: 180, ideal: 210, max: 240
        )
    } detail: {
      selectedSectionContent
        .navigationTitle(currentSection.title)
        .toolbarTitleDisplayMode(.inline)
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button(action: goBack) {
          Label("Back", systemImage: "chevron.left")
        }
        .disabled(backHistory.isEmpty)
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesBackButton
        )
        Button(action: goForward) {
          Label("Forward", systemImage: "chevron.right")
        }
        .disabled(forwardHistory.isEmpty)
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesForwardButton
        )
      }
    }
    .toolbar(removing: .sidebarToggle)
    .toolbarRole(.editor)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: selectedSection) { oldValue, newValue in
      guard let oldValue, let newValue,
        oldValue != newValue
      else { return }
      if suppressHistoryRecording {
        suppressHistoryRecording = false
        return
      }
      backHistory.append(oldValue)
      forwardHistory.removeAll()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.preferencesRoot)
    .overlay {
      PreferencesOverlayMarkers(
        title: currentSection.title,
        preferencesAccessibilityValue: preferencesAccessibilityValue
      )
    }
    .accessibilityFrameMarker(HarnessAccessibility.preferencesPanel)
  }

  @ViewBuilder private var selectedSectionContent: some View {
    switch currentSection {
    case .general:
      PreferencesGeneralSection(
        store: store,
        themeMode: $themeMode,
        themeStyle: $themeStyle,
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

  private func goBack() {
    guard let previousSection = backHistory.popLast() else {
      return
    }
    suppressHistoryRecording = true
    forwardHistory.append(currentSection)
    selectedSection = previousSection
  }

  private func goForward() {
    guard let nextSection = forwardHistory.popLast() else {
      return
    }
    suppressHistoryRecording = true
    backHistory.append(currentSection)
    selectedSection = nextSection
  }
}

// MARK: - Sidebar

private struct PreferencesSidebar: View {
  @Binding var selection: PreferencesSection?

  var body: some View {
    List(selection: $selection) {
      ForEach(PreferencesSection.allCases) { section in
        NavigationLink(value: section) {
          Label(section.title, systemImage: section.systemImage)
        }
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesSectionButton(
            section.rawValue
          )
        )
        .accessibilityValue(
          selection == section ? "selected" : "not selected"
        )
      }
    }
    .listStyle(.sidebar)
    .accessibilityIdentifier(HarnessAccessibility.preferencesSidebar)
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
  @Bindable var store: HarnessStore
  @Binding var themeMode: HarnessThemeMode
  @Binding var themeStyle: HarnessThemeStyle
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
        Picker("Style", selection: $themeStyle) {
          ForEach(HarnessThemeStyle.allCases) {
            Text($0.label).tag($0)
          }
        }
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesThemeStylePicker
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
    .formStyle(.grouped)
  }
}
