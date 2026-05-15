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
struct PolicyCanvasInspectorEdgePinToggle: View {
  let pinnedPortSide: Bool
  let commit: (Bool) -> Void

  var body: some View {
    Toggle(
      "Port pin",
      isOn: Binding(
        get: { pinnedPortSide },
        set: { commit($0) }
      )
    )
    .toggleStyle(.switch)
    .labelsHidden()
    .help("On keeps the current port side. Off lets the router pick the lowest-bend side.")
    .accessibilityLabel("Port pin")
    .accessibilityHint("Off lets the router pick the lowest-bend port side")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField("edge-pin")
    )
  }
}
