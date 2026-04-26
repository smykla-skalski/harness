import HarnessMonitorKit
import SwiftUI

struct AgentsSidebar: View {
  @Binding var selection: AgentTuiSheetSelection
  let agentTuis: [AgentTuiSnapshot]
  let sessionTitlesByID: [String: String]
  let codexRuns: [CodexRunSnapshot]
  let codexTitlesByID: [String: String]
  let externalAgents: [AgentRegistration]
  let tasks: [WorkItem]
  let refresh: () -> Void
  @Environment(\.fontScale)
  private var fontScale

  private var rowPadding: CGFloat {
    HarnessMonitorTheme.spacingXS * fontScale
  }

  private var selectionBinding: Binding<AgentTuiSheetSelection?> {
    Binding(
      get: { selection },
      set: { selection = $0 ?? .create }
    )
  }

  private var activeTuis: [AgentTuiSnapshot] {
    agentTuis.filter { $0.status.isActive }
  }

  private var inactiveTuis: [AgentTuiSnapshot] {
    agentTuis.filter { !$0.status.isActive }
  }

  private var activeCodexRuns: [CodexRunSnapshot] {
    codexRuns.filter { $0.status.isActive }
  }

  private var inactiveCodexRuns: [CodexRunSnapshot] {
    codexRuns.filter { !$0.status.isActive }
  }

  var body: some View {
    List(selection: selectionBinding) {
      Label("New", systemImage: "plus.rectangle")
        .scaledFont(.body)
        .padding(.vertical, rowPadding)
        .tag(AgentTuiSheetSelection.create)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiCreateTab)

      if !externalAgents.isEmpty {
        Section("Agents") {
          ForEach(externalAgents) { agent in
            HStack(spacing: HarnessMonitorTheme.spacingSM) {
              Image(systemName: "person.crop.circle")
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                  .scaledFont(.body)
                Text("\(agent.runtime) • \(agent.role.title)")
                  .scaledFont(.caption)
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
              if agent.isAutoSpawned {
                AutoSpawnedBadgeView(agentID: agent.agentId)
                  .allowsHitTesting(false)
              }
            }
            .padding(.vertical, rowPadding)
            .tag(AgentTuiSheetSelection.agent(agent.agentId))
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.agentTuiExternalTab(agent.agentId)
            )
          }
        }
      }

      if !activeTuis.isEmpty {
        Section("Interactive") {
          ForEach(activeTuis) { tui in
            AgentsSidebarRow(
              snapshot: tui,
              title: sessionTitlesByID[tui.tuiId] ?? "Agent session"
            )
            .padding(.vertical, rowPadding)
            .tag(AgentTuiSheetSelection.terminal(tui.tuiId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTab(tui.tuiId))
          }
        }
      }

      if !inactiveTuis.isEmpty {
        Section("Past Terminals") {
          ForEach(inactiveTuis) { tui in
            AgentsSidebarRow(
              snapshot: tui,
              title: sessionTitlesByID[tui.tuiId] ?? "Agent session"
            )
            .padding(.vertical, rowPadding)
            .tag(AgentTuiSheetSelection.terminal(tui.tuiId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTab(tui.tuiId))
          }
        }
      }

      if !activeCodexRuns.isEmpty {
        Section("Codex Threads") {
          ForEach(activeCodexRuns) { run in
            CodexRunSidebarRow(
              snapshot: run,
              title: codexTitlesByID[run.runId] ?? "Codex run"
            )
            .padding(.vertical, rowPadding)
            .tag(AgentTuiSheetSelection.codex(run.runId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTab(run.runId))
          }
        }
      }

      if !inactiveCodexRuns.isEmpty {
        Section("Past Codex Threads") {
          ForEach(inactiveCodexRuns) { run in
            CodexRunSidebarRow(
              snapshot: run,
              title: codexTitlesByID[run.runId] ?? "Codex run"
            )
            .padding(.vertical, rowPadding)
            .tag(AgentTuiSheetSelection.codex(run.runId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTab(run.runId))
          }
        }
      }

      if !tasks.isEmpty {
        Section("Tasks") {
          ForEach(tasks, id: \.taskId) { task in
            HStack(spacing: HarnessMonitorTheme.spacingSM) {
              Image(systemName: "checklist")
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                  .scaledFont(.body)
                  .lineLimit(1)
                Text("\(task.severity.title) • \(task.status.title)")
                  .scaledFont(.caption)
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, rowPadding)
            .tag(AgentTuiSheetSelection.task(task.taskId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentsTaskTab(task.taskId))
          }
        }
      }
    }
    .listStyle(.sidebar)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button(action: refresh) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRefreshButton)
      }
    }
  }
}
