import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews pinning")
struct DashboardReviewsPinningTests {
  @Test("pinned pull-request storage round-trips and preserves order")
  func pinnedPullRequestStorageRoundTrips() {
    var pins = DashboardReviewsPinnedPullRequests()

    let didPinFirst = pins.pin("pr-1")
    let didPinSecond = pins.pin("pr-2")
    let didPinDuplicate = pins.pin("pr-1")

    #expect(didPinFirst)
    #expect(didPinSecond)
    #expect(didPinDuplicate == false)
    #expect(pins.pullRequestIDs == ["pr-1", "pr-2"])

    let didUnpinFirst = pins.unpin("pr-1")

    #expect(didUnpinFirst)
    #expect(pins.pullRequestIDs == ["pr-2"])

    let decoded = DashboardReviewsPinnedPullRequests.decode(from: pins.encodedString)
    #expect(decoded == pins)
  }

  @Test("pin selection intent only unpins when every selected PR is already pinned")
  func pinSelectionIntentChoosesPinOrUnpin() {
    let first = item(id: "pr-1")
    let second = item(id: "pr-2")

    #expect(
      dashboardReviewsPinSelectionIntent(
        items: [first],
        pinnedPullRequestIDs: []
      ) == .pin
    )
    #expect(
      dashboardReviewsPinSelectionIntent(
        items: [first, second],
        pinnedPullRequestIDs: ["pr-1"]
      ) == .pin
    )
    #expect(
      dashboardReviewsPinSelectionIntent(
        items: [first, second],
        pinnedPullRequestIDs: ["pr-1", "pr-2"]
      ) == .unpin
    )
  }

  @Test("pinning copy uses singular and plural titles")
  func pinningCopyUsesSingularAndPluralTitles() {
    #expect(
      dashboardReviewsPinSelectionMenuTitle(itemCount: 1, intent: .pin) == "Pin Pull Request"
    )
    #expect(
      dashboardReviewsPinSelectionMenuTitle(itemCount: 1, intent: .unpin)
        == "Unpin Pull Request"
    )
    #expect(
      dashboardReviewsPinSelectionMenuTitle(itemCount: 2, intent: .pin) == "Pin Selection"
    )
    #expect(
      dashboardReviewsPinSelectionSuccessMessage(itemCount: 1, intent: .pin)
        == "Pinned 1 pull request"
    )
    #expect(
      dashboardReviewsPinSelectionSuccessMessage(itemCount: 2, intent: .unpin)
        == "Unpinned 2 pull requests"
    )
  }

  @Test("togglePersisted flips and persists pins durably in UserDefaults")
  func togglePersistedRoundTrips() {
    let defaults = UserDefaults(suiteName: "DashboardReviewsPinningTests-\(UUID().uuidString)")!

    #expect(
      DashboardReviewsPinnedPullRequests.isPersistedPinned(pullRequestID: "pr-1", in: defaults)
        == false
    )

    let nowPinned = DashboardReviewsPinnedPullRequests.togglePersisted(
      pullRequestID: "pr-1",
      in: defaults
    )
    #expect(nowPinned)
    #expect(
      DashboardReviewsPinnedPullRequests.isPersistedPinned(pullRequestID: "pr-1", in: defaults)
    )

    let stored = DashboardReviewsPinnedPullRequests.decode(
      from: defaults.string(forKey: DashboardReviewsPinnedPullRequests.storageKey) ?? ""
    )
    #expect(stored.pullRequestIDs == ["pr-1"])

    let nowUnpinned = DashboardReviewsPinnedPullRequests.togglePersisted(
      pullRequestID: "pr-1",
      in: defaults
    )
    #expect(nowUnpinned == false)
    #expect(
      DashboardReviewsPinnedPullRequests.isPersistedPinned(pullRequestID: "pr-1", in: defaults)
        == false
    )
  }

  @Test("reviewPullRequestID returns the id only for review targets")
  func reviewPullRequestIDExtractsOnlyReviewTargets() {
    #expect(reviewPullRequestID(for: .review(pullRequestID: "pr-9")) == "pr-9")
    #expect(reviewPullRequestID(for: .session(sessionID: "alpha")) == nil)
    #expect(reviewPullRequestID(for: .settingsSection(rawValue: "general")) == nil)
  }

  @Test("toggleReviewPin flips the durable pin and reports feedback")
  func toggleReviewPinPersistsAndReportsFeedback() {
    let defaults = UserDefaults(suiteName: "ToggleReviewPin-\(UUID().uuidString)")!
    var messages: [String] = []

    toggleReviewPin(pullRequestID: "pr-9", in: defaults) { messages.append($0) }
    #expect(
      DashboardReviewsPinnedPullRequests.isPersistedPinned(pullRequestID: "pr-9", in: defaults)
    )
    #expect(messages == ["Pinned to Reviews"])

    toggleReviewPin(pullRequestID: "pr-9", in: defaults) { messages.append($0) }
    #expect(
      DashboardReviewsPinnedPullRequests.isPersistedPinned(pullRequestID: "pr-9", in: defaults)
        == false
    )
    #expect(messages == ["Pinned to Reviews", "Unpinned from Reviews"])
  }

  @Test("pinned repository storage round-trips, dedups, and preserves order")
  func pinnedRepositoryStorageRoundTrips() {
    var pins = DashboardReviewsPinnedRepositories()

    #expect(pins.pin("kong/a"))
    #expect(pins.pin("kong/b"))
    #expect(pins.pin("kong/a") == false)
    #expect(pins.contains("kong/a"))
    #expect(pins.repositoryIDs == ["kong/a", "kong/b"])

    #expect(pins.unpin("kong/a"))
    #expect(pins.unpin("kong/a") == false)
    #expect(pins.repositoryIDs == ["kong/b"])

    let decoded = DashboardReviewsPinnedRepositories.decode(from: pins.encodedString)
    #expect(decoded == pins)
    #expect(DashboardReviewsPinnedRepositories(storedValue: pins.encodedString) == pins)
  }

  private func item(id: String) -> ReviewItem {
    ReviewItem(
      pullRequestID: id,
      repositoryID: "repo-1",
      repository: "octocat/example",
      number: 1,
      title: "Bump dependency",
      url: "https://github.com/octocat/example/pull/1",
      authorLogin: "octocat",
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc123",
      additions: 1,
      deletions: 1,
      createdAt: "2026-05-22T10:00:00Z",
      updatedAt: "2026-05-22T11:00:00Z"
    )
  }
}
