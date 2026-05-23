import HarnessMonitorKit
import SwiftUI

struct DashboardReviewActionBar: View {
  let items: [ReviewItem]
  let availableLabels: [ReviewRepositoryLabel]
  let frequentNames: [String]
  let showsDescriptions: Bool
  let isBusy: Bool
  let onApprove: () -> Void
  let onMerge: () -> Void
  let onRerunChecks: () -> Void
  let onRefresh: () -> Void
  let onSelectLabel: (String) -> Void
  let onCustomLabel: () -> Void
  let onCopyApprovalLinks: () -> Void
  let onAuto: () -> Void
  let onOpenItem: () -> Void
  let onFixCI: () -> Void
  let onRebaseViaBot: () -> Void

  var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
      ScrollView(.horizontal) {
        HStack(spacing: HarnessMonitorTheme.itemSpacing) {
          buttons
        }
        .padding(.vertical, 1)
      }
      .scrollIndicators(.hidden)
      .mask(Self.overflowFadeGradient)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Trailing fade affordance hinting at horizontal overflow when the inner
  /// HStack exceeds the scroll viewport. Invisible when content fits because
  /// the fade only affects the trailing edge which is empty in that case.
  private static let overflowFadeGradient = LinearGradient(
    stops: [
      .init(color: .black, location: 0.0),
      .init(color: .black, location: 0.94),
      .init(color: .clear, location: 1.0),
    ],
    startPoint: .leading,
    endPoint: .trailing
  )

  @ViewBuilder private var buttons: some View {
    DashboardReviewActionButton(
      title: approveButtonTitle,
      systemImage: approveButtonSystemImage,
      prominence: approveProminence,
      helpText: helpTextOrBusy(DashboardReviewsDisabledReason.approveReason(for: items)),
      action: onApprove
    )
    .disabled(isBusy || !items.contains { $0.canAttemptManualApproval })

    DashboardReviewActionButton(
      title: dashboardReviewMergeActionTitle(for: items),
      systemImage: "arrow.triangle.merge",
      prominence: mergeProminence,
      helpText: helpTextOrBusy(DashboardReviewsDisabledReason.mergeReason(for: items)),
      action: onMerge
    )
    .disabled(isBusy || !items.contains { $0.canAttemptManualMerge })

    DashboardReviewActionButton(
      title: "Rerun checks",
      systemImage: "arrow.clockwise.circle",
      prominence: .secondary,
      helpText: helpTextOrBusy(DashboardReviewsDisabledReason.rerunReason(for: items)),
      action: onRerunChecks
    )
    .disabled(isBusy || !items.contains { $0.canAttemptRerunChecks })
    .help(isBusy ? Self.busyHelpText : rerunChecksHelp)
    .accessibilityHint(isBusy ? Self.busyHelpText : rerunChecksHelp)

    DashboardReviewActionButton(
      title: "Refresh",
      systemImage: "arrow.clockwise",
      prominence: .secondary,
      helpText: helpTextOrBusy(
        DashboardReviewsDisabledReason.emptySelectionReason(for: items)
      ),
      action: onRefresh
    )
    .disabled(isBusy || items.isEmpty)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.reviewsRefreshSelectedButton
    )

    DashboardReviewsLabelPickerActionMenu(
      labels: availableLabels,
      frequentNames: frequentNames,
      showsDescriptions: showsDescriptions,
      onSelect: onSelectLabel,
      onCustom: onCustomLabel
    )
    .disabled(isBusy || !items.contains { $0.canAddReviewLabel })
    .help(DashboardReviewsDisabledReason.labelReason(for: items) ?? "Add a GitHub label")

    DashboardReviewActionButton(
      title: "Copy approval links",
      systemImage: "doc.on.doc",
      prominence: .secondary,
      action: onCopyApprovalLinks
    )

    if items.count == 1, let item = items.first {
      DashboardReviewActionButton(
        title: "Auto",
        systemImage: "bolt",
        prominence: .utility,
        helpText: helpTextOrBusy(DashboardReviewsDisabledReason.autoReason(for: items)),
        action: onAuto
      )
      .disabled(isBusy || !item.canRunAutoMode)
      DashboardReviewActionButton(
        title: "Open pull request", systemImage: "safari", prominence: .utility, action: onOpenItem
      )
      if let bot = ReviewBot.detect(authorLogin: item.authorLogin) {
        DashboardReviewActionButton(
          title: bot.rebaseActionTitle,
          systemImage: "arrow.triangle.2.circlepath",
          prominence: .secondary,
          helpText: DashboardReviewsDisabledReason.rebaseReason(for: item)
            ?? "Available because @\(item.authorLogin) is a known bot",
          action: onRebaseViaBot
        )
        .disabled(isBusy || !item.canRebaseViaBot)
      }
      if item.canStartFixCI {
        DashboardReviewActionButton(
          title: "Fix CI",
          systemImage: "wrench.and.screwdriver",
          prominence: .secondary,
          helpText: "Available because required checks are failing",
          action: onFixCI
        )
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsFixCIButton)
      }
    } else {
      DashboardReviewActionButton(
        title: "Auto",
        systemImage: "bolt",
        prominence: .utility,
        helpText: helpTextOrBusy(
          DashboardReviewsDisabledReason.autoReason(for: items)
            ?? DashboardReviewsDisabledReason.autoPreview(for: items)
        ),
        action: onAuto
      )
      .disabled(isBusy || !items.contains { $0.canRunAutoMode })
    }
  }

  private static let busyHelpText = "Action in progress"

  private var approveProminence: DashboardReviewActionProminence {
    dashboardReviewApproveProminence(for: items)
  }

  /// True when the detail pane shows a single review whose approve action is
  /// disabled because the PR is already approved (with at least one approval
  /// record on file). Used to swap the button copy from "Approve" to
  /// "Approved by you" so the disabled state reads as an affirmation rather
  /// than a dead control.
  private var isShowingApprovedAffirmation: Bool {
    guard items.count == 1, let item = items.first else { return false }
    return !item.canAttemptManualApproval
      && item.reviewStatus == .approved
      && item.reviews.contains { $0.state == .approved }
  }

  private var approveButtonTitle: String {
    isShowingApprovedAffirmation ? "Approved by you" : "Approve"
  }

  private var approveButtonSystemImage: String {
    isShowingApprovedAffirmation ? "checkmark.seal.fill" : "checkmark.seal"
  }

  private var mergeProminence: DashboardReviewActionProminence {
    dashboardReviewMergeProminence(for: items)
  }

  private func helpTextOrBusy(_ fallback: String?) -> String? {
    isBusy ? Self.busyHelpText : fallback
  }

  private var rerunChecksHelp: String {
    if items.isEmpty {
      return "Select a review to rerun failed checks."
    }
    if items.contains(where: { $0.canAttemptRerunChecks }) {
      return "Rerun failed or timed-out GitHub check suites."
    }
    if let reason = DashboardReviewsDisabledReason.rerunReason(for: items) {
      return reason
    }
    if items.count == 1, let reason = items.first?.rerunChecksUnavailableReason {
      return reason
    }
    return "No selected review has rerunnable failed or timed-out checks."
  }
}
