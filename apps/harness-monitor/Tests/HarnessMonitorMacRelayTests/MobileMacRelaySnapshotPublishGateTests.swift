import Foundation
import HarnessMonitorCore
import HarnessMonitorKit
import HarnessMonitorMacRelay
import XCTest

/// Mirrors the real source: identical content every poll, but a fresh revision
/// and fresh timestamps, which is why plain snapshot equality never matches.
private actor RevisionBumpingSnapshotSource: MobileMirrorSnapshotSource {
  private let base: MobileMirrorSnapshot
  private var revision: Int64 = 0
  private var needsYouOverride: Int?

  init(base: MobileMirrorSnapshot) {
    self.base = base
  }

  func overrideNeedsYouCount(_ count: Int) {
    needsYouOverride = count
  }

  func makeSnapshot(now: Date) async throws -> MobileMirrorSnapshot {
    revision += 1
    var snapshot = base
    snapshot.revision = revision
    snapshot.generatedAt = now
    snapshot.expiresAt = now.addingTimeInterval(3_600)
    snapshot.stations = base.stations.map { station in
      var refreshed = station
      refreshed.lastSeenAt = now
      if let needsYouOverride {
        refreshed.needsYouCount = needsYouOverride
      }
      return refreshed
    }
    return snapshot
  }
}

private actor FailOnceSnapshotSink: MobileMirrorSnapshotSink {
  private var recordedSnapshots: [MobileMirrorSnapshot] = []
  private var shouldFail = true

  func writeSnapshot(_ snapshot: MobileMirrorSnapshot) async throws {
    if shouldFail {
      shouldFail = false
      throw MobileRelayTransientTestError(message: "CloudKit unavailable")
    }
    recordedSnapshots.append(snapshot)
  }

  func snapshots() -> [MobileMirrorSnapshot] {
    recordedSnapshots
  }
}

final class MobileMacRelaySnapshotPublishGateTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeRelay(
    source: RevisionBumpingSnapshotSource,
    sink: RecordingMobileMirrorSnapshotSink
  ) -> MobileMacRelayService {
    MobileMacRelayService(
      stationID: "station-mac-studio",
      snapshotSource: source,
      snapshotSink: sink,
      commandQueue: InMemoryMobileRelayCommandQueue(commands: []),
      executor: SecretSucceedingMobileRelayCommandExecutor(message: "done")
    )
  }

  func testUnchangedSnapshotIsNotRepublished() async throws {
    let source = RevisionBumpingSnapshotSource(base: MobileDemoFixtures.snapshot(now: start))
    let sink = RecordingMobileMirrorSnapshotSink()
    let relay = makeRelay(source: source, sink: sink)

    _ = try await relay.publishSnapshot(now: start)
    _ = try await relay.publishSnapshot(now: start.addingTimeInterval(15))
    _ = try await relay.publishSnapshot(now: start.addingTimeInterval(30))

    let published = await sink.snapshots()
    XCTAssertEqual(published.count, 1, "Unchanged mirror content must not be rewritten")
  }

  func testChangedSnapshotIsRepublished() async throws {
    let source = RevisionBumpingSnapshotSource(base: MobileDemoFixtures.snapshot(now: start))
    let sink = RecordingMobileMirrorSnapshotSink()
    let relay = makeRelay(source: source, sink: sink)

    _ = try await relay.publishSnapshot(now: start)
    await source.overrideNeedsYouCount(42)
    _ = try await relay.publishSnapshot(now: start.addingTimeInterval(15))

    let published = await sink.snapshots()
    XCTAssertEqual(published.count, 2)
    XCTAssertEqual(published.last?.stations.first?.needsYouCount, 42)
  }

  /// The phone reads `lastSeenAt` and `expiresAt`, so an idle Mac still has to
  /// refresh the record periodically or it looks stale and eventually expires.
  func testHeartbeatRepublishesUnchangedSnapshot() async throws {
    let source = RevisionBumpingSnapshotSource(base: MobileDemoFixtures.snapshot(now: start))
    let sink = RecordingMobileMirrorSnapshotSink()
    let relay = makeRelay(source: source, sink: sink)

    _ = try await relay.publishSnapshot(now: start)
    _ = try await relay.publishSnapshot(now: start.addingTimeInterval(15))
    _ = try await relay.publishSnapshot(now: start.addingTimeInterval(120))

    let published = await sink.snapshots()
    XCTAssertEqual(published.count, 2)
  }

  /// A clock that moved backwards must not read as "still inside the heartbeat"
  /// and park the mirror until wall time catches up.
  func testClockGoingBackwardsStillHeartbeats() async throws {
    let source = RevisionBumpingSnapshotSource(base: MobileDemoFixtures.snapshot(now: start))
    let sink = RecordingMobileMirrorSnapshotSink()
    let relay = makeRelay(source: source, sink: sink)

    _ = try await relay.publishSnapshot(now: start)
    _ = try await relay.publishSnapshot(now: start.addingTimeInterval(-500))

    let published = await sink.snapshots()
    XCTAssertEqual(published.count, 2)
  }

  /// A write that threw never reached the phone, so the gate must not treat that
  /// content as already published or the mirror silently stops updating.
  func testFailedWriteIsRetriedOnTheNextPublish() async throws {
    let source = RevisionBumpingSnapshotSource(base: MobileDemoFixtures.snapshot(now: start))
    let sink = FailOnceSnapshotSink()
    let relay = MobileMacRelayService(
      stationID: "station-mac-studio",
      snapshotSource: source,
      snapshotSink: sink,
      commandQueue: InMemoryMobileRelayCommandQueue(commands: []),
      executor: SecretSucceedingMobileRelayCommandExecutor(message: "done")
    )

    await XCTAssertThrowsErrorAsync(try await relay.publishSnapshot(now: start))
    _ = try await relay.publishSnapshot(now: start.addingTimeInterval(15))

    let published = await sink.snapshots()
    XCTAssertEqual(published.count, 1, "A failed write must not count as published")
  }
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected an error", file: file, line: line)
  } catch {
    // Expected.
  }
}
