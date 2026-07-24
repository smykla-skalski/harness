import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Remote daemon pairing invitation")
struct RemoteDaemonPairingInvitationTests {
  @Test("Decodes the versioned daemon deep link under the shared pair host")
  func decodesVersionedDeepLink() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-10T04:00:00Z"))
    let invitation = try RemoteDaemonPairingInvitation.decode(
      invitationURL(
        endpoint: "https://daemon.example.com:8443",
        expiresAt: "2026-07-10T04:10:00Z"
      ),
      now: now
    )

    #expect(invitation.version == 1)
    #expect(invitation.endpoint.absoluteString == "https://daemon.example.com:8443")
    #expect(invitation.code == "manual-code-value")
    #expect(invitation.serverSPKISHA256.value == Self.validPin)
    #expect(invitation.role == .operator)
    #expect(invitation.scopes == ["read", "write"])
    #expect(invitation.expiresAt > now)
  }

  @Test("Still decodes links handed out under the legacy remote-pair host")
  func decodesLegacyRemotePairHost() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-10T04:00:00Z"))
    let invitation = try RemoteDaemonPairingInvitation.decode(
      invitationURL(
        endpoint: "https://daemon.example.com:8443",
        expiresAt: "2026-07-10T04:10:00Z",
        host: "remote-pair"
      ),
      now: now
    )

    #expect(invitation.endpoint.absoluteString == "https://daemon.example.com:8443")
    #expect(invitation.code == "manual-code-value")
  }

  @Test("Rejects hosts that are not pairing hosts")
  func rejectsNonPairingHost() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-10T04:00:00Z"))

    #expect(throws: RemoteDaemonPairingInvitationError.invalidURL) {
      try RemoteDaemonPairingInvitation.decode(
        invitationURL(
          endpoint: "https://daemon.example.com",
          expiresAt: "2026-07-10T04:10:00Z",
          host: "reviews"
        ),
        now: now
      )
    }
  }

  @Test("Recognizes remote-daemon links from the payload marker, not the host")
  func recognizesRemotePairingLinkByPayload() throws {
    let remoteOnPair = try invitationURL(
      endpoint: "https://daemon.example.com",
      expiresAt: "2026-07-10T04:10:00Z"
    )
    let remoteOnLegacy = try invitationURL(
      endpoint: "https://daemon.example.com",
      expiresAt: "2026-07-10T04:10:00Z",
      host: "remote-pair"
    )
    #expect(RemoteDaemonPairingInvitation.isRemotePairingLink(remoteOnPair))
    #expect(RemoteDaemonPairingInvitation.isRemotePairingLink(remoteOnLegacy))
  }

  @Test("Leaves a relay invitation on the shared pair host for the router")
  func ignoresRelayInvitationOnSharedHost() throws {
    let relayOnPair = try payloadURL(
      object: [
        "stationID": "station-mac-studio",
        "publicKeyFingerprint": "00:11:22:33:44:55:66:77",
        "nonce": "pairing-nonce",
      ],
      host: "pair"
    )
    #expect(!RemoteDaemonPairingInvitation.isRemotePairingLink(relayOnPair))
  }

  @Test("Leaves an ambiguous both-marker payload for the router")
  func ignoresAmbiguousBothMarkerPayload() throws {
    let ambiguous = try payloadURL(
      object: [
        "server_spki_sha256": Self.validPin,
        "publicKeyFingerprint": "00:11:22:33:44:55:66:77",
      ],
      host: "pair"
    )
    #expect(!RemoteDaemonPairingInvitation.isRemotePairingLink(ambiguous))
  }

  @Test("Leaves a link carrying multiple payload items for the router")
  func ignoresMultiplePayloadItems() throws {
    let single = try invitationURL(
      endpoint: "https://daemon.example.com",
      expiresAt: "2026-07-10T04:10:00Z"
    )
    let encoded = try #require(
      URLComponents(url: single, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "payload" })?
        .value
    )
    var components = try #require(URLComponents(string: "harness://pair"))
    components.queryItems = [
      URLQueryItem(name: "payload", value: encoded),
      URLQueryItem(name: "payload", value: encoded),
    ]
    let url = try #require(components.url)

    #expect(!RemoteDaemonPairingInvitation.isRemotePairingLink(url))
  }

  @Test("Rejects remote-daemon classification for non-pairing hosts and junk payloads")
  func rejectsRemoteClassificationForNonPairingHostsAndJunk() throws {
    let remotePayloadOnRoute = try invitationURL(
      endpoint: "https://daemon.example.com",
      expiresAt: "2026-07-10T04:10:00Z",
      host: "reviews"
    )
    let junkOnPair = try #require(URL(string: "harness://pair?payload=not-a-payload"))
    #expect(!RemoteDaemonPairingInvitation.isRemotePairingLink(remotePayloadOnRoute))
    #expect(!RemoteDaemonPairingInvitation.isRemotePairingLink(junkOnPair))
  }

  @Test("Rejects non-HTTPS endpoints")
  func rejectsNonHTTPSEndpoint() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-10T04:00:00Z"))

    #expect(throws: RemoteDaemonPairingInvitationError.self) {
      try RemoteDaemonPairingInvitation.decode(
        invitationURL(
          endpoint: "http://daemon.example.com",
          expiresAt: "2026-07-10T04:10:00Z"
        ),
        now: now
      )
    }
  }

  @Test("Rejects expired pairing codes")
  func rejectsExpiredInvitation() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-10T04:11:00Z"))

    #expect(throws: RemoteDaemonPairingInvitationError.expired) {
      try RemoteDaemonPairingInvitation.decode(
        invitationURL(
          endpoint: "https://daemon.example.com",
          expiresAt: "2026-07-10T04:10:00Z"
        ),
        now: now
      )
    }
  }

  @Test("Rejects malformed SPKI pins")
  func rejectsMalformedPin() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-10T04:00:00Z"))

    #expect(throws: RemoteDaemonPairingInvitationError.self) {
      try RemoteDaemonPairingInvitation.decode(
        invitationURL(
          endpoint: "https://daemon.example.com",
          pin: "sha256/not-a-digest",
          expiresAt: "2026-07-10T04:10:00Z"
        ),
        now: now
      )
    }
  }

  @Test("Canonicalizes equivalent SPKI encodings")
  func canonicalizesEquivalentPinEncoding() throws {
    let pin = try RemoteDaemonSPKIPin(
      validating: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/\nanC/ea4bTIY"
    )

    #expect(pin.value == Self.validPin)
    #expect(pin.digest.count == 32)
  }

  @Test("Imports manual endpoint, code, and SPKI fields")
  func importsManualFields() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-10T04:00:00Z"))

    let invitation = try RemoteDaemonPairingInput.manual(
      endpoint: "https://daemon.example.com:8443",
      code: " manual-code-value ",
      serverSPKISHA256: Self.validPin
    ).invitation(now: now)

    #expect(invitation.endpoint.absoluteString == "https://daemon.example.com:8443")
    #expect(invitation.code == "manual-code-value")
    #expect(invitation.serverSPKISHA256.value == Self.validPin)
    #expect(invitation.expiresAt == now.addingTimeInterval(600))
  }

  private func invitationURL(
    endpoint: String,
    pin: String = Self.validPin,
    expiresAt: String,
    host: String = "pair"
  ) throws -> URL {
    let payload: [String: Any] = [
      "version": 1,
      "endpoint": endpoint,
      "code": "manual-code-value",
      "server_spki_sha256": pin,
      "role": "operator",
      "scopes": ["read", "write"],
      "expires_at": expiresAt,
    ]
    return try payloadURL(object: payload, host: host)
  }

  private func payloadURL(object: [String: Any], host: String) throws -> URL {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let encoded = data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return try #require(URL(string: "harness://\(host)?payload=\(encoded)"))
  }

  private static let validPin = "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
}
