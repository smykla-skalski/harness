import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dependency update parity helpers")
struct DependencyUpdatesParityHelperTests {
  @Test("Rerun targets include only failed or timed-out check suites")
  func rerunTargetsFilterToRerunnableSuites() {
    let item = makeItem(
      checkStatus: .failure,
      checks: [
        DependencyUpdateCheck(
          name: "failed",
          status: .completed,
          conclusion: .failure,
          checkSuiteID: "suite-failed"
        ),
        DependencyUpdateCheck(
          name: "timed out",
          status: .completed,
          conclusion: .timedOut,
          checkSuiteID: "suite-timeout"
        ),
        DependencyUpdateCheck(
          name: "pending",
          status: .inProgress,
          conclusion: .none,
          checkSuiteID: "suite-pending"
        ),
        DependencyUpdateCheck(
          name: "passing",
          status: .completed,
          conclusion: .success,
          checkSuiteID: "suite-success"
        ),
        DependencyUpdateCheck(
          name: "status-context",
          status: .completed,
          conclusion: .failure,
          checkSuiteID: nil
        ),
      ]
    )

    #expect(item.hasRerunnableChecks)
    #expect(item.rerunnableCheckSuiteIDs == ["suite-failed", "suite-timeout"])
    #expect(item.rerunTarget.checkSuiteIDs == ["suite-failed", "suite-timeout"])
  }

  @Test("Manual approval remains available before auto mode eligibility")
  func manualApprovalDoesNotRequirePassingChecks() {
    let item = makeItem(reviewStatus: .reviewRequired, checkStatus: .pending)

    #expect(item.canAttemptManualApproval)
    #expect(!item.isAutoApprovable)
  }

  @Test("Manual approval is available when GitHub reports no review decision")
  func manualApprovalAllowedWhenReviewStatusIsNone() {
    #expect(makeItem(reviewStatus: .none).canAttemptManualApproval)
    #expect(makeItem(reviewStatus: .reviewRequired).canAttemptManualApproval)
    #expect(!makeItem(reviewStatus: .approved).canAttemptManualApproval)
    #expect(!makeItem(reviewStatus: .changesRequested).canAttemptManualApproval)
    #expect(!makeItem(state: .closed, reviewStatus: .none).canAttemptManualApproval)
  }

  @Test("Fix CI is available only for failing checks")
  func fixCIRequiresFailingChecks() {
    #expect(makeItem(checkStatus: .failure).canStartFixCI)
    #expect(!makeItem(checkStatus: .pending).canStartFixCI)
    #expect(!makeItem(checkStatus: .success).canStartFixCI)
  }

  @Test("Repository ordering prefers configured repos then configured orgs")
  func repositoryOrderingHonorsConfiguredPriority() {
    let ordering = DashboardDependenciesRepositoryOrdering(
      configuredRepositories: ["beta/explicit", "alpha/explicit"],
      configuredOrganizations: ["org-b", "org-a"]
    )

    let sorted = ordering.sorted(
      [
        "misc/zeta",
        "org-a/dep-two",
        "org-b/dep-one",
        "alpha/explicit",
        "org-a/dep-one",
        "beta/explicit",
      ]
    )

    #expect(
      sorted
        == [
          "beta/explicit",
          "alpha/explicit",
          "org-b/dep-one",
          "org-a/dep-one",
          "org-a/dep-two",
          "misc/zeta",
        ]
    )
  }

  @Test("Item decoder defaults labels, checks, and reviews when keys are missing")
  func itemDecoderDefaultsArrayFieldsWhenKeysAreMissing() throws {
    let payload = """
      {
        "pullRequestId": "pr-1",
        "repositoryId": "repo-1",
        "repository": "org-a/example",
        "number": 42,
        "title": "Bump dependency",
        "url": "https://github.com/org-a/example/pull/42",
        "authorLogin": "renovate[bot]",
        "state": "open",
        "mergeable": "mergeable",
        "reviewStatus": "review_required",
        "checkStatus": "success",
        "policyBlocked": false,
        "isDraft": false,
        "headSha": "abc123",
        "additions": 10,
        "deletions": 4,
        "createdAt": "2026-05-20T10:00:00Z",
        "updatedAt": "2026-05-20T11:00:00Z"
      }
      """

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let item = try decoder.decode(DependencyUpdateItem.self, from: Data(payload.utf8))

    #expect(item.labels == [])
    #expect(item.checks == [])
    #expect(item.reviews == [])
    #expect(item.pullRequestID == "pr-1")
  }

  private func makeItem(
    state: DependencyUpdatePullRequestState = .open,
    mergeable: DependencyUpdateMergeableState = .mergeable,
    reviewStatus: DependencyUpdateReviewStatus = .reviewRequired,
    checkStatus: DependencyUpdateCheckStatus = .success,
    isDraft: Bool = false,
    checks: [DependencyUpdateCheck] = []
  ) -> DependencyUpdateItem {
    DependencyUpdateItem(
      pullRequestID: "pr-1",
      repositoryID: "repo-1",
      repository: "org-a/example",
      number: 42,
      title: "Bump dependency",
      url: "https://github.com/org-a/example/pull/42",
      authorLogin: "renovate[bot]",
      state: state,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: false,
      isDraft: isDraft,
      headSha: "abc123",
      labels: [],
      checks: checks,
      reviews: [],
      additions: 10,
      deletions: 4,
      createdAt: "2026-05-20T10:00:00Z",
      updatedAt: "2026-05-20T11:00:00Z"
    )
  }
}
