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

  init(status: TaskBoardStatus?) {
    switch status {
    case .none:
      self = .all
    case .new:
      self = .new
    case .planning:
      self = .planning
    case .planReview:
      self = .planReview
    case .needsYou:
      self = .needsYou
    case .todo:
      self = .todo
    case .inProgress:
      self = .inProgress
    case .inReview:
      self = .inReview
    case .done:
      self = .done
    case .blocked:
      self = .blocked
    }
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
      return
        "This creates live session work for the selected board item and cannot be undone from the task board."
    }
    return
      "This creates live session work for every board item matching the current filter and cannot be undone from the task board."
  }
}
