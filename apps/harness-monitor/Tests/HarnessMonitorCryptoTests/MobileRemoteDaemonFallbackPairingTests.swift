import Foundation
import HarnessMonitorCrypto
import XCTest

final class MobileRemoteDaemonFallbackPairingTests: XCTestCase {
  func testCoordinatorPreservesSingleCloudMirrorStationAsFallback() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let identity = makePairingIdentity(
      id: MobileRemoteDaemonPairingDevice.iOS.identityID,
      now: now.addingTimeInterval(-600)
    )
    let cloudCredential = makePairedStationCredential(
      stationID: "station-studio",
      deviceIdentityID: identity.id,
      now: now.addingTimeInterval(-300)
    )
    let identityStore = InMemoryMobileDeviceIdentityStore(identities: [identity])
    let credentialStore = InMemoryMobilePairedStationCredentialStore(
      credentials: [cloudCredential]
    )
    let coordinator = MobileRemoteDaemonPairingCoordinator(
      identityStore: identityStore,
      credentialStore: credentialStore,
      transport: RecordingRemotePairingTransport(
        claim: MobileRemoteDaemonPairingClaim(
          clientID: "ios-identity-fingerprint",
          displayName: "Bart's iPhone",
          platform: "ios",
          role: .operator,
          scopes: ["read", "write"],
          token: "server-issued-token",
          tokenHint: "abcd1234",
          pairedAt: now
        )
      ),
      device: .iOS
    )

    let credential = try await coordinator.pair(
      invitationURL: remoteInvitationURL(now: now),
      deviceName: "Bart's iPhone",
      now: now
    )

