import HarnessMonitorKit
import SwiftUI

public struct ContentNavigationToolbarItems: ToolbarContent {
  public let store: HarnessMonitorStore

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  private var toolbarUI: HarnessMonitorStore.ContentToolbarSlice {
    store.contentUI.toolbar
  }

  public var body: some ToolbarContent {
    ContentNavigationToolbar(
      store: store,
      canNavigateBack: toolbarUI.canNavigateBack,
      canNavigateForward: toolbarUI.canNavigateForward
    )
  }
}

struct ContentPrimaryToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let toolbarUI: HarnessMonitorStore.ContentToolbarSlice
  let showInspector: Bool
  let setInspectorVisibility: (Bool, ContentInspectorVisibilitySource) -> Void

  var body: some ToolbarContent {
    InspectorToolbarActions(
      store: store,
      toolbarUI: toolbarUI,
      showInspector: showInspector,
      setInspectorVisibility: setInspectorVisibility
    )
  }
}

struct InspectorToolbarActions: ToolbarContent {
  let store: HarnessMonitorStore
  let toolbarUI: HarnessMonitorStore.ContentToolbarSlice
  let showInspector: Bool
  let setInspectorVisibility: (Bool, ContentInspectorVisibilitySource) -> Void

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button {
        store.sleepPreventionEnabled.toggle()
      } label: {
        Label(
          toolbarUI.sleepPreventionEnabled ? "Sleep Prevention On" : "Prevent Sleep",
          systemImage: toolbarUI.sleepPreventionEnabled ? "moon.zzz.fill" : "moon.zzz"
        )
      }
      .tint(toolbarUI.sleepPreventionEnabled ? .orange : nil)
      .help(
        toolbarUI.sleepPreventionEnabled
          ? "Click to allow system sleep"
          : "Prevent sleep while sessions are active"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)
      RefreshToolbarButton(isRefreshing: toolbarUI.isRefreshing) {
        Task { await store.refresh() }
      }
      .help("Refresh sessions")
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      Button {
        setInspectorVisibility(!showInspector, .explicitUserPreference)
      } label: {
        Label(
          showInspector ? "Hide Inspector" : "Show Inspector",
          systemImage: "sidebar.trailing"
        )
      }
      .accessibilityLabel(showInspector ? "Hide Inspector" : "Show Inspector")
      .accessibilityIdentifier(HarnessMonitorAccessibility.inspectorToggleButton)
      .help(showInspector ? "Hide inspector" : "Show inspector")
    }
  }
}
