import SwiftUI

/// Hidden, zero-frame buttons that own the canvas-level Cmd+A, Cmd+C, Cmd+V,
/// Cmd+D, and arrow-key shortcuts for Wave 4J's power-edit operations.
/// Mirrors the pattern the deletion + search shortcut groups already use:
/// SwiftUI's `Button` + `.keyboardShortcut` makes the chord part of the
/// responder chain without an AppKit `NSEvent` monitor, and gating each
/// button on `focusedField != nil` hands the chord back to inline TextFields
/// whenever the user is mid-edit (so Cmd+C in a rename field copies the
/// selected characters rather than the canvas selection).
///
/// Composes alongside Wave 4K's broader inspector editing without conflict:
/// the only shared seam is `focusedField`, which 4K already binds for its
/// inspector text fields. New inspector fields opt in by binding to a
/// `PolicyCanvasFocusedField` variant; the chord gating then handles their
/// keyboard shadow automatically.
struct PolicyCanvasPowerEditShortcuts: View {
  let viewModel: PolicyCanvasViewModel
  @FocusState.Binding var focusedField: PolicyCanvasFocusedField?

  var body: some View {
    Group {
      Button("Select all policy canvas components") {
        viewModel.selectAll()
      }
      .keyboardShortcut("a", modifiers: .command)
      .disabled(focusedField != nil)

      Button("Copy policy canvas selection") {
        viewModel.copySelectionToClipboard()
      }
      .keyboardShortcut("c", modifiers: .command)
      .disabled(focusedField != nil)

      Button("Paste policy canvas selection") {
        viewModel.pasteFromClipboard()
      }
      .keyboardShortcut("v", modifiers: .command)
      .disabled(focusedField != nil)

      Button("Duplicate policy canvas selection") {
        viewModel.duplicateSelection()
      }
      .keyboardShortcut("d", modifiers: .command)
      .disabled(focusedField != nil)

      arrowButtons
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  /// Twelve hidden buttons — four directions x three step sizes (1pt, 10pt,
  /// grid step). SwiftUI's `.keyboardShortcut` overload accepts a single
  /// modifier-set per button so each variant gets its own button; the body
  /// stays readable because `arrowShortcut` does the grunt work.
  private var arrowButtons: some View {
    Group {
      arrowShortcut("Up", key: .upArrow, modifiers: [], dx: 0, dy: -1)
      arrowShortcut("Down", key: .downArrow, modifiers: [], dx: 0, dy: 1)
      arrowShortcut("Left", key: .leftArrow, modifiers: [], dx: -1, dy: 0)
      arrowShortcut("Right", key: .rightArrow, modifiers: [], dx: 1, dy: 0)

      arrowShortcut("Up x10", key: .upArrow, modifiers: .shift, dx: 0, dy: -10)
      arrowShortcut("Down x10", key: .downArrow, modifiers: .shift, dx: 0, dy: 10)
      arrowShortcut("Left x10", key: .leftArrow, modifiers: .shift, dx: -10, dy: 0)
      arrowShortcut("Right x10", key: .rightArrow, modifiers: .shift, dx: 10, dy: 0)

      arrowShortcut(
        "Up grid",
        key: .upArrow,
        modifiers: .command,
        dx: 0,
        dy: -PolicyCanvasLayout.gridSize
      )
      arrowShortcut(
        "Down grid",
        key: .downArrow,
        modifiers: .command,
        dx: 0,
        dy: PolicyCanvasLayout.gridSize
      )
      arrowShortcut(
        "Left grid",
        key: .leftArrow,
        modifiers: .command,
        dx: -PolicyCanvasLayout.gridSize,
        dy: 0
      )
      arrowShortcut(
        "Right grid",
        key: .rightArrow,
        modifiers: .command,
        dx: PolicyCanvasLayout.gridSize,
        dy: 0
      )
    }
  }

  private func arrowShortcut(
    _ label: String,
    key: KeyEquivalent,
    modifiers: EventModifiers,
    dx: CGFloat,
    dy: CGFloat
  ) -> some View {
    Button("Nudge selection \(label)") {
      _ = viewModel.nudgeSelection(by: CGSize(width: dx, height: dy))
    }
    .keyboardShortcut(key, modifiers: modifiers)
    .disabled(focusedField != nil)
  }
}