    XCTAssertEqual(credential.stationID, cloudCredential.stationID)
    XCTAssertEqual(credential.endpoint, cloudCredential.endpoint)
    XCTAssertEqual(credential.snapshotKeyID, cloudCredential.snapshotKeyID)
    XCTAssertEqual(credential.commandKeyID, cloudCredential.commandKeyID)
    XCTAssertEqual(
      credential.symmetricKeyRawRepresentation,
      cloudCredential.symmetricKeyRawRepresentation
    )
    XCTAssertTrue(credential.hasCloudMirrorAccess)
    XCTAssertEqual(credential.remoteDaemonAccess?.bearerToken, "server-issued-token")
    let storedCredentials = try await credentialStore.loadAll()
    XCTAssertEqual(storedCredentials, [credential])
  }

  func testCoordinatorUsesSelectedCloudFallbackAmongMultipleStations() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let identity = makePairingIdentity(
      id: MobileRemoteDaemonPairingDevice.iOS.identityID,
      now: now.addingTimeInterval(-600)
    )
    let studio = makePairedStationCredential(
      stationID: "station-studio",
      deviceIdentityID: identity.id,
      now: now.addingTimeInterval(-300)
    )
    let laptop = makePairedStationCredential(
      stationID: "station-laptop",
      deviceIdentityID: identity.id,
      now: now.addingTimeInterval(-200)
    )
    let credentialStore = InMemoryMobilePairedStationCredentialStore(
      credentials: [studio, laptop]
    )
    let coordinator = MobileRemoteDaemonPairingCoordinator(
      identityStore: InMemoryMobileDeviceIdentityStore(identities: [identity]),
      credentialStore: credentialStore,
      transport: RecordingRemotePairingTransport(
        claim: MobileRemoteDaemonPairingClaim(
          clientID: "ios-identity-fingerprint",
          displayName: "Bart's iPhone",
          platform: "ios",
          role: .operator,
          scopes: ["read", "write"],
          token: "server-issued-token",
          tokenHint: "abcd1234",
          pairedAt: now
        )
      ),
      device: .iOS
    )

    let credential = try await coordinator.pair(
      invitationURL: remoteInvitationURL(now: now),
      deviceName: "Bart's iPhone",
      cloudFallbackStationID: laptop.stationID,
      now: now
    )

    XCTAssertEqual(credential.stationID, laptop.stationID)
    XCTAssertEqual(credential.snapshotKeyID, laptop.snapshotKeyID)
    XCTAssertEqual(credential.remoteDaemonAccess?.bearerToken, "server-issued-token")
    let storedCredentials = try await credentialStore.loadAll()
    XCTAssertEqual(storedCredentials.count, 2)
    XCTAssertEqual(
      storedCredentials.first { $0.stationID == laptop.stationID },
      credential
    )
    XCTAssertEqual(
      storedCredentials.first { $0.stationID == studio.stationID },
      studio
    )
  }

  func testCoordinatorRejectsMissingCloudFallbackBeforeClaim() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let identity = makePairingIdentity(
      id: MobileRemoteDaemonPairingDevice.iOS.identityID,
      now: now.addingTimeInterval(-600)
    )
    let studio = makePairedStationCredential(
      stationID: "station-studio",
      deviceIdentityID: identity.id,
      now: now.addingTimeInterval(-300)
    )
    let credentialStore = InMemoryMobilePairedStationCredentialStore(
      credentials: [studio]
    )
    let transport = RecordingRemotePairingTransport(
      claim: MobileRemoteDaemonPairingClaim(
        clientID: "ios-identity-fingerprint",
        displayName: "Bart's iPhone",
        platform: "ios",
        role: .operator,
        scopes: ["read", "write"],
        token: "server-issued-token",
        tokenHint: "abcd1234",
        pairedAt: now
      )
    )
    let coordinator = MobileRemoteDaemonPairingCoordinator(
      identityStore: InMemoryMobileDeviceIdentityStore(identities: [identity]),
      credentialStore: credentialStore,
      transport: transport,
      device: .iOS
    )

    do {
      _ = try await coordinator.pair(
        invitationURL: remoteInvitationURL(now: now),
        deviceName: "Bart's iPhone",
        cloudFallbackStationID: "station-missing",
        now: now
      )
      XCTFail("expected missing Cloud fallback to fail")
    } catch {
      XCTAssertEqual(
        error as? MobileRemoteDaemonPairingError,
        .invalidCloudFallbackStation
      )
    }

    let capturedRequest = await transport.lastRequest()
    XCTAssertNil(capturedRequest)
    let storedCredentials = try await credentialStore.loadAll()
    XCTAssertEqual(storedCredentials, [studio])
  }

  func testSelectedCloudFallbackRemovesStandaloneRemoteDuplicate() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    let identity = makePairingIdentity(
      id: MobileRemoteDaemonPairingDevice.iOS.identityID,
      now: now.addingTimeInterval(-600)
    )
    let cloudCredential = makePairedStationCredential(
      stationID: "station-studio",
      deviceIdentityID: identity.id,
      now: now.addingTimeInterval(-300)
    )
    let standaloneRemote = MobilePairedStationCredential(
      stationID: "remote-daemon-example-com",
      stationName: "daemon.example.com",
      endpoint: URL(string: "https://daemon.example.com")!,
      stationPublicKeyFingerprint: testSPKIPin,
      deviceIdentityID: identity.id,
      snapshotKeyID: "",
      commandKeyID: "",
      symmetricKeyRawRepresentation: Data(),
      pairedAt: now.addingTimeInterval(-200),
      remoteDaemonAccess: try remoteAccess(deviceIdentityID: identity.id)
    )
    let credentialStore = InMemoryMobilePairedStationCredentialStore(
      credentials: [cloudCredential, standaloneRemote]
    )
    let coordinator = MobileRemoteDaemonPairingCoordinator(
      identityStore: InMemoryMobileDeviceIdentityStore(identities: [identity]),
      credentialStore: credentialStore,
      transport: RecordingRemotePairingTransport(
        claim: MobileRemoteDaemonPairingClaim(
          clientID: "ios-identity-fingerprint",
          displayName: "Bart's iPhone",
          platform: "ios",
          role: .operator,
          scopes: ["read", "write"],
          token: "server-issued-token",
          tokenHint: "abcd1234",
          pairedAt: now
        )
      ),
      device: .iOS
    )

    let credential = try await coordinator.pair(
      invitationURL: remoteInvitationURL(now: now),
      deviceName: "Bart's iPhone",
      cloudFallbackStationID: cloudCredential.stationID,
      now: now
    )

    XCTAssertEqual(credential.stationID, cloudCredential.stationID)
    let storedCredentials = try await credentialStore.loadAll()
    XCTAssertEqual(storedCredentials, [credential])
  }
}
