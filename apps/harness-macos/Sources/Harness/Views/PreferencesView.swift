import HarnessKit
import Observation
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
    store.diagnostics?.workspace.lastEvent ?? store.daemonStatus?.diagnostics.lastEvent
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
    "style=\(themeStyle.rawValue), mode=\(themeMode.rawValue), "
      + "section=\(currentSection.rawValue), preferencesChrome=extended"
  }

  private var currentSection: PreferencesSection {
    selectedSection ?? .general
  }

  var body: some View {
    NavigationSplitView {
      PreferencesSidebar(selection: $selectedSection)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
    } detail: {
      selectedSectionContent
        .navigationTitle(currentSection.title)
        .toolbarTitleDisplayMode(.inline)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .harnessExtendedChromeBackground {
          HarnessTheme.canvas
        }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button(action: goBack) {
          Label("Back", systemImage: "chevron.left")
        }
        .disabled(backHistory.isEmpty)
        .accessibilityIdentifier(HarnessAccessibility.preferencesBackButton)

        Button(action: goForward) {
          Label("Forward", systemImage: "chevron.right")
        }
        .disabled(forwardHistory.isEmpty)
        .accessibilityIdentifier(HarnessAccessibility.preferencesForwardButton)
      }
    }
    .toolbar(removing: .sidebarToggle)
    .toolbarRole(.editor)
    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .foregroundStyle(HarnessTheme.ink)
    .tint(HarnessTheme.accent(for: themeStyle))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: selectedSection) { oldValue, newValue in
      guard let oldValue, let newValue, oldValue != newValue else {
        return
      }
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
      generalSection
    case .connection:
      connectionSection
    case .diagnostics:
      diagnosticsSection
    }
  }

  private var generalSection: some View {
    PreferencesSectionScrollContainer {
      VStack(alignment: .leading, spacing: 18) {
        PreferencesAppearanceCard(themeMode: $themeMode, themeStyle: $themeStyle)
        PreferencesActionGrid(
          isLoading: generalActionsAreLoading,
          reconnect: { await store.reconnect() },
          refreshDiagnostics: { await store.refreshDiagnostics() },
          startDaemon: { await store.startDaemon() },
          installLaunchAgent: { await store.installLaunchAgent() },
          requestRemoveLaunchAgentConfirmation: { store.requestRemoveLaunchAgentConfirmation() }
        )
        PreferencesOverviewGrid(
          endpoint: effectiveHealth?.endpoint ?? store.daemonStatus?.manifest?.endpoint
            ?? "Unavailable",
          version: effectiveHealth?.version ?? store.daemonStatus?.manifest?.version
            ?? "Unavailable",
          launchAgentState: launchAgentState,
          launchAgentCaption: launchAgentCaption,
          cacheEntryCount: cacheEntryCount,
          sessionCount: store.daemonStatus?.sessionCount ?? store.sessions.count
        )
        PreferencesStatusCard(
          startedAt: effectiveHealth?.startedAt ?? store.daemonStatus?.manifest?.startedAt,
          lastError: store.lastError,
          lastAction: store.lastAction
        )
      }
    }
  }

  private var connectionSection: some View {
    PreferencesSectionScrollContainer {
      VStack(alignment: .leading, spacing: 18) {
        PreferencesConnectionActionsCard(
          isReconnectLoading: store.connectionState == .connecting,
          isRefreshLoading: store.isDiagnosticsRefreshInFlight,
          reconnect: { await store.reconnect() },
          refreshDiagnostics: { await store.refreshDiagnostics() }
        )
        PreferencesConnectionCard(
          metrics: store.connectionMetrics,
          events: store.connectionEvents
        )
      }
    }
  }

  private var diagnosticsSection: some View {
    PreferencesSectionScrollContainer {
      VStack(alignment: .leading, spacing: 18) {
        PreferencesDiagnosticsCard(
          launchAgent: store.daemonStatus?.launchAgent,
          tokenPresent: effectiveTokenPresent,
          projectCount: store.daemonStatus?.projectCount ?? 0,
          sessionCount: store.daemonStatus?.sessionCount ?? 0,
          lastEvent: effectiveLastEvent
        )
        PreferencesPathsCard(
          launchAgentPath: store.daemonStatus?.launchAgent.path ?? "Unavailable",
          launchAgentDomain: store.daemonStatus?.launchAgent.domainTarget,
          launchAgentService: store.daemonStatus?.launchAgent.serviceTarget,
          manifestPath: store.diagnostics?.workspace.manifestPath
            ?? store.daemonStatus?.diagnostics.manifestPath
            ?? "Unavailable",
          authTokenPath: store.diagnostics?.workspace.authTokenPath
            ?? store.daemonStatus?.diagnostics.authTokenPath
            ?? "Unavailable",
          eventsPath: store.diagnostics?.workspace.eventsPath
            ?? store.daemonStatus?.diagnostics.eventsPath
            ?? "Unavailable",
          cacheRoot: store.diagnostics?.workspace.cacheRoot
            ?? store.daemonStatus?.diagnostics.cacheRoot
            ?? "Unavailable"
        )
        PreferencesRecentEventsCard(
          events: Array((store.diagnostics?.recentEvents ?? []).prefix(10))
        )
      }
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

private struct PreferencesSidebar: View {
  @Binding var selection: PreferencesSection?

  var body: some View {
    List(selection: $selection) {
      ForEach(PreferencesSection.allCases) { section in
        NavigationLink(value: section) {
          Label(section.title, systemImage: section.systemImage)
        }
        .tag(section)
          .accessibilityIdentifier(HarnessAccessibility.preferencesSectionButton(section.rawValue))
        .accessibilityValue(selection == section ? "selected" : "not selected")
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .accessibilityIdentifier(HarnessAccessibility.preferencesSidebar)
  }
}

private struct PreferencesSectionScrollContainer<Content: View>: View {
  private let content: Content
  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }
  var body: some View {
    HarnessColumnScrollView(horizontalPadding: 28, verticalPadding: 16) {
      content
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 28)
    }
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

private struct PreferencesAppearanceCard: View {
  @Binding var themeMode: HarnessThemeMode
  @Binding var themeStyle: HarnessThemeStyle
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Themes")
        .font(.system(.title3, weight: .semibold))
      VStack(spacing: 0) {
        appearanceRow
        Divider()
        styleRow
      }
      Text("Both settings apply live to every Harness window on this Mac.")
        .font(.system(.subheadline, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
    }
    .harnessCard()
  }

  private var appearanceRow: some View {
    PreferencesPickerRow(title: "Appearance") {
      Picker("Appearance", selection: $themeMode) {
        ForEach(HarnessThemeMode.allCases) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 160, alignment: .trailing)
      .accessibilityIdentifier(HarnessAccessibility.preferencesThemeModePicker)
    }
  }

  private var styleRow: some View {
    PreferencesPickerRow(title: "Style") {
      Picker("Style", selection: $themeStyle) {
        ForEach(HarnessThemeStyle.allCases) { style in
          Text(style.label).tag(style)
        }
      }
      .pickerStyle(.menu)
      .frame(width: 160, alignment: .trailing)
      .accessibilityIdentifier(HarnessAccessibility.preferencesThemeStylePicker)
    }
  }
}

private struct PreferencesPickerRow<Control: View>: View {
  let title: String
  let control: Control

  init(title: String, @ViewBuilder control: () -> Control) {
    self.title = title
    self.control = control()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      Text(title)
        .font(.system(.headline, design: .rounded, weight: .semibold))
      Spacer(minLength: 12)
      control
        .labelsHidden()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}
