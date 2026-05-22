import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  @ViewBuilder
  func reviewSelectionContextMenu(for selection: Set<String>) -> some View {
    let items = contextMenuItems(forSelection: selection)
    if let primaryItem = items.first {
      let isSingleItem = items.count == 1
      let availableLabels = contextMenuAvailableLabels(for: items)
      let frequentNames = contextMenuFrequentNames(for: items)
      let isBusy = items.contains { isPullRequestRefreshing($0.pullRequestID) }
      if isSingleItem {
        Button("Open Pull Request") {
          openItem(primaryItem)
        }
        Button("Copy Link") {
          HarnessMonitorClipboard.copy(primaryItem.url)
        }
        Divider()
      }
      Button("Approve") {
        requestApproveOrConfirm(items: items)
      }
      .disabled(isBusy || !items.contains { $0.canAttemptManualApproval })
      Button(dashboardReviewMergeActionTitle(for: items)) {
        requestMergeOrConfirm(items: items)
      }
      .disabled(isBusy || !items.contains { $0.canAttemptManualMerge })
      Button("Rerun Checks") {
        Task { await rerunChecks(items: items) }
      }
      .disabled(isBusy || !items.contains { $0.canAttemptRerunChecks })
      Button("Refresh") {
        refresh(items: items)
      }
      .disabled(isBusy)
      DashboardReviewsLabelPickerMenu(
        title: "Add Label",
        labels: availableLabels,
        frequentNames: frequentNames,
        showsDescriptions: normalizedPreferences.showLabelDescriptions,
        onSelect: { name in Task { await addLabel(name, to: items) } },
        onCustom: {
          routeLabelTargetItems = items
          routeLabelDraft = ""
          routeIsLabelSheetPresented = true
        }
      )
      .disabled(isBusy || !items.contains { $0.canAddReviewLabel })
      Button("Auto") {
        requestAuto(items: items)
      }
      .disabled(isBusy || !items.contains { $0.canRunAutoMode })
      if isSingleItem, primaryItem.canStartFixCI {
        Button("Fix CI") {
          Task { await fixCI(item: primaryItem) }
        }
      }
    }
  }

  func contextMenuItems(forSelection selection: Set<String>) -> [ReviewItem] {
    guard !selection.isEmpty else { return [] }
    return filteredItems.filter { selection.contains($0.pullRequestID) }
  }

  func contextMenuAvailableLabels(
    for items: [ReviewItem]
  ) -> [ReviewRepositoryLabel] {
    if items.count == 1, let item = items.first {
      return rowAvailableLabels(for: item)
    }
    return dashboardReviewsAvailableLabels(
      repositoryLabels: routeResponse.repositoryLabels,
      items: items
    )
  }

  func contextMenuFrequentNames(for items: [ReviewItem]) -> [String] {
    if items.count == 1, let item = items.first {
      return rowFrequentLabelNames(for: item)
    }
    return frequentLabelNames(for: items)
  }
}
