import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels
import SwiftUI

struct PolicyCanvasInspectorSection<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .scaledFont(.caption.weight(.bold))
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .textCase(.uppercase)

      VStack(alignment: .leading, spacing: 8) {
        content
      }
      .padding(10)
      .background(
        PolicyCanvasVisualStyle.fieldSurface,
        in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
      )
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
          .stroke(PolicyCanvasVisualStyle.subtleBorder, lineWidth: 1)
      }
    }
  }
}

struct PolicyCanvasInspectorField<Content: View>: View {
  let label: String
  let content: Content

  init(label: String, @ViewBuilder content: () -> Content) {
    self.label = label
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      // P29 contrast: white at 0.78 reads ~5.6:1 on the inspector `#14171F`
      // background and clears WCAG AA for small body text; 0.70 (~4.4:1)
      // was below the per-Wave-3G contrast bar.
      Text(label)
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      content
    }
  }
}

struct PolicyCanvasInspectorRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .scaledFont(.caption)
        // P29 contrast bump (0.70 -> 0.78) matches the field-label rule above.
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .frame(width: 68, alignment: .leading)

      Text(value)
        .scaledFont(.caption.weight(.medium))
        // Primary value text on the inspector card stays at 0.92 to keep
        // emphasis between label and value while clearing the AA bar.
        .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension PolicyAction {
  var policyCanvasTitle: String {
    rawValue.replacingOccurrences(of: "_", with: " ")
  }
}

extension PolicyEvidenceField {
  var policyCanvasTitle: String {
    rawValue.replacingOccurrences(of: "_", with: " ")
  }
}

extension PolicyEvidencePredicate {
  var policyCanvasTitle: String {
    switch self {
    case .isTrue: "is true"
    case .isFalse: "is false"
    case .isZero: "is zero"
    case .isPositive: "is positive"
    case .isPresent: "is present"
    case .isMissing: "is missing"
    }
  }
}

extension PolicyCanvasGroupTone {
  var policyCanvasTitle: String {
    switch self {
    case .intake:
      "Intake"
    case .evaluation:
      "Evaluation"
    case .release:
      "Release"
    }
  }
}

/// Inspector text field that keeps per-keystroke writes local @State and
/// commits the resulting string back through `commit` only on Enter or
/// focus-loss. Escape reverts the field to the bound external `value` and
/// drops focus without committing. Wave 4K (P08) uses this for every
/// editable property in the inspector so the undo stack carries one entry
/// per committed edit, not one per character.
///
/// The field syncs `text` from `value` whenever the bound value changes
/// while the field is unfocused — so external mutations (selection change,
/// undo from elsewhere) propagate without stomping the user's in-progress
/// edit. The wrapper also takes a `label` parameter and applies it as the
/// accessible name so VoiceOver announces "Name", "Subtitle", "Condition"
/// rather than the placeholder string — the visible `Text(label)` in
/// `PolicyCanvasInspectorField` is purely visual and not auto-associated
/// with the contained TextField.
struct PolicyCanvasInspectorCommitTextField: View {
  let label: String
  let placeholder: String
  let value: String
  let focusField: PolicyCanvasFocusedField
  @FocusState.Binding var focusedField: PolicyCanvasFocusedField?
  let commit: (String) -> Void
  let accessibilityIdentifier: String
  @State private var draft: String

  init(
    label: String,
    placeholder: String,
    value: String,
    focusField: PolicyCanvasFocusedField,
    focusedField: FocusState<PolicyCanvasFocusedField?>.Binding,
    accessibilityIdentifier: String,
    commit: @escaping (String) -> Void
  ) {
    self.label = label
    self.placeholder = placeholder
    self.value = value
    self.focusField = focusField
    self._focusedField = focusedField
    self.commit = commit
    self.accessibilityIdentifier = accessibilityIdentifier
    self._draft = State(initialValue: value)
  }

  var body: some View {
    TextField(placeholder, text: $draft)
      .textFieldStyle(.roundedBorder)
      .scaledFont(.callout)
      .focused($focusedField, equals: focusField)
      .accessibilityLabel(label)
      .accessibilityIdentifier(accessibilityIdentifier)
      .onSubmit {
        if draft != value {
          commit(draft)
        }
        focusedField = nil
      }
      .onKeyPress(.escape) {
        // Revert to the current external `value` rather than a captured
        // init snapshot: an external write (selection change, undo) may
        // have legitimately changed the bound value during the edit, and
        // restoring a stale init snapshot would silently overwrite that
        // change.
        let hadPendingEdit = draft != value
        draft = value
        focusedField = nil
        if hadPendingEdit {
          AccessibilityNotification.Announcement("Edit discarded").post()
        }
        return .handled
      }
      .onChange(of: focusedField) { _, newValue in
        // Commit-on-focus-loss: when focus moves away from this field's
        // identity (either to nil or to a different inspector field), land
        // the latest draft through `commit`. We compare against `value`
        // (the bound external state) rather than a captured init snapshot
        // because external state may have legitimately changed mid-edit.
        if newValue != focusField, draft != value {
          commit(draft)
        }
      }
      .onChange(of: value) { _, newValue in
        // External writes (selection change, undo) replace `value`. If the
        // user is not actively editing this field, mirror the new value
        // into the draft so the field shows the live state.
        if focusedField != focusField {
          draft = newValue
        }
      }
  }
}
