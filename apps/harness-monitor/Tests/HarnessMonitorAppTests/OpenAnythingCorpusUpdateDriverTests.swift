import Observation
import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit

@MainActor
final class OpenAnythingCorpusUpdateDriverTests: XCTestCase {
  func testObservedSourceChangeRebuildsCorpus() async {
    let source = OpenAnythingCorpusUpdateDriverTestSource()
    let coordinator = OpenAnythingCorpusCoordinator()
    let driver = OpenAnythingCorpusUpdateDriver()
    driver.start(coordinator: coordinator) {
      source.input()
    }
    defer {
      driver.stop()
    }

    await waitUntil {
      coordinator.palette.recordCount > 0
    }
    let initialCount = coordinator.palette.recordCount

    source.sessions = [PreviewFixtures.summary]

    await waitUntil {
      coordinator.palette.recordCount == initialCount + 1
    }
    let sessionRecordID = "session.\(PreviewFixtures.summary.sessionId)"
    coordinator.palette.query = PreviewFixtures.summary.sessionId
    await coordinator.palette.runSearch()

    XCTAssertNotNil(coordinator.palette.displayedResults.hit(id: sessionRecordID))
  }

  private func waitUntil(
    timeout: TimeInterval = 1,
    _ predicate: @MainActor () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(predicate())
  }
}

@MainActor
@Observable
private final class OpenAnythingCorpusUpdateDriverTestSource {
  var sessions: [SessionSummary] = []

  func input() -> OpenAnythingCorpusInput {
    OpenAnythingCorpusInput(
      settingsSections: [],
      sessions: sessions,
      taskBoardItems: [],
      decisions: [],
      reviews: [],
      loadedSession: nil,
      showsPolicyCanvasLab: false
    )
  }
}
