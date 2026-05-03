import HarnessMonitorKit
import SwiftUI

struct ContentWindowToolbarModel: Equatable {
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let canCreateTask: Bool
  let isRefreshing: Bool
  let sleepPreventionEnabled: Bool
  let mcpStatus: HarnessMonitorMCPStatusSnapshot

  var sleepPreventionTitle: String {
    sleepPreventionEnabled ? "Allow Sleep" : "Prevent Sleep"
  }

  var sleepPreventionSystemImage: String {
    sleepPreventionEnabled ? "moon.zzz.fill" : "moon.zzz"
  }
}

struct ContentWindowToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let model: ContentWindowToolbarModel

  init(store: HarnessMonitorStore, model: ContentWindowToolbarModel) {
    self.store = store
    self.model = model
  }

  @ToolbarContentBuilder var body: some ToolbarContent {
    ContentNavigationToolbar(store: store, model: model)
    SidebarToolbarCreateMenuToolbarItem(
      store: store,
      canCreateTask: model.canCreateTask
    )
  }
}

struct ContentPrimaryToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let model: ContentWindowToolbarModel

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
          ? "Allow system sleep"
          : "Keep the system awake while sessions are active"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sleepPreventionButton)
      MCPStatusLabel(status: model.mcpStatus, variant: .toolbar)
        .help(model.mcpStatus.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.mcpStatus.accessibilityLabel)
        .accessibilityValue(model.mcpStatus.accessibilityValue)
        .accessibilityIdentifier(HarnessMonitorAccessibility.mcpToolbarStatus)
      RefreshToolbarButton(isRefreshing: model.isRefreshing) {
        Task { await store.refresh() }
      }
      .help("Refresh sessions")
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      WorkspaceToolbarButton(store: store, slice: store.supervisorToolbarSlice)
    }
  }
}
