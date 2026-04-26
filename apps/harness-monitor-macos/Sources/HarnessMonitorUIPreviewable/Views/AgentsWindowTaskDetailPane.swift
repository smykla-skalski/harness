import HarnessMonitorKit
import SwiftData
import SwiftUI

struct AgentsWindowTaskDetailPane: View {
  let store: HarnessMonitorStore
  let task: WorkItem
  let notesSessionID: String?
  let isPersistenceAvailable: Bool

  private var facts: [InspectorFact] {
    [
      .init(title: "Severity", value: task.severity.title),
      .init(title: "Status", value: task.status.title),
      .init(title: "Assignee", value: task.assignmentSummary),
      .init(title: "Queue Policy", value: task.queuePolicy.title),
      .init(title: "Source", value: task.source.title),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.agentsTaskSelection(task.taskId),
        text: task.taskId
      )
      Text(task.title)
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text(task.context ?? "No task context provided.")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if task.source == .improver {
        ReviewImproverCard(task: task)
      }
      InspectorFactGrid(facts: facts)
      ReviewStatePanel(task: task)
      Button("Manage Task") {
        store.presentedSheet = .taskActions(
          sessionID: store.selectedSessionID ?? "",
          taskID: task.taskId
        )
      }
      .harnessActionButtonStyle(variant: .bordered)
      .accessibilityIdentifier(HarnessMonitorAccessibility.manageTaskOpenButton)
      .disabled(!store.areSelectedSessionActionsAvailable)
      if let checkpoint = task.checkpointSummary {
        InspectorSection(title: "Checkpoint") {
          InspectorFactGrid(
            facts: [
              .init(title: "Progress", value: "\(checkpoint.progress)%"),
              .init(title: "Recorded", value: formatTimestamp(checkpoint.recordedAt)),
            ]
          )
          Text(checkpoint.summary)
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      if let suggestion = task.suggestedFix {
        InspectorSection(title: "Suggested Fix") {
          Text(suggestion)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      if !task.notes.isEmpty {
        InspectorSection(title: "Notes") {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            ForEach(task.notes) { note in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(note.agentId ?? "system")
                    .scaledFont(.caption.bold())
                  Spacer()
                  Text(formatTimestamp(note.timestamp))
                    .scaledFont(.caption.monospaced())
                    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                }
                Text(note.text)
                  .scaledFont(.subheadline)
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              }
              .harnessCellPadding()
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if let blockedReason = task.blockedReason, !blockedReason.isEmpty {
        InspectorSection(title: "Blocked Reason") {
          Text(blockedReason)
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.danger)
        }
      }
      if let completedAt = task.completedAt {
        InspectorSection(title: "Completed") {
          Text(formatTimestamp(completedAt))
            .scaledFont(.subheadline.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      InspectorSection(title: "Your Notes") {
        if let notesSessionID, isPersistenceAvailable {
          AgentsWindowTaskUserNotesSection(
            store: store,
            taskID: task.taskId,
            sessionID: notesSessionID
          )
        } else {
          AgentsWindowTaskPersistenceUnavailableState()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.agentsTaskCard,
      label: task.title,
      value: task.taskId
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.agentsTaskCard).frame")
  }
}

struct AgentsWindowTaskUserNotesSection: View {
  let store: HarnessMonitorStore
  let taskID: String
  let sessionID: String
  @Query private var userNotes: [UserNote]
  @State private var newNoteText = ""
  @FocusState private var isNoteFieldFocused: Bool

  init(
    store: HarnessMonitorStore,
    taskID: String,
    sessionID: String
  ) {
    self.store = store
    self.taskID = taskID
    self.sessionID = sessionID
    let targetKind = "task"
    let targetID = taskID
    let selectedSessionID = sessionID
    _userNotes = Query(
      filter: #Predicate<UserNote> { note in
        note.targetKind == targetKind
          && note.targetId == targetID
          && note.sessionId == selectedSessionID
      },
      sort: [SortDescriptor(\UserNote.createdAt, order: .reverse)]
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      if !userNotes.isEmpty {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          ForEach(userNotes, id: \.persistentModelID) { note in
            HStack(alignment: .top) {
              Text(note.text)
                .scaledFont(.subheadline)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
              Button {
                _ = store.deleteNote(note)
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .scaledFont(.caption)
                  .foregroundStyle(HarnessMonitorTheme.danger)
                  .frame(minWidth: 24, minHeight: 24)
                  .contentShape(Rectangle())
              }
              .accessibilityLabel("Delete Note")
              .accessibilityHint("Removes this note from the selected task.")
              .help("Delete note")
              .harnessDismissButtonStyle()
            }
            .harnessCellPadding()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        TextField("Add a note", text: $newNoteText)
          .harnessNativeFormControl()
          .focused($isNoteFieldFocused)
          .submitLabel(.done)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsTaskNoteField)
          .onSubmit { submitNote() }
        Button("Add") { submitNote() }
          .harnessActionButtonStyle(variant: .bordered)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsTaskNoteAddButton)
          .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func submitNote() {
    let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    guard
      store.addNote(
        text: text,
        targetKind: "task",
        targetId: taskID,
        sessionId: sessionID
      )
    else {
      return
    }

    newNoteText = ""
    isNoteFieldFocused = false
  }
}

struct AgentsWindowTaskPersistenceUnavailableState: View {
  var body: some View {
    Text("Persistent notes are unavailable while the local store is offline.")
      .scaledFont(.subheadline)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentsTaskNotesUnavailable)
  }
}
