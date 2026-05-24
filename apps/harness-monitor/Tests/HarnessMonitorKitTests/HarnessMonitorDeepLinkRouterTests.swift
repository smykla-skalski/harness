import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("HarnessMonitorDeepLinkRouter")
struct HarnessMonitorDeepLinkRouterTests {
  @Test("Parses a fully qualified pull-request deep link")
  func parsesPullRequest() {
    let url = URL(string: "harness://reviews/octocat/repo/1234")!
    let route = HarnessMonitorDeepLinkRouter.parse(url: url)
    #expect(route == .pullRequest(id: "octocat/repo#1234"))
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
    let original = HarnessMonitorDeepLinkRoute.pullRequest(id: "octocat/repo#1234")
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
    let url = HarnessMonitorDeepLinkRouter.url(for: .pullRequest(id: "not-a-pr-id"))
    #expect(url == nil)
  }
}
