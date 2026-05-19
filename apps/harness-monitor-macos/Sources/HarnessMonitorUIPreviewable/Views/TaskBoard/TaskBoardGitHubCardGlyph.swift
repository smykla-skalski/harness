import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardCardGlyph {
  let systemImage: String
  let tint: Color
}

enum TaskBoardGitHubCardGlyph {
  static func resolve(for item: TaskBoardItem) -> TaskBoardCardGlyph? {
    guard item.hasGitHubSurface else {
      return nil
    }
    if item.hasManagedPullRequest {
      return TaskBoardCardGlyph(
        systemImage: "arrow.triangle.pull",
        tint: HarnessMonitorTheme.warmAccent
      )
    }
    if item.githubExternalRefs.contains(where: { $0.isPullRequestURL }) {
      return TaskBoardCardGlyph(
        systemImage: "text.badge.checkmark",
        tint: HarnessMonitorTheme.caution
      )
    }
    if item.githubExternalRefs.contains(where: { $0.isIssueURL }) {
      return TaskBoardCardGlyph(
        systemImage: "smallcircle.filled.circle",
        tint: HarnessMonitorTheme.accent
      )
    }
    return TaskBoardCardGlyph(
      systemImage: "number.circle",
      tint: HarnessMonitorTheme.secondaryInk
    )
  }
}

extension TaskBoardItem {
  fileprivate var hasGitHubSurface: Bool {
    hasManagedPullRequest || !githubExternalRefs.isEmpty
  }

  fileprivate var hasManagedPullRequest: Bool {
    if workflow?.prNumber != nil {
      return true
    }
    guard let prURL = workflow?.prUrl else {
      return false
    }
    return !prURL.isEmpty
  }

  fileprivate var githubExternalRefs: [TaskBoardExternalRef] {
    externalRefs.filter { $0.provider == .gitHub }
  }
}

extension TaskBoardExternalRef {
  fileprivate var isPullRequestURL: Bool {
    normalizedURLPath.contains("/pull/")
  }

  fileprivate var isIssueURL: Bool {
    normalizedURLPath.contains("/issues/")
  }

  private var normalizedURLPath: String {
    guard
      let url,
      let path = URL(string: url)?.path.lowercased()
    else {
      return ""
    }
    return path
  }
}
