import HarnessKit
import SwiftUI

struct SessionMetricGrid: View {
  let metrics: SessionMetrics
  @ScaledMetric(relativeTo: .caption)
  private var barWidth: CGFloat = 8
  @ScaledMetric(relativeTo: .title)
  private var cardMinHeight: CGFloat = 60

  var body: some View {
    HarnessAdaptiveGridLayout(
      minimumColumnWidth: 130,
      maximumColumns: 5,
      spacing: HarnessTheme.sectionSpacing
    ) {
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
    HStack(alignment: .top, spacing: HarnessTheme.sectionSpacing) {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(tint)
        .frame(width: barWidth)
        .frame(minHeight: cardMinHeight)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        Text(title.uppercased())
          .font(.caption.weight(.semibold))
          .tracking(HarnessTheme.uppercaseTracking)
          .foregroundStyle(HarnessTheme.secondaryInk)
        Text(value)
          .font(.system(.title, design: .rounded, weight: .heavy))
          .foregroundStyle(tint)
          .contentTransition(.numericText())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, HarnessTheme.itemSpacing)
  }
}

private let sessionLaneCardHeight: CGFloat = 116

struct SessionTaskListSection: View {
  let tasks: [WorkItem]
  let store: HarnessStore

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text("Tasks")
        .font(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if tasks.isEmpty {
        ContentUnavailableView {
          Label("No tasks yet", systemImage: "checklist")
        } description: {
          Text("Create a task from the Action Console in the inspector.")
        }
      } else {
        VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
          ForEach(tasks) { task in
            SessionTaskSummaryCard(task: task, store: store)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct SessionTaskSummaryCard: View {
  let task: WorkItem
  let store: HarnessStore

  var body: some View {
    Button { store.inspect(taskID: task.taskId) } label: {
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        HStack(alignment: .top) {
          Text(task.title)
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .lineLimit(2)
          Spacer()
          Text(task.severity.title)
            .font(.caption.bold())
            .harnessPillPadding()
            .background(severityColor(for: task.severity), in: Capsule())
            .foregroundStyle(HarnessTheme.onContrast)
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
      .padding(HarnessTheme.cardPadding)
    }
    .harnessInteractiveCardButtonStyle()
    .contextMenu {
      Button { store.inspect(taskID: task.taskId) } label: {
        Label("Inspect", systemImage: "info.circle")
      }
      Divider()
      Button { copyToClipboard(task.taskId) } label: {
        Label("Copy Task ID", systemImage: "doc.on.doc")
      }
    }
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
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text("Agents")
        .font(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if agents.isEmpty {
        ContentUnavailableView {
          Label("No agents registered", systemImage: "person.2")
        } description: {
          Text("Agents appear here when they join the session.")
        }
      } else {
        VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
          ForEach(agents) { agent in
            SessionAgentSummaryCard(agent: agent, store: store)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct SessionAgentSummaryCard: View {
  let agent: AgentRegistration
  let store: HarnessStore

  var body: some View {
    Button { store.inspect(agentID: agent.agentId) } label: {
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        HStack(alignment: .top) {
          Text(agent.name)
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .lineLimit(2)
          Spacer()
          Text(agent.role.title)
            .font(.caption.bold())
            .harnessPillPadding()
            .background(HarnessTheme.accent, in: Capsule())
            .foregroundStyle(HarnessTheme.onContrast)
        }
        Text("\(agent.runtime) • \(agent.agentId)")
          .font(.caption.monospaced())
          .foregroundStyle(HarnessTheme.secondaryInk)
          .lineLimit(1)
        Spacer(minLength: 0)
        HStack(spacing: HarnessTheme.itemSpacing) {
          badge(agent.runtimeCapabilities.supportsContextInjection ? "Context" : "Watch")
          badge("\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s")
          badge(formatTimestamp(agent.lastActivityAt))
        }
      }
      .frame(maxWidth: .infinity, minHeight: sessionLaneCardHeight, alignment: .topLeading)
      .padding(HarnessTheme.cardPadding)
    }
    .harnessInteractiveCardButtonStyle()
    .contextMenu {
      Button { store.inspect(agentID: agent.agentId) } label: {
        Label("Inspect", systemImage: "info.circle")
      }
      Divider()
      Button { copyToClipboard(agent.agentId) } label: {
        Label("Copy Agent ID", systemImage: "doc.on.doc")
      }
    }
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
      .harnessPillPadding()
      .harnessInfoPill()
  }
}

private func copyToClipboard(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}
