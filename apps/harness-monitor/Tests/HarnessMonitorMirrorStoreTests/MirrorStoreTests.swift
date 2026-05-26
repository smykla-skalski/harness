import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorMirrorStore
import XCTest

private struct StubAuthenticator: MirrorAuthenticating {
  let result: Bool
  func authenticate(reason: String) async -> Bool { result }
}

private struct StubFetchError: Error {}

private struct StubSyncClient: MobileMonitorSyncClient {
  var snapshotResult: MobileMirrorSnapshot?
  var fetchError: (any Error)?

  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot? {
    if let fetchError {
      throw fetchError
    }
    return snapshotResult
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileQueuedCommand {
    throw StubFetchError()
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    throw StubFetchError()
  }
}

private final class CallCounter: @unchecked Sendable {
  var count = 0
}

/// A sync client whose `fetchLatestSnapshot` blocks on a gate the test controls,
/// so a refresh can be held mid-flight while another refresh is requested. It
/// counts fetch calls and announces each start through `fetchStarts`.
private final class GatedSyncClient: MobileMonitorSyncClient, @unchecked Sendable {
  private let lock = NSLock()
  private var callCount = 0
  private var gateOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private let startContinuation: AsyncStream<Int>.Continuation
  let fetchStarts: AsyncStream<Int>
  let result: MobileMirrorSnapshot?

  init(result: MobileMirrorSnapshot?) {
    self.result = result
    (fetchStarts, startContinuation) = AsyncStream<Int>.makeStream()
  }

  var fetchCallCount: Int { lock.withLock { callCount } }

  func openGate() {
    let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
      gateOpen = true
      defer { waiters.removeAll() }
      return waiters
    }
    resumed.forEach { $0.resume() }
  }

  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot? {
    let started: Int = lock.withLock {
      callCount += 1
      return callCount
    }
    startContinuation.yield(started)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let openNow: Bool = lock.withLock {
        if gateOpen {
          return true
        }
        waiters.append(continuation)
        return false
      }
      if openNow {
        continuation.resume()
      }
    }
    return result
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileQueuedCommand {
    throw StubFetchError()
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    throw StubFetchError()
  }
}

private actor StubPrivacyService: MobileCloudMirrorPrivacyManaging {
  let archive: MobileCloudMirrorExportArchive
  let deletionReport: MobileCloudMirrorDeletionReport

  init(archive: MobileCloudMirrorExportArchive) {
    self.archive = archive
    deletionReport = MobileCloudMirrorDeletionReport(
      deletedAt: archive.generatedAt,
      stationIDs: archive.stationIDs,
      records: archive.records
    )
  }

  func exportArchive(stationID: String, now: Date) async throws -> MobileCloudMirrorExportArchive {
    archive
  }

  func exportArchive(stationIDs: [String], now: Date) async throws -> MobileCloudMirrorExportArchive {
    archive
  }

  func exportArchive(
    stationIDs: [String],
    directRecordIDs: [String],
    now: Date
  ) async throws -> MobileCloudMirrorExportArchive {
    archive
  }

  func exportRecords(stationID: String, now: Date) async throws -> Data {
    try archive.encodedData()
  }

  func exportRecords(stationIDs: [String], now: Date) async throws -> Data {
    try archive.encodedData()
  }

  func deleteRecordReport(stationID: String, now: Date) async throws
    -> MobileCloudMirrorDeletionReport
  {
    deletionReport
  }

  func deleteRecordReport(stationIDs: [String], now: Date) async throws
    -> MobileCloudMirrorDeletionReport
  {
    deletionReport
  }

  func deleteRecordReport(
    stationIDs: [String],
    directRecordIDs: [String],
    now: Date
  ) async throws -> MobileCloudMirrorDeletionReport {
    deletionReport
  }

  func deleteRecords(stationID: String) async throws -> Int {
    deletionReport.deletedRecordCount
  }

  func deleteRecords(stationIDs: [String]) async throws -> Int {
    deletionReport.deletedRecordCount
  }
}

final class MirrorStoreProfileTests: XCTestCase {
  func testPhoneProfileConstants() {
    XCTAssertEqual(MirrorStoreProfile.phone.commandIDPrefix, "command-")
    XCTAssertEqual(MirrorStoreProfile.phone.demoActorDeviceID, "device-demo-phone")
    XCTAssertEqual(MirrorStoreProfile.phone.pullRequestMergeAuditReason, "Confirmed from iPhone.")
    XCTAssertEqual(MirrorStoreProfile.phone.commandExpiry, 15 * 60)
  }

  func testWatchProfileConstants() {
    XCTAssertEqual(MirrorStoreProfile.watch.commandIDPrefix, "watch-command-")
    XCTAssertEqual(MirrorStoreProfile.watch.demoActorDeviceID, "device-demo-watch")
    XCTAssertEqual(
      MirrorStoreProfile.watch.pullRequestMergeAuditReason,
      "Confirmed from Apple Watch."
    )
    XCTAssertEqual(MirrorStoreProfile.watch.commandExpiry, 10 * 60)
  }
}

@MainActor
final class MirrorStoreCommandTests: XCTestCase {
  private func makeRefreshDraft() -> MobileCommandDraft {
    MobileCommandDraft(
      kind: .refresh,
      confirmationText: "Refresh",
      target: MobileCommandTarget(stationID: "station-1", targetRevision: 0)
    )
  }

  private func makeStore(
    profile: MirrorStoreProfile,
    authenticated: Bool
  ) -> MirrorStore {
    MirrorStore(
      snapshot: .empty(),
      demoModeEnabled: true,
      profile: profile,
      sharedSnapshotStore: nil,
      authenticator: StubAuthenticator(result: authenticated)
    )
  }

