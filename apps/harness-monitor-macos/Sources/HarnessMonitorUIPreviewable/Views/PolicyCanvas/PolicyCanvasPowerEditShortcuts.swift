import SwiftUI

/// Native SwiftUI key-press routing for the canvas-level power-edit
/// shortcuts (Cmd+A, Cmd+C, Cmd+V, Cmd+D, arrow nudges). Replaces the
/// previous 17-Button overlay pattern: the responder chain has one
/// focused-view-aware key handler instead of seventeen invisible Buttons
/// that each match per keypress.
///
/// `.onKeyPress` is a real SwiftUI API (macOS 13+) that hooks into the
/// responder chain without an NSEvent monitor. When an inline TextField
/// owns first responder, the field consumes the key and the canvas-level
/// handler is suppressed automatically (and we double-gate on
/// `focusedField` for defence in depth so a key chord routed from a
/// non-text focusable child still falls back to the inspector field). The
/// `phases: .down` filter keeps us off key-up; arrow nudges add `.repeat`
/// so a held arrow auto-repeats at the OS-native rate without an internal
/// timer.
///
/// Composes alongside Wave 4K's broader inspector editing without conflict:
/// the only shared seam is `focusedField`, which 4K already binds for its
/// inspector text fields. New inspector fields opt in by binding to a
/// `PolicyCanvasFocusedField` variant; the chord gating then suppresses
/// the canvas-level keys whenever a TextField owns first responder.
struct PolicyCanvasPowerEditShortcuts: ViewModifier {
  let viewModel: PolicyCanvasViewModel
  @FocusState.Binding var focusedField: PolicyCanvasFocusedField?

  func body(content: Content) -> some View {
    content
      .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
        handleArrow(dx: 0, dy: -1, modifiers: press.modifiers)
      }
      .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
        handleArrow(dx: 0, dy: 1, modifiers: press.modifiers)
      }
      .onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in
        handleArrow(dx: -1, dy: 0, modifiers: press.modifiers)
      }
      .onKeyPress(.rightArrow, phases: [.down, .repeat]) { press in
        handleArrow(dx: 1, dy: 0, modifiers: press.modifiers)
      }
      .onKeyPress(keys: ["a", "c", "v", "d"], phases: .down) { press in
        handleChord(press: press)
      }
  }

  /// Resolve modifier presses into the right nudge step and dispatch
  /// through the view model. Returns `.handled` only when the nudge
  /// actually moved something — otherwise the press falls through to the
  /// next responder so a no-op press on an empty selection still lets the
  /// scrollview / focus ring own arrow keys.
  private func handleArrow(
    dx: CGFloat,
    dy: CGFloat,
    modifiers: EventModifiers
  ) -> KeyPress.Result {
    guard focusedField == nil else {
      return .ignored
    }
    let step: CGFloat
    if modifiers.contains(.command) {
      step = PolicyCanvasLayout.gridSize
    } else if modifiers.contains(.shift) {
      step = 10
    } else {
      step = PolicyCanvasViewModel.bareArrowNudgeStep
    }
    let moved = viewModel.nudgeSelection(
      by: CGSize(width: dx * step, height: dy * step)
    )
    return moved ? .handled : .ignored
  }

  /// Cmd+A / Cmd+C / Cmd+V / Cmd+D dispatch. Non-Cmd presses of these
  /// letters fall through; we only intercept the chord. Suppressed when an
  /// inspector text field owns focus so paste in the rename field still
  /// works against the system clipboard.
  private func handleChord(press: KeyPress) -> KeyPress.Result {
    guard focusedField == nil, press.modifiers.contains(.command) else {
      return .ignored
    }
    switch press.characters {
    case "a":
      viewModel.selectAll()
      return .handled
    case "c":
      _ = viewModel.copySelectionToClipboard()
      return .handled
    case "v":
      _ = viewModel.pasteFromClipboard()
      return .handled
    case "d":
      _ = viewModel.duplicateSelection()
      return .handled
    default:
      return .ignored
    }
  }
}

extension View {
  /// Wrap the canvas root with the power-edit key handler. Sugar so the
  /// host view's `body` does not need to spell the modifier struct.
  func policyCanvasPowerEditShortcuts(
    viewModel: PolicyCanvasViewModel,
    focusedField: FocusState<PolicyCanvasFocusedField?>.Binding
  ) -> some View {
    modifier(
      PolicyCanvasPowerEditShortcuts(
        viewModel: viewModel,
        focusedField: focusedField
      )
    )
  }
}
