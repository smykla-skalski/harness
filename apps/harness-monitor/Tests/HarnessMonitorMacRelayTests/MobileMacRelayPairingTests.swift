import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import HarnessMonitorMacRelay
import XCTest

final class MobileMacRelayPairingTests: XCTestCase {
  func testMacPairingHTTPServerAcceptsPhonePairingAndTrustsDevice() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stationIdentity = MobilePairingStationIdentity(
      stationID: "station-mac-studio",
      stationName: "Studio",
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      createdAt: now
    )
    let trustStore = try MobileMacTrustedCommandDeviceStore()
    let pairAcceptedProbe = PairAcceptedProbe()
    let server = MobilePairingHTTPServer(
      stationIdentity: stationIdentity,
      trustStore: trustStore,
      now: { now },
      onPairAccepted: {
        await pairAcceptedProbe.record()
      }
    )
    let invitation = try await server.start(invitationTTL: 60)
    defer { server.stop() }
    let invitationURL = try MobilePairingInvitationCodec.encode(invitation)
    let deviceIdentity = MobileDeviceIdentity(
      id: "device-phone",
      displayName: "Bart's iPhone",
      createdAt: now
    )
    let service = MobilePairingService(transport: URLSessionMobilePairingTransport())

    let credential = try await service.pair(
      invitation: invitation,
      deviceIdentity: deviceIdentity,
      now: now
    )
    let trustedDevice = try await trustStore.trustedDevice(
      deviceID: deviceIdentity.id,
      signingKeyFingerprint: try deviceIdentity.signingKeyFingerprint()
    )
    let renewedInvitation = try await server.renewInvitation(invitationTTL: 60)
    let publicSigningKey = try await trustStore.publicSigningKey(
      actorDeviceID: deviceIdentity.id,
      signingKeyFingerprint: try deviceIdentity.signingKeyFingerprint()
    )
    let acceptedCount = await pairAcceptedProbe.count

