import Foundation

@frozen
public enum TaskBoardInboxLane: String, CaseIterable, Identifiable, Sendable {
  case needsYou = "needs_you"
  case ready
  case running
  case review
  case blocked
  case backlog

  public static var allCases: [TaskBoardInboxLane] {
    [.needsYou, .ready, .running, .review, .blocked, .backlog]
  }

  public static var active: Self { .running }
  public static var open: Self { .backlog }

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .needsYou:
      "Needs You"
    case .ready:
      "Ready"
    case .running:
      "Running"
    case .review:
      "Review"
    case .blocked:
      "Blocked"
    case .backlog:
      "Backlog"
    }
  }

  public var systemImage: String {
    switch self {
    case .needsYou:
      "person.crop.circle.badge.exclamationmark"
    case .ready:
      "tray.and.arrow.down"
    case .running:
      "arrow.triangle.2.circlepath"
    case .review:
      "checkmark.seal"
    case .blocked:
      "exclamationmark.triangle"
    case .backlog:
      "tray"
    }
  }

  public init?(task: WorkItem) {
    switch task.status {
    case .blocked:
      self = .blocked
    case .awaitingReview, .inReview:
      self = .review
    case .inProgress:
      self = .running
    case .open:
      self = task.assignedTo != nil || task.queuedAt != nil ? .ready : .backlog
    case .done:
      return nil
    }
  }

  public init?(status: TaskStatus) {
    switch status {
    case .blocked:
      self = .blocked
    case .awaitingReview, .inReview:
      self = .review
    case .inProgress:
      self = .running
    case .open:
      self = .backlog
    case .done:
      return nil
    }
  }

  public init?(taskBoardItem item: TaskBoardItem) {
    self.init(status: item.status)
  }

  public init?(status: TaskBoardStatus) {
    switch status {
    case .planReview:
      self = .needsYou
    case .blocked:
      self = .blocked
    case .todo:
      self = .ready
    case .inProgress:
      self = .running
    case .inReview:
      self = .review
    case .new, .planning:
      self = .backlog
    case .done:
      return nil
    }
  }
}

public struct TaskBoardInboxItem: Equatable, Identifiable, Sendable {
  public let session: SessionSummary
  public let task: WorkItem
  public let lane: TaskBoardInboxLane

  public var id: String { "\(session.sessionId):\(task.taskId)" }

  public init?(
    session: SessionSummary,
    task: WorkItem
  ) {
    guard let lane = TaskBoardInboxLane(task: task) else {
      return nil
    }
    self.session = session
    self.task = task
    self.lane = lane
  }

  public var subtitle: String {
    let title = session.displayTitle
    if title == "(untitled)" {
      return session.projectAndWorktreeDisplayLabel()
    }
    return title
  }

  public var metadataText: String {
    let assignee = task.assignedTo ?? "Unassigned"
    return "\(task.status.title) - \(task.severity.title) - \(assignee)"
  }
}

public struct TaskBoardInboxSection: Equatable, Identifiable, Sendable {
  public let lane: TaskBoardInboxLane
  public let items: [TaskBoardInboxItem]

  public var id: TaskBoardInboxLane { lane }

  public init(
    lane: TaskBoardInboxLane,
    items: [TaskBoardInboxItem]
  ) {
    self.lane = lane
    self.items = items
  }
}

public struct TaskBoardInboxSnapshot: Equatable, Sendable {
  public let items: [TaskBoardInboxItem]
  public let generatedAt: Date?
  public let isFromCache: Bool

  public init(
    items: [TaskBoardInboxItem] = [],
    generatedAt: Date? = nil,
    isFromCache: Bool = false
  ) {
    self.items = Self.sortedItems(items)
    self.generatedAt = generatedAt
    self.isFromCache = isFromCache
  }

  public init(
    sessions: [SessionSummary],
    detailsBySessionID: [String: SessionDetail],
    limit: Int = 80,
    generatedAt: Date? = nil,
    isFromCache: Bool = false
  ) {
    let lookup = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
    let items = detailsBySessionID.values.flatMap { detail in
      let session = lookup[detail.session.sessionId] ?? detail.session
      return detail.tasks.compactMap { TaskBoardInboxItem(session: session, task: $0) }
    }
    let limitedItems = Self.sortedItems(items).prefix(max(limit, 0))
    self.items = Array(limitedItems)
    self.generatedAt = generatedAt
    self.isFromCache = isFromCache
  }

  public var sections: [TaskBoardInboxSection] {
    TaskBoardInboxLane.allCases.map { lane in
      TaskBoardInboxSection(
        lane: lane,
        items: items.filter { $0.lane == lane }
      )
    }
  }

  public var openItemCount: Int {
    visibleItemCount
  }

  public var visibleItemCount: Int {
    items.count
  }

  public var needsYouItemCount: Int {
    items.count { $0.lane == .needsYou }
  }

  public var blockedItemCount: Int {
    items.count { $0.lane == .blocked }
  }

  public var reviewItemCount: Int {
    items.count { $0.lane == .review }
  }

  public var isEmpty: Bool {
    items.isEmpty
  }

  static func sortedItems(_ items: [TaskBoardInboxItem]) -> [TaskBoardInboxItem] {
    items.sorted { left, right in
      let leftLane = lanePriority(left.lane)
      let rightLane = lanePriority(right.lane)
      if leftLane != rightLane {
        return leftLane < rightLane
      }

      let leftSeverity = severityPriority(left.task.severity)
      let rightSeverity = severityPriority(right.task.severity)
      if leftSeverity != rightSeverity {
        return leftSeverity > rightSeverity
      }

      if left.task.updatedAt != right.task.updatedAt {
        return left.task.updatedAt > right.task.updatedAt
      }

      if left.session.sessionId != right.session.sessionId {
        return left.session.sessionId < right.session.sessionId
      }

      return left.task.taskId < right.task.taskId
    }
  }

  private static func lanePriority(_ lane: TaskBoardInboxLane) -> Int {
    switch lane {
    case .needsYou:
      0
    case .ready:
      1
    case .running:
      2
    case .review:
      3
    case .blocked:
      4
    case .backlog:
      5
    }
  }

  private static func severityPriority(_ severity: TaskSeverity) -> Int {
    switch severity {
    case .critical:
      3
    case .high:
      2
    case .medium:
      1
    case .low:
      0
    }
  }
}
