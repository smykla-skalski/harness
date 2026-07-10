import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Remote daemon pairing invitation")
struct RemoteDaemonPairingInvitationTests {
  @Test("Decodes the versioned daemon deep link")
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
    expiresAt: String
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
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let encoded = data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return try #require(URL(string: "harness://remote-pair?payload=\(encoded)"))
  }

  private static let validPin = "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
}
