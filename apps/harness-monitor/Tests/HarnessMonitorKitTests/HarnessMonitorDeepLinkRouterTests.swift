import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("HarnessMonitorDeepLinkRouter")
struct HarnessMonitorDeepLinkRouterTests {
  @Test("Parses a fully qualified pull-request deep link")
  func parsesPullRequest() {
    let url = URL(string: "harness://reviews/octocat/repo/1234")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(route == .pullRequest(id: "octocat/repo#1234", file: nil))
  }

  @Test("Parses a bare reviews deep link without needsMe")
  func parsesReviewsBare() {
    let url = URL(string: "harness://reviews")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(route == .reviews(needsMeOn: false))
  }

  @Test("Parses reviews?needsMe=1 as needs-me on")
  func parsesReviewsNeedsMe() {
    let url = URL(string: "harness://reviews?needsMe=1")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(route == .reviews(needsMeOn: true))
  }

  @Test("Parses a bare task-board deep link")
  func parsesTaskBoardBare() {
    let url = URL(string: "harness://taskboard")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(route == .taskBoard(itemID: nil))
  }

  @Test("Parses a task-board deep link with an item ID")
  func parsesTaskBoardWithItem() {
    let url = URL(string: "harness://taskboard/task-abc-123")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(route == .taskBoard(itemID: "task-abc-123"))
  }

  @Test("Rejects URLs with a different scheme")
  func rejectsForeignScheme() {
    let url = URL(string: "https://reviews/octocat/repo/1234")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(route == nil)
  }

  @Test("Rejects URLs with an unknown host")
  func rejectsUnknownHost() {
    let url = URL(string: "harness://settings/general")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(route == nil)
  }

  @Test("Rejects incomplete reviews paths")
  func rejectsIncompletePullRequest() {
    // Only owner/repo, no number - not a complete PR ID
    let url = URL(string: "harness://reviews/octocat/repo")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    // Falls back to bare reviews; not a half-resolved PR ID
    #expect(route == .reviews(needsMeOn: false))
  }

  @Test("Round-trips a pull-request route to URL and back")
  func roundTripsPullRequest() {
    let original = HarnessMonitorDeepLinkRoute.pullRequest(id: "octocat/repo#1234", file: nil)
    let url = HarnessMonitorDeepLinkRouter.url(for: original)
    #expect(url?.absoluteString == "harness://reviews/octocat/repo/1234")
    let parsed = url.flatMap(HarnessMonitorDeepLinkRouter.parse(url:))
    #expect(parsed == original)
  }

  @Test("Round-trips reviews-with-needs-me to URL and back")
  func roundTripsReviewsNeedsMe() {
    let original = HarnessMonitorDeepLinkRoute.reviews(needsMeOn: true)
    let url = HarnessMonitorDeepLinkRouter.url(for: original)
    #expect(url?.absoluteString == "harness://reviews?needsMe=1")
    let parsed = url.flatMap(HarnessMonitorDeepLinkRouter.parse(url:))
    #expect(parsed == original)
  }

  @Test("Round-trips a task-board item to URL and back")
  func roundTripsTaskBoardItem() {
    let original = HarnessMonitorDeepLinkRoute.taskBoard(itemID: "task-abc")
    let url = HarnessMonitorDeepLinkRouter.url(for: original)
    #expect(url?.absoluteString == "harness://taskboard/task-abc")
    let parsed = url.flatMap(HarnessMonitorDeepLinkRouter.parse(url:))
    #expect(parsed == original)
  }

  @Test("Rejects malformed pull-request IDs when building URLs")
  func rejectsMalformedPullRequestID() {
    let url = HarnessMonitorDeepLinkRouter.url(for: .pullRequest(id: "not-a-pr-id", file: nil))
    #expect(url == nil)
  }

  // MARK: - File + line deep links

  @Test("Parses a pull-request file deep link with a line range")
  func parsesPullRequestFileRange() {
    let url = URL(
      string:
        "harness://reviews/octocat/repo/1234/files/Sources/App/Main.swift?lines=10-20&side=right"
    )!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(
      route
        == .pullRequest(
          id: "octocat/repo#1234",
          file: ReviewDeepLinkFileTarget(
            path: "Sources/App/Main.swift",
            lines: ReviewLineSelection(start: 10, end: 20, side: .right)
          )
        )
    )
  }

