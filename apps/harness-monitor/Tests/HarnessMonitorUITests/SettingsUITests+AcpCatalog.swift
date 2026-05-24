import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class SettingsUITestsAcpCatalog: HarnessMonitorUITestCase {
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"

  func testSupervisorNotificationsPaneShowsAcpCatalogControlsAndStateMarker() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        "HARNESS_FEATURE_ACP": "1",
      ]
    )

    openSettings(in: app)
    selectSupervisorNotificationsPane(in: app)

    let toggle = element(in: app, identifier: Accessibility.settingsAcpCatalogToggle)
    XCTAssertTrue(waitForElement(toggle, timeout: Self.actionTimeout))
    XCTAssertFalse(toggle.isEnabled, "Environment override should lock ACP catalog toggle")

    let permission = element(in: app, identifier: Accessibility.settingsAcpCatalogPermission)
    XCTAssertTrue(waitForElement(permission, timeout: Self.actionTimeout))

    let statusMarker = element(
      in: app,
      identifier: Accessibility.settingsAcpNotificationStatusState
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.markerText(for: statusMarker).contains("feature-acp=true")
      }
    )
  }

  private func markerText(for element: XCUIElement) -> String {
    if let value = element.value as? String, !value.isEmpty {
      return value
    }
    if !element.label.isEmpty {
      return element.label
    }
    return element.debugDescription
  }
}
