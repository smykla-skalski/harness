import HarnessMonitorKit
import SwiftUI

enum DashboardDependenciesVisualMetrics {
  static let pillCornerRadius: CGFloat = 7
  static let dependencyRowHorizontalPadding: CGFloat = 4
  static let dependencyRowVerticalPadding: CGFloat = 10
  static let sectionMaxWidth: CGFloat = 940
  static let checksMaxWidth: CGFloat = 680
}

enum DashboardDependencyCheckTextCenterAlignment: AlignmentID {
  static func defaultValue(in context: ViewDimensions) -> CGFloat {
    context[VerticalAlignment.center]
  }
}

extension VerticalAlignment {
  static let dashboardDependencyCheckTextCenter = VerticalAlignment(
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
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(checkGroups) { group in
            DashboardDependencyCheckGroupView(
              group: group,
              suppressPassingStatus: allPassing,
              showsHeader: checkGroups.count > 1,
              onRerunCheck: onRerunCheck
            )
          }
        }
      }
      .frame(maxWidth: DashboardDependenciesVisualMetrics.checksMaxWidth, alignment: .leading)
    }
  }

  private var allPassing: Bool {
    !checks.isEmpty && checks.allSatisfy(\.isPassing)
  }

  private var checkGroups: [DashboardDependencyCheckGroup] {
    dashboardDependencyCheckGroups(for: checks)
  }
}

private struct DashboardDependencyCheckGroupView: View {
  let group: DashboardDependencyCheckGroup
  let suppressPassingStatus: Bool
  let showsHeader: Bool
  let onRerunCheck: (DependencyUpdateCheck) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if showsHeader {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          Text(group.title)
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.ink)
          Text(group.checkCountLabel)
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        .padding(.bottom, HarnessMonitorTheme.spacingXS)
      }
      ForEach(Array(group.checks.enumerated()), id: \.element.id) { index, check in
        DashboardDependencyCheckRow(
          check: check,
          suppressPassingStatus: suppressPassingStatus,
          onRerunCheck: onRerunCheck
        )
        .overlay(alignment: .bottom) {
          if index < group.checks.count - 1 {
            Divider().opacity(0.45)
          }
        }
      }
    }
  }
}
