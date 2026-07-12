import Foundation
import Security

public enum TaskBoardOpenRouterCredentialStoreError: LocalizedError, Equatable {
  case unexpectedStatus(OSStatus)
  case invalidPayload

  public var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      "OpenRouter credential store failed with Keychain status \(status)"
    case .invalidPayload:
      "Stored OpenRouter credentials are unreadable"
    }
  }
}

public struct TaskBoardOpenRouterCredentialStore: TaskBoardOpenRouterCredentialPersisting, Sendable
{
  private let service = "io.harnessmonitor.task-board.openrouter-credentials"

  public init() {}

  public func load(
    scope: TaskBoardCredentialScope = .legacy
  ) throws -> TaskBoardOpenRouterCredentialSnapshot {
    var query = baseQuery(scope: scope)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      break
    case errSecItemNotFound:
      return TaskBoardOpenRouterCredentialSnapshot()
    default:
      throw TaskBoardOpenRouterCredentialStoreError.unexpectedStatus(status)
    }

    guard let data = item as? Data else {
      throw TaskBoardOpenRouterCredentialStoreError.invalidPayload
    }
    do {
      return try JSONDecoder().decode(TaskBoardOpenRouterCredentialSnapshot.self, from: data)
    } catch {
      throw TaskBoardOpenRouterCredentialStoreError.invalidPayload
    }
  }

  public func save(_ snapshot: TaskBoardOpenRouterCredentialSnapshot) throws {
    try save(snapshot, scope: .legacy)
  }

  public func save(
    _ snapshot: TaskBoardOpenRouterCredentialSnapshot,
    scope: TaskBoardCredentialScope
  ) throws {
    if snapshot.isEmpty {
      try delete(scope: scope)
      return
    }

    let data = try JSONEncoder().encode(snapshot)
    let updateStatus = SecItemUpdate(
      baseQuery(scope: scope) as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var addQuery = baseQuery(scope: scope)
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw TaskBoardOpenRouterCredentialStoreError.unexpectedStatus(addStatus)
      }
    default:
      throw TaskBoardOpenRouterCredentialStoreError.unexpectedStatus(updateStatus)
    }
  }

  public func delete() throws {
    try delete(scope: .legacy)
  }

  public func delete(scope: TaskBoardCredentialScope) throws {
    let status = SecItemDelete(baseQuery(scope: scope) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw TaskBoardOpenRouterCredentialStoreError.unexpectedStatus(status)
    }
  }

  private func baseQuery(scope: TaskBoardCredentialScope) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: scope.account,
    ]
  }
}
