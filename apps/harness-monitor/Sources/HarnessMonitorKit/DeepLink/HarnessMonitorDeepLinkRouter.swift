import Foundation

/// Typed deep-link routes for the `harness://` URL scheme.
///
/// Used by the main app's `.onOpenURL` handler and by the App Intents
/// extension when an intent needs to surface a specific surface in a running
/// Monitor instance. The router lives in HarnessMonitorKit (not the app
/// target) so the parser is testable without spinning up SwiftUI and so the
/// upcoming intents/widget extensions can reuse it for URL construction.
/// A file (and optional line range) targeted inside a pull-request diff by a
/// `harness://` deep link, e.g. `.../files/Sources/App/Main.swift?lines=10-20`.
public struct ReviewDeepLinkFileTarget: Sendable, Equatable {
  public let path: String
  public let lines: ReviewLineSelection?

  public init(path: String, lines: ReviewLineSelection? = nil) {
    self.path = path
    self.lines = lines
  }
}

public enum HarnessMonitorDeepLinkRoute: Sendable, Equatable {
  /// Surface a single pull request, optionally scrolled to a specific file and
  /// line range. ID format matches `ReviewItem.pullRequestID` ("owner/repo#1234");
  /// the URL path encodes it as `owner/repo/number` to avoid escaping `/` and
  /// `#`. When `file` is set the URL carries a `/files/<path>?lines=&side=` tail.
  case pullRequest(id: String, file: ReviewDeepLinkFileTarget?)

  /// Reviews route. When `needsMeOn` is true the route should activate with
  /// the needs-me filter on; widgets tap this to land the user on what they
  /// need to act on.
  case reviews(needsMeOn: Bool)

  /// Task Board route. Optionally targets a specific item via its ID.
  case taskBoard(itemID: String?)
}

private struct HarnessMonitorPullRequestDeepLink: Sendable, Equatable {
  let owner: String
  let repo: String
  let number: String
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
      if pathSegments.count >= 3 {
        let owner = pathSegments[0]
        let repo = pathSegments[1]
        let number = pathSegments[2]
        guard !owner.isEmpty, !repo.isEmpty, !number.isEmpty else { return nil }
        let file = parseFileTarget(pathSegments: pathSegments, queryItems: queryItems)
        return .pullRequest(id: "\(owner)/\(repo)#\(number)", file: file)
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
    case .pullRequest(let id, let file):
      guard let parsed = parsePullRequestID(id) else { return nil }
      components.host = "reviews"
      var segments = [parsed.owner, parsed.repo, parsed.number]
      if let file {
        segments.append("files")
        segments.append(contentsOf: file.path.split(separator: "/").map(String.init))
        if let lines = file.lines {
          var items = [URLQueryItem(name: "lines", value: lines.urlLinesValue)]
          if lines.side == .left {
            items.append(URLQueryItem(name: "side", value: ReviewDiffSide.left.rawValue))
          }
          components.queryItems = items
        }
      }
      components.percentEncodedPath =
        "/"
        + segments
        .map { $0.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? $0 }
        .joined(separator: "/")
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

  /// Pull a `/files/<path...>?lines=&side=` tail out of a reviews path. The
  /// file path keeps its own `/` separators by rejoining the segments after
  /// the `files` marker. Returns `nil` when there is no file segment.
  private static func parseFileTarget(
    pathSegments: [String],
    queryItems: [URLQueryItem]
  ) -> ReviewDeepLinkFileTarget? {
    guard pathSegments.count >= 5, pathSegments[3] == "files" else { return nil }
    let path = pathSegments[4...].joined(separator: "/")
    guard !path.isEmpty else { return nil }
    let lines = ReviewLineSelection.parse(
      linesQuery: queryItems.first { $0.name == "lines" }?.value,
      sideQuery: queryItems.first { $0.name == "side" }?.value
    )
    return ReviewDeepLinkFileTarget(path: path, lines: lines)
  }

  /// Allowed characters for one URL path segment: the standard path set minus
  /// the separator, so spaces and reserved characters inside file names encode.
  private static let pathSegmentAllowed: CharacterSet = {
    var set = CharacterSet.urlPathAllowed
    set.remove("/")
    return set
  }()

  private static func parsePullRequestID(
    _ id: String
  ) -> HarnessMonitorPullRequestDeepLink? {
    let hashSplit = id.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    guard hashSplit.count == 2 else { return nil }
    let repoFull = String(hashSplit[0])
    let number = String(hashSplit[1])
    let slashSplit = repoFull.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard slashSplit.count == 2 else { return nil }
    let owner = String(slashSplit[0])
    let repo = String(slashSplit[1])
    guard !owner.isEmpty, !repo.isEmpty, !number.isEmpty else { return nil }
    return HarnessMonitorPullRequestDeepLink(owner: owner, repo: repo, number: number)
  }
}
