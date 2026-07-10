import CryptoKit
import Foundation
import Security
import Testing

@testable import HarnessMonitorKit

@Suite("Remote daemon transport security", .serialized)
struct RemoteDaemonTransportSecurityTests {
  @Test("Keychain token store round trips, rotates, and deletes")
  func keychainTokenRoundTrip() throws {
    let service = "io.harnessmonitor.tests.remote-token.\(UUID().uuidString)"
    let profileID = UUID()
    let store = RemoteDaemonKeychainTokenStore(service: service)
    defer { try? store.deleteToken(profileID: profileID) }

    try store.saveToken("first-opaque-token", profileID: profileID)
    #expect(try store.loadToken(profileID: profileID) == "first-opaque-token")

    try store.saveToken("rotated-opaque-token", profileID: profileID)
    #expect(try store.loadToken(profileID: profileID) == "rotated-opaque-token")

    try store.deleteToken(profileID: profileID)
    #expect(try store.loadToken(profileID: profileID) == nil)
  }

  @Test("Extracts the same standard SPKI pin as the daemon")
  func extractsStandardSPKIPin() throws {
    let certificateDER = try #require(Data(base64Encoded: Self.certificateBase64))

    let spkiDER = try RemoteDaemonSPKIDERExtractor.extract(from: certificateDER)
    let pin = "sha256/\(Data(SHA256.hash(data: spkiDER)).base64EncodedString())"

    #expect(pin == Self.validPin)
  }

  @Test("Accepts system-trusted matching SPKI and rejects pin mismatch")
  func evaluatesTrustAndPin() throws {
    let trust = try makeTrust()
    let matching = RemoteDaemonServerTrustEvaluator(
      pin: try RemoteDaemonSPKIPin(validating: Self.validPin)
    )
    let mismatched = RemoteDaemonServerTrustEvaluator(
      pin: try RemoteDaemonSPKIPin(
        validating: "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
      )
    )

    #expect(matching.evaluate(trust))
    #expect(!mismatched.evaluate(trust))
  }

  @Test("Pinned HTTP and WebSocket transports share the trust delegate")
  func pinnedHTTPAndWebSocketSessionsShareDelegate() async throws {
    let profile = try remoteProfileFixture()
    let connection = HarnessMonitorConnection(
      endpoint: profile.endpoint,
      token: "opaque-token",
      serverTrust: .spkiSHA256(profile.serverSPKISHA256),
      source: .remote(profileID: profile.id)
    )

    let httpClient = HarnessMonitorAPIClient(connection: connection)
    let webSocketClient = WebSocketTransport(connection: connection)

    #expect(httpClient.session.delegate is RemoteDaemonURLSessionDelegate)
    #expect(await webSocketClient.session.delegate is RemoteDaemonURLSessionDelegate)
    await httpClient.shutdown()
    await webSocketClient.shutdown()
  }

  private func makeTrust() throws -> SecTrust {
    let certificateData = try #require(Data(base64Encoded: Self.certificateBase64))
    let certificate = try #require(
      SecCertificateCreateWithData(nil, certificateData as CFData)
    )
    let policy = SecPolicyCreateBasicX509()
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates(certificate, policy, &trust)
    #expect(status == errSecSuccess)
    let resolvedTrust = try #require(trust)
    #expect(SecTrustSetAnchorCertificates(resolvedTrust, [certificate] as CFArray) == errSecSuccess)
    #expect(SecTrustSetAnchorCertificatesOnly(resolvedTrust, true) == errSecSuccess)
    let verifyDate = try #require(
      ISO8601DateFormatter().date(from: "2026-07-10T04:00:00Z")
    )
    SecTrustSetVerifyDate(resolvedTrust, verifyDate as CFDate)
    return resolvedTrust
  }

  private static let validPin = "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
  private static let certificateBase64 = """
    MIIDGzCCAgOgAwIBAgIUO6qbgSSvho2GLuSvxiWE6x7/H+wwDQYJKoZIhvcNAQEL
    BQAwHTEbMBkGA1UEAwwSZGFlbW9uLmV4YW1wbGUuY29tMB4XDTI2MDcwOTExNTAx
    MloXDTI2MDcxMDExNTAxMlowHTEbMBkGA1UEAwwSZGFlbW9uLmV4YW1wbGUuY29t
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApCKXa4o1OtABLolsV/fs
    E1njTM+x0qBJFKYVW+3Pi8MCAnnQZ+yYzQ4D8Wfv1zjOy1Y/UYdIiqxBFLNp0erD
    xW+b4kuHSKuGDb15ZAys6iRA5bcTKnz8QGKVzmFIwAbS4dPJNzRb7AuDqpOE0Hxh
    E6kF/sa/GFz+aW1adDvZZkYrszUPn/3C2DvBjZFEwQgmEX4CUuNySw43tHh+EjFP
    nt+Bl5yRazZ/WNfDM3pjjnJcxaYNgP8wv1Hf4AAZqnVi17sH9Z7e3ChJZQF/fNgJ
    0+IOd5z9Q9QTlmDgeVgTIn4cgPFs9VKmCsjByek0bIRlybwl4jhuut6KhvrnXCFY
    DwIDAQABo1MwUTAdBgNVHQ4EFgQUEQWSux09fVAsGngLhkNIpOgPzj0wHwYDVR0j
    BBgwFoAUEQWSux09fVAsGngLhkNIpOgPzj0wDwYDVR0TAQH/BAUwAwEB/zANBgkq
    hkiG9w0BAQsFAAOCAQEAEPjbUJyM/J/wBxMIK4JrAJEX2hmkhpHGCp88OKavf6W/
    IalWjl70Df+FSc5yBePFKjUUo6S96r5Q4CXBx+DNfRgN26HDk2w55eivYnmi1nNc
    VHs+G7SrVjiNijOgozt45HQR4CvAgPxcZoGu1U4lmprrx7HaWIC+56y6MFghb4Kg
    +InZkMWy6ySoFbYjMSsPBifaKnuF1NUTPjL0VE8oNyNftIvFjjZuctvHjhlK+FMP
    Tys9LeCcV0h6PMHH+/hQLJC4R3RuS2uu55KtmTnhHMjNB3M56XfWb/y18n3GVkys
    yy4u0xXmF216ZT32j2SxkTQxQOVG9EqmwaZUcuACYQ==
    """.filter { !$0.isWhitespace }
}
