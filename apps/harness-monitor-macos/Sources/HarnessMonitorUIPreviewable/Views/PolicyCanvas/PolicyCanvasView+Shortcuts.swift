import SwiftUI

/// Hidden keyboard-shortcut buttons mounted as zero-size overlays on the
/// `PolicyCanvasView` body. Split out of `PolicyCanvasView.swift` on touch
/// so the host file lands under the 420-line cap.
///
/// The two groups (`deletionShortcutButtons` + `searchShortcutButtons`) share
/// the same gating convention: when an inspector text field already owns
/// first-responder, the shortcut is suppressed so the field keeps its own
/// chord handling (Delete/Backspace target the character, Escape commits or
/// dismisses, Cmd+F can be claimed by a future inline-find affordance). The
/// buttons render with `.opacity(0)` + 0pt frames + `.accessibilityHidden`
/// so they only contribute keyboard chord wiring.
extension PolicyCanvasView {
  /// Gated on `focusedField == nil`: when the user is editing an inline
  /// TextField in the inspector (rename node, group title, edge label, reason
  /// code, rule id), Delete/Backspace should target the character in the field,
  /// not the selected canvas component; Escape should commit/dismiss the
  /// TextField, not clear the canvas selection mid-typing. SwiftUI's text-field
  /// first responder consumes these keys natively, so disabling the overlay
  /// buttons hands the chord back to the field without an alternate route.
  @ViewBuilder var deletionShortcutButtons: some View {
    Group {
      Button("Delete selected policy component") {
        requestDeleteSelectedComponent()
      }
      .keyboardShortcut(.delete, modifiers: [])
      .disabled(focusedField != nil)

      Button("Forward delete selected policy component") {
        requestDeleteSelectedComponent()
      }
      .keyboardShortcut(.deleteForward, modifiers: [])
      .disabled(focusedField != nil)

      Button("Clear policy canvas selection") {
        clearSelectionAndDragState()
      }
      .keyboardShortcut(.escape, modifiers: [])
      .disabled(focusedField != nil)
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  /// Hidden Cmd+F button that toggles the search palette. Same gating
  /// convention as the deletion shortcuts: when an inspector text field
  /// already owns first-responder, the shortcut is suppressed so a rename
  /// or label edit can still receive its own Cmd+F if a future field opts
  /// into one. The palette itself takes focus via `@FocusState` on appear
  /// and routes Esc back to dismiss through its own Cancel button.
  @ViewBuilder var searchShortcutButtons: some View {
    Button("Toggle policy canvas search palette") {
      searchPaletteVisible.toggle()
    }
    .keyboardShortcut("f", modifiers: .command)
    .disabled(focusedField != nil)
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  func requestDeleteSelectedComponent() {
    pendingDeletionRequest = viewModel.deleteSelectedComponent()
  }

  /// Escape handler. Cancels any pending deletion confirmation, then clears
  /// the editor's selection and any in-flight drag highlight so the canvas
  /// returns to a quiet idle state. Document-side state is untouched —
  /// `documentDirty` survives Escape because the user's edits are still
  /// pending for the next save.
  func clearSelectionAndDragState() {
    if pendingDeletionRequest != nil {
      pendingDeletionRequest = nil
      return
    }
    viewModel.clearSelection()
  }
}
