import CryptoKit
import Foundation
import Security

enum RemoteDaemonSPKIDERError: Error, Equatable {
  case malformedCertificate
}

enum RemoteDaemonSPKIDERExtractor {
  static func extract(from certificateDER: Data) throws -> Data {
    let bytes = [UInt8](certificateDER)
    var certificateCursor = DERCursor(bytes: bytes)
    let certificate = try certificateCursor.read(expectedTag: 0x30)
    guard certificateCursor.isAtEnd else {
      throw RemoteDaemonSPKIDERError.malformedCertificate
    }
    var outerCursor = DERCursor(bytes: bytes, range: certificate.contentRange)
    let tbsCertificate = try outerCursor.read(expectedTag: 0x30)
    var tbsCursor = DERCursor(bytes: bytes, range: tbsCertificate.contentRange)
    if tbsCursor.nextTag == 0xA0 {
      _ = try tbsCursor.read(expectedTag: 0xA0)
    }
    _ = try tbsCursor.read(expectedTag: 0x02)
    for _ in 0..<4 {
      _ = try tbsCursor.read(expectedTag: 0x30)
    }
    let subjectPublicKeyInfo = try tbsCursor.read(expectedTag: 0x30)
    return Data(bytes[subjectPublicKeyInfo.fullRange])
  }
}

private struct DERElement {
  let fullRange: Range<Int>
  let contentRange: Range<Int>
}

private struct DERCursor {
  let bytes: [UInt8]
  let endIndex: Int
  var index: Int

  init(bytes: [UInt8], range: Range<Int>? = nil) {
    self.bytes = bytes
    let range = range ?? bytes.indices
    self.index = range.lowerBound
    self.endIndex = range.upperBound
  }

  var isAtEnd: Bool { index == endIndex }
  var nextTag: UInt8? { index < endIndex ? bytes[index] : nil }

  mutating func read(expectedTag: UInt8) throws -> DERElement {
    let start = index
    guard index < endIndex, bytes[index] == expectedTag else {
      throw RemoteDaemonSPKIDERError.malformedCertificate
    }
    index += 1
    let length = try readLength()
    let contentStart = index
    let contentEnd = contentStart + length
    guard contentEnd >= contentStart, contentEnd <= endIndex else {
      throw RemoteDaemonSPKIDERError.malformedCertificate
    }
    index = contentEnd
    return DERElement(
      fullRange: start..<contentEnd,
      contentRange: contentStart..<contentEnd
    )
  }

  private mutating func readLength() throws -> Int {
    guard index < endIndex else {
      throw RemoteDaemonSPKIDERError.malformedCertificate
    }
    let first = Int(bytes[index])
    index += 1
    if first & 0x80 == 0 {
      return first
    }
    let count = first & 0x7F
    guard count > 0, count <= 4, index + count <= endIndex else {
      throw RemoteDaemonSPKIDERError.malformedCertificate
    }
    var length = 0
    for _ in 0..<count {
      length = (length << 8) | Int(bytes[index])
      index += 1
    }
    return length
  }
}

struct RemoteDaemonServerTrustEvaluator: Sendable {
  let pin: RemoteDaemonSPKIPin

  func evaluate(_ trust: SecTrust) -> Bool {
    var trustError: CFError?
    guard SecTrustEvaluateWithError(trust, &trustError) else {
      return false
    }
    guard
      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let leaf = chain.first
    else {
      return false
    }
    let certificateDER = SecCertificateCopyData(leaf) as Data
    guard let spkiDER = try? RemoteDaemonSPKIDERExtractor.extract(from: certificateDER) else {
      return false
    }
    let digest = Data(SHA256.hash(data: spkiDER))
    return constantTimeEqual(digest, pin.digest)
  }

  private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { difference, pair in
      difference | (pair.0 ^ pair.1)
    } == 0
  }
}

final class RemoteDaemonURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  private let trustEvaluator: RemoteDaemonServerTrustEvaluator

  init(pin: RemoteDaemonSPKIPin) {
    self.trustEvaluator = RemoteDaemonServerTrustEvaluator(pin: pin)
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    guard trustEvaluator.evaluate(trust) else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
}

enum HarnessMonitorURLSessionFactory {
  static func make(
    configuration: URLSessionConfiguration,
    serverTrust: HarnessMonitorServerTrust
  ) -> URLSession {
    switch serverTrust {
    case .system:
      URLSession(configuration: configuration)
    case .spkiSHA256(let pin):
      URLSession(
        configuration: configuration,
        delegate: RemoteDaemonURLSessionDelegate(pin: pin),
        delegateQueue: nil
      )
    }
  }
}
