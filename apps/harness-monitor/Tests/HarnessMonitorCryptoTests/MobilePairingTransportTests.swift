import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import XCTest

final class MobilePairingTransportTests: XCTestCase {
  override func setUp() {
    super.setUp()
    StationPairingURLProtocol.reset()
  }

  override func tearDown() {
    StationPairingURLProtocol.reset()
    super.tearDown()
  }

  func testRejectedPairingReportsTheServerStatus() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    StationPairingURLProtocol.respond(statusCode: 409, body: "{}")
    let transport = URLSessionMobilePairingTransport(session: makeSession())
    let invitation = makePairingInvitation(now: now)

    do {
      _ = try await transport.sendPairingRequest(
        makePairingRequest(invitation: invitation),
        to: invitation.endpoint
      )
      XCTFail("expected the station rejection to surface")
    } catch let error as MobilePairingError {
      XCTAssertEqual(error, .serverStatus(409))
    }
  }

  func testEveryRejectionStatusReadsAsARejectionRatherThanABadLink() {
    let unrecognized = localizedDescription(for: .unsupportedURL("harness://pair?payload=abc"))

    for statusCode in [400, 403, 409, 410, 429, 500, 503] {
      let description = localizedDescription(for: .serverStatus(statusCode))

      XCTAssertNotEqual(description, unrecognized)
      XCTAssertTrue(description.contains("HTTP \(statusCode)"), description)
    }
  }

  private func localizedDescription(for error: MobilePairingError) -> String {
    (error as NSError).localizedDescription
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StationPairingURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func makePairingRequest(
    invitation: MobilePairingInvitation
  ) -> MobilePairingRequest {
    MobilePairingRequest(
      stationID: invitation.stationID,
      nonce: invitation.nonce,
      deviceID: "device-phone",
      deviceDisplayName: "Phone",
      deviceSigningPublicKeyRawRepresentation: Data(repeating: 1, count: 32),
      deviceAgreementKeyRawRepresentation: Data(repeating: 2, count: 32),
      deviceSigningKeyFingerprint: "00:11:22:33:44:55:66:77"
    )
  }
}

private final class StationPairingURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var responseStatusCode = 200
  nonisolated(unsafe) private static var responseBody = Data()

  static func reset() {
    lock.withLock {
      responseStatusCode = 200
      responseBody = Data()
    }
  }

  static func respond(statusCode: Int, body: String) {
    lock.withLock {
      responseStatusCode = statusCode
      responseBody = Data(body.utf8)
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let state = Self.lock.withLock { (Self.responseStatusCode, Self.responseBody) }
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: state.0,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: state.1)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
