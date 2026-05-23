import HarnessMonitorKit
import SwiftUI

struct DashboardReviewCheckRow: View {
  @Environment(\.openURL)
  private var openURL

  let check: ReviewCheck
  // Kept for source-compat with CheckList; passing pill always renders now.
  var suppressPassingStatus: Bool = false
  let onRerunCheck: (ReviewCheck) -> Void

  @State private var isHovered = false

  var body: some View {
    content
      .harnessReviewRowHoverTint(isHovered: isHovered)
      .onHover { isHovered = $0 }
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
        .imageScale(.medium)
        .frame(width: 18, alignment: .center)
      Text(check.name)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(2)
        .alignmentGuide(.dashboardReviewCheckTextCenter) { dimensions in
          dimensions[VerticalAlignment.center]
        }
        .layoutPriority(1)

      Spacer(minLength: HarnessMonitorTheme.spacingSM)

      if isHovered {
        inlineActions
          .transition(.opacity)
      }

      if check.detailsWebURL != nil {
        Label("Open", systemImage: "arrow.up.forward.square")
          .labelStyle(.iconOnly)
          .imageScale(.medium)
          .foregroundStyle(HarnessMonitorTheme.accent)
          .accessibilityHidden(true)
      }

      DashboardReviewStatusPill(
        label: check.statusLabel,
        tint: check.tint,
        isQuiet: check.isNeutralStatus
      )
    }
    .padding(.vertical, 8)
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .frame(minHeight: 34)
    .animation(.easeOut(duration: 0.12), value: isHovered)
  }

  @ViewBuilder private var inlineActions: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Button {
        onRerunCheck(check)
      } label: {
        Image(systemName: "arrow.clockwise")
          .imageScale(.medium)
          .frame(width: 22, height: 22)
          .contentShape(.rect)
      }
      .harnessPlainButtonStyle()
      .disabled(!check.isRerunnable)
      .help(check.isRerunnable ? "Rerun check" : (check.rerunUnavailableReason ?? "Rerun is not available"))
      .accessibilityLabel("Rerun check \(check.name)")

      if let detailsURL = check.detailsWebURL {
        Button {
          HarnessMonitorClipboard.copy(detailsURL.absoluteString)
        } label: {
          Image(systemName: "doc.on.doc")
            .imageScale(.medium)
            .frame(width: 22, height: 22)
            .contentShape(.rect)
        }
        .harnessPlainButtonStyle()
        .help("Copy check URL")
        .accessibilityLabel("Copy URL for \(check.name)")
      }
    }
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
