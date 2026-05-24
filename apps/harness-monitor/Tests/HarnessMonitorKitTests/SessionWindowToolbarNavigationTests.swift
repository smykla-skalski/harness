import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
final class SessionWindowToolbarNavigationTests: XCTestCase {
  func testSessionToolbarModelUsesGlobalWindowNavigationHistory() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let history = GlobalWindowNavigationHistory(store: store)
    let sessionWindow = NSObject()
    let view = SessionWindowView(
      store: store,
      token: SessionWindowToken(sessionID: "sess-alpha"),
      history: history
    )
    store.registerOpenSessionWindow(
      windowID: ObjectIdentifier(sessionWindow),
      sessionID: "sess-alpha"
    )

    XCTAssertFalse(view.sessionToolbarModel.canNavigateBack)
    XCTAssertFalse(view.sessionToolbarModel.canNavigateForward)

    history.installDashboardStateIfNeeded(route: .taskBoard)
    history.recordSessionSelection(
      sessionID: "sess-alpha",
      selection: .route(.timeline)
    )

    XCTAssertFalse(view.stateCache.navigationHistory.canGoBack)
    XCTAssertFalse(store.contentUI.toolbar.canNavigateBack)
    XCTAssertTrue(view.sessionToolbarModel.canNavigateBack)
    XCTAssertFalse(view.sessionToolbarModel.canNavigateForward)

    history.navigateBack()

    XCTAssertFalse(view.sessionToolbarModel.canNavigateBack)
    XCTAssertTrue(view.sessionToolbarModel.canNavigateForward)
  }
}