  @Test("Parses a single-line file deep link defaulting to the right side")
  func parsesPullRequestFileSingleLine() {
    let url = URL(string: "harness://reviews/octocat/repo/1234/files/README.md?lines=42")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(
      route
        == .pullRequest(
          id: "octocat/repo#1234",
          file: ReviewDeepLinkFileTarget(
            path: "README.md",
            lines: ReviewLineSelection(line: 42, side: .right)
          )
        )
    )
  }

  @Test("Parses a left-side line target with a deep file path")
  func parsesPullRequestFileLeftSide() {
    let url = URL(
      string: "harness://reviews/octocat/repo/1234/files/a/b/c.swift?lines=5&side=left"
    )!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(
      route
        == .pullRequest(
          id: "octocat/repo#1234",
          file: ReviewDeepLinkFileTarget(
            path: "a/b/c.swift",
            lines: ReviewLineSelection(line: 5, side: .left)
          )
        )
    )
  }

  @Test("Parses a file deep link with no line query")
  func parsesPullRequestFileNoLines() {
    let url = URL(string: "harness://reviews/octocat/repo/1234/files/Sources/App/Main.swift")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(
      route
        == .pullRequest(
          id: "octocat/repo#1234",
          file: ReviewDeepLinkFileTarget(path: "Sources/App/Main.swift", lines: nil)
        )
    )
  }

  @Test("Treats a files marker with no path as a plain pull request")
  func parsesFilesMarkerWithoutPath() {
    let url = URL(string: "harness://reviews/octocat/repo/1234/files")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(route == .pullRequest(id: "octocat/repo#1234", file: nil))
  }

  @Test("Round-trips a file+range route to URL and back")
  func roundTripsPullRequestFileRange() {
    let original = HarnessMonitorDeepLinkRoute.pullRequest(
      id: "octocat/repo#1234",
      file: ReviewDeepLinkFileTarget(
        path: "Sources/App/Main.swift",
        lines: ReviewLineSelection(start: 10, end: 20, side: .right)
      )
    )
    let url = HarnessMonitorDeepLinkRouter.url(for: original)
    #expect(
      url?.absoluteString
        == "harness://reviews/octocat/repo/1234/files/Sources/App/Main.swift?lines=10-20"
    )
    #expect(url.flatMap(HarnessMonitorDeepLinkRouter.parse(url:)) == original)
  }

  @Test("Round-trips a left-side single-line route to URL and back")
  func roundTripsPullRequestFileLeftSide() {
    let original = HarnessMonitorDeepLinkRoute.pullRequest(
      id: "octocat/repo#1234",
      file: ReviewDeepLinkFileTarget(
        path: "a/b/c.swift",
        lines: ReviewLineSelection(line: 5, side: .left)
      )
    )
    let url = HarnessMonitorDeepLinkRouter.url(for: original)
    #expect(
      url?.absoluteString
        == "harness://reviews/octocat/repo/1234/files/a/b/c.swift?lines=5&side=left"
    )
    #expect(url.flatMap(HarnessMonitorDeepLinkRouter.parse(url:)) == original)
  }

  @Test("Round-trips a file-only route with no line range")
  func roundTripsPullRequestFileOnly() {
    let original = HarnessMonitorDeepLinkRoute.pullRequest(
      id: "octocat/repo#1234",
      file: ReviewDeepLinkFileTarget(path: "Sources/App/Main.swift", lines: nil)
    )
    let url = HarnessMonitorDeepLinkRouter.url(for: original)
    #expect(
      url?.absoluteString == "harness://reviews/octocat/repo/1234/files/Sources/App/Main.swift"
    )
    #expect(url.flatMap(HarnessMonitorDeepLinkRouter.parse(url:)) == original)
  }

  @Test("Percent-encodes spaces in file paths and round-trips")
  func roundTripsPullRequestFilePathWithSpace() {
    let original = HarnessMonitorDeepLinkRoute.pullRequest(
      id: "octocat/repo#1234",
      file: ReviewDeepLinkFileTarget(
        path: "Sources/My File.swift",
        lines: ReviewLineSelection(line: 3)
      )
    )
    let url = HarnessMonitorDeepLinkRouter.url(for: original)
    #expect(url?.absoluteString.contains("Sources/My%20File.swift") == true)
    #expect(url.flatMap(HarnessMonitorDeepLinkRouter.parse(url:)) == original)
  }
}
