import Foundation
import HarnessMonitorCore
import HarnessMonitorMirrorStore
import XCTest

private struct StubAuthenticator: MirrorAuthenticating {
  let result: Bool
  func authenticate(reason: String) async -> Bool { result }
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
