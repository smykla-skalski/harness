import Foundation
import LocalAuthentication

/// Local-authentication gate the store runs before signing a command. Injected
/// so tests can drive the queue flow without a biometric prompt.
public protocol MirrorAuthenticating: Sendable {
  func authenticate(reason: String) async -> Bool
}

/// The live gate: device owner authentication via `LAContext`.
public struct LocalAuthenticationAuthenticator: MirrorAuthenticating {
  public init() {}

  public func authenticate(reason: String) async -> Bool {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      return false
    }
    return await withCheckedContinuation { continuation in
      context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: reason
      ) { success, _ in
        continuation.resume(returning: success)
      }
    }
  }
}
