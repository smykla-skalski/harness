import HarnessMonitorKit
import SwiftUI

struct DashboardReviewRow: View {
  let item: ReviewItem
  let showsRepository: Bool
  let isSelected: Bool
  let isPinned: Bool
  let isRefreshing: Bool
  let actionTitle: String?
  let updatedLabel: String
  let repositoryLabels: [ReviewRepositoryLabel]
  let showsAvatars: Bool
  let showsLabels: Bool
  let showsLineCounters: Bool
  let showsPullRequestNumber: Bool
  let showsPullRequestAge: Bool
  let wrapsTitle: Bool
  let titleMaximumLines: Int
  let hidesSemanticPrefixesInTitle: Bool

  init(
    item: ReviewItem,
    showsRepository: Bool,
    isSelected: Bool = false,
    isPinned: Bool = false,
    isRefreshing: Bool,
    actionTitle: String?,
    updatedLabel: String,
    repositoryLabels: [ReviewRepositoryLabel] = [],
    showsAvatars: Bool = true,
    showsLabels: Bool = true,
    showsLineCounters: Bool = true,
    showsPullRequestNumber: Bool = true,
    showsPullRequestAge: Bool = true,
    wrapsTitle: Bool = true,
    titleMaximumLines: Int = DashboardReviewsPreferences.defaultRowTitleMaximumLines,
    hidesSemanticPrefixesInTitle: Bool = false
  ) {
    self.item = item
    self.showsRepository = showsRepository
    self.isSelected = isSelected
    self.isPinned = isPinned
    self.isRefreshing = isRefreshing
    self.actionTitle = actionTitle
    self.updatedLabel = updatedLabel
    self.repositoryLabels = repositoryLabels
    self.showsAvatars = showsAvatars
    self.showsLabels = showsLabels
    self.showsLineCounters = showsLineCounters
    self.showsPullRequestNumber = showsPullRequestNumber
    self.showsPullRequestAge = showsPullRequestAge
    self.wrapsTitle = wrapsTitle
    self.titleMaximumLines = titleMaximumLines
    self.hidesSemanticPrefixesInTitle = hidesSemanticPrefixesInTitle
  }

  var body: some View {
    DashboardReviewListRow(
      item: item,
      showsRepository: showsRepository,
      isSelected: isSelected,
      isPinned: isPinned,
      isRefreshing: isRefreshing,
      actionTitle: actionTitle,
      updatedLabel: updatedLabel,
      repositoryLabels: repositoryLabels,
      showsAvatars: showsAvatars,
      showsLabels: showsLabels,
      showsLineCounters: showsLineCounters,
      showsPullRequestNumber: showsPullRequestNumber,
      showsPullRequestAge: showsPullRequestAge,
      wrapsTitle: wrapsTitle,
      titleMaximumLines: titleMaximumLines,
      hidesSemanticPrefixesInTitle: hidesSemanticPrefixesInTitle
    )
    .tag(item.pullRequestID)
    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    .listRowSeparator(.hidden)
  }
}
