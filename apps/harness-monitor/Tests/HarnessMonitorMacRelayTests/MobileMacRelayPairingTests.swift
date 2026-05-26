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

  func testTrustReplacesPriorIdentityForSameDeviceAndStation() async throws {
    let store = try MobileMacTrustedCommandDeviceStore()
    let stationID = "station-mac-studio"
    let first = Self.trustedDevice(
      stationID: stationID,
      deviceID: "default-mobile-device",
      fingerprint: "5E:3E:AD:1C:A7:90:04:B3",
      pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let second = Self.trustedDevice(
      stationID: stationID,
      deviceID: "default-mobile-device",
      fingerprint: "86:C6:FA:4C:B4:91:C2:12",
      pairedAt: Date(timeIntervalSince1970: 1_700_010_000)
    )

    try await store.trust(first)
    try await store.trust(second)

    let devices = try await store.trustedDevices()
    XCTAssertEqual(devices, [second])
    let staleEntry = try await store.trustedDevice(
      deviceID: "default-mobile-device",
      signingKeyFingerprint: "5E:3E:AD:1C:A7:90:04:B3"
    )
    XCTAssertNil(staleEntry)
  }

  func testTrustKeepsSameDevicePairedWithDifferentStations() async throws {
    let store = try MobileMacTrustedCommandDeviceStore()
    let stationOne = Self.trustedDevice(
      stationID: "station-one",
      deviceID: "default-mobile-device",
      fingerprint: "AA:AA:AA:AA:AA:AA:AA:AA",
      pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let stationTwo = Self.trustedDevice(
      stationID: "station-two",
      deviceID: "default-mobile-device",
      fingerprint: "BB:BB:BB:BB:BB:BB:BB:BB",
      pairedAt: Date(timeIntervalSince1970: 1_700_010_000)
    )

    try await store.trust(stationOne)
    try await store.trust(stationTwo)

    let devices = try await store.trustedDevices()
    XCTAssertEqual(devices, [stationOne, stationTwo])
  }

  func testEnsureInvitationStartsServerLazilyWhenNotRunning() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let server = MobilePairingHTTPServer(
      stationIdentity: Self.stationIdentity(now: now),
      trustStore: try MobileMacTrustedCommandDeviceStore(),
      now: { now }
    )
    defer { server.stop() }

    let invitation = try await server.ensureInvitation(invitationTTL: 60)

    XCTAssertEqual(invitation.stationID, "station-mac-studio")
    XCTAssertGreaterThan(invitation.expiresAt, now)
    let decoded = try MobilePairingInvitationCodec.decode(
      MobilePairingInvitationCodec.encode(invitation),
      now: now
    )
    XCTAssertEqual(decoded.nonce, invitation.nonce)
  }

  func testEnsureInvitationReusesStillValidInvitation() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let server = MobilePairingHTTPServer(
      stationIdentity: Self.stationIdentity(now: now),
      trustStore: try MobileMacTrustedCommandDeviceStore(),
      now: { now }
    )
    defer { server.stop() }

    let first = try await server.ensureInvitation(invitationTTL: 60)
    let second = try await server.ensureInvitation(invitationTTL: 60)

    XCTAssertEqual(second.nonce, first.nonce)
    XCTAssertEqual(second.expiresAt, first.expiresAt)
  }

  func testEnsureInvitationRenewsExpiredInvitation() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = MutableTestClock(start)
    let server = MobilePairingHTTPServer(
      stationIdentity: Self.stationIdentity(now: start),
      trustStore: try MobileMacTrustedCommandDeviceStore(),
      now: { clock.date() }
    )
    defer { server.stop() }

    let first = try await server.ensureInvitation(invitationTTL: 60)
    clock.advance(to: start.addingTimeInterval(120))
    let second = try await server.ensureInvitation(invitationTTL: 60)

    XCTAssertNotEqual(second.nonce, first.nonce)
    XCTAssertGreaterThan(second.expiresAt, clock.date())
  }

  private static func stationIdentity(now: Date) -> MobilePairingStationIdentity {
    MobilePairingStationIdentity(
      stationID: "station-mac-studio",
      stationName: "Studio",
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      createdAt: now
    )
  }

  private static func trustedDevice(
    stationID: String,
    deviceID: String,
    fingerprint: String,
    pairedAt: Date
  ) -> MobilePairingTrustedDevice {
    MobilePairingTrustedDevice(
      stationID: stationID,
      deviceID: deviceID,
      displayName: "iPhone",
      signingKeyFingerprint: fingerprint,
      signingPublicKeyRawRepresentation: Data(fingerprint.utf8),
      agreementPublicKeyRawRepresentation: Data(fingerprint.utf8),
      snapshotKeyID: "snapshot-key",
      commandKeyID: "command-key",
      symmetricKeyRawRepresentation: Data(repeating: 7, count: 32),
      pairedAt: pairedAt
    )
  }
}

private final class MutableTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(_ start: Date) {
    current = start
  }

  func date() -> Date {
    lock.withLock { current }
  }

  func advance(to value: Date) {
    lock.withLock { current = value }
  }
}
