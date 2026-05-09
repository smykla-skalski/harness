import XCTest

@MainActor
protocol WorkspaceWindowUITestSupporting: AnyObject {}

@MainActor
extension WorkspaceWindowUITestSupporting where Self: HarnessMonitorUITestCase {
  func launchInCockpitPreview(
    additionalEnvironment: [String: String] = [:]
  ) -> XCUIApplication {
    var environment = [
      "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"
    ]
    environment.merge(additionalEnvironment) { _, new in new }
    return launch(
      mode: "preview",
      additionalEnvironment: environment
    )
  }

  func openWorkspaceWindow(in app: XCUIApplication) {
    app.activate()
  }
}
