import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import HarnessMonitorMacRelay
import XCTest

final class MobileMacRelayLazyInvitationTests: XCTestCase {
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

  func testRuntimeEnsurePairingInvitationMintsLazily() async throws {
    let runtime = try Self.makeRuntime()
    defer { runtime.stop() }

    let url = try await runtime.ensurePairingInvitation()

    XCTAssertEqual(url.scheme, "harness")
    XCTAssertEqual(url.host, "pair")
    let invitation = try MobilePairingInvitationCodec.decode(url, now: .now)
    XCTAssertEqual(invitation.stationName, "Studio")
  }

  func testRuntimeRenewPairingInvitationProducesFreshCode() async throws {
    let runtime = try Self.makeRuntime()
    defer { runtime.stop() }

    let first = try await runtime.ensurePairingInvitation()
    let second = try await runtime.renewPairingInvitationURL()

    XCTAssertNotEqual(first.absoluteString, second.absoluteString)
  }

  private static func makeRuntime() throws -> MobileMacRelayRuntime {
    let storageRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: storageRoot, withIntermediateDirectories: true)
    return try MobileMacRelayRuntime(
      storageRoot: storageRoot,
      stationName: "Studio",
      clientProvider: { nil },
      pairingHost: "127.0.0.1",
      database: InMemoryMobileCloudMirrorDatabase()
    )
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
