import HarnessMonitorRegistry
import SwiftUI

extension View {
  public func harnessTrackMCPElement(
    _ identifier: String,
    kind: RegistryElementKind,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    enabled: Bool = true
  ) -> some View {
    trackAccessibility(
      identifier,
      kind: kind,
      label: label,
      value: value,
      hint: hint,
      enabled: enabled,
      registry: HarnessMonitorMCPAccessibilityService.shared.registry
    )
  }
}
