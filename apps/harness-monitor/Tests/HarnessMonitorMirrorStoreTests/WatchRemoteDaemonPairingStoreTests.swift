import Foundation
@testable import HarnessMonitorCrypto
import HarnessMonitorMirrorStore
import XCTest

@MainActor
final class WatchRemoteDaemonPairingStoreTests: XCTestCase {
  func testRemovingDirectWatchPairingWaitsForPairingMutationGate() async throws {
    let mutationGate = MobilePairingMutationGate()
    let fixture = try WatchRemotePairingStoreFixture(
      device: .watchOS,
      mutationGate: mutationGate
    )
    await fixture.store.loadStoredPairings()
    let blockerStarted = expectation(description: "blocking mutation started")
    let releaseBlocker = WatchPairingReleaseGate()
    let blocker = Task {
      try await mutationGate.perform {
        blockerStarted.fulfill()
        await releaseBlocker.wait()
      }
    }
    await fulfillment(of: [blockerStarted], timeout: 1)

    let removal = Task { @MainActor in
      await fixture.store.removeDirectWatchPairing(stationID: fixture.credential.stationID)
    }
    await mutationGate.waitUntilQueuedOperations(atLeast: 1)

    let credentialWhileBlocked = try await fixture.credentialStore.load(
      stationID: fixture.credential.stationID
    )
    XCTAssertEqual(credentialWhileBlocked, fixture.credential)

    await releaseBlocker.release()
    try await blocker.value
    await removal.value
    let credentialAfterRemoval = try await fixture.credentialStore.load(
      stationID: fixture.credential.stationID
    )
    XCTAssertNil(credentialAfterRemoval)
  }

  func testRemovingDirectWatchPairingRequestsIPhoneFallback() async throws {
    let fixture = try WatchRemotePairingStoreFixture(device: .watchOS)
    await fixture.store.loadStoredPairings()
    fixture.store.requestFreshPairingMaterial = { fixture.transferRequests.increment() }

    await fixture.store.removeDirectWatchPairing(stationID: fixture.credential.stationID)

    let storedCredential = try await fixture.credentialStore.load(
      stationID: fixture.credential.stationID
    )
    let storedIdentity = try await fixture.identityStore.load(id: fixture.identity.id)
    XCTAssertNil(storedCredential)
    XCTAssertNil(storedIdentity)
    XCTAssertEqual(fixture.transferRequests.value, 1)
    XCTAssertEqual(fixture.store.syncStatus, .unpaired)
  }

  func testRemovingDirectWatchPairingIgnoresIPhoneTransferredCredential() async throws {
    let fixture = try WatchRemotePairingStoreFixture(device: .iOS)
    await fixture.store.loadStoredPairings()
    fixture.store.requestFreshPairingMaterial = { fixture.transferRequests.increment() }

    await fixture.store.removeDirectWatchPairing(stationID: fixture.credential.stationID)

    let storedCredential = try await fixture.credentialStore.load(
      stationID: fixture.credential.stationID
    )
    XCTAssertEqual(storedCredential, fixture.credential)
    XCTAssertEqual(fixture.transferRequests.value, 0)
  }
}

@MainActor
private struct WatchRemotePairingStoreFixture {
  let identity: MobileDeviceIdentity
  let credential: MobilePairedStationCredential
  let identityStore: InMemoryMobileDeviceIdentityStore
  let credentialStore: InMemoryMobilePairedStationCredentialStore
  let transferRequests = WatchPairingCallCounter()
  let store: MirrorStore

  init(
    device: MobileRemoteDaemonPairingDevice,
    mutationGate: MobilePairingMutationGate = MobilePairingMutationGate()
  ) throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let endpoint = URL(string: "https://daemon.example.com")!
    let pin = try MobileRemoteDaemonSPKIPin(
      validating: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
    )
    identity = MobileDeviceIdentity(
      id: device.identityID,
      displayName: device.platform,
      signingPrivateKeyRawRepresentation: Data(repeating: 1, count: 32),
      agreementPrivateKeyRawRepresentation: Data(repeating: 2, count: 32),
      createdAt: now
    )
    credential = MobilePairedStationCredential(
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      endpoint: endpoint,
      stationPublicKeyFingerprint: pin.value,
      deviceIdentityID: device.identityID,
      snapshotKeyID: "",
      commandKeyID: "",
      symmetricKeyRawRepresentation: Data(),
      pairedAt: now,
      defaultStation: true,
      remoteDaemonAccess: MobileRemoteDaemonAccess(
        endpoint: endpoint,
        clientID: "\(device.platform)-client",
        displayName: device.platform,
        platform: device.platform,
        role: .operator,
        scopes: ["read", "write"],
        bearerToken: "server-token",
        tokenHint: "token123",
        serverSPKISHA256: pin,
        pairedAt: now
      )
    )
    identityStore = InMemoryMobileDeviceIdentityStore(identities: [identity])
    credentialStore = InMemoryMobilePairedStationCredentialStore(credentials: [credential])
    store = MirrorStore(
      demoModeEnabled: false,
      profile: .watch,
      identityStore: identityStore,
      credentialStore: credentialStore,
      pairingMutationGate: mutationGate,
      sharedSnapshotStore: nil
    )
  }
}

private actor WatchPairingReleaseGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func wait() async {
    guard !released else {
      return
    }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

private final class WatchPairingCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}
