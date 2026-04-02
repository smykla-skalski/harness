import HarnessKit
import SwiftData
import SwiftUI

struct TaskUserNotesSection: View {
  let taskID: String
  let sessionID: String
  let addNote: @MainActor (String, String, String) -> Bool
  let deleteNote: @MainActor (UserNote) -> Void
  @Query private var userNotes: [UserNote]
  @State private var newNoteText = ""
  @FocusState private var isNoteFieldFocused: Bool

  init(
    taskID: String,
    sessionID: String,
    addNote: @escaping @MainActor (String, String, String) -> Bool,
    deleteNote: @escaping @MainActor (UserNote) -> Void
  ) {
    self.taskID = taskID
    self.sessionID = sessionID
    self.addNote = addNote
    self.deleteNote = deleteNote
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
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      if !userNotes.isEmpty {
        VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
          ForEach(userNotes, id: \.persistentModelID) { note in
            HStack(alignment: .top) {
              Text(note.text)
                .scaledFont(.subheadline)
                .foregroundStyle(HarnessTheme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
              Button {
                deleteNote(note)
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .scaledFont(.caption)
                  .foregroundStyle(HarnessTheme.danger)
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
      HStack(spacing: HarnessTheme.itemSpacing) {
        TextField("Add a note", text: $newNoteText)
          .harnessNativeFormControl()
          .focused($isNoteFieldFocused)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.done)
          .accessibilityIdentifier(HarnessAccessibility.taskNoteField)
          .onSubmit { submitNote() }
        Button("Add") { submitNote() }
          .harnessActionButtonStyle(variant: .bordered)
          .accessibilityIdentifier(HarnessAccessibility.taskNoteAddButton)
          .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func submitNote() {
    let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    guard addNote(text, taskID, sessionID) else {
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
      .foregroundStyle(HarnessTheme.secondaryInk)
      .accessibilityIdentifier(HarnessAccessibility.taskNotesUnavailable)
  }
}
