import HarnessMonitorIntents
import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  func openItem(_ item: ReviewItem) {
    guard let url = URL(string: item.url) else { return }
    openURL(url)
  }

  func copyApprovalLinks(for items: [ReviewItem]) {
    let scopedItems: [ReviewItem]
    if selectedItems.isEmpty, items.count == 1, let repository = items.first?.repository,
      groupMode == .repository
    {
      scopedItems = filteredItems.filter { $0.repository == repository }
    } else {
      scopedItems = items
    }
    let links =
      scopedItems
      .filter { $0.reviewStatus == .reviewRequired }
      .map(\.url)
    guard !links.isEmpty else {
      store.toast.presentWarning("No approval links are needed for the current scope")
      return
    }
    HarnessMonitorClipboard.copy(links.joined(separator: "\n"))
    store.presentSuccessFeedback("Copied \(links.count) approval link(s)")
  }

  func relativeUpdatedLabel(for item: ReviewItem) -> String {
    relativeUpdatedLabels[item.pullRequestID] ?? item.updatedAt
  }

  func toggleRepositoryCollapse(_ repository: String) {
    var collapsed = routeCollapsedRepositories
    collapsed.toggle(repository)
    routeCollapsedRepositories = collapsed
    routeCollapsedRepositoriesStorage = collapsed.encodedString
  }

  func toggleRepositoryPin(_ repository: String) {
    var pinned = routePinnedRepositories
    if pinned.contains(repository) {
      pinned.unpin(repository)
    } else {
      pinned.pin(repository)
    }
    routePinnedRepositories = pinned
    routePinnedRepositoriesStorage = pinned.encodedString
  }

  func reconcileSelection() {
    let liveIDs = Set(routeResponse.items.map(\.pullRequestID))
    routeSelectedIDs = routeSelectedIDs.intersection(liveIDs)
    if routeSelectedIDs.isEmpty, let persisted = persistedPrimarySelectionID.nonEmpty,
      liveIDs.contains(persisted)
    {
      routeSelectedIDs = [persisted]
    }
  }

  func refreshCachedPresentationSelection() {
    let presentation = routeCachedPresentation.applyingSelection(
      selectedIDs: routeSelectedIDs,
      persistedPrimarySelectionID: persistedPrimarySelectionID,
      sortModeRaw: sortModeRaw
    )
    if routeCachedPresentation != presentation {
      routeCachedPresentation = presentation
    }
  }

  @MainActor
  func rebuildPresentation(input: DashboardReviewsListPresentationInput) async {
    routePresentationGeneration &+= 1
    let generation = routePresentationGeneration
    let listPresentation = await routePresentationWorker.computeList(input: input)
    guard !Task.isCancelled, routePresentationGeneration == generation else {
      return
    }
    let presentation = DashboardReviewsPresentation(
      listPresentation: listPresentation,
      selectedIDs: routeSelectedIDs,
      persistedPrimarySelectionID: persistedPrimarySelectionID,
      sortModeRaw: sortModeRaw
    )
    if routeCachedPresentation != presentation {
      routeCachedPresentation = presentation
    }
  }
}
