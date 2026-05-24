import HarnessMonitorKit

extension DashboardReviewsPresentation {
  init(
    listPresentation: DashboardReviewsListPresentation,
    selectedIDs: Set<String>,
    persistedPrimarySelectionID: String,
    sortModeRaw: String
  ) {
    let selectedItems = DashboardReviewsPresentationSelection.selectedItems(
      selectedIDs: selectedIDs,
      itemsByID: listPresentation.itemsByID,
      sortModeRaw: sortModeRaw
    )
    let primaryDetailItem = DashboardReviewsPresentationSelection.primaryDetailItem(
      selectedItems: selectedItems,
      filteredItems: listPresentation.filteredItems,
      persistedPrimarySelectionID: persistedPrimarySelectionID
    )
    self.init(
      filteredItems: listPresentation.filteredItems,
      groupedItems: listPresentation.groupedItems,
      itemsByID: listPresentation.itemsByID,
      selectedItems: selectedItems,
      primaryDetailItem: primaryDetailItem,
      relativeUpdatedLabels: listPresentation.relativeUpdatedLabels,
      version: DashboardReviewsPresentationVersion(
        listVersion: listPresentation.version,
        selectedPullRequestIDs: selectedItems.map(\.pullRequestID),
        primaryDetailPullRequestID: primaryDetailItem?.pullRequestID
      )
    )
  }

  func applyingSelection(
    selectedIDs: Set<String>,
    persistedPrimarySelectionID: String,
    sortModeRaw: String
  ) -> DashboardReviewsPresentation {
    let selectedItems = DashboardReviewsPresentationSelection.selectedItems(
      selectedIDs: selectedIDs,
      itemsByID: itemsByID,
      sortModeRaw: sortModeRaw
    )
    let primaryDetailItem = DashboardReviewsPresentationSelection.primaryDetailItem(
      selectedItems: selectedItems,
      filteredItems: filteredItems,
      persistedPrimarySelectionID: persistedPrimarySelectionID
    )
    return Self(
      filteredItems: filteredItems,
      groupedItems: groupedItems,
      itemsByID: itemsByID,
      selectedItems: selectedItems,
      primaryDetailItem: primaryDetailItem,
      relativeUpdatedLabels: relativeUpdatedLabels,
      version: DashboardReviewsPresentationVersion(
        listVersion: version.listVersion,
        selectedPullRequestIDs: selectedItems.map(\.pullRequestID),
        primaryDetailPullRequestID: primaryDetailItem?.pullRequestID
      )
    )
  }
}

enum DashboardReviewsPresentationSelection {
  static func selectedItems(
    selectedIDs: Set<String>,
    itemsByID: [String: ReviewItem],
    sortModeRaw: String
  ) -> [ReviewItem] {
    let sortMode = DashboardReviewsSortMode(rawValue: sortModeRaw) ?? .status
    let comparator = sortMode.comparator
    return
      selectedIDs
      .compactMap { itemsByID[$0] }
      .sorted(by: comparator)
  }

  static func primaryDetailItem(
    selectedItems: [ReviewItem],
    filteredItems: [ReviewItem],
    persistedPrimarySelectionID: String
  ) -> ReviewItem? {
    if selectedItems.count == 1 {
      return selectedItems.first
    }
    if selectedItems.isEmpty, !persistedPrimarySelectionID.isEmpty {
      return filteredItems.first { $0.pullRequestID == persistedPrimarySelectionID }
    }
    return selectedItems.isEmpty ? filteredItems.first : nil
  }
}
