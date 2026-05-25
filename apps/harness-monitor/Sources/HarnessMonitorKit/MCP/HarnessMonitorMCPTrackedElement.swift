import HarnessMonitorRegistry
import SwiftUI

private struct HarnessMCPElementTrackingEnabledKey: EnvironmentKey {
  static let defaultValue = true
}

private final class HarnessMonitorMCPSemanticActionBox: @unchecked Sendable {
  let action: () -> Void

  init(action: @escaping () -> Void) {
    self.action = action
  }
}

private struct HarnessMCPElementTrackingModifier: ViewModifier {
  let elementID: String
  let kind: RegistryElementKind
  let label: String?
  let value: String?
  let hint: String?
  let enabled: Bool
  let semanticActions: RegistryTrackedSemanticActions
  let semanticActionSink: (any RegistrySemanticActionSink)?
  let registry: AccessibilityRegistry
  @Environment(\.harnessMCPElementTrackingEnabled)
  private var trackingEnabled

  @ViewBuilder
  func body(content: Content) -> some View {
    if trackingEnabled {
      content.trackAccessibility(
        elementID,
        kind: kind,
        label: label,
        value: value,
        hint: hint,
        enabled: enabled,
        semanticActions: semanticActions,
        semanticActionSink: semanticActionSink,
        registry: registry
      )
    } else {
      content.accessibilityIdentifier(elementID)
    }
  }
}

extension EnvironmentValues {
  public var harnessMCPElementTrackingEnabled: Bool {
    get { self[HarnessMCPElementTrackingEnabledKey.self] }
    set { self[HarnessMCPElementTrackingEnabledKey.self] = newValue }
  }
}

extension View {
  private func harnessSemanticActions(
    pressAction: (() -> Void)?
  ) -> RegistryTrackedSemanticActions {
    guard let pressAction else {
      return .none
    }
    let box = HarnessMonitorMCPSemanticActionBox(action: pressAction)
    return RegistryTrackedSemanticActions(press: { box.action() })
  }

  public func harnessTrackMCPElement(
    _ identifier: String,
    kind: RegistryElementKind,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    enabled: Bool = true,
    service: HarnessMonitorMCPAccessibilityService = .shared,
    pressAction: (() -> Void)? = nil
  ) -> some View {
    modifier(
      HarnessMCPElementTrackingModifier(
        elementID: identifier,
        kind: kind,
        label: label,
        value: value,
        hint: hint,
        enabled: enabled,
        semanticActions: harnessSemanticActions(pressAction: pressAction),
        semanticActionSink: service,
        registry: service.registry
      )
    )
  }

  public func harnessMCPElementTrackingEnabled(_ enabled: Bool) -> some View {
    environment(\.harnessMCPElementTrackingEnabled, enabled)
  }

  public func harnessMCPButton(
    _ identifier: String,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    enabled: Bool = true,
    service: HarnessMonitorMCPAccessibilityService = .shared,
    pressAction: (() -> Void)? = nil
  ) -> some View {
    harnessTrackMCPElement(
      identifier,
      kind: .button,
      label: label,
      value: value,
      hint: hint,
      enabled: enabled,
      service: service,
      pressAction: pressAction
    )
  }

  public func harnessMCPTextField(
    _ identifier: String,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    enabled: Bool = true
  ) -> some View {
    harnessTrackMCPElement(
      identifier,
      kind: .textField,
      label: label,
      value: value,
      hint: hint,
      enabled: enabled
    )
  }

  public func harnessMCPText(
    _ identifier: String,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    enabled: Bool = true
  ) -> some View {
    harnessTrackMCPElement(
      identifier,
      kind: .text,
      label: label,
      value: value,
      hint: hint,
      enabled: enabled
    )
  }

  public func harnessMCPRow(
    _ identifier: String,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    enabled: Bool = true,
    service: HarnessMonitorMCPAccessibilityService = .shared,
    pressAction: (() -> Void)? = nil
  ) -> some View {
    harnessTrackMCPElement(
      identifier,
      kind: .row,
      label: label,
      value: value,
      hint: hint,
      enabled: enabled,
      service: service,
      pressAction: pressAction
    )
  }

  public func harnessMCPTab(
    _ identifier: String,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    enabled: Bool = true,
    service: HarnessMonitorMCPAccessibilityService = .shared,
    pressAction: (() -> Void)? = nil
  ) -> some View {
    harnessTrackMCPElement(
      identifier,
      kind: .tab,
      label: label,
      value: value,
      hint: hint,
      enabled: enabled,
      service: service,
      pressAction: pressAction
    )
  }

  public func harnessMCPList(
    _ identifier: String,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    enabled: Bool = true
  ) -> some View {
    harnessTrackMCPElement(
      identifier,
      kind: .list,
      label: label,
      value: value,
      hint: hint,
      enabled: enabled
    )
  }

  public func harnessMCPMenuItem(
    _ identifier: String,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    enabled: Bool = true,
    service: HarnessMonitorMCPAccessibilityService = .shared,
    pressAction: (() -> Void)? = nil
  ) -> some View {
    harnessTrackMCPElement(
      identifier,
      kind: .menuItem,
      label: label,
      value: value,
      hint: hint,
      enabled: enabled,
      service: service,
      pressAction: pressAction
    )
  }
}
