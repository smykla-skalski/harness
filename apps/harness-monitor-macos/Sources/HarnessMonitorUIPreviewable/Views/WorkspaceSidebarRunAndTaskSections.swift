import HarnessMonitorKit
import SwiftUI

struct WorkspaceSidebarRunAndTaskSections: View {
  let store: HarnessMonitorStore
  @Binding private var selection: WorkspaceSelection
  let rowPadding: CGFloat
  let currentSessionID: String?
  let codexTitlesByID: [String: String]
  let activeCodexRuns: [CodexRunSnapshot]
  let inactiveCodexRuns: [CodexRunSnapshot]
  let tasks: [WorkItem]

  init(
    store: HarnessMonitorStore,
    selection: Binding<WorkspaceSelection>,
    rowPadding: CGFloat,
    currentSessionID: String?,
    codexTitlesByID: [String: String],
    activeCodexRuns: [CodexRunSnapshot],
    inactiveCodexRuns: [CodexRunSnapshot],
    tasks: [WorkItem]
  ) {
    self.store = store
    _selection = selection
    self.rowPadding = rowPadding
    self.currentSessionID = currentSessionID
    self.codexTitlesByID = codexTitlesByID
    self.activeCodexRuns = activeCodexRuns
    self.inactiveCodexRuns = inactiveCodexRuns
    self.tasks = tasks
  }

  var body: some View {
    if !activeCodexRuns.isEmpty {
      Section("Open Runs") {
        ForEach(activeCodexRuns) { run in
          codexRunRow(run)
        }
      }
    }

    if !inactiveCodexRuns.isEmpty {
      Section("Past Runs") {
        ForEach(inactiveCodexRuns) { run in
          codexRunRow(run)
        }
      }
    }

    if !tasks.isEmpty {
      Section("Tasks") {
        ForEach(tasks, id: \.taskId) { task in
          taskRow(task)
        }
      }
    }
  }

  private func codexRunRow(_ run: CodexRunSnapshot) -> some View {
    CodexRunSidebarRow(
      snapshot: run,
      title: codexTitlesByID[run.runId] ?? "Run"
    )
    .padding(.vertical, rowPadding)
    .tag(WorkspaceSelection.codex(sessionID: run.sessionId, runID: run.runId))
    .harnessMCPTab(
      HarnessMonitorAccessibility.agentTuiTab(run.runId),
      label: codexTitlesByID[run.runId] ?? "Run",
      pressAction: {
        selection = .codex(sessionID: run.sessionId, runID: run.runId)
      }
    )
  }

  private func taskRow(_ task: WorkItem) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "checklist")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      VStack(alignment: .leading, spacing: 2) {
        Text(task.title)
          .scaledFont(.body)
          .lineLimit(2)
        Text("\(task.severity.title) • \(task.status.title)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, rowPadding)
    .tag(WorkspaceSelection.task(sessionID: currentSessionID, taskID: task.taskId))
    .harnessMCPRow(
      HarnessMonitorAccessibility.workspaceTaskTab(task.taskId),
      label: task.title,
      value: "\(task.severity.title) • \(task.status.title)",
      pressAction: {
        selection = .task(sessionID: currentSessionID, taskID: task.taskId)
      }
    )
    .contextMenu {
      Button {
        HarnessMonitorClipboard.copy(task.taskId)
      } label: {
        Label("Copy Task ID", systemImage: "doc.on.doc")
      }
      Divider()
      Button(role: .destructive) {
        guard let currentSessionID else {
          return
        }
        store.requestDeleteTaskConfirmation(
          sessionID: currentSessionID,
          taskID: task.taskId,
          taskTitle: task.title
        )
      } label: {
        Label("Delete Task...", systemImage: "trash")
      }
      .disabled(currentSessionID == nil || !store.areSelectedSessionActionsAvailable)
    }
  }
}
