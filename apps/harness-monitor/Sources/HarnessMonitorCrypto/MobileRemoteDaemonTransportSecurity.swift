import CryptoKit
import Foundation
import Security

enum MobileRemoteDaemonSPKIDERError: Error {
  case malformedCertificate
}

enum MobileRemoteDaemonSPKIDERExtractor {
  static func extract(from certificateDER: Data) throws -> Data {
    let bytes = [UInt8](certificateDER)
    var certificateCursor = MobileRemoteDERCursor(bytes: bytes)
    let certificate = try certificateCursor.read(expectedTag: 0x30)
    guard certificateCursor.isAtEnd else {
      throw MobileRemoteDaemonSPKIDERError.malformedCertificate
    }
    var outerCursor = MobileRemoteDERCursor(bytes: bytes, range: certificate.contentRange)
    let tbsCertificate = try outerCursor.read(expectedTag: 0x30)
    var tbsCursor = MobileRemoteDERCursor(bytes: bytes, range: tbsCertificate.contentRange)
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

private struct MobileRemoteDERElement {
  let fullRange: Range<Int>
  let contentRange: Range<Int>
}

private struct MobileRemoteDERCursor {
  let bytes: [UInt8]
  let endIndex: Int
  var index: Int

  init(bytes: [UInt8], range: Range<Int>? = nil) {
    self.bytes = bytes
    let range = range ?? bytes.indices
    index = range.lowerBound
    endIndex = range.upperBound
  }

  var isAtEnd: Bool { index == endIndex }
  var nextTag: UInt8? { index < endIndex ? bytes[index] : nil }

  mutating func read(expectedTag: UInt8) throws -> MobileRemoteDERElement {
    let start = index
    guard index < endIndex, bytes[index] == expectedTag else {
      throw MobileRemoteDaemonSPKIDERError.malformedCertificate
    }
    index += 1
    let length = try readLength()
    let contentStart = index
    let contentEnd = contentStart + length
    guard contentEnd >= contentStart, contentEnd <= endIndex else {
      throw MobileRemoteDaemonSPKIDERError.malformedCertificate
    }
    index = contentEnd
    return MobileRemoteDERElement(
      fullRange: start..<contentEnd,
      contentRange: contentStart..<contentEnd
    )
  }

  private mutating func readLength() throws -> Int {
    guard index < endIndex else {
      throw MobileRemoteDaemonSPKIDERError.malformedCertificate
    }
    let first = Int(bytes[index])
    index += 1
    if first & 0x80 == 0 {
      return first
    }
    let count = first & 0x7F
    guard count > 0, count <= 4, index + count <= endIndex else {
      throw MobileRemoteDaemonSPKIDERError.malformedCertificate
    }
    var length = 0
    for _ in 0..<count {
      length = (length << 8) | Int(bytes[index])
      index += 1
    }
    return length
  }
}

struct MobileRemoteDaemonServerTrustEvaluator: Sendable {
  let pin: MobileRemoteDaemonSPKIPin

  func evaluate(_ trust: SecTrust) -> Bool {
    var trustError: CFError?
    guard SecTrustEvaluateWithError(trust, &trustError),
      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let leaf = chain.first
    else {
      return false
    }
    let certificateDER = SecCertificateCopyData(leaf) as Data
    guard let spkiDER = try? MobileRemoteDaemonSPKIDERExtractor.extract(from: certificateDER) else {
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

final class MobileRemoteDaemonURLSessionDelegate:
  NSObject, URLSessionDelegate, @unchecked Sendable
{
  private let evaluator: MobileRemoteDaemonServerTrustEvaluator

  init(pin: MobileRemoteDaemonSPKIPin) {
    evaluator = MobileRemoteDaemonServerTrustEvaluator(pin: pin)
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    guard evaluator.evaluate(trust) else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
}

public enum MobileRemoteDaemonURLSessionFactory {
  public static func make(
    configuration: URLSessionConfiguration,
    pin: MobileRemoteDaemonSPKIPin
  ) -> URLSession {
    URLSession(
      configuration: configuration,
      delegate: MobileRemoteDaemonURLSessionDelegate(pin: pin),
      delegateQueue: nil
    )
  }
}
