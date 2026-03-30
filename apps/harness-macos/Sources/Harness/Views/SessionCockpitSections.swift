import HarnessKit
import SwiftUI

struct SessionMetricGrid: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let metrics: SessionMetrics

  var body: some View {
    HarnessGlassContainer(spacing: 14) {
      HarnessAdaptiveGridLayout(minimumColumnWidth: 130, maximumColumns: 5, spacing: 14) {
        metricCard(
          title: "Agents",
          value: "\(metrics.agentCount)",
          tint: HarnessTheme.accent(for: themeStyle)
        )
        metricCard(title: "Active", value: "\(metrics.activeAgentCount)", tint: HarnessTheme.success)
        metricCard(
          title: "In Flight",
          value: "\(metrics.inProgressTaskCount)",
          tint: HarnessTheme.warmAccent
        )
        metricCard(title: "Blocked", value: "\(metrics.blockedTaskCount)", tint: HarnessTheme.danger)
        metricCard(title: "Completed", value: "\(metrics.completedTaskCount)", tint: HarnessTheme.ink)
      }
    }
  }

  private func metricCard(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(HarnessTheme.secondaryInk)
      Text(value)
        .font(.system(size: 28, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCard(minHeight: 80)
  }
}

private let sessionLaneCardHeight: CGFloat = 116

struct SessionTaskListSection: View {
  let tasks: [WorkItem]
  let onSelect: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Tasks")
        .font(.system(.title3, design: .serif, weight: .semibold))
      HarnessGlassContainer(spacing: 12) {
        ForEach(tasks) { task in
          SessionTaskSummaryCard(task: task) {
            onSelect(task.taskId)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .harnessCard()
  }
}

struct SessionTaskSummaryCard: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let task: WorkItem
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top) {
          Text(task.title)
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .lineLimit(2)
          Spacer()
          Text(task.severity.title)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(severityColor(for: task.severity, style: themeStyle), in: Capsule())
            .foregroundStyle(.white)
        }
        Text(task.context ?? "No extra context")
          .font(.subheadline)
          .foregroundStyle(HarnessTheme.secondaryInk)
          .multilineTextAlignment(.leading)
          .lineLimit(2)
        Spacer(minLength: 0)
        HStack(alignment: .firstTextBaseline) {
          Text(task.status.title)
            .font(.caption.weight(.bold))
            .foregroundStyle(taskStatusColor(for: task.status, style: themeStyle))
          Spacer()
          Text(task.assignedTo ?? "unassigned")
            .font(.caption.monospaced())
            .foregroundStyle(HarnessTheme.secondaryInk)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, minHeight: sessionLaneCardHeight, alignment: .topLeading)
      .padding(14)
    }
    .harnessInteractiveCardButtonStyle()
    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityIdentifier(HarnessAccessibility.sessionTaskCard(task.taskId))
    .accessibilityFrameMarker("\(HarnessAccessibility.sessionTaskCard(task.taskId)).frame")
    .transition(
      .asymmetric(
        insertion: .scale(scale: 0.95).combined(with: .opacity),
        removal: .opacity
      ))
  }
}

struct SessionAgentListSection: View {
  let agents: [AgentRegistration]
  let onSelect: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Agents")
        .font(.system(.title3, design: .serif, weight: .semibold))
      HarnessGlassContainer(spacing: 12) {
        ForEach(agents) { agent in
          SessionAgentSummaryCard(agent: agent) {
            onSelect(agent.agentId)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .harnessCard()
  }
}

struct SessionAgentSummaryCard: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let agent: AgentRegistration
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top) {
          Text(agent.name)
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .lineLimit(2)
          Spacer()
          Text(agent.role.title)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(HarnessTheme.accent(for: themeStyle), in: Capsule())
            .foregroundStyle(.white)
        }
        Text("\(agent.runtime) • \(agent.agentId)")
          .font(.caption.monospaced())
          .foregroundStyle(HarnessTheme.secondaryInk)
          .lineLimit(1)
        Spacer(minLength: 0)
        HStack(spacing: 10) {
          badge(agent.runtimeCapabilities.supportsContextInjection ? "Context" : "Watch")
          badge("\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s")
          badge(formatTimestamp(agent.lastActivityAt))
        }
      }
      .frame(maxWidth: .infinity, minHeight: sessionLaneCardHeight, alignment: .topLeading)
      .padding(14)
    }
    .harnessInteractiveCardButtonStyle()
    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityIdentifier(HarnessAccessibility.sessionAgentCard(agent.agentId))
    .accessibilityFrameMarker("\(HarnessAccessibility.sessionAgentCard(agent.agentId)).frame")
    .transition(
      .asymmetric(
        insertion: .scale(scale: 0.95).combined(with: .opacity),
        removal: .opacity
      ))
  }

  private func badge(_ value: String) -> some View {
    Text(value)
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background {
        HarnessGlassCapsuleBackground()
      }
  }
}
