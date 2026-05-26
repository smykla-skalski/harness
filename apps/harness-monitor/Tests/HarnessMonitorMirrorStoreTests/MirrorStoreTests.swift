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
