import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

final class OpenRecentWindowUITests: HarnessMonitorUITestCase {
  func testOpenFolderRowRequestsNativeImporter() {
    let app = launch(mode: "empty")
    let root = element(in: app, identifier: Accessibility.openRecentRoot)
    XCTAssertTrue(root.waitForExistence(timeout: Self.fastActionTimeout))

    let actionState = element(in: app, identifier: Accessibility.openRecentActionState)
    XCTAssertTrue(actionState.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(actionState.label.contains("openFolder=0"))

    tapButton(in: app, identifier: Accessibility.openRecentOpenFolderButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        actionState.label.contains("openFolder=1")
      },
      "Open Folder row did not invoke the SwiftUI action path"
    )
    XCTAssertTrue(
      waitUntil(timeout: 2.0) {
        app.sheets.firstMatch.exists
          || app.dialogs.firstMatch.exists
          || self.element(in: app, title: "Open").exists
      },
      "Open Folder row did not present the native file importer panel"
    )
    app.typeKey(.escape, modifierFlags: [])
  }
}
