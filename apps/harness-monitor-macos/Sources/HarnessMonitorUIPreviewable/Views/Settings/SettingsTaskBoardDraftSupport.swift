import HarnessMonitorKit

enum DispatchStatusFilterChoice: String, CaseIterable, Hashable {
  case all
  case new
  case planning
  case planReview
  case needsYou
  case todo
  case inProgress
  case blocked
  case inReview
  case done

  private static let statusChoices: [TaskBoardStatus: Self] = [
    .new: .new,
    .planning: .planning,
    .planReview: .planReview,
    .needsYou: .needsYou,
    .todo: .todo,
    .inProgress: .inProgress,
    .blocked: .blocked,
    .inReview: .inReview,
    .done: .done,
  ]

  init(status: TaskBoardStatus?) {
    self = status.flatMap { Self.statusChoices[$0] } ?? .all
  }
}

extension DispatchStatusFilterChoice {
  var title: String {
    switch self {
    case .all: "All Items"
    case .new: "New"
    case .planning: "Planning"
    case .planReview: "Plan Review"
    case .needsYou: "Needs You"
    case .todo: "Todo"
    case .inProgress: "In Progress"
    case .blocked: "Blocked"
    case .inReview: "In Review"
    case .done: "Done"
    }
  }

  var status: TaskBoardStatus? {
    switch self {
    case .all: nil
    case .new: .new
    case .planning: .planning
    case .planReview: .planReview
    case .needsYou: .needsYou
    case .todo: .todo
    case .inProgress: .inProgress
    case .blocked: .blocked
    case .inReview: .inReview
    case .done: .done
    }
  }
}

extension TaskBoardOrchestratorWorkflow {
  var title: String {
    switch self {
    case .defaultTask: "Default Task"
    case .prFix: "PR Fix"
    case .prReview: "PR Review"
    case .dependencyUpdate: "Dependency Update"
    case .unknown(let raw): raw
    }
  }
}

extension TaskBoardGitHubMergeMethod {
  var title: String {
    switch self {
    case .squash: "Squash"
    case .merge: "Merge Commit"
    case .rebase: "Rebase"
    case .unknown(let raw): raw
    }
  }
}

extension TaskBoardGitHubAutomation {
  var title: String {
    switch self {
    case .syncTaskBoard: "Sync Task Board"
    case .createBranch: "Create Branch"
    case .openPullRequest: "Open Pull Request"
    case .watchChecks: "Watch Checks"
    case .requestReview: "Request Review"
    case .autoMerge: "Auto Merge"
    }
  }
}
