import HarnessMonitorKit
import SwiftUI

enum DashboardDependenciesVisualMetrics {
  static let pillCornerRadius: CGFloat = 7
  static let dependencyRowHorizontalPadding: CGFloat = 4
  static let dependencyRowVerticalPadding: CGFloat = 10
  static let sectionMaxWidth: CGFloat = 940
  static let checksMaxWidth: CGFloat = 680
}

private enum DashboardDependencyCheckTextCenterAlignment: AlignmentID {
  static func defaultValue(in context: ViewDimensions) -> CGFloat {
    context[VerticalAlignment.center]
  }
}

extension VerticalAlignment {
  fileprivate static let dashboardDependencyCheckTextCenter = VerticalAlignment(
    DashboardDependencyCheckTextCenterAlignment.self
  )
}

struct DashboardDependenciesSummaryStatStrip: View {
  let summary: DependencyUpdatesSummary
  let showsCachedResults: Bool
  let refreshDescription: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        DashboardDependencyMetricPill(
          title: "Total", value: summary.total, tint: HarnessMonitorTheme.accent)
        DashboardDependencyMetricPill(
          title: "Ready", value: summary.readyToMerge, tint: HarnessMonitorTheme.success)
        DashboardDependencyMetricPill(
          title: "Review", value: summary.reviewRequired, tint: HarnessMonitorTheme.accent)
        DashboardDependencyMetricPill(
          title: "Checks", value: summary.waitingOnChecks, tint: HarnessMonitorTheme.caution)
        DashboardDependencyMetricPill(
          title: "Blocked", value: summary.blocked, tint: HarnessMonitorTheme.danger)
        if showsCachedResults {
          DashboardDependencyStatusPill(
            label: "Cached",
            tint: HarnessMonitorTheme.secondaryInk,
            systemImage: "archivebox"
          )
        }
      }

      Label("Refresh interval \(refreshDescription)", systemImage: "clock.arrow.circlepath")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .labelStyle(.titleAndIcon)
    }
  }
}

struct DashboardDependencyMetricPill: View {
  let title: String
  let value: Int
  let tint: Color

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(verbatim: String(value))
        .foregroundStyle(tint)
    }
    .scaledFont(.caption.weight(.semibold))
    .lineLimit(1)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background {
      RoundedRectangle(
        cornerRadius: DashboardDependenciesVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .fill(tint.opacity(0.14))
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: DashboardDependenciesVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(tint.opacity(0.34), lineWidth: 1)
    }
  }
}

struct DashboardDependencyStatusPill: View {
  let label: String
  let tint: Color
  var systemImage: String?
  var isQuiet = false

  init(
    label: String,
    tint: Color,
    systemImage: String? = nil,
    isQuiet: Bool = false
  ) {
    self.label = label
    self.tint = tint
    self.systemImage = systemImage
    self.isQuiet = isQuiet
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if let systemImage {
        Image(systemName: systemImage)
          .imageScale(.small)
      }
      Text(label)
    }
    .scaledFont(.caption.weight(.semibold))
    .lineLimit(1)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background {
      RoundedRectangle(
        cornerRadius: DashboardDependenciesVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .fill(tint.opacity(isQuiet ? 0.10 : 0.18))
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: DashboardDependenciesVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(tint.opacity(isQuiet ? 0.22 : 0.38), lineWidth: 1)
    }
    .foregroundStyle(tint)
  }
}

private struct DashboardDependencyChangePill: View {
  let additions: UInt64
  let deletions: UInt64

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Text(verbatim: "+\(additions)")
        .foregroundStyle(HarnessMonitorTheme.success)
      Text(verbatim: "-\(deletions)")
        .foregroundStyle(HarnessMonitorTheme.danger)
    }
    .scaledFont(.caption.weight(.semibold).monospacedDigit())
    .lineLimit(1)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background {
      RoundedRectangle(
        cornerRadius: DashboardDependenciesVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .fill(HarnessMonitorTheme.secondaryInk.opacity(0.10))
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: DashboardDependenciesVisualMetrics.pillCornerRadius,
        style: .continuous
      )
      .strokeBorder(HarnessMonitorTheme.secondaryInk.opacity(0.22), lineWidth: 1)
    }
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    "\(additions) \(additions == 1 ? "addition" : "additions"), \(deletions) "
      + (deletions == 1 ? "deletion" : "deletions")
  }
}

