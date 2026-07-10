import CryptoKit
import Foundation
import Security
import XCTest

@testable import HarnessMonitorCrypto

final class MobileRemoteDaemonTransportSecurityTests: XCTestCase {
  func testExtractorMatchesDaemonSPKIPin() throws {
    let certificateDER = try XCTUnwrap(Data(base64Encoded: Self.certificateBase64))

    let spkiDER = try MobileRemoteDaemonSPKIDERExtractor.extract(from: certificateDER)
    let pin = "sha256/\(Data(SHA256.hash(data: spkiDER)).base64EncodedString())"

    XCTAssertEqual(pin, Self.validPin)
  }

  func testTrustEvaluatorAcceptsMatchingPinAndRejectsMismatch() throws {
    let trust = try makeTrust()
    let matching = MobileRemoteDaemonServerTrustEvaluator(
      pin: try MobileRemoteDaemonSPKIPin(validating: Self.validPin)
    )
    let mismatched = MobileRemoteDaemonServerTrustEvaluator(
      pin: try MobileRemoteDaemonSPKIPin(
        validating: "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
      )
    )

    XCTAssertTrue(matching.evaluate(trust))
    XCTAssertFalse(mismatched.evaluate(trust))
  }

  func testURLSessionFactoryInstallsPinningDelegate() throws {
    let pin = try MobileRemoteDaemonSPKIPin(validating: Self.validPin)

    let session = MobileRemoteDaemonURLSessionFactory.make(
      configuration: .ephemeral,
      pin: pin
    )
    defer { session.invalidateAndCancel() }

    XCTAssertTrue(session.delegate is MobileRemoteDaemonURLSessionDelegate)
  }

  private func makeTrust() throws -> SecTrust {
    let certificateData = try XCTUnwrap(Data(base64Encoded: Self.certificateBase64))
    let certificate = try XCTUnwrap(
      SecCertificateCreateWithData(nil, certificateData as CFData)
    )
    var trust: SecTrust?
    XCTAssertEqual(
      SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust),
      errSecSuccess
    )
    let resolvedTrust = try XCTUnwrap(trust)
    XCTAssertEqual(
      SecTrustSetAnchorCertificates(resolvedTrust, [certificate] as CFArray),
      errSecSuccess
    )
    XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(resolvedTrust, true), errSecSuccess)
    let verifyDate = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-10T04:00:00Z")
    )
    XCTAssertEqual(SecTrustSetVerifyDate(resolvedTrust, verifyDate as CFDate), errSecSuccess)
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
