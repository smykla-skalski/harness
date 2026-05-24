import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review list row status icon semantics")
struct DashboardReviewListRowStatusIconTests {
  @Test("draft beats every other status")
  func draftBeatsEveryOtherStatus() {
    let item = makeItem(
      isDraft: true,
      reviewStatus: .approved,
      checkStatus: .success
    )
    #expect(item.statusLabel == "Draft")
    #expect(item.statusSystemImage == "pencil.tip.crop.circle")
  }

  @Test("ready-to-merge gets the green checkmark.circle.fill")
  func readyToMergeGetsGreenCheckmarkCircle() {
    let item = makeItem(
      reviewStatus: .approved,
      checkStatus: .success
    )
    #expect(item.statusLabel == "Ready to merge")
    #expect(item.statusSystemImage == "checkmark.circle.fill")
  }

  @Test("viewer-actionable PR gets the accent checkmark.seal.fill")
  func viewerActionablePRGetsAccentCheckmarkSeal() {
    // viewerCanUpdate && isAutoApprovable && !isDraft
    let item = makeItem(
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      viewerCanUpdate: true
    )
    #expect(item.statusLabel == "Ready for your approval")
    #expect(item.statusSystemImage == "checkmark.seal.fill")
  }

  @Test("read-only viewer drops accent semantics back to the open state")
  func readOnlyViewerDropsAccentSemanticsBackToOpenState() {
    // isAutoApprovable would otherwise fire, but viewerCanUpdate=false.
    let item = makeItem(
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      viewerCanUpdate: false
    )
    // With viewerCanUpdate=false, isAutoApprovable is also false (gates on it),
    // so the row falls through to "Open" with a neutral circle.
    #expect(item.statusLabel == "Open")
    #expect(item.statusSystemImage == "circle")
  }

  @Test("checks-pending shows the caution clock icon")
  func checksPendingShowsTheCautionClockIcon() {
    let item = makeItem(
      reviewStatus: .reviewRequired,
      checkStatus: .pending
    )
    #expect(item.statusLabel == "Checks running")
    #expect(item.statusSystemImage == "clock.arrow.circlepath")
  }

  @Test("requires-attention picks an attention-specific icon, not a generic triangle")
  func requiresAttentionPicksAnAttentionSpecificIcon() {
    // The icon must name the actual problem so it complements (rather than
    // duplicates) the textual pill the row renders below the title.
    let changesRequested = makeItem(
      reviewStatus: .changesRequested,
      checkStatus: .pending
    )
    #expect(changesRequested.statusLabel == "Needs attention")
    #expect(changesRequested.statusSystemImage == "arrow.uturn.backward.circle.fill")

    let failingChecks = makeItem(
      reviewStatus: .reviewRequired,
      checkStatus: .failure
    )
    #expect(failingChecks.statusLabel == "Needs attention")
    #expect(failingChecks.statusSystemImage == "xmark.circle.fill")

    let mergeConflicts = makeItem(
      reviewStatus: .reviewRequired,
      mergeable: .conflicting,
      checkStatus: .pending
    )
    #expect(mergeConflicts.statusLabel == "Needs attention")
    #expect(mergeConflicts.statusSystemImage == "arrow.triangle.merge")

    let policyBlocked = makeItem(
      reviewStatus: .reviewRequired,
      checkStatus: .pending,
      policyBlocked: true
    )
    #expect(policyBlocked.statusLabel == "Needs attention")
    #expect(policyBlocked.statusSystemImage == "hourglass.circle.fill")
  }

  @Test("approved-without-merge gets the green check (not blue seal)")
  func approvedWithoutMergeGetsGreenCheck() {
    // Approved, but viewerCanUpdate=false so it's not ready-to-merge.
    let item = makeItem(
      reviewStatus: .approved,
      checkStatus: .success,
      viewerCanUpdate: false
    )
    #expect(item.statusLabel == "Approved")
    #expect(item.statusSystemImage == "checkmark.circle.fill")
  }

