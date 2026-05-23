import Foundation

/// Typed deep-link routes for the `harness://` URL scheme.
///
/// Used by the main app's `.onOpenURL` handler and by the App Intents
/// extension when an intent needs to surface a specific surface in a running
/// Monitor instance. The router lives in HarnessMonitorKit (not the app
/// target) so the parser is testable without spinning up SwiftUI and so the
/// upcoming intents/widget extensions can reuse it for URL construction.
public enum HarnessMonitorDeepLinkRoute: Sendable, Equatable {
  /// Surface a single pull request. ID format matches `ReviewItem.pullRequestID`
  /// ("owner/repo#1234"); the URL path encodes it as `owner/repo/number` to
  /// avoid escaping `/` and `#` inside the path component.
  case pullRequest(id: String)

  /// Reviews route. When `needsMeOn` is true the route should activate with
  /// the needs-me filter on; widgets tap this to land the user on what they
  /// need to act on.
  case reviews(needsMeOn: Bool)

  /// Task Board route. Optionally targets a specific item via its ID.
  case taskBoard(itemID: String?)
}

/// Pure URL -> Route parser. No SwiftUI / AppKit dependency.
public enum HarnessMonitorDeepLinkRouter {
  public static let scheme = "harness"

  /// Parse a `harness://` URL into a typed route. Returns `nil` for any URL
  /// that doesn't match the scheme or whose host is unknown so callers can
  /// reject and fall through to whatever default open behavior they have.
  public static func parse(url: URL) -> HarnessMonitorDeepLinkRoute? {
    guard url.scheme == scheme else { return nil }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    let host = components.host ?? ""
    let pathSegments = components.path
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)
    let queryItems = components.queryItems ?? []

    switch host {
    case "reviews":
      if pathSegments.count == 3 {
        let owner = pathSegments[0]
        let repo = pathSegments[1]
        let number = pathSegments[2]
        guard !owner.isEmpty, !repo.isEmpty, !number.isEmpty else { return nil }
        return .pullRequest(id: "\(owner)/\(repo)#\(number)")
      }
      let needsMe = queryItems.contains { $0.name == "needsMe" && $0.value == "1" }
      return .reviews(needsMeOn: needsMe)
    case "taskboard":
      return .taskBoard(itemID: pathSegments.first)
    default:
      return nil
    }
  }

  /// Build a deep-link URL for a route. Used by the extension when surfacing
  /// `OpenPullRequestIntent` (and friends) so the URL shape matches the
  /// parser without callers needing to keep them in sync by hand.
  public static func url(for route: HarnessMonitorDeepLinkRoute) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    switch route {
    case .pullRequest(let id):
      guard let parsed = parsePullRequestID(id) else { return nil }
      components.host = "reviews"
      components.path = "/\(parsed.owner)/\(parsed.repo)/\(parsed.number)"
    case .reviews(let needsMeOn):
      components.host = "reviews"
      if needsMeOn {
        components.queryItems = [URLQueryItem(name: "needsMe", value: "1")]
      }
    case .taskBoard(let itemID):
      components.host = "taskboard"
      if let itemID, !itemID.isEmpty {
        components.path = "/\(itemID)"
      }
    }
    return components.url
  }

  private static func parsePullRequestID(
    _ id: String
  ) -> (owner: String, repo: String, number: String)? {
    let hashSplit = id.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    guard hashSplit.count == 2 else { return nil }
    let repoFull = String(hashSplit[0])
    let number = String(hashSplit[1])
    let slashSplit = repoFull.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard slashSplit.count == 2 else { return nil }
    let owner = String(slashSplit[0])
    let repo = String(slashSplit[1])
    guard !owner.isEmpty, !repo.isEmpty, !number.isEmpty else { return nil }
    return (owner, repo, number)
  }
}
