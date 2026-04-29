import Foundation

/// Store-owned ACP selection state shared across the Decisions detail pane and the legacy
/// reader-only modal. The state is keyed by decision id so both surfaces observe the same
/// selection and submission lifecycle.
public struct BatchResolutionState: Equatable, Sendable {
  public struct ItemState: Equatable, Sendable, Identifiable {
    public enum ToggleState: String, Codable, Equatable, Sendable {
      case selected
      case unselected
    }

    public let itemID: String
    public var toggleState: ToggleState

    public var id: String { itemID }

    public init(itemID: String, toggleState: ToggleState) {
      self.itemID = itemID
      self.toggleState = toggleState
    }
  }

  public let batchID: String
  public var perItem: [ItemState]
  public var submittedAt: Date?

  public init(
    batchID: String,
    perItem: [ItemState],
    submittedAt: Date? = nil
  ) {
    self.batchID = batchID
    self.perItem = perItem
    self.submittedAt = submittedAt
  }

  public static func initial(batchID: String, requestIDs: [String]) -> Self {
    Self(
      batchID: batchID,
      perItem: requestIDs.map {
        ItemState(itemID: $0, toggleState: .selected)
      }
    )
  }

  public func rebased(to requestIDs: [String]) -> Self {
    let stateByID = Dictionary(uniqueKeysWithValues: perItem.map { ($0.itemID, $0.toggleState) })
    return Self(
      batchID: batchID,
      perItem: requestIDs.map { requestID in
        ItemState(
          itemID: requestID,
          toggleState: stateByID[requestID] ?? .selected
        )
      },
      submittedAt: submittedAt
    )
  }

  public var selectedRequestIDs: [String] {
    perItem.compactMap { item in
      item.toggleState == .selected ? item.itemID : nil
    }
  }

  public var hasSelection: Bool {
    !selectedRequestIDs.isEmpty
  }

  public var isSubmitting: Bool {
    submittedAt != nil
  }

  public func isSelected(requestID: String) -> Bool {
    perItem.first(where: { $0.itemID == requestID })?.toggleState == .selected
  }

  public mutating func setSelected(_ isSelected: Bool, for itemID: String) {
    guard let index = perItem.firstIndex(where: { $0.itemID == itemID }) else {
      return
    }
    perItem[index].toggleState = isSelected ? .selected : .unselected
  }
}
