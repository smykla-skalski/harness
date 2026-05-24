import SwiftUI

/// Inline-rename TextField for `PolicyCanvasInspector`'s "Name" row.
/// Buffers the in-progress edit in local `@State` and commits via the
/// undoable `renameNode(_:to:)` funnel on Enter or when focus leaves the
/// field. Per-keystroke writes intentionally do NOT flow into the funnel
/// — flooding the undo stack with one entry per character would burn the
/// undo budget on a single rename gesture.
///
/// Composes alongside Wave 4K's broader inspector property editing: the
/// rename surface owns the title field and only the title field. 4K's
/// kind / group / policy-action editors keep using their existing
/// per-field bindings on `updateSelectedNodeKind` / `updateSelectedNodeGroup`
/// / `updateSelected*Policy*`. The two seams share `focusedField` and the
/// surrounding `PolicyCanvasInspectorField` row chrome; nothing else.
///
/// Identity is keyed on the node id so a selection change resets the
/// buffer cleanly — without the id key, swapping selection from node A
/// to node B mid-edit would carry A's typed draft into B's TextField.
struct PolicyCanvasInspectorRenameField: View {
  let viewModel: PolicyCanvasViewModel
  let nodeID: String
  let originalTitle: String
  @FocusState.Binding var focusedField: PolicyCanvasFocusedField?
  @State private var draftTitle: String

  init(
    viewModel: PolicyCanvasViewModel,
    nodeID: String,
    originalTitle: String,
    focusedField: FocusState<PolicyCanvasFocusedField?>.Binding
  ) {
    self.viewModel = viewModel
    self.nodeID = nodeID
    self.originalTitle = originalTitle
    self._focusedField = focusedField
    // Seed the draft from the title at mount so the field never paints a
    // blank cell on first appear. The `.onAppear` write was racing the
    // first-frame layout: a fast Tab into the field could land on an
    // empty buffer before the modifier closure fired.
    self._draftTitle = State(initialValue: originalTitle)
  }

  var body: some View {
    TextField("Node name", text: $draftTitle)
      .textFieldStyle(.roundedBorder)
      .scaledFont(.callout)
      .focused($focusedField, equals: .nodeTitle)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("node-title")
      )
      .onSubmit {
        commit()
      }
      .onChange(of: focusedField) { _, newValue in
        // Commit on focus-lost. The TextField's `.onSubmit` fires on Enter
        // (commit-on-Enter), but losing focus by clicking elsewhere does
        // not trigger `.onSubmit`. Without a focus-loss commit the user
        // sees the inspector revert their edits on the next selection
        // change.
        if newValue != .nodeTitle {
          commit()
        }
      }
      .onChange(of: originalTitle) { _, newValue in
        // Re-sync the buffer if the title changes underneath us (e.g.
        // undo lands while the field is focused). Without this guard the
        // user would see their on-screen draft fall out of sync with the
        // model's current title until they refocus the field.
        if focusedField != .nodeTitle {
          draftTitle = newValue
        }
      }
      .onDisappear {
        // The TextField identity is keyed on `nodeID` (see `.id(_:)` at
        // the bottom), so a selection switch — including the shift-click
        // multi-select that drops the inspector's single-node section —
        // tears down this view. Without an `.onDisappear` commit the
        // typed draft would never reach the model. Routes through the
        // same gated commit so an unchanged buffer still no-ops.
        commit()
      }
      .id(nodeID)
  }

  private func commit() {
    let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != originalTitle else {
      // Empty / unchanged: snap the buffer back to the model. This
      // avoids a degenerate undo step and keeps the displayed text
      // stable when the user mashes Enter on an unchanged title.
      draftTitle = originalTitle
      return
    }
    viewModel.renameNode(nodeID, to: trimmed)
  }
}
