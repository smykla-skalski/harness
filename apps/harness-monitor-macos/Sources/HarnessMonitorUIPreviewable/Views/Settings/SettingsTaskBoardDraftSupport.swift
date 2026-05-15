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
    case .blocked:
      self = .blocked
    case .inReview:
      self = .inReview
    case .done:
      self = .done
    case .unknown:
      self = .all
    }
  }

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
