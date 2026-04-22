import HarnessMonitorKit
import SwiftUI

struct ContentWindowToolbarModel: Equatable {
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let canStartNewSession: Bool
  let isRefreshing: Bool
  let sleepPreventionEnabled: Bool
  let showInspector: Bool

  var sleepPreventionTitle: String {
    sleepPreventionEnabled ? "Sleep Prevention On" : "Prevent Sleep"
  }

  var sleepPreventionSystemImage: String {
    sleepPreventionEnabled ? "moon.zzz.fill" : "moon.zzz"
  }

  var inspectorToggleTitle: String {
    showInspector ? "Hide Inspector" : "Show Inspector"
  }
}

struct ContentWindowToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let model: ContentWindowToolbarModel

  init(store: HarnessMonitorStore, model: ContentWindowToolbarModel) {
    self.store = store
    self.model = model
  }

  @ToolbarContentBuilder
  var body: some ToolbarContent {
    ContentNavigationToolbar(store: store, model: model)
    SidebarToolbarNewSessionToolbarItem(
      isEnabled: model.canStartNewSession,
      presentNewSession: { store.presentedSheet = .newSession }
    )
  }
}

struct ContentPrimaryToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let model: ContentWindowToolbarModel
  let setInspectorVisibility: (Bool, ContentInspectorVisibilitySource) -> Void

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        store.sleepPreventionEnabled.toggle()
      } label: {
        Label(
          model.sleepPreventionTitle,
          systemImage: model.sleepPreventionSystemImage
        )
      }
      .tint(model.sleepPreventionEnabled ? .orange : nil)
      .help(
        model.sleepPreventionEnabled
          ? "Click to allow system sleep"
          : "Prevent sleep while sessions are active"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)
      RefreshToolbarButton(isRefreshing: model.isRefreshing) {
        Task { await store.refresh() }
      }
      .help("Refresh sessions")
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      Button {
        setInspectorVisibility(!model.showInspector, .explicitUserPreference)
      } label: {
        Label(model.inspectorToggleTitle, systemImage: "sidebar.trailing")
      }
      .accessibilityLabel(model.inspectorToggleTitle)
      .accessibilityIdentifier(HarnessMonitorAccessibility.inspectorToggleButton)
      .help(model.showInspector ? "Hide inspector" : "Show inspector")
    }
  }
}
