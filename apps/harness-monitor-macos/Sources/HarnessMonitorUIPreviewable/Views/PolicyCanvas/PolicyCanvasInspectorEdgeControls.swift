import SwiftUI

/// Inspector kind picker for a selected edge. Lets the user override the
/// heuristic-derived `PolicyCanvasEdgeKind.derive(from:)` result when the
/// condition string is ambiguous (e.g. `deny_list_member` could be a
/// control branch or an error path). The Picker title matches the visible
/// `PolicyCanvasInspectorField` label ("Kind") so VoiceOver's accessible
/// name starts with the same word sighted users read - WCAG 2.5.3 (Label
/// in Name).
struct PolicyCanvasInspectorEdgeKindPicker: View {
  let kind: PolicyCanvasEdgeKind
  let commit: (PolicyCanvasEdgeKind) -> Void

  var body: some View {
    Picker(
      "Kind",
      selection: Binding(
        get: { kind },
        set: { commit($0) }
      )
    ) {
      ForEach(PolicyCanvasEdgeKind.allCases, id: \.self) { value in
        Text(Self.title(for: value)).tag(value)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .help(
      """
      Override the heuristic-derived kind. Flow is unconditional, control is a \
      conditional branch, error is a deny path.
      """
    )
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasInspectorField("edge-kind"))
  }

  static func title(for kind: PolicyCanvasEdgeKind) -> String {
    kind.accessibilityWord.capitalized
  }
}

/// Inspector port-pin toggle. When off, the visibility router walks all
/// 4-side anchor combinations and picks the lowest-bend route. Default
/// is on so existing documents keep their stable port positions; flipping
/// off is an explicit user opt-in. The accessible label and `.help` share
/// the same "Port pin" wording the visible field carries (WCAG 2.5.3),
/// and the help text resolves the gulf of execution: a binary switch
/// with no visible signifier of the off-state effect.
///
/// When the edge's kind is `.error`, the toggle is disabled and the help
/// text explains the constraint: error edges are always pinned regardless
/// of this control, so a flex pass cannot silently relocate a deliberately
/// positioned deny-branch port. This is Norman's forcing-function pattern
/// applied to the routing layer.
struct PolicyCanvasInspectorEdgePinToggle: View {
  let pinnedPortSide: Bool
  let isLockedByKind: Bool
  let commit: (Bool) -> Void

  var body: some View {
    Toggle(
      "Port pin",
      isOn: Binding(
        get: { isLockedByKind ? true : pinnedPortSide },
        set: { commit($0) }
      )
    )
    .toggleStyle(.switch)
    .labelsHidden()
    .disabled(isLockedByKind)
    .help(helpText)
    .accessibilityLabel("Port pin")
    .accessibilityHint(accessibilityHintText)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField("edge-pin")
    )
  }

  private var helpText: String {
    if isLockedByKind {
      return
        "Error edges are always pinned. Change the edge kind to flow or control to unlock this control."
    }
    return "On keeps the current port side. Off lets the router pick the lowest-bend side."
  }

  private var accessibilityHintText: String {
    if isLockedByKind {
      // VoiceOver already announces the disabled trait via `.disabled()`;
      // the hint adds the *reason*, not the state. Leading with "Disabled."
      // would double-announce.
      return "Error edges are always pinned to prevent the router from relocating them."
    }
    return "Off lets the router pick the lowest-bend port side"
  }
}