  func testDemoQueueStampsPhoneProfile() async {
    let store = makeStore(profile: .phone, authenticated: true)
    await store.queueCommand(makeRefreshDraft())
    let command = store.snapshot.commands.first
    XCTAssertEqual(command?.actorDeviceID, "device-demo-phone")
    XCTAssertEqual(command?.status, .queued)
    XCTAssertTrue(command?.id.hasPrefix("command-") ?? false)
    XCTAssertEqual(store.syncStatus, .demo)
  }

  func testDemoQueueStampsWatchProfile() async {
    let store = makeStore(profile: .watch, authenticated: true)
    await store.queueCommand(makeRefreshDraft())
    let command = store.snapshot.commands.first
    XCTAssertEqual(command?.actorDeviceID, "device-demo-watch")
    XCTAssertTrue(command?.id.hasPrefix("watch-command-") ?? false)
  }

  func testAuthenticationFailureBlocksQueue() async {
    let store = makeStore(profile: .phone, authenticated: false)
    await store.queueCommand(makeRefreshDraft())
    XCTAssertTrue(store.snapshot.commands.isEmpty)
    XCTAssertTrue(store.lastAuthenticationFailed)
  }
}

@MainActor
final class MirrorStorePrivacyExportTests: XCTestCase {
  func testExportMirroredRecordsWritesArchiveFileThatExistsAfterReturn() async throws {
    let now = Date(timeIntervalSince1970: 1_748_306_800)
    let archive = MobileCloudMirrorExportArchive(
      generatedAt: now,
      stationIDs: ["station-1"],
      records: []
    )
    let privacyService = StubPrivacyService(archive: archive)
    let store = MirrorStore(
      snapshot: MobileMirrorSnapshot(
        revision: 7,
        generatedAt: now,
        expiresAt: now.addingTimeInterval(300),
        stations: [
          MobileStationSummary(
            id: "station-1",
            displayName: "Bart's Mac",
            state: .online,
            lastSeenAt: now,
            activeSessionCount: 0,
            needsYouCount: 0,
            commandQueueCount: 0,
            defaultStation: true
          )
        ],
        attention: [],
        sessions: [],
        reviews: [],
        commands: []
      ),
      demoModeEnabled: false,
      profile: .phone,
      privacyServiceProvider: { privacyService },
      sharedSnapshotStore: nil,
      authenticator: StubAuthenticator(result: true)
    )

    let exportedURL = await store.exportMirroredRecords()
    let fileURL = try XCTUnwrap(exportedURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    XCTAssertTrue(fileURL.isFileURL)
    XCTAssertTrue(fileURL.lastPathComponent.hasPrefix("harness-monitor-mirror-"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertEqual(try Data(contentsOf: fileURL), try archive.encodedData())
  }
}

@MainActor
final class MirrorStoreWatchPairingTests: XCTestCase {
  private func makeWatchStore(client: StubSyncClient) -> MirrorStore {
    MirrorStore(
      snapshot: .empty(),
      syncClient: client,
      demoModeEnabled: false,
      profile: .watch,
      sharedSnapshotStore: nil,
      authenticator: StubAuthenticator(result: true)
    )
  }

  func testRefreshRequestsFreshPairingWhenMirrorMissing() async {
    let counter = CallCounter()
    let store = makeWatchStore(client: StubSyncClient())
    store.requestFreshPairingMaterial = { counter.count += 1 }

    await store.refresh()

    guard case .stale = store.syncStatus else {
      return XCTFail("expected stale status, got \(store.syncStatus)")
    }
    XCTAssertEqual(counter.count, 1, "missing mirror should request fresh pairing once")
  }

  func testRefreshDoesNotRequestPairingOnFetchError() async {
    let counter = CallCounter()
    let store = makeWatchStore(client: StubSyncClient(fetchError: StubFetchError()))
    store.requestFreshPairingMaterial = { counter.count += 1 }

    await store.refresh()

    XCTAssertEqual(counter.count, 0, "a fetch error is not a missing mirror; do not re-request")
  }
}

@MainActor
final class MirrorStoreRefreshConcurrencyTests: XCTestCase {
  private func makeStore(client: GatedSyncClient) -> MirrorStore {
    MirrorStore(
      snapshot: .empty(),
      syncClient: client,
      demoModeEnabled: false,
      profile: .phone,
      sharedSnapshotStore: nil,
      authenticator: StubAuthenticator(result: true)
    )
  }

  func testConcurrentRefreshCoalescesIntoSingleTrailingPass() async {
    let client = GatedSyncClient(result: .empty())
    let store = makeStore(client: client)

    let first = Task { await store.refresh() }
    var starts = client.fetchStarts.makeAsyncIterator()
    _ = await starts.next()
    XCTAssertEqual(client.fetchCallCount, 1, "the first refresh is now suspended in fetch")

    // A refresh requested while the first is in flight must coalesce, not start a
    // concurrent fetch. Give the second task ample room to reach its fetch (which
    // it would, unfixed) before asserting it did not.
    let second = Task { await store.refresh() }
    for _ in 0..<100 {
      await Task.yield()
    }
    XCTAssertEqual(client.fetchCallCount, 1, "the second refresh must coalesce, not fetch concurrently")

    client.openGate()
    await first.value
    await second.value
    _ = await starts.next()
    XCTAssertEqual(client.fetchCallCount, 2, "the coalesced request drives exactly one trailing fetch")
    XCTAssertNotEqual(store.syncStatus, .syncing, "status must settle, never stay pinned at syncing")
  }
}
