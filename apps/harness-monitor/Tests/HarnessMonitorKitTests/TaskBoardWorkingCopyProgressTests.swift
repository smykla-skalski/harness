import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Task-board working-copy obtain progress")
struct TaskBoardWorkingCopyProgressTests {
  /// A real `advanced` frame as the daemon serializes it, so the decode is
  /// exercised against the wire shape rather than a hand-built Swift value.
  private let advancedJSON = """
    {
      "kind": "advanced",
      "repo_full_name": "acme/widgets",
      "phase": "Receiving objects",
      "done": 40,
      "total": 100,
      "blocked": false
    }
    """

  /// Decodes exactly as `StreamEvent.decodePayloadWire` does. The generated wire
  /// type spells its snake_case keys explicitly, so a `.convertFromSnakeCase`
  /// decoder would rewrite `repo_full_name` to `repoFullName` and then fail to
  /// find it.
  private func decode(_ json: String) throws -> TaskBoardWorkingCopyProgress {
    let wire = try PolicyWireCoding.decoder.decode(
      WorkingCopyProgressEventPayloadWire.self,
      from: Data(json.utf8)
    )
    return TaskBoardWorkingCopyProgress(wire: wire)
  }

  @Test("An advanced frame decodes into a fraction the UI can render")
  func advancedFrameDecodesIntoARenderableFraction() throws {
    let progress = try decode(advancedJSON)

    #expect(progress.kind == .advanced)
    #expect(progress.repoFullName == "acme/widgets")
    #expect(progress.phase == "Receiving objects")
    #expect(progress.fractionCompleted == 0.4)
    #expect(progress.phaseLabel == "Receiving objects 40/100")
    #expect(progress.isInFlight)
  }

  @Test("An unbounded phase claims no fraction")
  func anUnboundedPhaseClaimsNoFraction() throws {
    let progress = try decode(
      """
      {
        "kind": "advanced",
        "repo_full_name": "acme/widgets",
        "phase": "Counting objects",
        "done": 7,
        "blocked": false
      }
      """
    )

    #expect(progress.total == nil)
    #expect(progress.fractionCompleted == nil)
    #expect(progress.phaseLabel == "Counting objects 7")
  }

  @Test("Terminal frames end the in-flight state")
  func terminalFramesEndTheInFlightState() throws {
    let completed = try decode(
      """
      {"kind": "completed", "repo_full_name": "acme/widgets", "duration_millis": 742}
      """
    )
    let failed = try decode(
      """
      {"kind": "failed", "repo_full_name": "acme/widgets", "message": "auth denied"}
      """
    )

    #expect(!completed.isInFlight)
    #expect(completed.durationMillis == 742)
    #expect(!failed.isInFlight)
    #expect(failed.message == "auth denied")
  }

  @Test("A total of zero is treated as unbounded rather than divided by")
  func aTotalOfZeroIsTreatedAsUnbounded() {
    let progress = TaskBoardWorkingCopyProgress(
      kind: .advanced,
      repoFullName: "acme/widgets",
      phase: "Receiving objects",
      done: 0,
      total: 0
    )

    #expect(progress.fractionCompleted == nil)
  }

  @Test("The transport decodes the event into a working-copy push event")
  func theTransportDecodesTheEventIntoAPushEvent() throws {
    let payloadJSON: [String: Any] = [
      "kind": "advanced",
      "repo_full_name": "acme/widgets",
      "phase": "Receiving objects",
      "done": 40,
      "total": 100,
      "blocked": false,
    ]
    let payloadData = try JSONSerialization.data(withJSONObject: payloadJSON)
    let payload = try JSONDecoder().decode(JSONValue.self, from: payloadData)
    let streamEvent = StreamEvent(
      event: "task_board_working_copy_progress",
      recordedAt: "2026-07-25T12:00:00Z",
      sessionId: nil,
      payload: payload
    )

    let pushEvent = try DaemonPushEvent(streamEvent: streamEvent)

    switch pushEvent.kind {
    case .taskBoardWorkingCopyProgress(let progress):
      #expect(progress.repoFullName == "acme/widgets")
      #expect(progress.kind == .advanced)
      #expect(progress.fractionCompleted == 0.4)
    default:
      Issue.record("expected taskBoardWorkingCopyProgress, got \(pushEvent.kind)")
    }
  }

