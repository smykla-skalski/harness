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

  @Test("beginning a mutation prunes expired unmatched mutations")
  func beginningMutationPrunesExpiredUnmatchedMutations() throws {
    var coordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
    let expiredMutation = coordinator.begin(
      baselineRevision: 10,
      operations: ["reviews.approve"],
      expectedRevisionCount: 1,
      now: startedAt
    )
    let expiredToken = try #require(expiredMutation)

    _ = coordinator.begin(
      baselineRevision: 20,
      operations: ["reviews.comment"],
      expectedRevisionCount: 1,
      now: startedAt.addingTimeInterval(181)
    )

    #expect(
      coordinator.confirm(
        expiredToken,
        endingRevision: 11,
        appliedRevisionCount: 1,
        now: startedAt
      ) == .discarded
    )
  }

  @Test("confirmation discards an expired mutation")
  func confirmationDiscardsExpiredMutation() throws {
    var coordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let startedAt = Date(timeIntervalSinceReferenceDate: 2_000)
    let started = coordinator.begin(
      baselineRevision: 30,
      operations: ["reviews.approve"],
      expectedRevisionCount: 1,
      now: startedAt
    )
    let token = try #require(started)

    #expect(
      coordinator.confirm(
        token,
        endingRevision: 31,
        appliedRevisionCount: 1,
        now: startedAt.addingTimeInterval(181)
      ) == .discarded
    )
  }

  @Test("targeted refresh completions ignore expired mutations")
  func targetedRefreshCompletionsIgnoreExpiredMutations() throws {
    var succeededCoordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    var failedCoordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let startedAt = Date(timeIntervalSinceReferenceDate: 3_000)
    let succeeded = succeededCoordinator.begin(
      baselineRevision: 40,
      operations: ["reviews.approve"],
      expectedRevisionCount: 1,
      now: startedAt
    )
    let succeededToken = try #require(succeeded)
    let failed = failedCoordinator.begin(
      baselineRevision: 50,
      operations: ["reviews.comment"],
      expectedRevisionCount: 1,
      now: startedAt
    )
    let failedToken = try #require(failed)
    let expiredAt = startedAt.addingTimeInterval(181)

    #expect(
      succeededCoordinator.targetedRefreshSucceeded(for: succeededToken, now: expiredAt) == .none
    )
    #expect(
      succeededCoordinator.confirm(
        succeededToken,
        endingRevision: 41,
        appliedRevisionCount: 1,
        now: startedAt
      ) == .discarded
    )
    #expect(failedCoordinator.targetedRefreshFailed(for: failedToken, now: expiredAt) == .none)
  }

  @Test("expired matched confirmation requests a full refresh")
  func expiredMatchedConfirmationRefreshesAll() throws {
    var coordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let startedAt = Date(timeIntervalSinceReferenceDate: 4_000)
    let started = coordinator.begin(
      baselineRevision: 60,
      operations: ["reviews.approve"],
      expectedRevisionCount: 1,
      now: startedAt
    )
    let token = try #require(started)
    #expect(
      coordinator.changeDecision(
        for: change(revision: 61, operation: "reviews.approve"),
        now: startedAt.addingTimeInterval(1)
      ) == .waitForTargetedRefresh
    )

    #expect(
      coordinator.confirm(
        token,
        endingRevision: 61,
        appliedRevisionCount: 1,
        now: startedAt.addingTimeInterval(181)
      ) == .refreshAll
    )
  }

  @Test("expired matched targeted refresh success requests a full refresh")
  func expiredMatchedTargetedRefreshSuccessRefreshesAll() throws {
    var coordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let startedAt = Date(timeIntervalSinceReferenceDate: 5_000)
    let started = coordinator.begin(
      baselineRevision: 70,
      operations: ["reviews.approve"],
      expectedRevisionCount: 1,
      now: startedAt
    )
    let token = try #require(started)
    #expect(
      coordinator.changeDecision(
        for: change(revision: 71, operation: "reviews.approve"),
        now: startedAt.addingTimeInterval(1)
      ) == .waitForTargetedRefresh
    )
    #expect(
      coordinator.confirm(
        token,
        endingRevision: 71,
        appliedRevisionCount: 1,
        now: startedAt.addingTimeInterval(2)
      ) == .confirmed
    )

    #expect(
      coordinator.targetedRefreshSucceeded(
        for: token,
        now: startedAt.addingTimeInterval(181)
      ) == .refreshAll
    )
  }

  @Test("expired matched targeted refresh failure requests a full refresh")
  func expiredMatchedTargetedRefreshFailureRefreshesAll() throws {
    var coordinator = DashboardReviewsGitHubMutationRefreshCoordinator()
    let startedAt = Date(timeIntervalSinceReferenceDate: 6_000)
    let started = coordinator.begin(
      baselineRevision: 80,
      operations: ["reviews.comment"],
      expectedRevisionCount: 1,
      now: startedAt
    )
    let token = try #require(started)
    #expect(
      coordinator.changeDecision(
        for: change(revision: 81, operation: "reviews.comment"),
        now: startedAt.addingTimeInterval(1)
      ) == .waitForTargetedRefresh
    )

    #expect(
      coordinator.targetedRefreshFailed(
        for: token,
        now: startedAt.addingTimeInterval(181)
      ) == .refreshAll
    )
  }

  private func change(revision: UInt64, operation: String) -> GitHubDataChangedPayload {
    GitHubDataChangedPayload(revision: revision, operation: operation)
  }
}
