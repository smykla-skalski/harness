import HarnessMonitorKit
import SwiftUI

private enum DashboardReviewOverviewSignalKind: String, Identifiable {
  case files
  case checks
  case reviews

  var id: String { rawValue }
}

private struct DashboardReviewOverviewSignal: Identifiable {
  let kind: DashboardReviewOverviewSignalKind
  let title: String
  let subtitle: String
  let systemImage: String
  let tint: Color
  let helpText: String
  let isEnabled: Bool

  var id: DashboardReviewOverviewSignalKind { kind }
}

struct DashboardReviewOverviewSignalStrip: View {
  let item: ReviewItem
  let filesAvailability: DashboardReviewsFilesModeAvailability
  @Binding var detailMode: DashboardReviewsDetailMode
  @Binding var showsSecondaryDetails: Bool
  @Binding var jumpTarget: String?

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        ForEach(signals) { signal in
          signalButton(signal)
        }
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        ForEach(signals) { signal in
          signalButton(signal)
        }
      }
    }
  }

  private var signals: [DashboardReviewOverviewSignal] {
    [filesSignal, checksSignal, reviewsSignal]
  }

  private var filesSignal: DashboardReviewOverviewSignal {
    let subtitle = filesAvailability.unavailableSummary ?? lineChangeSummary
    return DashboardReviewOverviewSignal(
      kind: .files,
      title: "Files",
      subtitle: subtitle,
      systemImage: filesAvailability.systemImage,
      tint:
        filesAvailability.isAvailable
        ? HarnessMonitorTheme.accent
        : HarnessMonitorTheme.secondaryInk,
      helpText:
        filesAvailability.isAvailable
        ? "Open Files. Code diffs stay on demand to preserve GitHub budget."
        : filesAvailability.helpText,
      isEnabled: filesAvailability.isAvailable
    )
  }

  private var checksSignal: DashboardReviewOverviewSignal {
    DashboardReviewOverviewSignal(
      kind: .checks,
      title: "Checks",
      subtitle: checksSummary,
      systemImage: checksSystemImage,
      tint: checksTint,
      helpText: "Open more details to inspect checks and rerun actions.",
      isEnabled: true
    )
  }

  private var reviewsSignal: DashboardReviewOverviewSignal {
    DashboardReviewOverviewSignal(
      kind: .reviews,
      title: "Reviews",
      subtitle: reviewsSummary,
      systemImage: reviewsSystemImage,
      tint: reviewsTint,
      helpText: "Open more details to inspect reviewer state and comments.",
      isEnabled: true
    )
  }

  private var lineChangeSummary: String {
    if item.additions == 0, item.deletions == 0 {
      return "No line changes"
    }
    return "+\(item.additions) -\(item.deletions) lines"
  }

  private var checksSummary: String {
    let attentionCount = item.checks.count { $0.requiresAttention }
    switch item.checkStatus {
    case .failure:
      if attentionCount > 0 {
        return "\(attentionCount) need attention"
      }
      return item.checks.isEmpty ? "Checks failed" : "\(item.checks.count) checks failed"
    case .pending:
      return item.checks.isEmpty ? "Checks are running" : "\(item.checks.count) running"
    case .success:
      return item.checks.isEmpty ? "No checks reported" : "\(item.checks.count) passing"
    case .none:
      return "No checks reported"
    case .unknown:
      return item.checks.isEmpty ? "Checks unavailable" : "\(item.checks.count) checks recorded"
    }
  }

  private var checksSystemImage: String {
    switch item.checkStatus {
    case .failure:
      "exclamationmark.triangle"
    case .pending:
      "clock"
    case .success:
      "checkmark.circle"
    case .none, .unknown:
      "checklist"
    }
  }

  private var checksTint: Color {
    switch item.checkStatus {
    case .failure:
      HarnessMonitorTheme.danger
    case .pending:
      HarnessMonitorTheme.caution
    case .success:
      HarnessMonitorTheme.success
    case .none, .unknown:
      HarnessMonitorTheme.secondaryInk
    }
  }

  private var reviewsSummary: String {
    let approvals = item.reviews.count { $0.state == .approved }
    let changesRequested = item.reviews.count { $0.state == .changesRequested }
    switch (approvals, changesRequested, item.reviews.count) {
    case (_, let changesRequested, _) where changesRequested > 0 && approvals > 0:
      let changeNoun = changesRequested == 1 ? "change request" : "change requests"
      let approvalNoun = approvals == 1 ? "approval" : "approvals"
      return "\(approvals) \(approvalNoun), \(changesRequested) \(changeNoun)"
    case (_, let changesRequested, _) where changesRequested > 0:
      let changeNoun = changesRequested == 1 ? "change request" : "change requests"
      return "\(changesRequested) \(changeNoun)"
    case (let approvals, _, _) where approvals > 0:
      let approvalNoun = approvals == 1 ? "approval" : "approvals"
      return "\(approvals) \(approvalNoun)"
    case (_, _, 0):
      return "No reviews yet"
    default:
      let reviewCount = item.reviews.count
      let reviewNoun = reviewCount == 1 ? "review" : "reviews"
      return "\(reviewCount) \(reviewNoun) recorded"
    }
  }

  private var reviewsSystemImage: String {
    if item.reviews.contains(where: { $0.state == .changesRequested }) {
      return "arrow.uturn.backward.circle"
    }
    if item.reviews.contains(where: { $0.state == .approved }) {
      return "checkmark.seal"
    }
    return "person.2"
  }

  private var reviewsTint: Color {
    if item.reviews.contains(where: { $0.state == .changesRequested }) {
      return HarnessMonitorTheme.caution
    }
    if item.reviews.contains(where: { $0.state == .approved }) {
      return HarnessMonitorTheme.success
    }
    return HarnessMonitorTheme.secondaryInk
  }

  private func signalButton(_ signal: DashboardReviewOverviewSignal) -> some View {
    Button {
      switch signal.kind {
      case .files:
        detailMode = .files
      case .checks, .reviews:
        showsSecondaryDetails = true
        jumpTarget = DashboardReviewDetailSectionID.moreDetails.rawValue
      }
    } label: {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Label(signal.title, systemImage: signal.systemImage)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
          .lineLimit(1)
        Text(signal.subtitle)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .frame(minHeight: 44, alignment: .leading)
    }
    .harnessInteractiveCardButtonStyle(
      tint: signal.tint,
      respondsToHover: true
    )
    .disabled(!signal.isEnabled)
    .accessibilityLabel(signal.title)
    .accessibilityValue(signal.subtitle)
    .accessibilityHint(signal.helpText)
    .help(signal.helpText)
  }
}
