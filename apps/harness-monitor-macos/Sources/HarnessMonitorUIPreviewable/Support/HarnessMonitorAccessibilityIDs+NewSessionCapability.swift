extension HarnessMonitorAccessibility {
  public static let newSessionCapabilityPickerSection = "harness.new-session.capability-picker.section"
  public static let newSessionCapabilityPicker = "harness.new-session.capability-picker"

  public static func newSessionCapabilityRow(_ identifier: String) -> String {
    "harness.new-session.capability.\(slug(identifier))"
  }

  public static func newSessionCapabilityProbe(_ identifier: String) -> String {
    "harness.new-session.capability.\(slug(identifier)).probe"
  }

  public static func newSessionCapabilityTransportButton(
    _ identifier: String,
    transportID: String
  ) -> String {
    "harness.new-session.capability.\(slug(identifier)).transport.\(slug(transportID))"
  }

  public static func newSessionDiagnosticsToggle(_ identifier: String) -> String {
    "harness.new-session.capability.\(slug(identifier)).diagnostics-toggle"
  }
}
