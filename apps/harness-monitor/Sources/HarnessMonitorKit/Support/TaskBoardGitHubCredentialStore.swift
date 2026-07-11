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
  private let account = "default"

  public init() {}

  public func load() throws -> TaskBoardGitHubCredentialSnapshot {
    var query = baseQuery
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
    if snapshot.isEmpty {
      try delete()
      return
    }

    let data = try JSONEncoder().encode(snapshot)
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var addQuery = baseQuery
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
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw TaskBoardGitHubCredentialStoreError.unexpectedStatus(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
