import Foundation

final class SessionInvalidationProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var invalidated = false

  var didInvalidate: Bool {
    lock.withLock { invalidated }
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
    lock.withLock {
      invalidated = true
    }
  }
}
