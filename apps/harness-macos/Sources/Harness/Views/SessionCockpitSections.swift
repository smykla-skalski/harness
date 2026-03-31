import HarnessKit
import SwiftUI

struct SessionMetricGrid: View {
  let metrics: SessionMetrics

  var body: some View {
    HarnessAdaptiveGridLayout(minimumColumnWidth: 130, maximumColumns: 5, spacing: 14) {
      metricCard(
        title: "Agents",
        value: "\(metrics.agentCount)",
        tint: HarnessTheme.accent
      )
      metricCard(
        title: "Active", value: "\(metrics.activeAgentCount)", tint: HarnessTheme.success)
      metricCard(
        title: "In Flight",
        value: "\(metrics.inProgressTaskCount)",
        tint: HarnessTheme.warmAccent
      )
      metricCard(
        title: "Blocked", value: "\(metrics.blockedTaskCount)", tint: HarnessTheme.danger)
      metricCard(
        title: "Completed", value: "\(metrics.completedTaskCount)", tint: HarnessTheme.ink)
    }
    .animation(.spring(duration: 0.3), value: metrics)
  }

  private func metricCard(title: String, value: String, tint: Color) -> some View {
    HStack(alignment: .top, spacing: 12) {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(tint)
        .frame(width: 10)
        .frame(minHeight: 60)
        .accessibilityHidden(true)
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
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }
}

private let sessionLaneCardHeight: CGFloat = 116

struct SessionTaskListSection: View {
  let tasks: [WorkItem]
  let store: HarnessStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Tasks")
        .font(.system(.title3, design: .rounded, weight: .semibold))
      VStack(alignment: .leading, spacing: 12) {
        ForEach(tasks) { task in
          SessionTaskSummaryCard(task: task, store: store)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct SessionTaskSummaryCard: View {
  let task: WorkItem
  let store: HarnessStore

  var body: some View {
    Button { store.inspect(taskID: task.taskId) } label: {
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
            .background(severityColor(for: task.severity), in: Capsule())
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
            .foregroundStyle(taskStatusColor(for: task.status))
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
  let store: HarnessStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Agents")
        .font(.system(.title3, design: .rounded, weight: .semibold))
      VStack(alignment: .leading, spacing: 12) {
        ForEach(agents) { agent in
          SessionAgentSummaryCard(agent: agent, store: store)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct SessionAgentSummaryCard: View {
  let agent: AgentRegistration
  let store: HarnessStore

  var body: some View {
    Button { store.inspect(agentID: agent.agentId) } label: {
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
            .background(HarnessTheme.accent, in: Capsule())
            .foregroundStyle(.white)
        }
        Text("\(agent.runtime) • \(agent.agentId)")
          .font(.caption.monospaced())
          .foregroundStyle(HarnessTheme.secondaryInk)
          .lineLimit(1)
        Spacer(minLength: 0)
        HarnessGlassContainer(spacing: 10) {
          HStack(spacing: 10) {
            badge(agent.runtimeCapabilities.supportsContextInjection ? "Context" : "Watch")
            badge("\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s")
            badge(formatTimestamp(agent.lastActivityAt))
          }
        }
      }
      .frame(maxWidth: .infinity, minHeight: sessionLaneCardHeight, alignment: .topLeading)
      .padding(14)
    }
    .harnessInteractiveCardButtonStyle()
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
      .harnessCapsuleGlass()
  }
}
