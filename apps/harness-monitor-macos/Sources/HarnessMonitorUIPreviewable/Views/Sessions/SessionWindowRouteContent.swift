import HarnessMonitorKit
import SwiftUI

struct SessionWindowOverview: View {
  let snapshot: HarnessMonitorSessionWindowSnapshot

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.sessionCockpitScrollView,
      scrollSurfaceLabel: "Session overview"
    ) {
      VStack(alignment: .leading, spacing: 16) {
        Text(snapshot.summary.displayTitle)
          .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
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
        .foregroundStyle(.secondary)
      Text(value)
        .textSelection(.enabled)
    }
  }

  private var agentCount: Int {
    snapshot.detail?.agents.count ?? snapshot.summary.metrics.agentCount
  }
}

struct SessionWindowAgentsList: View {
  let detail: SessionDetail?

  var body: some View {
    sessionListSurface("Agents") {
      if let agents = detail?.agents, !agents.isEmpty {
        ForEach(agents) { agent in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(agent.name)
              Text("\(agent.role.title) - \(agent.runtime) - \(agent.agentId)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "person.crop.circle")
          }
        }
      } else {
        ContentUnavailableView("No Agents", systemImage: "person.3")
      }
    }
  }
}

struct SessionWindowTasksList: View {
  let detail: SessionDetail?

  var body: some View {
    sessionListSurface("Tasks") {
      if let tasks = detail?.tasks, !tasks.isEmpty {
        ForEach(tasks) { task in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(task.title)
              Text("\(task.status.title) - \(task.severity.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "checklist")
          }
        }
      } else {
        ContentUnavailableView("No Tasks", systemImage: "checklist")
      }
    }
  }
}

struct SessionWindowDecisionsList: View {
  let decisions: [Decision]
  @Bindable var state: SessionWindowStateCache

  var body: some View {
    List(selection: decisionBinding) {
      ForEach(decisions) { decision in
        VStack(alignment: .leading, spacing: 2) {
          Text(decision.summary)
            .lineLimit(1)
          Text(decision.ruleID)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .tag(decision.id)
      }
    }
    .listStyle(.inset)
  }

  private var decisionBinding: Binding<String?> {
    Binding(
      get: { state.selection.decisionID },
      set: { decisionID in
        guard let decisionID else { return }
        state.selectDecision(decisionID)
      }
    )
  }
}

struct SessionWindowRunsList: View {
  let detail: SessionDetail?

  var body: some View {
    sessionListSurface("Terminal/Runs") {
      if let agents = detail?.agents, !agents.isEmpty {
        ForEach(agents) { agent in
          Label(agent.name, systemImage: "terminal")
        }
      } else {
        ContentUnavailableView("No Terminal Sessions", systemImage: "terminal")
      }
    }
  }
}

public struct DecisionDetailSummary: View {
  let decision: Decision

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
    .padding(24)
  }
}

@MainActor
func sessionListSurface<Content: View>(
  _ title: String,
  @ViewBuilder content: () -> Content
) -> some View {
  List {
    Section(title) {
      content()
    }
  }
  .listStyle(.inset)
}
