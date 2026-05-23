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
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var buttons: some View {
    DashboardReviewActionButton(
      title: "Approve",
      systemImage: "checkmark.seal",
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
      title: "Rerun Checks",
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
          helpText: DashboardReviewsDisabledReason.rebaseReason(for: item),
          action: onRebaseViaBot
        )
        .disabled(isBusy || !item.canRebaseViaBot)
      }
      if item.canStartFixCI {
        DashboardReviewActionButton(
          title: "Fix CI",
          systemImage: "wrench.and.screwdriver",
          prominence: .secondary,
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
