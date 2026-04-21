import HarnessMonitorKit
import SwiftUI

extension HarnessMonitorStore.ContentToolbarSlice {
  fileprivate var toolbarCenterpieceModel: ToolbarCenterpieceModel {
    ToolbarCenterpieceModel(
      workspaceName: "Harness Monitor",
      destinationName: "My Mac",
      destinationSystemImage: "laptopcomputer"
    )
  }

  fileprivate var toolbarStatusMessages: [ToolbarStatusMessage] {
    statusMessages.map(ToolbarStatusMessage.init)
  }
}

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

public struct ContentCenterpieceToolbarItems: ToolbarContent {
  public let store: HarnessMonitorStore
  public let toolbarUI: HarnessMonitorStore.ContentToolbarSlice
  public let displayMode: ToolbarCenterpieceDisplayMode
  public let availableDetailWidth: CGFloat

  public init(
    store: HarnessMonitorStore,
    toolbarUI: HarnessMonitorStore.ContentToolbarSlice,
    displayMode: ToolbarCenterpieceDisplayMode,
    availableDetailWidth: CGFloat
  ) {
    self.store = store
    self.toolbarUI = toolbarUI
    self.displayMode = displayMode
    self.availableDetailWidth = availableDetailWidth
  }

  public var body: some ToolbarContent {
    ContentCenterpieceToolbar(
      model: toolbarUI.toolbarCenterpieceModel,
      displayMode: displayMode,
      availableDetailWidth: availableDetailWidth,
      statusMessages: toolbarUI.toolbarStatusMessages,
      connectionState: toolbarUI.connectionState
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
