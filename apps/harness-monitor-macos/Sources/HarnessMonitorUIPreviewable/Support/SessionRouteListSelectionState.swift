import Foundation

struct SessionRouteListSelectionState: Equatable {
  var selectedIDs: Set<String> = []
  var anchorID: String?

  func displayedSelection(fallbackPrimaryID: String?) -> Set<String> {
    if selectedIDs.isEmpty {
      guard let fallbackPrimaryID else { return [] }
      return [fallbackPrimaryID]
    }
    return selectedIDs
  }

  func primarySelectionID(fallbackPrimaryID: String?) -> String? {
    let displayed = displayedSelection(fallbackPrimaryID: fallbackPrimaryID)
    if let anchorID, displayed.contains(anchorID) {
      return anchorID
    }
    if let fallbackPrimaryID, displayed.contains(fallbackPrimaryID) {
      return fallbackPrimaryID
    }
    return displayed.first
  }

  func hasActiveMultiSelection(fallbackPrimaryID: String?) -> Bool {
    displayedSelection(fallbackPrimaryID: fallbackPrimaryID).count > 1
  }

  @discardableResult
  mutating func applySelection(
    _ newSelection: Set<String>,
    fallbackPrimaryID: String?
  ) -> String? {
    let previous = displayedSelection(fallbackPrimaryID: fallbackPrimaryID)
    let effective: Set<String>
    if newSelection.isEmpty, let fallbackPrimaryID {
      effective = [fallbackPrimaryID]
    } else {
      effective = newSelection
    }

    selectedIDs = effective
    let added = effective.subtracting(previous)
    if effective.count <= 1 {
      anchorID = effective.first
    } else if let addedID = added.first {
      anchorID = addedID
    } else if let anchorID, effective.contains(anchorID) {
      self.anchorID = anchorID
    } else {
      anchorID = effective.first
    }

    return primarySelectionID(fallbackPrimaryID: fallbackPrimaryID)
  }

  mutating func collapse(to primaryID: String?) {
    selectedIDs = primaryID.map { [$0] } ?? []
    anchorID = primaryID
  }

  @discardableResult
  mutating func prune(
    visibleIDs: Set<String>,
    fallbackPrimaryID: String?
  ) -> String? {
    let pruned = displayedSelection(fallbackPrimaryID: fallbackPrimaryID)
      .intersection(visibleIDs)
    if pruned.isEmpty {
      if let fallbackPrimaryID, visibleIDs.contains(fallbackPrimaryID) {
        selectedIDs = [fallbackPrimaryID]
        anchorID = fallbackPrimaryID
      } else {
        selectedIDs = []
        anchorID = nil
      }
      return primarySelectionID(fallbackPrimaryID: fallbackPrimaryID)
    }

    selectedIDs = pruned
    if let anchorID, pruned.contains(anchorID) {
      self.anchorID = anchorID
    } else {
      anchorID = primarySelectionID(fallbackPrimaryID: fallbackPrimaryID)
    }
    return primarySelectionID(fallbackPrimaryID: fallbackPrimaryID)
  }
}
