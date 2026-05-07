import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class WindowChromeParityTests:
  HarnessMonitorUITestCase,
  WorkspaceWindowUITestSupporting
{
  func testMainAndWorkspaceWindowsShareShellChromeContract() throws {
    let app = launchInCockpitPreview()
    openWorkspaceCreatePane(in: app)

    let mainState = shellState(in: app, windowID: "main")
    let workspaceState = shellState(in: app, windowID: "workspace")

    XCTAssertEqual(
      normalizedShellFields(mainState),
      normalizedShellFields(workspaceState)
    )
    XCTAssertEqual(mainState["shell"], "shared")
    XCTAssertEqual(workspaceState["shell"], "shared")
  }

  func testMainAndWorkspaceBannersShareChromePlacementAndMaterial() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        "HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE": "1",
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "empty",
      ]
    )
    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.persistenceBanner),
        timeout: Self.uiTimeout
      ),
      "Main persistence banner should publish before comparing banner chrome"
    )
    openWorkspaceShell(in: app)

    let mainState = bannerChromeState(in: app, windowID: "main")
    let workspaceState = bannerChromeState(in: app, windowID: "workspace")

    XCTAssertEqual(
      normalizedBannerFields(mainState),
      normalizedBannerFields(workspaceState)
    )
    XCTAssertEqual(mainState["visible"], "true")
    XCTAssertEqual(workspaceState["visible"], "true")
  }

  func testBackdropModesShareShellChromeMarkerAcrossWindows() throws {
    for mode in ["none", "content", "window"] {
      let app = launchInCockpitPreview(
        additionalEnvironment: ["HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE": mode]
      )
      openWorkspaceShell(in: app)

      let mainState = shellState(in: app, windowID: "main")
      let workspaceState = shellState(in: app, windowID: "workspace")

      XCTAssertEqual(mainState["backdrop"], mode)
      XCTAssertEqual(workspaceState["backdrop"], mode)
      XCTAssertEqual(
        normalizedShellFields(mainState),
        normalizedShellFields(workspaceState),
        "Shell chrome marker mismatch for backdrop mode \(mode)"
      )
    }
  }

  private func shellState(
    in app: XCUIApplication,
    windowID: String
  ) -> [String: String] {
    markerState(
      in: app,
      identifier: Accessibility.windowShellState(windowID)
    ) { fields in
      fields["shell"] == "shared" && fields["contentReadiness"] == "ready"
    }
  }

  private func openWorkspaceShell(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: Accessibility.workspaceToolbarButton, label: "workspace")
    _ = shellState(in: app, windowID: "workspace")
  }

  private func openWorkspaceCreatePane(in app: XCUIApplication) {
    openWorkspaceShell(in: app)

    let createTab = element(in: app, identifier: Accessibility.agentTuiCreateTab)
    XCTAssertTrue(
      waitForElement(createTab, timeout: Self.uiTimeout),
      "Workspace create tab should be visible before asserting create-pane banner chrome"
    )
    tapViaCoordinate(in: app, element: createTab)

    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.agentTuiLaunchPane),
        timeout: Self.uiTimeout
      ),
      "Workspace create pane should be visible before asserting create-pane banner chrome"
    )
  }

  private func bannerChromeState(
    in app: XCUIApplication,
    windowID: String
  ) -> [String: String] {
    markerState(
      in: app,
      identifier: Accessibility.windowBannerChromeState(windowID)
    ) { fields in
      fields["chrome"] == "shared" && fields["visible"] == "true"
    }
  }

  private func markerState(
    in app: XCUIApplication,
    identifier: String,
    matches: @escaping ([String: String]) -> Bool = { _ in true }
  ) -> [String: String] {
    let marker = element(in: app, identifier: identifier)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        guard marker.exists else {
          return false
        }
        return matches(self.parseMarkerFields(marker.label))
      },
      "Expected marker \(identifier) to publish the requested fields; actual=\(marker.label)"
    )
    return parseMarkerFields(marker.label)
  }

  private func normalizedShellFields(_ fields: [String: String]) -> [String: String] {
    fields.filter { field in
      !["windowID", "title", "minSize"].contains(field.key)
    }
  }

  private func normalizedBannerFields(_ fields: [String: String]) -> [String: String] {
    fields.filter { field in
      field.key != "windowID"
    }
  }

  private func parseMarkerFields(_ label: String) -> [String: String] {
    var fields: [String: String] = [:]
    for field in label.split(separator: ",") {
      let parts = field.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else {
        continue
      }
      let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
      fields[key] = value
    }
    return fields
  }
}
