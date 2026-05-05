import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension WorkspaceWindowUITests {
  func selectWorkspaceCapability(
    in app: XCUIApplication,
    identifier: String,
    title: String
  ) {
    let rowIdentifier = Accessibility.agentCapabilityRow(identifier)
    let capabilityRow = element(in: app, identifier: rowIdentifier)
    XCTAssertTrue(
      waitForElement(capabilityRow, timeout: Self.actionTimeout),
      "\(title) capability row should be visible before selection"
    )

    tapElement(in: app, identifier: rowIdentifier)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let selectedRow = self.element(in: app, identifier: rowIdentifier)
        return self.accessibilityValueContains(selectedRow, "Selected")
      },
      "\(title) capability row should become selected"
    )
  }

  func selectWorkspaceTransport(
    in app: XCUIApplication,
    optionTitle: String
  ) {
    let transportPicker = element(
      in: app,
      identifier: Accessibility.workspaceTransportPicker
    )
    XCTAssertTrue(
      waitForElement(transportPicker, timeout: Self.actionTimeout),
      "Transport picker should be visible before selecting \(optionTitle)"
    )

    if accessibilityValueContains(transportPicker, optionTitle) {
      return
    }

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.workspaceTransportPicker,
      optionTitle: optionTitle
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let updatedPicker = self.element(
          in: app,
          identifier: Accessibility.workspaceTransportPicker
        )
        return self.accessibilityValueContains(updatedPicker, optionTitle)
      },
      "Transport picker should select \(optionTitle)"
    )
  }

  private func accessibilityValueContains(
    _ element: XCUIElement,
    _ expected: String
  ) -> Bool {
    guard element.exists else { return false }
    if let value = element.value as? String,
      value.localizedCaseInsensitiveContains(expected)
    {
      return true
    }
    return element.label.localizedCaseInsensitiveContains(expected)
  }
}
