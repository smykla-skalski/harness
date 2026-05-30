import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard dependencies disabled reason helpers")
struct DashboardReviewsDisabledReasonTests {
  @Test("Approve reason is nil when at least one item is approvable")
  func approveReasonIsNilWhenAnyItemIsApprovable() {
    let approvable = makeItem(state: .open, reviewStatus: .reviewRequired)
    let approved = makeItem(state: .open, reviewStatus: .approved)

    #expect(DashboardReviewsDisabledReason.approveReason(for: [approvable]) == nil)
    #expect(DashboardReviewsDisabledReason.approveReason(for: [approved, approvable]) == nil)
  }

  @Test("Approve reason reports already-approved selections")
  func approveReasonReportsAlreadyApproved() {
    let approved = makeItem(state: .open, reviewStatus: .approved)

    #expect(
      DashboardReviewsDisabledReason.approveReason(for: [approved])
        == "Already approved"
    )
  }

  @Test("Approve reason reports changes-requested selections")
  func approveReasonReportsChangesRequested() {
    let changes = makeItem(state: .open, reviewStatus: .changesRequested)

    #expect(
      DashboardReviewsDisabledReason.approveReason(for: [changes])
        == "Changes requested - resolve review before approving"
    )
  }

  @Test("Approve reason reports selections the viewer cannot update")
  func approveReasonReportsMissingUpdatePermission() {
    let readOnly = makeItem(state: .open, reviewStatus: .reviewRequired, viewerCanUpdate: false)

    #expect(
      DashboardReviewsDisabledReason.approveReason(for: [readOnly])
        == "Current GitHub token cannot update selected pull request(s)"
    )
    #expect(!readOnly.canAttemptManualApproval)
  }

  @Test("Approve reason reports closed selections")
  func approveReasonReportsClosedState() {
    let closed = makeItem(state: .closed, reviewStatus: .reviewRequired)

    #expect(
      DashboardReviewsDisabledReason.approveReason(for: [closed])
        == "Pull request is not open"
    )
  }

  @Test("Approve reason is the empty fallback for an empty selection")
  func approveReasonForEmptySelection() {
    #expect(
      DashboardReviewsDisabledReason.approveReason(for: [])
        == "No pull requests selected"
    )
  }

  @Test("Merge reason reports draft, conflict, and closed selections")
  func mergeReasonReportsDraftConflictAndClosed() {
    let draft = makeItem(state: .open, isDraft: true)
    let conflict = makeItem(state: .open, mergeable: .conflicting)
    let closed = makeItem(state: .closed)

    #expect(
      DashboardReviewsDisabledReason.mergeReason(for: [draft])
        == "Pull request is a draft"
    )
    #expect(
      DashboardReviewsDisabledReason.mergeReason(for: [conflict])
        == "Merge conflicts must be resolved before merging"
    )
    #expect(
      DashboardReviewsDisabledReason.mergeReason(for: [closed])
        == "Pull request is not open"
    )
  }

  @Test("Merge reason is nil when any item is mergeable")
  func mergeReasonIsNilWhenAnyItemIsMergeable() {
    let mergeable = makeItem(state: .open, mergeable: .mergeable)
    let conflict = makeItem(state: .open, mergeable: .conflicting)

    #expect(DashboardReviewsDisabledReason.mergeReason(for: [mergeable, conflict]) == nil)
  }

  @Test("Merge action title becomes explicit for admin bypass")
  func mergeActionTitleBecomesExplicitForAdminBypass() {
    let clean = makeItem(state: .open, reviewStatus: .approved, checkStatus: .success)
    let adminBypass = makeItem(
      state: .open,
      reviewStatus: .approved,
      checkStatus: .failure,
      requiredFailedCheckNames: ["ci / test"],
      viewerCanMergeAsAdmin: true
    )

    #expect(dashboardReviewMergeActionTitle(for: [clean]) == "Merge")
    #expect(dashboardReviewMergeActionTitle(for: [adminBypass]) == "Merge as Admin")
  }

  @Test("Approve confirmation appears only for attention selections")
  func approveConfirmationAppearsOnlyForAttentionSelections() {
    let clean = makeItem(state: .open, reviewStatus: .reviewRequired, checkStatus: .success)
    let failing = makeItem(state: .open, reviewStatus: .reviewRequired, checkStatus: .failure)

    #expect(dashboardReviewActionConfirmation(for: .approve, items: [clean]) == nil)
    let confirmation = dashboardReviewActionConfirmation(for: .approve, items: [failing])
    #expect(confirmation != nil)
    #expect(confirmation?.title == "Approve pull request that needs attention?")
    #expect(confirmation?.confirmButtonTitle == "Approve 1 Pull Request")
  }

  @Test("Merge confirmation explains admin bypass when required checks fail")
  func mergeConfirmationExplainsAdminBypassWhenRequiredChecksFail() {
    let item = makeItem(
      state: .open,
      reviewStatus: .approved,
      checkStatus: .failure,
      requiredFailedCheckNames: ["ci / test"],
      viewerCanMergeAsAdmin: true
    )

    let confirmation = dashboardReviewActionConfirmation(for: .merge, items: [item])

    #expect(confirmation?.title == "Merge as Admin despite required failing checks?")
    #expect(confirmation?.confirmButtonTitle == "Merge as Admin")
    #expect(confirmation?.confirmRole != nil)
    #expect(confirmation?.message.contains("Required checks failing: ci / test.") == true)
    #expect(
      confirmation?.message.contains("Merge as Admin uses your GitHub permissions") == true
    )
    #expect(
      confirmation?.message.contains("bypass branch protections and merge immediately") == true
    )
  }

  @Test("Merge confirmation summarizes mixed selections")
  func mergeConfirmationSummarizesMixedSelections() {
    let adminBypass = makeItem(
      state: .open,
      reviewStatus: .approved,
      checkStatus: .failure,
      requiredFailedCheckNames: ["ci / required"],
      viewerCanMergeAsAdmin: true
    )
    let optionalFailure = makeItem(
      state: .open,
      reviewStatus: .approved,
      checkStatus: .failure
    )
    let changesRequested = makeItem(
      state: .open,
      reviewStatus: .changesRequested,
      checkStatus: .success
    )

    let confirmation = dashboardReviewActionConfirmation(
      for: .merge,
      items: [adminBypass, optionalFailure, changesRequested]
    )

    #expect(confirmation?.message.contains("Selection summary:") == true)
    #expect(
      confirmation?.message.contains("1 selected PR can only merge with admin permissions.")
        == true)
    let optionalFailureSummary =
      "1 selected PR has failing checks that are not marked required."
    #expect(
      confirmation?.message.contains(optionalFailureSummary) == true
    )
    #expect(
      confirmation?.message.contains("1 selected PR has changes requested.")
        == true)
  }

  @Test("Attention badge kinds cover visible list reasons")
  func attentionBadgeKindsCoverVisibleListReasons() {
    let item = makeItem(
      state: .open,
      mergeable: .conflicting,
      reviewStatus: .changesRequested,
      checkStatus: .failure,
      policyBlocked: true,
      requiredFailedCheckNames: ["ci / required"]
    )
    let optionalFailure = makeItem(
      state: .open,
      reviewStatus: .approved,
      checkStatus: .failure
    )

    #expect(
      dashboardReviewAttentionBadgeKinds(for: item)
        == [.requiredChecks, .changesRequested, .policyBlocked, .mergeConflicts]
    )
    #expect(dashboardReviewAttentionBadgeKinds(for: optionalFailure) == [.failingChecks])
  }

  @Test("Rerun reason distinguishes passing from pending checks")
  func rerunReasonDistinguishesPassingFromPending() {
    let passing = makeItem(checkStatus: .success)
    let pending = makeItem(checkStatus: .pending)

    #expect(
      DashboardReviewsDisabledReason.rerunReason(for: [passing])
        == "All checks passing - nothing to rerun"
    )
    #expect(
      DashboardReviewsDisabledReason.rerunReason(for: [pending])
        == "Checks are still running"
    )
  }

  @Test("Rerun reason is nil when there is a failed rerunnable suite")
  func rerunReasonIsNilWhenRerunnable() {
    let failing = makeItem(
      checkStatus: .failure,
      checks: [
        ReviewCheck(
          name: "ci",
          status: .completed,
          conclusion: .failure,
          checkSuiteID: "suite-1"
        )
      ]
    )

    #expect(DashboardReviewsDisabledReason.rerunReason(for: [failing]) == nil)
  }

  @Test("Rerun reason requires update permission")
  func rerunReasonRequiresUpdatePermission() {
    let failing = makeItem(
      checkStatus: .failure,
      checks: [
        ReviewCheck(
          name: "ci",
          status: .completed,
          conclusion: .failure,
          checkSuiteID: "suite-1"
        )
      ],
      viewerCanUpdate: false
    )

    #expect(
      DashboardReviewsDisabledReason.rerunReason(for: [failing])
        == "Current GitHub token cannot update selected pull request(s)"
    )
    #expect(!failing.canAttemptRerunChecks)
  }

  @Test("Auto reason is nil when at least one item can run auto mode")
  func autoReasonIsNilWhenAnyItemAutoEligible() {
    let auto = makeItem(state: .open, reviewStatus: .none, checkStatus: .success)

    #expect(DashboardReviewsDisabledReason.autoReason(for: [auto]) == nil)
  }

  @Test("Auto reason reports when nothing in the selection matches")
  func autoReasonReportsNoMatch() {
    let changes = makeItem(state: .open, reviewStatus: .changesRequested, checkStatus: .success)

    #expect(
      DashboardReviewsDisabledReason.autoReason(for: [changes])
        == "Nothing in this selection matches the auto-mode rules"
    )
  }

  @Test("Label and rebase reasons require update permission")
  func labelAndRebaseReasonsRequireUpdatePermission() {
    let readOnly = makeItem(viewerCanUpdate: false)

    #expect(
      DashboardReviewsDisabledReason.labelReason(for: [readOnly])
        == "Current GitHub token cannot update selected pull request(s)"
    )
    #expect(
      DashboardReviewsDisabledReason.rebaseReason(for: readOnly)
        == "Current GitHub token cannot update selected pull request(s)"
    )
    #expect(!readOnly.canAddReviewLabel)
    #expect(!readOnly.canRebaseViaBot)
  }

  @Test("Replacing dependency items preserves update permission")
  func replacingReviewItemsPreservesUpdatePermission() {
    let readOnly = makeItem(viewerCanUpdate: false)

    #expect(!readOnly.replacing(checkStatus: .failure).viewerCanUpdate)
  }

  @Test("Auto preview is nil for single-item selections")
  func autoPreviewIsNilForSingleItem() {
    let item = makeItem(state: .open, reviewStatus: .reviewRequired, checkStatus: .success)

    #expect(DashboardReviewsDisabledReason.autoPreview(for: [item]) == nil)
  }

  @Test("Auto preview counts approvals separately from merge-ready PRs")
  func autoPreviewCountsApproveMergeSkipCorrectly() {
    let reviewRequired = makeItem(
      state: .open, reviewStatus: .reviewRequired, checkStatus: .success)
    let approved = makeItem(state: .open, reviewStatus: .approved, checkStatus: .success)
    let blocked = makeItem(state: .open, reviewStatus: .changesRequested, checkStatus: .success)

    let preview = DashboardReviewsDisabledReason.autoPreview(
      for: [reviewRequired, reviewRequired, approved, blocked]
    )

    #expect(preview == "Will approve 2, merge 1, skip 1")
  }

  @Test("Auto preview reports when no PRs in selection match auto-mode rules")
  func autoPreviewReportsNoMatch() {
    let blocked = makeItem(state: .open, reviewStatus: .changesRequested, checkStatus: .success)

    let preview = DashboardReviewsDisabledReason.autoPreview(for: [blocked, blocked])

    #expect(preview == "No PRs in this selection match the auto-mode rules")
  }

  private func makeItem(
    state: ReviewPullRequestState = .open,
    mergeable: ReviewMergeableState = .mergeable,
    reviewStatus: ReviewReviewStatus = .reviewRequired,
    checkStatus: ReviewCheckStatus = .success,
    policyBlocked: Bool = false,
    isDraft: Bool = false,
    checks: [ReviewCheck] = [],
    viewerCanUpdate: Bool = true,
    requiredFailedCheckNames: [String] = [],
    viewerCanMergeAsAdmin: Bool = false
  ) -> ReviewItem {
    ReviewItem(
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
      policyBlocked: policyBlocked,
      isDraft: isDraft,
      headSha: "abc123",
      labels: [],
      checks: checks,
      reviews: [],
      additions: 10,
      deletions: 4,
      createdAt: "2026-05-20T10:00:00Z",
      updatedAt: "2026-05-20T11:00:00Z",
      requiredFailedCheckNames: requiredFailedCheckNames,
      viewerCanUpdate: viewerCanUpdate,
      viewerCanMergeAsAdmin: viewerCanMergeAsAdmin
    )
  }
}
