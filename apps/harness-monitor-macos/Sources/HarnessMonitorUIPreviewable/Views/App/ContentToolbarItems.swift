import HarnessMonitorKit
import SwiftUI

struct ContentWindowNavigationToolbarModel: Equatable {
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let canCreateTask: Bool
}

struct ContentPrimaryToolbarModel: Equatable {
  let isRefreshing: Bool
  let sleepPreventionEnabled: Bool
  let manualRefreshSuccessToken: Int

  var sleepPreventionPresentation: SleepPreventionToolbarPresentation {
    SleepPreventionToolbarPresentation(isEnabled: sleepPreventionEnabled)
  }
}

struct ContentWindowToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let model: ContentWindowNavigationToolbarModel

  init(store: HarnessMonitorStore, model: ContentWindowNavigationToolbarModel) {
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
  let model: ContentPrimaryToolbarModel

  var body: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      SleepPreventionToolbarButton(
        store: store,
        presentation: model.sleepPreventionPresentation
      )
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      RefreshToolbarButton(store: store, model: model)
    }
    ToolbarSpacer(.fixed, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      SessionAttentionToolbarButton(store: store, slice: store.supervisorToolbarSlice)
    }
  }
}