enum DashboardDependencyActionProminence {
  case primary
  case success
  case secondary
  case utility

  var variant: HarnessMonitorAsyncActionButton.Variant {
    switch self {
    case .primary, .success:
      .prominent
    case .secondary, .utility:
      .bordered
    }
  }

  var tint: Color? {
    switch self {
    case .primary:
      HarnessMonitorTheme.accent
    case .success:
      HarnessMonitorTheme.success
    case .secondary:
      nil
    case .utility:
      .secondary
    }
  }
}

struct DashboardDependencyActionButton: View {
  let title: String
  let systemImage: String
  let prominence: DashboardDependencyActionProminence
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .lineLimit(1)
    }
    .harnessActionButtonStyle(variant: prominence.variant, tint: prominence.tint)
    .fixedSize(horizontal: true, vertical: true)
  }
}

struct DashboardDependencyStatusStrip: View {
  let item: DependencyUpdateItem

  var body: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      DashboardDependencyStatusPill(label: item.statusLabel, tint: item.statusTint)
      DashboardDependencyStatusPill(
        label: item.reviewStatus.label,
        tint: item.reviewStatus.tint,
        isQuiet: true
      )
      DashboardDependencyChangePill(additions: item.additions, deletions: item.deletions)
      if item.policyBlocked {
        DashboardDependencyStatusPill(
          label: "Policy wait",
          tint: HarnessMonitorTheme.caution,
          systemImage: "hourglass",
          isQuiet: true
        )
      }
    }
  }
}

struct DashboardDependencyCheckList: View {
  let checks: [DependencyUpdateCheck]
  let onRerunCheck: (DependencyUpdateCheck) -> Void

  var body: some View {
    if checks.isEmpty {
      Text("No checks reported")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        if allPassing {
          DashboardDependencyStatusPill(
            label: "All checks passed",
            tint: HarnessMonitorTheme.success,
            systemImage: "checkmark.circle.fill"
          )
        }
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(sortedChecks.enumerated()), id: \.element.id) { index, check in
            DashboardDependencyCheckRow(
              check: check,
              suppressPassingStatus: allPassing,
              onRerunCheck: onRerunCheck
            )
              .overlay(alignment: .bottom) {
                if index < sortedChecks.count - 1 {
                  Divider().opacity(0.45)
                }
              }
          }
        }
      }
      .frame(maxWidth: DashboardDependenciesVisualMetrics.checksMaxWidth, alignment: .leading)
    }
  }

  private var allPassing: Bool {
    !checks.isEmpty && checks.allSatisfy(\.isPassing)
  }

  private var sortedChecks: [DependencyUpdateCheck] {
    checks.sorted { lhs, rhs in
      if lhs.displayPriority != rhs.displayPriority {
        return lhs.displayPriority < rhs.displayPriority
      }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }
}

private struct DashboardDependencyCheckRow: View {
  @Environment(\.openURL) private var openURL

  let check: DependencyUpdateCheck
  let suppressPassingStatus: Bool
  let onRerunCheck: (DependencyUpdateCheck) -> Void

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
      .buttonStyle(.plain)
    } else {
      rowContent
    }
  }

  private var rowContent: some View {
    HStack(alignment: .dashboardDependencyCheckTextCenter, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: check.systemImage)
        .foregroundStyle(check.tint)
        .frame(width: 16, alignment: .center)
      Text(check.name)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(2)
        .alignmentGuide(.dashboardDependencyCheckTextCenter) { dimensions in
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
        DashboardDependencyStatusPill(
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
