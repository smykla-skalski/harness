import HarnessMonitorKit
import SwiftUI

public struct SidebarFooterSummary: Equatable {
  public var projectCount: Int
  public var worktreeCount: Int
  public var sessionCount: Int
  public var openWorkCount: Int
  public var blockedCount: Int

  public init(
    projectCount: Int = 0,
    worktreeCount: Int = 0,
    sessionCount: Int = 0,
    openWorkCount: Int = 0,
    blockedCount: Int = 0
  ) {
    self.projectCount = projectCount
    self.worktreeCount = worktreeCount
    self.sessionCount = sessionCount
    self.openWorkCount = openWorkCount
    self.blockedCount = blockedCount
  }

  public var accessibilityValue: String {
    var parts = [
      "projects=\(projectCount)",
      "sessions=\(sessionCount)",
      "openWork=\(openWorkCount)",
      "blocked=\(blockedCount)",
    ]
    if worktreeCount > 0 {
      parts.insert("worktrees=\(worktreeCount)", at: 1)
    }
    return parts.joined(separator: ", ")
  }
}

public struct SidebarFooterAccessory: View {
  public let metrics: ConnectionMetrics
  public let summary: SidebarFooterSummary

  public init(metrics: ConnectionMetrics, summary: SidebarFooterSummary = .init()) {
    self.metrics = metrics
    self.summary = summary
  }

  private var tint: Color {
    metrics.latencyTint
  }

  public var body: some View {
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      ConnectionToolbarBadge(metrics: metrics)

      Spacer(minLength: 0)

      SidebarFooterMetricsRow(summary: summary)
    }
    .padding(.vertical, HarnessMonitorTheme.itemSpacing)
    .padding(.horizontal, HarnessMonitorTheme.itemSpacing)
    .harnessFloatingControlGlass(
      cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
      tint: tint
    )
    .padding(HarnessMonitorTheme.itemSpacing)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFooter)
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.sidebarFooterState,
        text: summary.accessibilityValue
      )
    }
  }
}

private struct SidebarFooterMetricsRow: View {
  let summary: SidebarFooterSummary
  private static let spacing: CGFloat = 6

  private var metrics: [SidebarFooterMetric] {
    var result = [
      SidebarFooterMetric(kind: .projects, value: summary.projectCount),
      SidebarFooterMetric(kind: .sessions, value: summary.sessionCount),
      SidebarFooterMetric(kind: .openWork, value: summary.openWorkCount),
      SidebarFooterMetric(kind: .blocked, value: summary.blockedCount),
    ]
    if summary.worktreeCount > 0 {
      result.insert(SidebarFooterMetric(kind: .worktrees, value: summary.worktreeCount), at: 1)
    }
    return result
  }

  var body: some View {
    HStack(spacing: Self.spacing) {
      ForEach(metrics, id: \.kind.rawValue) { metric in
        SidebarFooterMetricToken(metric: metric)
      }
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarFooterMetricsFrame)
  }
}

private struct SidebarFooterMetric: Equatable {
  let kind: SidebarFooterMetricKind
  let value: Int
}

private enum SidebarFooterMetricKind: String, CaseIterable {
  case projects
  case worktrees
  case sessions
  case openWork
  case blocked

  var symbolName: String {
    switch self {
    case .projects: "folder.fill"
    case .worktrees: "square.3.layers.3d.down.right"
    case .sessions: "rectangle.stack.fill"
    case .openWork: "checklist"
    case .blocked: "exclamationmark.triangle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .projects: HarnessMonitorTheme.accent
    case .worktrees: HarnessMonitorTheme.warmAccent
    case .sessions: HarnessMonitorTheme.success
    case .openWork: HarnessMonitorTheme.warmAccent
    case .blocked: HarnessMonitorTheme.danger
    }
  }
}

private struct SidebarFooterMetricToken: View {
  let metric: SidebarFooterMetric

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: metric.kind.symbolName)
        .font(.caption.weight(.bold))
        .foregroundStyle(metric.kind.tint)
        .accessibilityHidden(true)

      Text("\(metric.value)")
        .font(.system(.subheadline, design: .rounded, weight: .bold).monospacedDigit())
        .foregroundStyle(metric.kind.tint)
        .contentTransition(.numericText())
    }
    .fixedSize(horizontal: true, vertical: false)
  }
}

#Preview("Sidebar Footer - Live") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SidebarFooterAccessory(
    metrics: store.connectionMetrics,
    summary: SidebarFooterSummary(
      projectCount: store.sidebarUI.projectCount,
      worktreeCount: store.sidebarUI.worktreeCount,
      sessionCount: store.sidebarUI.sessionCount,
      openWorkCount: store.sidebarUI.openWorkCount,
      blockedCount: store.sidebarUI.blockedCount
    )
  )
  .padding(20)
  .frame(width: 280)
}

#Preview("Sidebar Footer - Disconnected") {
  SidebarFooterAccessory(
    metrics: .initial,
    summary: SidebarFooterSummary()
  )
  .padding(20)
  .frame(width: 280)
}
