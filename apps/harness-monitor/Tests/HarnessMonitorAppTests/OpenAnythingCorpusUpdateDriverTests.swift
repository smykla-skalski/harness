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

  func testRapidObservedSourceChangesShareOneDelayedRebuild() async {
    let source = OpenAnythingCorpusUpdateDriverTestSource()
    let coordinator = OpenAnythingCorpusCoordinator()
    let delayNanoseconds: UInt64 = 50_000_000
    let driver = OpenAnythingCorpusUpdateDriver(
      sourceChangeCoalescingDelayNanoseconds: delayNanoseconds
    )
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
    let initialInputBuildCount = source.inputBuildCount

    source.sessions = [makeSummary(id: "session-1", title: "First")]
    try? await Task.sleep(nanoseconds: delayNanoseconds / 5)
    source.sessions = [
      makeSummary(id: "session-1", title: "First"),
      makeSummary(id: "session-2", title: "Second"),
    ]
    try? await Task.sleep(nanoseconds: delayNanoseconds / 5)
    source.sessions = [
      makeSummary(id: "session-1", title: "First"),
      makeSummary(id: "session-2", title: "Second"),
      makeSummary(id: "session-3", title: "Third"),
    ]

    await waitUntil(timeout: 2) {
      coordinator.palette.recordCount == initialCount + 3
    }

    XCTAssertEqual(source.inputBuildCount, initialInputBuildCount + 1)
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

  private func makeSummary(id: String, title: String) -> SessionSummary {
    SessionSummary(
      projectId: "project-\(id)",
      projectName: "harness",
      projectDir: "/Users/example/Projects/harness",
      contextRoot: "/Users/example/Library/Application Support/harness/sessions/harness",
      sessionId: id,
      worktreePath: "/Users/example/Projects/harness/.worktrees/\(id)",
      sharedPath: "/Users/example/Library/Application Support/harness/sessions/\(id)/memory",
      originPath: "/Users/example/Projects/harness",
      branchRef: "harness/\(id)",
      title: title,
      context: "Context for \(title)",
      status: .active,
      createdAt: "2026-03-28T14:05:00Z",
      updatedAt: "2026-03-28T14:18:00Z",
      lastActivityAt: "2026-03-28T14:18:00Z",
      leaderId: nil,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics()
    )
  }
}

@MainActor
@Observable
private final class OpenAnythingCorpusUpdateDriverTestSource {
  var sessions: [SessionSummary] = []
  @ObservationIgnored private(set) var inputBuildCount = 0

  func input() -> OpenAnythingCorpusInput {
    inputBuildCount += 1
    return OpenAnythingCorpusInput(
      settingsSections: [],
      sessions: sessions,
      taskBoardItems: [],
      decisions: [],
      reviews: [],
      loadedSession: nil
    )
  }
}
