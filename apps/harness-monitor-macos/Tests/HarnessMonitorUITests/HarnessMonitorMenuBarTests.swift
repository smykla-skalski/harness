import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// UI tests covering the macOS HIG menu bar restructure: the new Window menu
/// items must open the Agents and Decisions windows, and the View menu's
/// Show / Hide Inspector toggle must flip the inspector column visibility.
@MainActor
final class HarnessMonitorMenuBarTests: HarnessMonitorUITestCase {
  // swiftlint:disable:next static_over_final_class
  override nonisolated class var reuseLaunchedApp: Bool { true }

  func testWindowMenuOpensAgentsWindow() throws {
    let app = launch(mode: "preview")
    invokeMenuItem(in: app, menu: "Window", title: "Agents")

    let agentsWindow = element(in: app, identifier: Accessibility.agentsWindow)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { agentsWindow.exists },
      "Agents window should appear after invoking Window > Agents"
    )
  }

  func testWindowMenuOpensDecisionsWindow() throws {
    let app = launch(mode: "preview")
    invokeMenuItem(in: app, menu: "Window", title: "Decisions")

    let decisionsWindow = element(in: app, identifier: Accessibility.decisionsWindow)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { decisionsWindow.exists },
      "Decisions window should appear after invoking Window > Decisions"
    )
  }

  func testAppSettingsMenuOpensPreferences() throws {
    let app = launch(mode: "preview")
    app.typeKey(",", modifierFlags: .command)

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { preferencesRoot.exists },
      "Preferences root should appear after Cmd+, invokes the system Settings menu item"
    )
  }

  func testViewMenuTogglesInspector() throws {
    let app = launch(mode: "preview")

    let inspector = element(in: app, identifier: Accessibility.inspectorRoot)
    let initiallyVisible = inspector.waitForExistence(timeout: Self.actionTimeout)

    invokeMenuItem(
      in: app,
      menu: "View",
      title: initiallyVisible ? "Hide Inspector" : "Show Inspector"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { inspector.exists != initiallyVisible },
      "Inspector visibility should flip after the first View menu toggle"
    )

    invokeMenuItem(
      in: app,
      menu: "View",
      title: initiallyVisible ? "Show Inspector" : "Hide Inspector"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { inspector.exists == initiallyVisible },
      "Inspector visibility should return to its initial state after the second toggle"
    )
  }
}
