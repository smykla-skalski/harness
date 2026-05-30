import HarnessMonitorKit
import SwiftUI

struct DashboardReviewActionBar: View {
  let items: [ReviewItem]
  let viewerLogin: String?
  let availableLabels: [ReviewRepositoryLabel]
  let frequentNames: [String]
  let showsDescriptions: Bool
  let isBusy: Bool
  let snoozedPullRequests: DashboardReviewsSnoozedPullRequests
  let pinActionTitle: String
  let pinActionSystemImage: String
  let onApprove: () -> Void
  let onMerge: () -> Void
  let onRerunChecks: () -> Void
  let onRefresh: () -> Void
  let onSelectLabel: (String) -> Void
  let onCustomLabel: () -> Void
  let onTogglePinnedSelection: () -> Void
  let onCopyApprovalLinks: () -> Void
  let onAuto: () -> Void
  let onOpenItem: () -> Void
  let onFixCI: () -> Void
  let onRebaseViaBot: () -> Void
  let onSnooze: (DashboardReviewsSnoozeCondition) -> Void
  let onUnsnooze: () -> Void

  var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
        scrollingButtons
        moreActionsMenu
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var scrollingButtons: some View {
    ScrollView(.horizontal) {
      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        buttons
      }
      .padding(.vertical, 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .scrollIndicators(.hidden)
    .mask(Self.overflowFadeGradient)
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
    if items.count == 1, let item = items.first {
      DashboardReviewActionButton(
        title: "Auto",
        systemImage: "bolt",
        prominence: .primary,
        helpText: helpTextOrBusy(DashboardReviewsDisabledReason.autoReason(for: items)),
        action: onAuto
      )
      .disabled(isBusy || !item.canRunAutoMode)
    } else {
      DashboardReviewActionButton(
        title: "Auto",
        systemImage: "bolt",
        prominence: .primary,
        helpText: helpTextOrBusy(
          DashboardReviewsDisabledReason.autoReason(for: items)
            ?? DashboardReviewsDisabledReason.autoPreview(for: items)
        ),
        action: onAuto
      )
      .disabled(isBusy || !items.contains { $0.canRunAutoMode })
    }

    DashboardReviewActionButton(
      title: approveButtonTitle,
      systemImage: approveButtonSystemImage,
      prominence: .secondary,
      helpText: helpTextOrBusy(DashboardReviewsDisabledReason.approveReason(for: items)),
      action: onApprove
    )
    .disabled(isBusy || !items.contains { $0.canAttemptManualApproval })

    DashboardReviewActionButton(
      title: dashboardReviewMergeActionTitle(for: items),
      systemImage: "arrow.triangle.merge",
      prominence: .secondary,
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

    if items.count == 1, let item = items.first {
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
    }
  }

  private static let busyHelpText = "Action in progress"

  /// True when the detail pane shows a single review whose approve action is
  /// disabled because the viewer has already approved. Used to swap the button
  /// copy from "Approve" to "Approved by you" so the disabled state reads as
  /// an affirmation rather than a dead control.
  private var isShowingApprovedAffirmation: Bool {
    guard items.count == 1, let item = items.first, let login = viewerLogin else { return false }
    return !item.canAttemptManualApproval
      && item.reviewStatus == .approved
      && item.reviews.contains { $0.author == login && $0.state == .approved }
  }

  private var approveButtonTitle: String {
    isShowingApprovedAffirmation ? "Approved by you" : "Approve"
  }

  private var approveButtonSystemImage: String {
    isShowingApprovedAffirmation ? "checkmark.seal.fill" : "checkmark.seal"
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

  private var moreActionsMenu: some View {
    Menu {
      Button(action: onTogglePinnedSelection) {
        Label(pinActionTitle, systemImage: pinActionSystemImage)
      }

      Divider()

      if items.count == 1 {
        Button(action: onOpenItem) {
          Label("Open pull request", systemImage: "safari")
        }
      }

      Button(action: onCopyApprovalLinks) {
        Label("Copy approval links", systemImage: "doc.on.doc")
      }

      Divider()

      if !areAllSnoozed {
        Menu {
          Button("Until Tomorrow") {
            let tomorrow =
              Calendar.current.date(byAdding: .day, value: 1, to: .now)
              ?? .now.addingTimeInterval(86_400)
            onSnooze(.untilDate(tomorrow))
          }
          Button("Until Next Week") {
            let nextWeek =
              Calendar.current.date(byAdding: .day, value: 7, to: .now)
              ?? .now.addingTimeInterval(7 * 86_400)
            onSnooze(.untilDate(nextWeek))
          }
          Button("Until New Activity") {
            onSnooze(.untilActivity(lastSeenUpdatedAt: ""))
          }
          Button("Indefinitely") {
            onSnooze(.indefinitely)
          }
        } label: {
          Label("Snooze...", systemImage: "bell.slash")
        }
      }

      if areAnySnoozed {
        Button(action: onUnsnooze) {
          Label("Unsnooze", systemImage: "bell")
        }
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
        .lineLimit(1)
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .fixedSize(horizontal: true, vertical: true)
    .help("Show more review actions")
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsMoreButton)
    .accessibilityLabel("More review actions")
  }

  private var areAllSnoozed: Bool {
    guard !items.isEmpty else { return false }
    let currentDate = Date.now
    return items.allSatisfy { item in
      snoozedPullRequests.isSnoozed(
        item.pullRequestID, currentDate: currentDate, currentUpdatedAt: item.updatedAt)
    }
  }

  private var areAnySnoozed: Bool {
    guard !items.isEmpty else { return false }
    let currentDate = Date.now
    return items.contains { item in
      snoozedPullRequests.isSnoozed(
        item.pullRequestID, currentDate: currentDate, currentUpdatedAt: item.updatedAt)
    }
  }
}
