import HarnessMonitorKit
import SwiftUI

struct ContentWindowToolbarModel: Equatable {
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let canCreateTask: Bool
  let isRefreshing: Bool
  let sleepPreventionEnabled: Bool
  let manualRefreshSuccessToken: Int

  var sleepPreventionPresentation: SleepPreventionToolbarPresentation {
    SleepPreventionToolbarPresentation(isEnabled: sleepPreventionEnabled)
  }
}

struct ContentWindowToolbarItems: ToolbarContent {
  let store: HarnessMonitorStore
  let contentToolbar: HarnessMonitorStore.ContentToolbarSlice
  let canCreateTask: Bool

  private var model: ContentWindowToolbarModel {
    ContentWindowToolbarModel(
      canNavigateBack: contentToolbar.canNavigateBack,
      canNavigateForward: contentToolbar.canNavigateForward,
      canCreateTask: canCreateTask,
      isRefreshing: contentToolbar.isRefreshing,
      sleepPreventionEnabled: contentToolbar.sleepPreventionEnabled,
      manualRefreshSuccessToken: contentToolbar.manualRefreshSuccessToken
    )
  }

  init(
    store: HarnessMonitorStore,
    contentToolbar: HarnessMonitorStore.ContentToolbarSlice,
    canCreateTask: Bool
  ) {
    self.store = store
    self.contentToolbar = contentToolbar
    self.canCreateTask = canCreateTask
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
  let contentToolbar: HarnessMonitorStore.ContentToolbarSlice

  private var model: ContentWindowToolbarModel {
    ContentWindowToolbarModel(
      canNavigateBack: false,
      canNavigateForward: false,
      canCreateTask: false,
      isRefreshing: contentToolbar.isRefreshing,
      sleepPreventionEnabled: contentToolbar.sleepPreventionEnabled,
      manualRefreshSuccessToken: contentToolbar.manualRefreshSuccessToken
    )
  }

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
