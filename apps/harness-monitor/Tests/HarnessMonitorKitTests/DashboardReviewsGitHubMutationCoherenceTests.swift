import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews GitHub mutation coherence")
struct DashboardReviewsGitHubMutationCoherenceTests {
  @Test("matching change waits for the targeted refresh before acknowledgement")
  func matchingChangeWaitsForTargetedRefresh() throws {
    var coordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let started = coordinator.begin(
      baselineRevision: 10,
      operations: ["reviews.approve"],
      expectedRevisionCount: 1
    )
    let token = try #require(started)

    #expect(
      coordinator.changeDecision(for: change(revision: 11, operation: "reviews.approve"))
        == .waitForTargetedRefresh
    )
    #expect(
      coordinator.confirm(token, endingRevision: 11, appliedRevisionCount: 1) == .confirmed
    )
    #expect(
      coordinator.targetedRefreshSucceeded(for: token) == .acknowledge(revision: 11)
    )
  }

  @Test("targeted refresh can finish before its matching push arrives")
  func targetedRefreshCanFinishBeforePush() throws {
    var coordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let started = coordinator.begin(
      baselineRevision: 30,
      operations: ["reviews.comment"],
      expectedRevisionCount: 1
    )
    let token = try #require(started)

    #expect(
      coordinator.confirm(token, endingRevision: 31, appliedRevisionCount: 1) == .confirmed
    )
    #expect(coordinator.targetedRefreshSucceeded(for: token) == .none)
    #expect(
      coordinator.changeDecision(for: change(revision: 31, operation: "reviews.comment"))
        == .acknowledge(revision: 31)
    )
  }

  @Test("unrelated GitHub operation always requests a full refresh")
  func unrelatedOperationRefreshesAll() throws {
    var coordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let started = coordinator.begin(
      baselineRevision: 4,
      operations: ["reviews.approve"],
      expectedRevisionCount: 1
    )
    _ = try #require(started)

    #expect(
      coordinator.changeDecision(
        for: change(revision: 5, operation: "task_board.github.issue_update")
      ) == .refreshAll
    )
  }

  @Test("same-operation concurrent write falls back to a full refresh")
  func concurrentSameOperationRefreshesAll() throws {
    var coordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let started = coordinator.begin(
      baselineRevision: 40,
      operations: ["reviews.approve"],
      expectedRevisionCount: 1
    )
    let token = try #require(started)

    #expect(
      coordinator.changeDecision(for: change(revision: 41, operation: "reviews.approve"))
        == .waitForTargetedRefresh
    )
    #expect(
      coordinator.confirm(token, endingRevision: 42, appliedRevisionCount: 1) == .refreshAll
    )
  }

  @Test("multi-item mutation waits for its final revision")
  func multiItemMutationWaitsForFinalRevision() throws {
    var coordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let started = coordinator.begin(
      baselineRevision: 70,
      operations: ["task_board.github.replace_labels"],
      expectedRevisionCount: 3
    )
    let token = try #require(started)

    #expect(
      coordinator.changeDecision(
        for: change(revision: 71, operation: "task_board.github.replace_labels")
      ) == .waitForTargetedRefresh
    )
    #expect(
      coordinator.changeDecision(
        for: change(revision: 72, operation: "task_board.github.replace_labels")
      ) == .waitForTargetedRefresh
    )
    #expect(
      coordinator.confirm(token, endingRevision: 73, appliedRevisionCount: 3) == .confirmed
    )
    #expect(coordinator.targetedRefreshSucceeded(for: token) == .none)
    #expect(
      coordinator.changeDecision(
        for: change(revision: 73, operation: "task_board.github.replace_labels")
      ) == .acknowledge(revision: 73)
    )
  }

  @Test("partial mutation result cannot suppress the global refresh")
  func partialMutationIsNotConfirmed() throws {
    var coordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let started = coordinator.begin(
      baselineRevision: 90,
      operations: ["reviews.rerequest_checks"],
      expectedRevisionCount: 2
    )
    let token = try #require(started)

    #expect(
      coordinator.confirm(token, endingRevision: 92, appliedRevisionCount: 1) == .discarded
    )
    #expect(
      coordinator.changeDecision(
        for: change(revision: 92, operation: "reviews.rerequest_checks")
      ) == .refreshAll
    )
  }

  private func change(revision: UInt64, operation: String) -> GitHubDataChangedPayload {
    GitHubDataChangedPayload(revision: revision, operation: operation)
  }
}
