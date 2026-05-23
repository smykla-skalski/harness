import HarnessMonitorKit
import SwiftUI

struct DashboardReviewRow: View {
  let item: ReviewItem
  let showsRepository: Bool
  let isPinned: Bool
  let isRefreshing: Bool
  let actionTitle: String?
  let updatedLabel: String

  init(
    item: ReviewItem,
    showsRepository: Bool,
    isPinned: Bool = false,
    isRefreshing: Bool,
    actionTitle: String?,
    updatedLabel: String
  ) {
    self.item = item
    self.showsRepository = showsRepository
    self.isPinned = isPinned
    self.isRefreshing = isRefreshing
    self.actionTitle = actionTitle
    self.updatedLabel = updatedLabel
  }

  var body: some View {
    DashboardReviewListRow(
      item: item,
      showsRepository: showsRepository,
      isPinned: isPinned,
      isRefreshing: isRefreshing,
      actionTitle: actionTitle,
      updatedLabel: updatedLabel
    )
    .tag(item.pullRequestID)
    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    .listRowSeparator(.hidden)
  }
}
