#if canImport(SwiftUI)
import SwiftUI

public extension View {
  /// Register this view with an `AccessibilityRegistry` so the MCP server can discover it.
  ///
  /// - Parameters:
  ///   - identifier: Stable identifier exposed over the IPC protocol; must match the view's
  ///     `.accessibilityIdentifier(...)` so on-device UI tests and the MCP server line up.
  ///   - kind: Semantic kind surfaced to the MCP client.
  ///   - label: Optional human-readable label. Falls back to `identifier` when nil.
  ///   - value: Optional current value (e.g. text-field content).
  ///   - hint: Optional accessibility hint.
  ///   - windowID: Optional `CGWindowID` of the hosting window, when known.
  ///   - enabled: Whether the element currently accepts interaction.
  ///   - registry: Registry instance to target.
  func trackAccessibility(
    _ identifier: String,
    kind: RegistryElementKind,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    windowID: Int? = nil,
    enabled: Bool = true,
    registry: AccessibilityRegistry
  ) -> some View {
    modifier(
      TrackAccessibilityModifier(
        identifier: identifier,
        kind: kind,
        label: label ?? identifier,
        value: value,
        hint: hint,
        windowID: windowID,
        enabled: enabled,
        registry: registry
      )
    )
  }
}

struct TrackAccessibilityModifier: ViewModifier {
  let identifier: String
  let kind: RegistryElementKind
  let label: String
  let value: String?
  let hint: String?
  let windowID: Int?
  let enabled: Bool
  let registry: AccessibilityRegistry

  func body(content: Content) -> some View {
    content
      .accessibilityIdentifier(identifier)
      .background(
        GeometryReader { proxy in
          Color.clear
            .preference(
              key: TrackAccessibilityFramePreferenceKey.self,
              value: TrackAccessibilityFrame(rect: proxy.frame(in: .global))
            )
        }
      )
      .onPreferenceChange(TrackAccessibilityFramePreferenceKey.self) { frame in
        let registry = self.registry
        let element = RegistryElement(
          identifier: identifier,
          label: label,
          value: value,
          hint: hint,
          kind: kind,
          frame: RegistryRect(frame.rect),
          windowID: windowID,
          enabled: enabled
        )
        Task { await registry.registerElement(element) }
      }
      .onDisappear {
        let identifier = self.identifier
        let registry = self.registry
        Task { await registry.unregisterElement(identifier: identifier) }
      }
  }
}

struct TrackAccessibilityFrame: Equatable, Sendable {
  var rect: CGRect
}

struct TrackAccessibilityFramePreferenceKey: PreferenceKey {
  static let defaultValue = TrackAccessibilityFrame(rect: .zero)
  static func reduce(value: inout TrackAccessibilityFrame, nextValue: () -> TrackAccessibilityFrame) {
    value = nextValue()
  }
}
#endif
