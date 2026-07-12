import Foundation
import Security

public enum TaskBoardGitHubCredentialStoreError: LocalizedError, Equatable {
  case unexpectedStatus(OSStatus)
  case invalidPayload

  public var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      "GitHub credential store failed with Keychain status \(status)"
    case .invalidPayload:
      "Stored GitHub credentials are unreadable"
    }
  }
}

public struct TaskBoardGitHubCredentialStore: TaskBoardGitHubCredentialPersisting, Sendable {
  private let service = "io.harnessmonitor.task-board.github-credentials"

  public init() {}

  public func load(
    scope: TaskBoardCredentialScope = .legacy
  ) throws -> TaskBoardGitHubCredentialSnapshot {
    var query = baseQuery(scope: scope)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      break
    case errSecItemNotFound:
      return TaskBoardGitHubCredentialSnapshot()
    default:
      throw TaskBoardGitHubCredentialStoreError.unexpectedStatus(status)
    }

    guard let data = item as? Data else {
      throw TaskBoardGitHubCredentialStoreError.invalidPayload
    }
    do {
      return try JSONDecoder().decode(TaskBoardGitHubCredentialSnapshot.self, from: data)
    } catch {
      throw TaskBoardGitHubCredentialStoreError.invalidPayload
    }
  }

  public func save(_ snapshot: TaskBoardGitHubCredentialSnapshot) throws {
    try save(snapshot, scope: .legacy)
  }

  public func save(
    _ snapshot: TaskBoardGitHubCredentialSnapshot,
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
        throw TaskBoardGitHubCredentialStoreError.unexpectedStatus(addStatus)
      }
    default:
      throw TaskBoardGitHubCredentialStoreError.unexpectedStatus(updateStatus)
    }
  }

  public func delete() throws {
    try delete(scope: .legacy)
  }

  public func delete(scope: TaskBoardCredentialScope) throws {
    let status = SecItemDelete(baseQuery(scope: scope) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw TaskBoardGitHubCredentialStoreError.unexpectedStatus(status)
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
