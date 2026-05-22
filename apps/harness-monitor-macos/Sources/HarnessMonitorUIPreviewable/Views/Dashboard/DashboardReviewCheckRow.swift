import HarnessMonitorKit
import SwiftUI

struct DashboardReviewCheckRow: View {
  @Environment(\.openURL)
  private var openURL

  let check: ReviewCheck
  let suppressPassingStatus: Bool
  let onRerunCheck: (ReviewCheck) -> Void

  var body: some View {
    content
      .contextMenu { contextMenu }
      .help(rowHelp)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint(accessibilityHint)
  }

  @ViewBuilder private var content: some View {
    if let detailsURL = check.detailsWebURL {
      Button {
        openURL(detailsURL)
      } label: {
        rowContent
      }
      .harnessPlainButtonStyle()
    } else {
      rowContent
    }
  }

  private var rowContent: some View {
    HStack(alignment: .dashboardReviewCheckTextCenter, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: check.systemImage)
        .foregroundStyle(check.tint)
        .frame(width: 16, alignment: .center)
      Text(check.name)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(2)
        .alignmentGuide(.dashboardReviewCheckTextCenter) { dimensions in
          dimensions[VerticalAlignment.center]
        }
        .layoutPriority(1)
      if check.detailsWebURL != nil {
        Image(systemName: "arrow.up.forward.square")
          .imageScale(.small)
          .foregroundStyle(HarnessMonitorTheme.accent)
          .accessibilityHidden(true)
      }
      if !suppressPassingStatus {
        DashboardReviewStatusPill(
          label: check.statusLabel,
          tint: check.tint,
          isQuiet: check.isNeutralStatus
        )
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
  }

  @ViewBuilder private var contextMenu: some View {
    if let detailsURL = check.detailsWebURL {
      Button("Open Check Run") {
        openURL(detailsURL)
      }
      Button("Copy Check URL") {
        HarnessMonitorClipboard.copy(detailsURL.absoluteString)
      }
      Divider()
    }
    Button("Rerun Check") {
      onRerunCheck(check)
    }
    .disabled(!check.isRerunnable)
    .help(check.rerunUnavailableReason ?? "Rerun this check")
  }

  private var rowHelp: String {
    if let detailsURL = check.detailsWebURL {
      return "Open check run: \(detailsURL.absoluteString)"
    }
    return check.rerunUnavailableReason ?? "No check run link is available"
  }

  private var accessibilityLabel: String {
    "Check \(check.name), \(check.statusLabel)"
  }

  private var accessibilityHint: String {
    if check.detailsWebURL != nil {
      return "Opens the check run"
    }
    return check.rerunUnavailableReason ?? "Check run link unavailable"
  }
}
