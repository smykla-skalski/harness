import HarnessMonitorKit

enum TaskBoardStatusFilterChoice: String, CaseIterable, Identifiable, Hashable {
  case all
  case umbrella
  case todo
  case planning
  case inProgress
  case agenticReview
  case testing
  case inReview
  case toReview
  case humanRequired
  case failed
  case done
  case new
  case planReview
  case needsYou
  case blocked

  /// Stable storage for `allCases` so `ForEach` pickers do not see a new
  /// array identity on every parent body re-evaluation. CaseIterable's
  /// synthesized `allCases` allocates a fresh array on each call which
  /// fanned a UInt32 source into ForEachState<…>.Evictor every render.
  static let stableAllCases: [Self] = Self.allCases

  private static let statusChoices: [TaskBoardStatus: Self] = [
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
    .done: .done,
    .new: .new,
    .planReview: .planReview,
    .needsYou: .needsYou,
    .blocked: .blocked,
  ]

  init(status: TaskBoardStatus?) {
    self = status.flatMap { Self.statusChoices[$0] } ?? .all
  }

  var id: String { rawValue }

  var title: String {
    status?.title ?? "All Items"
  }

  var status: TaskBoardStatus? {
    switch self {
    case .all:
      nil
    case .umbrella:
      .umbrella
    case .todo:
      .todo
    case .planning:
      .planning
    case .inProgress:
      .inProgress
    case .agenticReview:
      .agenticReview
    case .testing:
      .testing
    case .inReview:
      .inReview
    case .toReview:
      .toReview
    case .humanRequired:
      .humanRequired
    case .failed:
      .failed
    case .done:
      .done
    case .new:
      .new
    case .planReview:
      .planReview
    case .needsYou:
      .needsYou
    case .blocked:
      .blocked
    }
  }
}

enum TaskBoardExternalProviderChoice: String, CaseIterable, Identifiable, Hashable {
  case all
  case gitHub
  case todoist

  static let monitorVisibleChoice: Self = .gitHub

  init(provider: TaskBoardExternalProvider?) {
    switch provider {
    case .none:
      self = .all
    case .gitHub:
      self = .gitHub
    case .todoist:
      self = .todoist
    }
  }

  var id: String { rawValue }

  var title: String {
    provider?.title ?? "All Providers"
  }

  var provider: TaskBoardExternalProvider? {
    switch self {
    case .all:
      nil
    case .gitHub:
      .gitHub
    case .todoist:
      .todoist
    }
  }
}

extension TaskBoardExternalProvider {
  var title: String {
    switch self {
    case .gitHub:
      "GitHub"
    case .todoist:
      "Todoist"
    }
  }

  var isVisibleInMonitorUI: Bool {
    switch self {
    case .gitHub:
      true
    case .todoist:
      false
    }
  }
}

extension TaskBoardExternalSyncDirection {
  var title: String {
    switch self {
    case .pull:
      "Pull"
    case .push:
      "Push"
    case .both:
      "Bidirectional"
    }
  }
}

extension TaskBoardSyncSummary {
  var monitorVisibleProviders: [TaskBoardProviderSyncSummary] {
    providers.filter { $0.provider.isVisibleInMonitorUI }
  }

  var monitorVisibleOperations: [TaskBoardExternalSyncOperation] {
    operations.filter { $0.provider.isVisibleInMonitorUI }
  }
}

struct TaskBoardDispatchConfirmationPresentation: Equatable {
  let request: TaskBoardDispatchRequest
  let itemTitle: String?

  var title: String {
    if let itemTitle {
      return "Dispatch \(itemTitle)?"
    }
    if let status = request.status {
      return "Dispatch \(status.title) items?"
    }
    return "Dispatch matching items?"
  }

  var message: String {
    if request.itemId != nil {
      return """
        This creates live session work for the selected board item and cannot be \
        undone from the task board.
        """
    }
    return """
      This creates live session work for every board item matching the current \
      filter and cannot be undone from the task board.
      """
  }
}