  @Test("open fallback shows the neutral circle")
  func openFallbackShowsTheNeutralCircle() {
    let item = makeItem(
      reviewStatus: .none,
      checkStatus: .none
    )
    #expect(item.statusLabel == "Open")
    #expect(item.statusSystemImage == "circle")
  }

  @Test("status accessibility label mirrors the status label")
  func statusAccessibilityLabelMirrorsTheStatusLabel() {
    let item = makeItem(
      isDraft: true,
      reviewStatus: .none,
      checkStatus: .none
    )
    #expect(item.statusAccessibilityLabel == item.statusLabel)
  }

  /// Pins the attention-icon cascade order for PRs with several active
  /// attention reasons at once. The icon must always name the *worst*
  /// reason so the row's at-a-glance signal matches the most severe item
  /// in the attention pill strip below it.
  ///
  /// Priority (top to bottom = worst to least-bad):
  /// 1. `hasRequiredFailedChecks` — required CI is broken (admin merge)
  /// 2. `checkStatus == .failure` — non-required CI is broken
  /// 3. `reviewStatus == .changesRequested` — reviewer blocked the PR
  /// 4. `policyBlocked` — branch / review policy still gating
  /// 5. `mergeable == .conflicting` — merge conflicts to resolve
  /// 6. fallback `exclamationmark.triangle.fill`
  @Test("attention-icon cascade picks the most severe reason when multiple apply")
  func attentionIconCascadePicksTheMostSevereReason() {
    // Required failed checks beat every other reason.
    let everythingWrong = makeItem(
      reviewStatus: .changesRequested,
      mergeable: .conflicting,
      checkStatus: .failure,
      policyBlocked: true,
      hasRequiredFailedChecks: true
    )
    #expect(everythingWrong.statusSystemImage == "xmark.octagon.fill")

    // Non-required check failure beats changes-requested / policy / conflicts.
    let failureBeatsRest = makeItem(
      reviewStatus: .changesRequested,
      mergeable: .conflicting,
      checkStatus: .failure,
      policyBlocked: true
    )
    #expect(failureBeatsRest.statusSystemImage == "xmark.circle.fill")

    // Changes-requested beats policy + conflicts when checks are pending.
    let changesRequestedBeatsPolicy = makeItem(
      reviewStatus: .changesRequested,
      mergeable: .conflicting,
      checkStatus: .pending,
      policyBlocked: true
    )
    #expect(changesRequestedBeatsPolicy.statusSystemImage == "arrow.uturn.backward.circle.fill")

    // Policy block beats conflicts when nothing more severe applies.
    let policyBeatsConflicts = makeItem(
      reviewStatus: .reviewRequired,
      mergeable: .conflicting,
      checkStatus: .pending,
      policyBlocked: true
    )
    #expect(policyBeatsConflicts.statusSystemImage == "hourglass.circle.fill")

    // Conflicts win when they're the only attention reason.
    let conflictsAlone = makeItem(
      reviewStatus: .reviewRequired,
      mergeable: .conflicting,
      checkStatus: .pending
    )
    #expect(conflictsAlone.statusSystemImage == "arrow.triangle.merge")
  }

  private func makeItem(
    isDraft: Bool = false,
    reviewStatus: ReviewReviewStatus,
    mergeable: ReviewMergeableState = .mergeable,
    checkStatus: ReviewCheckStatus,
    viewerCanUpdate: Bool = true,
    policyBlocked: Bool = false,
    hasRequiredFailedChecks: Bool = false
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: "pr-1",
      repositoryID: "repo-1",
      repository: "octocat/example",
      number: 42,
      title: "Bump dependency",
      url: "https://github.com/octocat/example/pull/42",
      authorLogin: "octocat",
      state: .open,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked,
      isDraft: isDraft,
      headSha: "abc123",
      additions: 10,
      deletions: 4,
      createdAt: "2026-05-22T10:00:00Z",
      updatedAt: "2026-05-22T11:00:00Z",
      requiredFailedCheckNames: hasRequiredFailedChecks ? ["required/lint"] : [],
      viewerCanUpdate: viewerCanUpdate
    )
  }
}