    XCTAssertEqual(invitationURL.scheme, "harness")
    XCTAssertEqual(invitationURL.host, "pair")
    XCTAssertEqual(credential.stationID, stationIdentity.stationID)
    XCTAssertEqual(
      credential.symmetricKeyRawRepresentation, trustedDevice?.symmetricKeyRawRepresentation)
    XCTAssertEqual(renewedInvitation.stationID, stationIdentity.stationID)
    XCTAssertNotEqual(renewedInvitation.nonce, invitation.nonce)
    XCTAssertEqual(publicSigningKey, try deviceIdentity.signingPublicKeyRawRepresentation())
    XCTAssertEqual(acceptedCount, 1)
  }

  func testMacPairingHTTPServerUsesPublicEndpointOverrideInInvitation() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stationIdentity = MobilePairingStationIdentity(
      stationID: "station-mac-studio",
      stationName: "Studio",
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      createdAt: now
    )
    let trustStore = try MobileMacTrustedCommandDeviceStore()
    let publicEndpoint = try XCTUnwrap(URL(string: "https://pair.smykla.com/"))
    let server = MobilePairingHTTPServer(
      stationIdentity: stationIdentity,
      trustStore: trustStore,
      publicEndpoint: publicEndpoint,
      now: { now }
    )
    let invitation = try await server.start(invitationTTL: 60)
    defer { server.stop() }

    let renewedInvitation = try await server.renewInvitation(invitationTTL: 60)

    XCTAssertEqual(invitation.endpoint, publicEndpoint)
    XCTAssertEqual(renewedInvitation.endpoint, publicEndpoint)
    XCTAssertNotEqual(renewedInvitation.nonce, invitation.nonce)
  }

  func testDefaultPairingHostPrefersReachableEthernetOverBridgeAndVPN() {
    let host = MobileMacRelayRuntime.preferredPairingHost(
      from: [
        MobilePairingNetworkInterface(
          name: "bridge100",
          ipv4Address: "192.168.64.1",
          isUp: true,
          isLoopback: false,
          isPointToPoint: false,
          supportsBroadcast: true
        ),
        MobilePairingNetworkInterface(
          name: "utun4",
          ipv4Address: "10.9.0.2",
          isUp: true,
          isLoopback: false,
          isPointToPoint: true,
          supportsBroadcast: false
        ),
        MobilePairingNetworkInterface(
          name: "en0",
          ipv4Address: "192.168.1.254",
          isUp: true,
          isLoopback: false,
          isPointToPoint: false,
          supportsBroadcast: true
        ),
      ],
      fallbackHostName: "studio.local"
    )

    XCTAssertEqual(host, "192.168.1.254")
  }

  func testDefaultPairingHostSkipsUnusableInterfacesAndFallsBack() {
    let host = MobileMacRelayRuntime.preferredPairingHost(
      from: [
        MobilePairingNetworkInterface(
          name: "lo0",
          ipv4Address: "127.0.0.1",
          isUp: true,
          isLoopback: true,
          isPointToPoint: false,
          supportsBroadcast: false
        ),
        MobilePairingNetworkInterface(
          name: "en5",
          ipv4Address: "169.254.2.4",
          isUp: true,
          isLoopback: false,
          isPointToPoint: false,
          supportsBroadcast: true
        ),
        MobilePairingNetworkInterface(
          name: "en7",
          ipv4Address: "10.0.0.24",
          isUp: false,
          isLoopback: false,
          isPointToPoint: false,
          supportsBroadcast: true
        ),
      ],
      fallbackHostName: "studio.local"
    )

    XCTAssertEqual(host, "studio.local")
  }

  func testTrustedDeviceStorePersistsCommandTrust() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("trusted-mobile-devices.json")
    let identity = MobileDeviceIdentity(id: "device-phone", displayName: "Phone")
    let device = MobilePairingTrustedDevice(
      stationID: "station-mac-studio",
      deviceID: identity.id,
      displayName: identity.displayName,
      signingKeyFingerprint: try identity.signingKeyFingerprint(),
      signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation(),
      agreementPublicKeyRawRepresentation: try identity.agreementPublicKeyRawRepresentation(),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: Data(repeating: 9, count: 32),
      pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let writer = try MobileMacTrustedCommandDeviceStore(fileURL: fileURL)
    try await writer.trust(device)
    let reader = try MobileMacTrustedCommandDeviceStore(fileURL: fileURL)

    let publicSigningKey = try await reader.publicSigningKey(
      actorDeviceID: identity.id,
      signingKeyFingerprint: try identity.signingKeyFingerprint()
    )
    let trustedDevices = try await reader.trustedDevices()

    XCTAssertEqual(publicSigningKey, try identity.signingPublicKeyRawRepresentation())
    XCTAssertEqual(trustedDevices, [device])
  }

  func testStationIdentityStorePersistsStationKeys() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("station-identity.json")
    let store = MobileMacStationIdentityStore(fileURL: fileURL)

    let first = try store.loadOrCreate(
      stationName: "Studio",
      now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let second = try store.loadOrCreate(
      stationName: "Studio Renamed",
      now: Date(timeIntervalSince1970: 1_700_001_000)
    )

    XCTAssertEqual(second.stationID, first.stationID)
    XCTAssertEqual(
      second.agreementPrivateKeyRawRepresentation, first.agreementPrivateKeyRawRepresentation)
    XCTAssertEqual(second.stationName, "Studio Renamed")
  }

  func testReviewsQueryPreferencesDecodeDashboardStorageForRelay() throws {
    let storedValue = """
      {
        "authorsText": "codex, renovate[bot]",
        "organizationsText": " smykla-skalski ",
        "repositoriesText": "kong/kuma\\nsmykla-skalski/harness",
        "excludeRepositoriesText": "smykla-skalski/old",
        "cacheMaxAgeSeconds": 5
      }
      """

    let request = try XCTUnwrap(
      MobileRelayReviewsQueryPreferences(storedValue: storedValue).queryRequest()
    )

    XCTAssertEqual(request.authors, ["codex", "renovate[bot]"])
    XCTAssertEqual(request.organizations, ["smykla-skalski"])
    XCTAssertEqual(request.repositories, ["kong/kuma", "smykla-skalski/harness"])
    XCTAssertEqual(request.excludeRepositories, ["smykla-skalski/old"])
    XCTAssertEqual(request.cacheMaxAgeSeconds, 30)
  }

  func testReviewsQueryPreferencesRejectEmptyDashboardScope() {
    let storedValue = """
      {
        "authorsText": "codex",
        "organizationsText": "",
        "repositoriesText": "",
        "excludeRepositoriesText": "",
        "cacheMaxAgeSeconds": 600
      }
      """

    XCTAssertNil(MobileRelayReviewsQueryPreferences(storedValue: storedValue).queryRequest())
  }

  func testMobileRelayDiscoversGitHubRepositoryFromSessionCheckout() throws {
    let checkoutRoot = try makeGitHubCheckout(remoteURL: "git@github.com:smykla-skalski/harness.git")
    let session = SessionSummary(
      projectId: "project",
      projectName: "Harness",
      projectDir: checkoutRoot.path,
      sessionId: "session-1",
      context: "Shipping the mobile relay.",
      status: .active,
      createdAt: "2023-11-14T22:00:00Z",
      updatedAt: "2023-11-14T22:01:00Z",
      lastActivityAt: "2023-11-14T22:02:00Z",
      leaderId: nil,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(activeAgentCount: 1)
    )

    let repositories = MobileRelayGitRepositoryDiscovery.repositories(from: [session])

    XCTAssertEqual(repositories, ["smykla-skalski/harness"])
  }
}
