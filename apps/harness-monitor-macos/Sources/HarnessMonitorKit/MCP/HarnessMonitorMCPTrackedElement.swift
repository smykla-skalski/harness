import HarnessMonitorRegistry
import SwiftUI

private final class HarnessMonitorMCPSemanticActionBox: @unchecked Sendable {
  let action: () -> Void

  init(action: @escaping () -> Void) {
    self.action = action
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
    trackAccessibility(
      identifier,
      kind: kind,
      label: label,
      value: value,
      hint: hint,
      enabled: enabled,
      semanticActions: harnessSemanticActions(pressAction: pressAction),
      semanticActionSink: service,
      registry: service.registry
    )
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
