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

  private var snapshot: PreferencesSnapshot {
    PreferencesSnapshot(store: store)
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
      PreferencesDetailContent(
        section: selectedSection,
        snapshot: snapshot,
        themeMode: $themeMode,
        reconnect: reconnect,
        refreshDiagnostics: refreshDiagnostics,
        startDaemon: startDaemon,
        installLaunchAgent: installLaunchAgent,
        removeLaunchAgent: removeLaunchAgent
      )
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
        preferencesAccessibilityValue: snapshot.accessibilityValue(
          themeMode: themeMode,
          selectedSection: selectedSection
        )
      )
    }
    .accessibilityFrameMarker(HarnessAccessibility.preferencesPanel)
  }

  private func reconnect() async {
    await store.reconnect()
  }

  private func refreshDiagnostics() async {
    await store.refreshDiagnostics()
  }

  private func startDaemon() async {
    await store.startDaemon()
  }

  private func installLaunchAgent() async {
    await store.installLaunchAgent()
  }

  private func removeLaunchAgent() async {
    store.requestRemoveLaunchAgentConfirmation()
  }
}
