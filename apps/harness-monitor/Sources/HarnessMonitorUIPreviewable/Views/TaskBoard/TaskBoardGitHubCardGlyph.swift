import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardCardGlyph {
  let systemImage: String?
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
  var taskBoardBackgroundProviderSymbol: ProviderBrandSymbol? {
    taskBoardRepositoryOwner.flatMap(ProviderBrandSymbol.init(taskBoardOwner:))
  }

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

  private var taskBoardRepositoryOwner: String? {
    if let owner = TaskBoardGitHubRepositoryIdentity.owner(fromPathLike: projectId) {
      return owner
    }
    if let owner = TaskBoardGitHubRepositoryIdentity.owner(fromURLString: workflow?.prUrl) {
      return owner
    }
    return githubExternalRefs.lazy.compactMap(\.repositoryOwner).first
  }
}

extension TaskBoardExternalRef {
  fileprivate var repositoryOwner: String? {
    if let owner = TaskBoardGitHubRepositoryIdentity.owner(fromURLString: url) {
      return owner
    }
    return TaskBoardGitHubRepositoryIdentity.owner(fromPathLike: externalId)
  }

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

private enum TaskBoardGitHubRepositoryIdentity {
  static func owner(fromURLString urlString: String?) -> String? {
    guard
      let urlString,
      let url = URL(string: urlString),
      let host = url.host?.lowercased(),
      host == "github.com" || host == "www.github.com"
    else {
      return nil
    }
    let components = url.path.split(separator: "/")
    guard components.count >= 2 else {
      return nil
    }
    return String(components[0])
  }

  static func owner(fromPathLike rawValue: String?) -> String? {
    guard let rawValue else {
      return nil
    }
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
      return nil
    }
    if let owner = owner(fromURLString: trimmed) {
      return owner
    }
    let components = trimmed.split(separator: "/")
    guard components.count >= 2 else {
      return nil
    }
    return String(components[0])
  }
}

extension ProviderBrandSymbol {
  fileprivate init?(taskBoardOwner owner: String) {
    let normalized = owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "kumahq":
      self = .kuma
    default:
      guard normalized.contains("kong") else {
        return nil
      }
      self = .kong
    }
  }
}
