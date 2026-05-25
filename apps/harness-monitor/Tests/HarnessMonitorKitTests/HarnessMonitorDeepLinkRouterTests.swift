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

  @Test("Builds and round-trips a pull-request deep-link id")
  func buildsPullRequestDeepLinkID() throws {
    let id = try #require(
      HarnessMonitorDeepLinkRouter.pullRequestDeepLinkID(
        repositoryFullName: "octocat/repo", number: 1234
      )
    )
    #expect(id == "octocat/repo#1234")
    let url = try #require(HarnessMonitorDeepLinkRouter.url(for: .pullRequest(id: id, file: nil)))
    #expect(url.absoluteString == "harness://reviews/octocat/repo/1234")
    #expect(HarnessMonitorDeepLinkRouter.parse(url: url) == .pullRequest(id: id, file: nil))
  }

  @Test("Rejects deep-link ids that cannot form owner/repo#number")
  func rejectsInvalidDeepLinkID() {
    #expect(
      HarnessMonitorDeepLinkRouter.pullRequestDeepLinkID(
        repositoryFullName: "PR_kwDOABCD123", number: 1
      ) == nil
    )
    #expect(
      HarnessMonitorDeepLinkRouter.pullRequestDeepLinkID(
        repositoryFullName: "octocat/repo", number: 0
      ) == nil
    )
  }

  @Test("A node-id review item derives its slug and matches both selectors")
  func reviewItemDeepLinkSelectors() {
    let item = makeReviewItem(
      pullRequestID: "PR_kwDOABCD123", repository: "octocat/repo", number: 1234
    )
    #expect(item.pullRequestDeepLinkID == "octocat/repo#1234")
    #expect(item.matchesDeepLinkSelector("PR_kwDOABCD123"))
    #expect(item.matchesDeepLinkSelector("octocat/repo#1234"))
    #expect(!item.matchesDeepLinkSelector("octocat/repo#9999"))
    #expect(!item.matchesDeepLinkSelector("unrelated"))
  }

  private func makeReviewItem(
    pullRequestID: String,
    repository: String,
    number: UInt64
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: pullRequestID,
      repositoryID: "repo-1",
      repository: repository,
      number: number,
      title: "Title",
      url: "https://github.com/\(repository)/pull/\(number)",
      authorLogin: "octocat",
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc123",
      additions: 1,
      deletions: 0,
      createdAt: "2026-05-20T10:00:00Z",
      updatedAt: "2026-05-20T11:00:00Z",
      viewerCanUpdate: true
    )
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
