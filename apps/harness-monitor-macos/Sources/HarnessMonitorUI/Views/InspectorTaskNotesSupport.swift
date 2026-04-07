import HarnessMonitorKit
import SwiftData
import SwiftUI

struct TaskUserNotesSection: View {
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
          .accessibilityIdentifier(HarnessMonitorAccessibility.taskNoteField)
          .onSubmit { submitNote() }
        Button("Add") { submitNote() }
          .harnessActionButtonStyle(variant: .bordered)
          .accessibilityIdentifier(HarnessMonitorAccessibility.taskNoteAddButton)
          .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func submitNote() {
    let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    guard store.addNote(
      text: text,
      targetKind: "task",
      targetId: taskID,
      sessionId: sessionID
    ) else {
      return
    }

    newNoteText = ""
    isNoteFieldFocused = false
  }
}

struct PersistenceUnavailableNotesState: View {
  var body: some View {
    Text("Persistent notes are unavailable while the local store is offline.")
      .scaledFont(.subheadline)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .accessibilityIdentifier(HarnessMonitorAccessibility.taskNotesUnavailable)
  }
}