  @Test("A count beyond its total still reports a full bar, never more")
  func aCountBeyondItsTotalStillReportsAFullBar() {
    let progress = TaskBoardWorkingCopyProgress(
      kind: .advanced,
      repoFullName: "acme/widgets",
      phase: "Receiving objects",
      done: 120,
      total: 100
    )

    #expect(progress.fractionCompleted == 1)
  }
}

@Suite("Task-board working-copy progress tracker")
struct TaskBoardWorkingCopyProgressTrackerTests {
  private let start = Date(timeIntervalSince1970: 1_000)

  private func advanced(done: UInt64, blocked: Bool = false) -> TaskBoardWorkingCopyProgress {
    TaskBoardWorkingCopyProgress(
      kind: .advanced,
      repoFullName: "acme/widgets",
      phase: "Receiving objects",
      done: done,
      total: 100,
      blocked: blocked
    )
  }

  @Test("Counts that keep moving never read as stalled")
  func countsThatKeepMovingNeverReadAsStalled() {
    var tracker = TaskBoardWorkingCopyProgressTracker()
    tracker.ingest(advanced(done: 10), at: start)
    tracker.ingest(advanced(done: 20), at: start.addingTimeInterval(4))
    tracker.ingest(advanced(done: 30), at: start.addingTimeInterval(8))

    let entry = tracker.entry(for: "acme/widgets")

    #expect(entry?.isStalled(now: start.addingTimeInterval(9)) == false)
  }

  @Test("Counts frozen past the threshold read as stalled")
  func countsFrozenPastTheThresholdReadAsStalled() {
    var tracker = TaskBoardWorkingCopyProgressTracker()
    tracker.ingest(advanced(done: 10), at: start)
    // The daemon keeps reporting on its interval; only the count is stuck.
    tracker.ingest(advanced(done: 10), at: start.addingTimeInterval(3))
    tracker.ingest(advanced(done: 10), at: start.addingTimeInterval(6))

    let entry = tracker.entry(for: "acme/widgets")

    #expect(entry?.isStalled(now: start.addingTimeInterval(6)) == true)
  }

  @Test("Silence reads as stalled too, since the daemon reports on an interval")
  func silenceReadsAsStalled() {
    var tracker = TaskBoardWorkingCopyProgressTracker()
    tracker.ingest(advanced(done: 10), at: start)

    let entry = tracker.entry(for: "acme/widgets")

    #expect(entry?.isStalled(now: start.addingTimeInterval(30)) == true)
  }

  @Test("A blocked phase reads as stalled immediately")
  func aBlockedPhaseReadsAsStalledImmediately() {
    var tracker = TaskBoardWorkingCopyProgressTracker()
    tracker.ingest(advanced(done: 10, blocked: true), at: start)

    let entry = tracker.entry(for: "acme/widgets")

    #expect(entry?.isStalled(now: start) == true)
  }

  @Test("A terminal event returns the row to its resolved state")
  func aTerminalEventReturnsTheRowToItsResolvedState() {
    var tracker = TaskBoardWorkingCopyProgressTracker()
    tracker.ingest(advanced(done: 10), at: start)
    #expect(tracker.isObtaining("acme/widgets"))

    tracker.ingest(
      TaskBoardWorkingCopyProgress(
        kind: .completed,
        repoFullName: "acme/widgets",
        durationMillis: 742
      ),
      at: start.addingTimeInterval(1)
    )

    #expect(!tracker.isObtaining("acme/widgets"))
    #expect(tracker.entry(for: "acme/widgets") == nil)
  }

  @Test("Each repository tracks its own progress")
  func eachRepositoryTracksItsOwnProgress() {
    var tracker = TaskBoardWorkingCopyProgressTracker()
    tracker.ingest(advanced(done: 10), at: start)
    tracker.ingest(
      TaskBoardWorkingCopyProgress(
        kind: .advanced,
        repoFullName: "acme/gadgets",
        phase: "Resolving deltas",
        done: 5,
        total: 50
      ),
      at: start
    )

    #expect(tracker.entry(for: "acme/widgets")?.progress.done == 10)
    #expect(tracker.entry(for: "acme/gadgets")?.progress.done == 5)
  }
}
