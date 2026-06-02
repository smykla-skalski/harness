import AppKit
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
  let repositoryLabelByName: [String: ReviewRepositoryLabel]
  let showsAvatars: Bool
  let showsLabels: Bool
  let showsLineCounters: Bool
  let showsPullRequestNumber: Bool
  let showsPullRequestAge: Bool
  let wrapsTitle: Bool
  let titleMaximumLines: Int
  let hidesSemanticPrefixesInTitle: Bool
  let slaThresholdHours: Int?
  @State private var isHovered = false

  init(
    item: ReviewItem,
    showsRepository: Bool,
    isSelected: Bool = false,
    isPinned: Bool = false,
    isRefreshing: Bool,
    actionTitle: String?,
    updatedLabel: String,
    repositoryLabelByName: [String: ReviewRepositoryLabel] = [:],
    showsAvatars: Bool = true,
    showsLabels: Bool = true,
    showsLineCounters: Bool = true,
    showsPullRequestNumber: Bool = true,
    showsPullRequestAge: Bool = true,
    wrapsTitle: Bool = true,
    titleMaximumLines: Int = DashboardReviewsPreferences.defaultRowTitleMaximumLines,
    hidesSemanticPrefixesInTitle: Bool = false,
    slaThresholdHours: Int? = nil
  ) {
    self.item = item
    self.showsRepository = showsRepository
    self.isSelected = isSelected
    self.isPinned = isPinned
    self.isRefreshing = isRefreshing
    self.actionTitle = actionTitle
    self.updatedLabel = updatedLabel
    self.repositoryLabelByName = repositoryLabelByName
    self.showsAvatars = showsAvatars
    self.showsLabels = showsLabels
    self.showsLineCounters = showsLineCounters
    self.showsPullRequestNumber = showsPullRequestNumber
    self.showsPullRequestAge = showsPullRequestAge
    self.wrapsTitle = wrapsTitle
    self.titleMaximumLines = titleMaximumLines
    self.hidesSemanticPrefixesInTitle = hidesSemanticPrefixesInTitle
    self.slaThresholdHours = slaThresholdHours
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
      repositoryLabelByName: repositoryLabelByName,
      showsAvatars: showsAvatars,
      showsLabels: showsLabels,
      showsLineCounters: showsLineCounters,
      showsPullRequestNumber: showsPullRequestNumber,
      showsPullRequestAge: showsPullRequestAge,
      wrapsTitle: wrapsTitle,
      titleMaximumLines: titleMaximumLines,
      hidesSemanticPrefixesInTitle: hidesSemanticPrefixesInTitle,
      slaThresholdHours: slaThresholdHours
    )
    .equatable()
    .tag(item.pullRequestID)
    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    .listRowSeparator(.hidden)
    .listRowBackground(rowChromeBackground)
    .onHover { hovering in
      if isHovered != hovering {
        isHovered = hovering
      }
    }
  }

  private var rowChromeBackground: some View {
    ZStack {
      if isHovered {
        HarnessMonitorTheme.ink.opacity(0.05)
      } else if isPinned {
        HarnessMonitorTheme.accent.opacity(0.05)
      } else {
        Color.clear
      }
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(height: 1)
      }
    }
  }
}
