import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardCardGlyph {
  let systemImage: String?
  let tint: Color
}

struct TaskBoardCardTitlePresentation: Equatable {
  static let reviewLeadingText = "Review: "

  let title: String
  let leadingText: String?

  init(item: TaskBoardItem) {
    guard item.requiresViewerGitHubReview else {
      self.title = item.title
      self.leadingText = nil
      return
    }
    self.title = Self.removingReviewPrefix(from: item.title)
    self.leadingText = Self.reviewLeadingText
  }

  private static func removingReviewPrefix(from title: String) -> String {
    let marker = "Review:"
    guard title.count >= marker.count else {
      return title
    }
    let markerEnd = title.index(title.startIndex, offsetBy: marker.count)
    guard String(title[..<markerEnd]).caseInsensitiveCompare(marker) == .orderedSame else {
      return title
    }
    return String(title[markerEnd...].drop(while: \.isWhitespace))
  }
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
  var requiresViewerGitHubReview: Bool {
    importedFromProvider == .gitHub
      && externalRefs.contains {
        $0.provider == .gitHub && $0.isActiveViewerReviewReference
      }
  }

  var taskBoardGitHubURL: URL? {
    for ref in externalRefs where ref.provider == .gitHub {
      if let url = TaskBoardGitHubURL.resolve(ref.url) {
        return url
      }
    }
    return TaskBoardGitHubURL.resolve(workflow?.prUrl)
  }

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

  var taskBoardRepositoryOwner: String? {
    if let owner = TaskBoardGitHubRepositoryIdentity.owner(fromPathLike: projectId) {
      return owner
    }
    if let owner = TaskBoardGitHubRepositoryIdentity.owner(fromURLString: workflow?.prUrl) {
      return owner
    }
    return githubExternalRefs.lazy.compactMap(\.repositoryOwner).first
  }
}

private enum TaskBoardGitHubURL {
  static func resolve(_ rawValue: String?) -> URL? {
    guard let rawValue else {
      return nil
    }
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let url = URL(string: trimmed),
      url.scheme?.lowercased() == "https",
      isGitHubHost(url.host)
    else {
      return nil
    }
    return url
  }

  static func isGitHubHost(_ rawHost: String?) -> Bool {
    guard let host = rawHost?.lowercased() else {
      return false
    }
    return host == "github.com" || host == "www.github.com"
  }
}

extension TaskBoardExternalRef {
  fileprivate var isActiveViewerReviewReference: Bool {
    guard let url = TaskBoardGitHubURL.resolve(url) else {
      return false
    }
    return url.path.lowercased().contains("/pull/") && syncState?.status != .done
  }

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
    guard let urlString else {
      return nil
    }
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let url = URL(string: trimmed),
      TaskBoardGitHubURL.isGitHubHost(url.host)
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
