import Foundation

public enum TaskBoardLaneOrigin: Codable, Equatable, Sendable {
  case manual(actor: String)
  case automatic(producer: String)

  private enum CodingKeys: String, CodingKey {
    case kind
    case actor
    case producer
  }

  private enum Kind: String, Codable {
    case manual
    case automatic
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .manual:
      self = .manual(actor: try container.decode(String.self, forKey: .actor))
    case .automatic:
      self = .automatic(producer: try container.decode(String.self, forKey: .producer))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .manual(let actor):
      try container.encode(Kind.manual, forKey: .kind)
      try container.encode(actor, forKey: .actor)
    case .automatic(let producer):
      try container.encode(Kind.automatic, forKey: .kind)
      try container.encode(producer, forKey: .producer)
    }
  }
}

public enum TaskBoardRelativeLaneEdge: Equatable, Sendable {
  case before
  case after
}

public struct TaskBoardRelativeLanePlacement: Equatable, Sendable {
  public let anchorItemID: String
  public let edge: TaskBoardRelativeLaneEdge

  public init(anchorItemID: String, edge: TaskBoardRelativeLaneEdge) {
    self.anchorItemID = anchorItemID
    self.edge = edge
  }

  public func resolvePosition(itemID: String, orderedItemIDs: [String]) -> UInt32? {
    TaskBoardLanePlacement.relative(self).resolvePosition(
      itemID: itemID,
      orderedItemIDs: orderedItemIDs
    )
  }
}

public enum TaskBoardLanePlacement: Equatable, Sendable {
  case first
  case last
  case relative(TaskBoardRelativeLanePlacement)

  public func resolvePosition(itemID: String, orderedItemIDs: [String]) -> UInt32? {
    let currentIndex = orderedItemIDs.firstIndex(of: itemID)
    let remainingItemIDs = orderedItemIDs.filter { $0 != itemID }
    let target: Int
    switch self {
    case .first:
      target = 0
    case .last:
      target = remainingItemIDs.count
    case .relative(let placement):
      guard let anchorIndex = remainingItemIDs.firstIndex(of: placement.anchorItemID) else {
        return nil
      }
      target = placement.edge == .after ? anchorIndex + 1 : anchorIndex
    }
    guard currentIndex != target else {
      return nil
    }
    return UInt32(exactly: target)
  }
}

public struct TaskBoardListItemsSnapshot: Equatable, Sendable {
  public let items: [TaskBoardItem]
  public let itemsChangeSeq: Int64
  public let itemRevisions: [String: Int64]

  public init(items: [TaskBoardItem], itemsChangeSeq: Int64, itemRevisions: [String: Int64]) {
    self.items = items
    self.itemsChangeSeq = itemsChangeSeq
    self.itemRevisions = itemRevisions
  }
}

public struct TaskBoardItemPositionSnapshot: Equatable, Sendable {
  public let item: TaskBoardItem
  public let itemRevision: Int64
  public let itemsChangeSeq: Int64

  public init(item: TaskBoardItem, itemRevision: Int64, itemsChangeSeq: Int64) {
    self.item = item
    self.itemRevision = itemRevision
    self.itemsChangeSeq = itemsChangeSeq
  }
}

public struct TaskBoardShiftedItemRevision: Equatable, Sendable {
  public let itemId: String
  public let itemRevision: Int64

  public init(itemId: String, itemRevision: Int64) {
    self.itemId = itemId
    self.itemRevision = itemRevision
  }
}

public struct TaskBoardItemPositionMutationResponse: Equatable, Sendable {
  public let snapshot: TaskBoardItemPositionSnapshot
  public let shifted: [TaskBoardShiftedItemRevision]

  public init(snapshot: TaskBoardItemPositionSnapshot, shifted: [TaskBoardShiftedItemRevision]) {
    self.snapshot = snapshot
    self.shifted = shifted
  }
}
