import HarnessKit
import Observation
import SwiftUI

private enum PreferencesSection: String, CaseIterable, Identifiable {
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
  @State private var selectedSection = PreferencesSection.general
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
    "style=\(themeStyle.rawValue), mode=\(themeMode.rawValue), section=\(selectedSection.rawValue)"
  }
  private var selectionBinding: Binding<PreferencesSection?> {
    Binding(
      get: { selectedSection },
      set: { newSelection in
        guard let newSelection else {
          return
        }
        selectedSection = newSelection
      }
    )
  }

  var body: some View {
    NavigationSplitView {
      PreferencesSidebar(selection: selectionBinding)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
    } detail: {
      PreferencesDetailContainer(
        title: selectedSection.title,
        canGoBack: !backHistory.isEmpty,
        canGoForward: !forwardHistory.isEmpty,
        goBack: goBack,
        goForward: goForward
      ) {
        selectedSectionContent
      }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar(removing: .sidebarToggle)
    .containerBackground(.windowBackground, for: .window)
    .background(.windowBackground)
    .foregroundStyle(HarnessTheme.ink)
    .tint(HarnessTheme.accent(for: themeStyle))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: selectedSection) { oldValue, newValue in
      guard oldValue != newValue else {
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
    .accessibilityValue(preferencesAccessibilityValue)
    .accessibilityFrameMarker(HarnessAccessibility.preferencesPanel)
  }

  @ViewBuilder private var selectedSectionContent: some View {
    switch selectedSection {
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
    forwardHistory.append(selectedSection)
    selectedSection = previousSection
  }

  private func goForward() {
    guard let nextSection = forwardHistory.popLast() else {
      return
    }
    suppressHistoryRecording = true
    backHistory.append(selectedSection)
    selectedSection = nextSection
  }
}

private struct PreferencesSidebar: View {
  @Binding var selection: PreferencesSection?

  var body: some View {
    List(selection: $selection) {
      ForEach(PreferencesSection.allCases) { section in
        Label(section.title, systemImage: section.systemImage)
          .tag(section as PreferencesSection?)
          .accessibilityIdentifier(HarnessAccessibility.preferencesSectionButton(section.rawValue))
          .accessibilityValue(selection == section ? "selected" : "not selected")
      }
    }
    .listStyle(.sidebar)
    .accessibilityIdentifier(HarnessAccessibility.preferencesSidebar)
  }
}

private struct PreferencesDetailContainer<Content: View>: View {
  let title: String
  let canGoBack: Bool
  let canGoForward: Bool
  let goBack: () -> Void
  let goForward: () -> Void
  private let content: Content
  init(
    title: String,
    canGoBack: Bool,
    canGoForward: Bool,
    goBack: @escaping () -> Void,
    goForward: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.goBack = goBack
    self.goForward = goForward
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 14) {
        PreferencesNavigationButton(
          systemImage: "chevron.left",
          accessibilityIdentifier: HarnessAccessibility.preferencesBackButton,
          isEnabled: canGoBack,
          action: goBack
        )
        PreferencesNavigationButton(
          systemImage: "chevron.right",
          accessibilityIdentifier: HarnessAccessibility.preferencesForwardButton,
          isEnabled: canGoForward,
          action: goForward
        )
        Text(title)
          .font(.system(size: 20, weight: .semibold))
          .accessibilityIdentifier(HarnessAccessibility.preferencesTitle)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 28)
      .padding(.top, 18)
      .padding(.bottom, 8)
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.windowBackground)
  }
}

private struct PreferencesNavigationButton: View {
  let systemImage: String
  let accessibilityIdentifier: String
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 36, height: 36)
    }
    .buttonBorderShape(.circle)
    .harnessAccessoryButtonStyle()
    .controlSize(.regular)
    .disabled(!isEnabled)
    .accessibilityIdentifier(accessibilityIdentifier)
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
      .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
