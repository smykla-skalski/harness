import HarnessMonitorKit

enum TaskBoardStatusFilterChoice: String, CaseIterable, Identifiable, Hashable {
  case all
  case new
  case planning
  case planReview
  case needsYou
  case todo
  case inProgress
  case inReview
  case done
  case blocked

  private static let statusChoices: [TaskBoardStatus: Self] = [
    .new: .new,
    .planning: .planning,
    .planReview: .planReview,
    .needsYou: .needsYou,
    .todo: .todo,
    .inProgress: .inProgress,
    .inReview: .inReview,
    .done: .done,
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
    case .new:
      .new
    case .planning:
      .planning
    case .planReview:
      .planReview
    case .needsYou:
      .needsYou
    case .todo:
      .todo
    case .inProgress:
      .inProgress
    case .inReview:
      .inReview
    case .done:
      .done
    case .blocked:
      .blocked
    }
  }
}

enum TaskBoardExternalProviderChoice: String, CaseIterable, Identifiable, Hashable {
  case all
  case gitHub
  case todoist

  static let publicCases: [Self] = [.all, .gitHub]

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
