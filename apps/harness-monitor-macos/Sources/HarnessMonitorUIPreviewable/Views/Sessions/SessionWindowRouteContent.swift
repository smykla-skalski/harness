import HarnessMonitorKit
import SwiftUI

struct SessionWindowRouteContentMetrics: Equatable {
  let contentPadding: CGFloat
  let overviewSpacing: CGFloat
  let gridHorizontalSpacing: CGFloat
  let gridVerticalSpacing: CGFloat
  let rowTextSpacing: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    contentPadding = 24 * min(scale, 1.3)
    overviewSpacing = 16 * min(scale, 1.35)
    gridHorizontalSpacing = 24 * min(scale, 1.25)
    gridVerticalSpacing = 10 * min(scale, 1.35)
    rowTextSpacing = 2 * min(scale, 1.45)
  }
}

struct SessionWindowOverview: View {
  let snapshot: HarnessMonitorSessionWindowSnapshot
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: metrics.contentPadding,
      verticalPadding: metrics.contentPadding,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.sessionCockpitScrollView,
      scrollSurfaceLabel: "Session overview"
    ) {
      VStack(alignment: .leading, spacing: metrics.overviewSpacing) {
        Text(snapshot.summary.displayTitle)
          .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        Grid(
          alignment: .leading,
          horizontalSpacing: metrics.gridHorizontalSpacing,
          verticalSpacing: metrics.gridVerticalSpacing
        ) {
          metric("Status", snapshot.summary.status.title)
          metric("Project", snapshot.summary.projectName)
          metric("Worktree", snapshot.summary.worktreeDisplayName)
          metric("Agents", "\(agentCount)")
          metric("Open tasks", "\(snapshot.summary.metrics.openTaskCount)")
          metric("Source", snapshot.source.rawValue)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func metric(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title)
        .scaledFont(.body)
        .foregroundStyle(.secondary)
      Text(value)
        .scaledFont(.body)
        .textSelection(.enabled)
    }
  }

  private var agentCount: Int {
    snapshot.detail?.agents.count ?? snapshot.summary.metrics.agentCount
  }
}

struct SessionWindowAgentsList: View {
  let detail: SessionDetail?
  @Bindable var state: SessionWindowStateCache
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  private var selectedAgentID: Binding<String?> {
    Binding(
      get: { state.selection.agentID },
      set: { agentID in
        guard let agentID, agentID != state.selection.agentID else { return }
        state.selectAgent(agentID)
      }
    )
  }

  var body: some View {
    List(selection: selectedAgentID) {
      Section("Agents") {
        if let agents = detail?.agents, !agents.isEmpty {
          ForEach(agents) { agent in
            Label {
              VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
                Text(agent.name)
                  .scaledFont(.body)
                Text("\(agent.role.title) - \(agent.runtime) - \(agent.agentId)")
                  .scaledFont(.caption)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "person.crop.circle")
            }
            .tag(agent.agentId)
          }
        } else {
          ContentUnavailableView("No Agents", systemImage: "person.3")
        }
      }
    }
    .listStyle(.inset)
  }
}

struct SessionWindowTasksList: View {
  let detail: SessionDetail?
  @Bindable var state: SessionWindowStateCache
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  private var selectedTaskID: Binding<String?> {
    Binding(
      get: { state.selection.taskID },
      set: { taskID in
        guard let taskID, taskID != state.selection.taskID else { return }
        state.selectTask(taskID)
      }
    )
  }

  var body: some View {
    List(selection: selectedTaskID) {
      Section("Tasks") {
        if let tasks = detail?.tasks, !tasks.isEmpty {
          ForEach(tasks) { task in
            Label {
              VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
                Text(task.title)
                  .scaledFont(.body)
                Text("\(task.status.title) - \(task.severity.title)")
                  .scaledFont(.caption)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "checklist")
            }
            .tag(task.taskId)
          }
        } else {
          ContentUnavailableView("No Tasks", systemImage: "checklist")
        }
      }
    }
    .listStyle(.inset)
  }
}

struct SessionWindowDecisionsList: View {
  let decisions: [Decision]
  @Bindable var state: SessionWindowStateCache
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  private var selectedDecisionID: Binding<String?> {
    Binding(
      get: { state.selection.decisionID },
      set: { decisionID in
        guard let decisionID, decisionID != state.selection.decisionID else { return }
        state.selectDecision(decisionID)
      }
    )
  }

  var body: some View {
    List(selection: selectedDecisionID) {
      ForEach(decisions) { decision in
        VStack(alignment: .leading, spacing: metrics.rowTextSpacing) {
          Text(decision.summary)
            .scaledFont(.body)
            .lineLimit(1)
          Text(decision.ruleID)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
        .tag(decision.id)
      }
    }
    .listStyle(.inset)
  }
}

struct SessionWindowRunsList: View {
  let detail: SessionDetail?
  @Bindable var state: SessionWindowStateCache

  private var selectedAgentID: Binding<String?> {
    Binding(
      get: { state.selection.agentID },
      set: { agentID in
        guard let agentID, agentID != state.selection.agentID else { return }
        state.selectAgent(agentID)
      }
    )
  }

  var body: some View {
    List(selection: selectedAgentID) {
      Section("Terminal/Runs") {
        if let agents = detail?.agents, !agents.isEmpty {
          ForEach(agents) { agent in
            Label(agent.name, systemImage: "terminal")
              .tag(agent.agentId)
          }
        } else {
          ContentUnavailableView("No Terminal Sessions", systemImage: "terminal")
        }
      }
    }
    .listStyle(.inset)
  }
}

public struct DecisionDetailSummary: View {
  let decision: Decision
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionWindowRouteContentMetrics {
    SessionWindowRouteContentMetrics(fontScale: fontScale)
  }

  public init(decision: Decision) {
    self.decision = decision
  }

  public var body: some View {
    Form {
      LabeledContent("Summary", value: decision.summary)
      LabeledContent("Rule", value: decision.ruleID)
      LabeledContent("Severity", value: decision.severityRaw)
      if let agentID = decision.agentID {
        LabeledContent("Agent", value: agentID)
      }
      if let taskID = decision.taskID {
        LabeledContent("Task", value: taskID)
      }
    }
    .formStyle(.grouped)
    .padding(metrics.contentPadding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
  }
}
