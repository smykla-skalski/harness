import SwiftUI

extension FocusedValues {
  @Entry public var harnessSidebarSearchFocusAction: (() -> Void)?
}

extension ContentView {
  func submitSidebarSearch() {
    store.flushPendingSearchRebuild()
    guard store.sidebarUI.isPersistenceAvailable else { return }
    _ = store.recordSearch(store.searchText)
  }

  func requestSidebarSearchPresentation() {
    guard canPresentSidebarSearch() else {
      schedulePendingSidebarSearchFocusRequest()
      return
    }
    presentSidebarSearchNow()
  }

  func applyPendingSidebarSearchPresentationRequestIfNeeded(isEnabled: Bool) {
    guard isEnabled, consumePendingSidebarSearchFocusRequest() else { return }
    presentSidebarSearchNow()
  }
}
