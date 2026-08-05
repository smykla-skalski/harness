import HarnessMonitorKit
import SwiftUI

struct DashboardDecisionScrollTarget: Hashable {
  let decisionID: String
  let requestTick: Int

  static func resolve(
    selectedDecisionID: String?,
    requestTick: Int,
    availableDecisionIDs: Set<String>
  ) -> Self? {
    guard
      requestTick != 0,
      let selectedDecisionID,
      availableDecisionIDs.contains(selectedDecisionID)
    else { return nil }
    return Self(decisionID: selectedDecisionID, requestTick: requestTick)
  }
}

struct DashboardDecisionScrollView<Content: View>: View {
  let store: HarnessMonitorStore
  let decisionIDs: Set<String>
  @ViewBuilder let content: () -> Content

  init(
    store: HarnessMonitorStore,
    decisionIDs: Set<String>,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.store = store
    self.decisionIDs = decisionIDs
    self.content = content
  }

  private var target: DashboardDecisionScrollTarget? {
    DashboardDecisionScrollTarget.resolve(
      selectedDecisionID: store.supervisorSelectedDecisionID,
      requestTick: store.supervisorPrimaryActionFocusRequestTick,
      availableDecisionIDs: decisionIDs
    )
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        content()
      }
      .task(id: target) {
        guard let target else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        proxy.scrollTo(target.decisionID, anchor: .center)
      }
    }
  }
}
