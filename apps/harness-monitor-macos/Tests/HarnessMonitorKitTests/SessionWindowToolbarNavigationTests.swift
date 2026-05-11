import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
final class SessionWindowToolbarNavigationTests: XCTestCase {
  func testSessionToolbarModelUsesWindowLocalNavigationHistory() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let view = SessionWindowView(
      store: store,
      token: SessionWindowToken(sessionID: "sess-alpha")
    )

    XCTAssertFalse(view.sessionToolbarModel.canNavigateBack)
    XCTAssertFalse(view.sessionToolbarModel.canNavigateForward)

    view.stateCache.selectRoute(.timeline)

    XCTAssertTrue(view.stateCache.navigationHistory.canGoBack)
    XCTAssertFalse(store.contentUI.toolbar.canNavigateBack)
    XCTAssertTrue(view.sessionToolbarModel.canNavigateBack)
    XCTAssertFalse(view.sessionToolbarModel.canNavigateForward)

    view.stateCache.navigateBack()

    XCTAssertFalse(view.sessionToolbarModel.canNavigateBack)
    XCTAssertTrue(view.sessionToolbarModel.canNavigateForward)
  }
}
