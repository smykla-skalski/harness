import Foundation

@frozen
public enum TaskBoardInboxLane: String, CaseIterable, Identifiable, Sendable {
  case umbrella
  case todo
  case planning
  case inProgress = "in_progress"
  case agenticReview = "agentic_review"
  case testing
  case inReview = "in_review"
  case toReview = "to_review"
  case humanRequired = "human_required"
  case failed

  private static let orderedCases: [Self] = [
    .umbrella,
    .todo,
    .planning,
    .inProgress,
    .agenticReview,
    .testing,
    .inReview,
    .toReview,
    .humanRequired,
    .failed,
  ]

  private static let laneByTaskBoardStatus: [TaskBoardStatus: Self] = [
    .umbrella: .umbrella,
    .todo: .todo,
    .planning: .planning,
    .inProgress: .inProgress,
    .agenticReview: .agenticReview,
    .testing: .testing,
    .inReview: .inReview,
    .toReview: .toReview,
    .humanRequired: .humanRequired,
    .failed: .failed,
    .new: .todo,
    .planReview: .agenticReview,
    .needsYou: .humanRequired,
    .blocked: .failed,
  ]

  public static var allCases: [Self] {
    orderedCases
  }

  public static var active: Self { .inProgress }
  public static var open: Self { .todo }

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .umbrella:
      "Umbrella"
    case .todo:
      "Todo"
    case .planning:
      "Planning"
    case .inProgress:
      "In Progress"
    case .agenticReview:
      "Agentic Review"
    case .testing:
      "Testing"
    case .inReview:
      "In Review"
    case .toReview:
      "To Review"
    case .humanRequired:
      "Human Required"
    case .failed:
      "Failed"
    }
  }

  public var systemImage: String {
    switch self {
    case .umbrella:
      "umbrella"
    case .todo:
      "tray.and.arrow.down"
    case .planning:
      "list.clipboard"
    case .inProgress:
      "arrow.triangle.2.circlepath"
    case .agenticReview:
      "sparkles"
    case .testing:
      "checkmark.shield"
    case .inReview:
      "checkmark.seal"
    case .toReview:
      "doc.text.magnifyingglass"
    case .humanRequired:
      "person.crop.circle.badge.exclamationmark"
    case .failed:
      "exclamationmark.triangle"
    }
  }

  public init?(task: WorkItem) {
    switch task.status {
    case .blocked:
      self = .failed
    case .awaitingReview:
      self = .toReview
    case .inReview:
      self = .inReview
    case .inProgress:
      self = .inProgress
    case .open:
      self = .todo
    case .done:
      return nil
    }
  }

  public init?(status: TaskStatus) {
    switch status {
    case .blocked:
      self = .failed
    case .awaitingReview:
      self = .toReview
    case .inReview:
      self = .inReview
    case .inProgress:
      self = .inProgress
    case .open:
      self = .todo
    case .done:
      return nil
    }
  }

  public init?(taskBoardItem item: TaskBoardItem) {
    self.init(status: item.status)
  }

  public init?(status: TaskBoardStatus) {
    guard let lane = Self.laneByTaskBoardStatus[status] else {
      return nil
    }
    self = lane
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
    let lookup = Self.sessionLookup(sessions)
    let items = detailsBySessionID.values.flatMap { detail in
      let session = lookup[detail.session.sessionId] ?? detail.session
      return detail.tasks.compactMap { TaskBoardInboxItem(session: session, task: $0) }
    }
    let limitedItems = Self.sortedItems(items).prefix(max(limit, 0))
    self.items = Array(limitedItems)
    self.generatedAt = generatedAt
    self.isFromCache = isFromCache
  }

  static func sessionLookup(_ sessions: [SessionSummary]) -> [String: SessionSummary] {
    Dictionary(sessions.map { ($0.sessionId, $0) }) { existing, duplicate in
      HarnessMonitorLogger.store.warning(
        """
        TaskBoardInboxSnapshot deduplicated duplicate session id \
        \(existing.sessionId, privacy: .public); \
        keeping first entry, dropping duplicate updatedAt=\
        \(duplicate.updatedAt, privacy: .public)
        """
      )
      return existing
    }
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
    items.count
  }

  public var visibleItemCount: Int {
    items.count
  }

  public var needsYouItemCount: Int {
    items.count { $0.lane == .humanRequired }
  }

  public var blockedItemCount: Int {
    items.count { $0.lane == .failed }
  }

  public var reviewItemCount: Int {
    items.count { Self.reviewLanes.contains($0.lane) }
  }

  public var completedItemCount: Int {
    0
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
    TaskBoardInboxLane.allCases.firstIndex(of: lane) ?? Int.max
  }

  private static let reviewLanes: Set<TaskBoardInboxLane> = [
    .agenticReview,
    .testing,
    .inReview,
    .toReview,
  ]

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
