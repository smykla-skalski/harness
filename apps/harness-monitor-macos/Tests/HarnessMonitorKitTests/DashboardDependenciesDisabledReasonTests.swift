import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard dependencies disabled reason helpers")
struct DashboardDependenciesDisabledReasonTests {
  @Test("Approve reason is nil when at least one item is approvable")
  func approveReasonIsNilWhenAnyItemIsApprovable() {
    let approvable = makeItem(state: .open, reviewStatus: .reviewRequired)
    let approved = makeItem(state: .open, reviewStatus: .approved)

    #expect(DashboardDependenciesDisabledReason.approveReason(for: [approvable]) == nil)
    #expect(DashboardDependenciesDisabledReason.approveReason(for: [approved, approvable]) == nil)
  }

  @Test("Approve reason reports already-approved selections")
  func approveReasonReportsAlreadyApproved() {
    let approved = makeItem(state: .open, reviewStatus: .approved)

    #expect(
      DashboardDependenciesDisabledReason.approveReason(for: [approved])
        == "Already approved"
    )
  }

  @Test("Approve reason reports changes-requested selections")
  func approveReasonReportsChangesRequested() {
    let changes = makeItem(state: .open, reviewStatus: .changesRequested)

    #expect(
      DashboardDependenciesDisabledReason.approveReason(for: [changes])
        == "Changes requested - resolve review before approving"
    )
  }

  @Test("Approve reason reports selections the viewer cannot update")
  func approveReasonReportsMissingUpdatePermission() {
    let readOnly = makeItem(state: .open, reviewStatus: .reviewRequired, viewerCanUpdate: false)

    #expect(
      DashboardDependenciesDisabledReason.approveReason(for: [readOnly])
        == "Current GitHub token cannot update selected pull request(s)"
    )
    #expect(!readOnly.canAttemptManualApproval)
  }

  @Test("Approve reason reports closed selections")
  func approveReasonReportsClosedState() {
    let closed = makeItem(state: .closed, reviewStatus: .reviewRequired)

    #expect(
      DashboardDependenciesDisabledReason.approveReason(for: [closed])
        == "Pull request is not open"
    )
  }

  @Test("Approve reason is the empty fallback for an empty selection")
  func approveReasonForEmptySelection() {
    #expect(
      DashboardDependenciesDisabledReason.approveReason(for: [])
        == "No pull requests selected"
    )
  }

  @Test("Merge reason reports draft, conflict, and closed selections")
  func mergeReasonReportsDraftConflictAndClosed() {
    let draft = makeItem(state: .open, isDraft: true)
    let conflict = makeItem(state: .open, mergeable: .conflicting)
    let closed = makeItem(state: .closed)

    #expect(
      DashboardDependenciesDisabledReason.mergeReason(for: [draft])
        == "Pull request is a draft"
    )
    #expect(
      DashboardDependenciesDisabledReason.mergeReason(for: [conflict])
        == "Merge conflicts must be resolved before merging"
    )
    #expect(
      DashboardDependenciesDisabledReason.mergeReason(for: [closed])
        == "Pull request is not open"
    )
  }

  @Test("Merge reason is nil when any item is mergeable")
  func mergeReasonIsNilWhenAnyItemIsMergeable() {
    let mergeable = makeItem(state: .open, mergeable: .mergeable)
    let conflict = makeItem(state: .open, mergeable: .conflicting)

    #expect(DashboardDependenciesDisabledReason.mergeReason(for: [mergeable, conflict]) == nil)
  }

  @Test("Approve prominence becomes warning when selection needs attention")
  func approveProminenceBecomesWarningWhenSelectionNeedsAttention() {
    let clean = makeItem(state: .open, reviewStatus: .reviewRequired, checkStatus: .success)
    let failing = makeItem(state: .open, reviewStatus: .approved, checkStatus: .failure)

    #expect(dashboardDependencyApproveProminence(for: [clean]) == .primary)
    #expect(dashboardDependencyApproveProminence(for: [failing]) == .warning)
  }

  @Test("Merge prominence becomes destructive for admin bypass of required failing checks")
  func mergeProminenceBecomesDestructiveForAdminBypassOfRequiredFailures() {
    let adminBypass = makeItem(
      state: .open,
      reviewStatus: .approved,
      checkStatus: .failure,
      requiredFailedCheckNames: ["ci / test"],
      viewerCanMergeAsAdmin: true
    )

    #expect(adminBypass.requiresAdminMergeForRequiredFailures)
    #expect(dashboardDependencyMergeProminence(for: [adminBypass]) == .destructive)
  }

  @Test("Merge prominence becomes warning when attention does not require admin bypass")
  func mergeProminenceBecomesWarningWithoutAdminBypass() {
    let optionalFailure = makeItem(
      state: .open,
      reviewStatus: .approved,
      checkStatus: .failure,
      requiredFailedCheckNames: [],
      viewerCanMergeAsAdmin: true
    )

    #expect(!optionalFailure.requiresAdminMergeForRequiredFailures)
    #expect(dashboardDependencyMergeProminence(for: [optionalFailure]) == .warning)
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

    #expect(dashboardDependencyMergeActionTitle(for: [clean]) == "Merge")
    #expect(dashboardDependencyMergeActionTitle(for: [adminBypass]) == "Merge as Admin")
  }

  @Test("Approve confirmation appears only for attention selections")
  func approveConfirmationAppearsOnlyForAttentionSelections() {
    let clean = makeItem(state: .open, reviewStatus: .reviewRequired, checkStatus: .success)
    let failing = makeItem(state: .open, reviewStatus: .approved, checkStatus: .failure)

    #expect(dashboardDependencyActionConfirmation(for: .approve, items: [clean]) == nil)
    let confirmation = dashboardDependencyActionConfirmation(for: .approve, items: [failing])
    #expect(confirmation != nil)
    #expect(confirmation?.title == "Approve pull request that needs attention?")
    #expect(confirmation?.confirmButtonTitle == "Approve Anyway")
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

    let confirmation = dashboardDependencyActionConfirmation(for: .merge, items: [item])

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

    let confirmation = dashboardDependencyActionConfirmation(
      for: .merge,
      items: [adminBypass, optionalFailure, changesRequested]
    )

    #expect(confirmation?.message.contains("Selection summary:") == true)
    #expect(
      confirmation?.message.contains("1 selected PR can only merge with admin permissions.")
        == true)
    #expect(
      confirmation?.message.contains("1 selected PR has failing checks that are not marked required.")
        == true)
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
      dashboardDependencyAttentionBadgeKinds(for: item)
        == [.requiredChecks, .changesRequested, .policyBlocked, .mergeConflicts]
    )
    #expect(dashboardDependencyAttentionBadgeKinds(for: optionalFailure) == [.failingChecks])
  }

  @Test("Rerun reason distinguishes passing from pending checks")
  func rerunReasonDistinguishesPassingFromPending() {
    let passing = makeItem(checkStatus: .success)
    let pending = makeItem(checkStatus: .pending)

    #expect(
      DashboardDependenciesDisabledReason.rerunReason(for: [passing])
        == "All checks passing - nothing to rerun"
    )
    #expect(
      DashboardDependenciesDisabledReason.rerunReason(for: [pending])
        == "Checks are still running"
    )
  }

  @Test("Rerun reason is nil when there is a failed rerunnable suite")
  func rerunReasonIsNilWhenRerunnable() {
    let failing = makeItem(
      checkStatus: .failure,
      checks: [
        DependencyUpdateCheck(
          name: "ci",
          status: .completed,
          conclusion: .failure,
          checkSuiteID: "suite-1"
        )
      ]
    )

    #expect(DashboardDependenciesDisabledReason.rerunReason(for: [failing]) == nil)
  }

  @Test("Rerun reason requires update permission")
  func rerunReasonRequiresUpdatePermission() {
    let failing = makeItem(
      checkStatus: .failure,
      checks: [
        DependencyUpdateCheck(
          name: "ci",
          status: .completed,
          conclusion: .failure,
          checkSuiteID: "suite-1"
        )
      ],
      viewerCanUpdate: false
    )

    #expect(
      DashboardDependenciesDisabledReason.rerunReason(for: [failing])
        == "Current GitHub token cannot update selected pull request(s)"
    )
    #expect(!failing.canAttemptRerunChecks)
  }

  @Test("Auto reason is nil when at least one item can run auto mode")
  func autoReasonIsNilWhenAnyItemAutoEligible() {
    let auto = makeItem(state: .open, reviewStatus: .none, checkStatus: .success)

    #expect(DashboardDependenciesDisabledReason.autoReason(for: [auto]) == nil)
  }

  @Test("Auto reason reports when nothing in the selection matches")
  func autoReasonReportsNoMatch() {
    let changes = makeItem(state: .open, reviewStatus: .changesRequested, checkStatus: .success)

    #expect(
      DashboardDependenciesDisabledReason.autoReason(for: [changes])
        == "Nothing in this selection matches the auto-mode rules"
    )
  }

  @Test("Label and rebase reasons require update permission")
  func labelAndRebaseReasonsRequireUpdatePermission() {
    let readOnly = makeItem(viewerCanUpdate: false)

    #expect(
      DashboardDependenciesDisabledReason.labelReason(for: [readOnly])
        == "Current GitHub token cannot update selected pull request(s)"
    )
    #expect(
      DashboardDependenciesDisabledReason.rebaseReason(for: readOnly)
        == "Current GitHub token cannot update selected pull request(s)"
    )
    #expect(!readOnly.canAddDependencyLabel)
    #expect(!readOnly.canRebaseViaBot)
  }

  @Test("Replacing dependency items preserves update permission")
  func replacingDependencyItemsPreservesUpdatePermission() {
    let readOnly = makeItem(viewerCanUpdate: false)

    #expect(!readOnly.replacing(checkStatus: .failure).viewerCanUpdate)
  }

  @Test("Auto preview is nil for single-item selections")
  func autoPreviewIsNilForSingleItem() {
    let item = makeItem(state: .open, reviewStatus: .reviewRequired, checkStatus: .success)

    #expect(DashboardDependenciesDisabledReason.autoPreview(for: [item]) == nil)
  }

  @Test("Auto preview counts approve, merge, and skip")
  func autoPreviewCountsApproveMergeSkipCorrectly() {
    let unreviewed = makeItem(state: .open, reviewStatus: .none, checkStatus: .success)
    let approved = makeItem(state: .open, reviewStatus: .approved, checkStatus: .success)
    let blocked = makeItem(state: .open, reviewStatus: .changesRequested, checkStatus: .success)

    let preview = DashboardDependenciesDisabledReason.autoPreview(
      for: [unreviewed, unreviewed, approved, blocked]
    )

    #expect(
      preview
        == "Will approve 2, merge 3 (includes the 2 just approved), skip 1"
    )
  }

  @Test("Auto preview reports when no PRs in selection match auto-mode rules")
  func autoPreviewReportsNoMatch() {
    let blocked = makeItem(state: .open, reviewStatus: .changesRequested, checkStatus: .success)

    let preview = DashboardDependenciesDisabledReason.autoPreview(for: [blocked, blocked])

    #expect(preview == "No PRs in this selection match the auto-mode rules")
  }

  private func makeItem(
    state: DependencyUpdatePullRequestState = .open,
    mergeable: DependencyUpdateMergeableState = .mergeable,
    reviewStatus: DependencyUpdateReviewStatus = .reviewRequired,
    checkStatus: DependencyUpdateCheckStatus = .success,
    policyBlocked: Bool = false,
    isDraft: Bool = false,
    checks: [DependencyUpdateCheck] = [],
    viewerCanUpdate: Bool = true,
    requiredFailedCheckNames: [String] = [],
    viewerCanMergeAsAdmin: Bool = false
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
