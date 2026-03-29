import HarnessMonitorKit
import SwiftUI

struct SessionMetricGrid: View {
  let metrics: SessionMetrics

  var body: some View {
    MonitorAdaptiveGridLayout(minimumColumnWidth: 130, maximumColumns: 5, spacing: 14) {
      metricCard(title: "Agents", value: "\(metrics.agentCount)", tint: MonitorTheme.accent)
      metricCard(title: "Active", value: "\(metrics.activeAgentCount)", tint: MonitorTheme.success)
      metricCard(
        title: "In Flight",
        value: "\(metrics.inProgressTaskCount)",
        tint: MonitorTheme.warmAccent
      )
      metricCard(title: "Blocked", value: "\(metrics.blockedTaskCount)", tint: MonitorTheme.danger)
      metricCard(title: "Completed", value: "\(metrics.completedTaskCount)", tint: MonitorTheme.ink)
    }
  }

  private func metricCard(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 28, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard(minHeight: 80)
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
      ForEach(tasks) { task in
        SessionTaskSummaryCard(task: task) {
          onSelect(task.taskId)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .monitorCard()
  }
}

struct SessionTaskSummaryCard: View {
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
          Text(task.severity.rawValue.capitalized)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(severityColor(for: task.severity), in: Capsule())
            .foregroundStyle(.white)
        }
        Text(task.context ?? "No extra context")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .lineLimit(2)
        Spacer(minLength: 0)
        HStack(alignment: .firstTextBaseline) {
          Text(task.status.rawValue)
            .font(.caption.weight(.bold))
            .foregroundStyle(taskStatusColor(for: task.status))
          Spacer()
          Text(task.assignedTo ?? "unassigned")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, minHeight: sessionLaneCardHeight, alignment: .topLeading)
      .padding(14)
      .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(MonitorAccessibility.sessionTaskCard(task.taskId))
  }
}

struct SessionAgentListSection: View {
  let agents: [AgentRegistration]
  let onSelect: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Agents")
        .font(.system(.title3, design: .serif, weight: .semibold))
      ForEach(agents) { agent in
        SessionAgentSummaryCard(agent: agent) {
          onSelect(agent.agentId)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .monitorCard()
  }
}

struct SessionAgentSummaryCard: View {
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
          Text(agent.role.rawValue.capitalized)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(MonitorTheme.accent, in: Capsule())
            .foregroundStyle(.white)
        }
        Text("\(agent.runtime) • \(agent.agentId)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
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
      .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(MonitorAccessibility.sessionAgentCard(agent.agentId))
  }

  private func badge(_ value: String) -> some View {
    Text(value)
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(MonitorTheme.surfaceHover, in: Capsule())
  }
}
