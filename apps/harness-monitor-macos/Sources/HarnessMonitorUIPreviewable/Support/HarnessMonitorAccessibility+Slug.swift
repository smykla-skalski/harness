extension HarnessMonitorAccessibility {
  static func slug(_ value: String) -> String {
    value.lowercased()
      .replacing(" ", with: "-")
      .replacing("_", with: "-")
      .replacing(":", with: "-")
      .replacing("/", with: "-")
      .replacing(".", with: "")
  }
}
