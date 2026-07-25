import Foundation
import Security

/// Deletes the Keychain entry the retired Todoist integration left behind.
///
/// The service is removed in a single call rather than one delete per scope,
/// because every database instance minted its own account under it and none of
/// them are reachable from the app any more. The `harness` CLI shares the
/// `default` account but deliberately does not purge: it would have to delete an
/// item this app created, which prompts for Keychain access on every run - a bad
/// trade for one orphaned entry that this app removes on its next launch anyway.
struct TaskBoardTodoistCredentialPurge: Sendable {
  static let service = "io.harnessmonitor.task-board.todoist-credentials"

  private let deleteService: @Sendable () -> OSStatus

  init(deleteService: @escaping @Sendable () -> OSStatus) {
    self.deleteService = deleteService
  }

  static var keychain: Self {
    Self {
      SecItemDelete(
        [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
        ] as CFDictionary
      )
    }
  }

  /// Reports whether an entry was actually removed, so the caller logs the
  /// one-time purge instead of the no-op that follows it on every later launch.
  @discardableResult
  func run() -> Bool {
    let status = deleteService()
    switch status {
    case errSecSuccess:
      return true
    case errSecItemNotFound:
      return false
    default:
      HarnessMonitorLogger.store.error(
        "Todoist credential purge failed with Keychain status \(status)"
      )
      return false
    }
  }
}

/// Records purge attempts instead of touching the Keychain, so test processes
/// never trigger the macOS access prompt.
final class RecordingTaskBoardTodoistCredentialPurge: @unchecked Sendable {
  private let lock = NSLock()
  private var attemptCountValue = 0

  var attemptCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return attemptCountValue
  }

  var purge: TaskBoardTodoistCredentialPurge {
    TaskBoardTodoistCredentialPurge { [self] in
      lock.lock()
      defer { lock.unlock() }
      attemptCountValue += 1
      return errSecItemNotFound
    }
  }
}
