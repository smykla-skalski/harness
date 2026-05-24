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
  private let account = "default"

  public init() {}

  public func load() throws -> TaskBoardOpenRouterCredentialSnapshot {
    var query = baseQuery
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
        throw TaskBoardOpenRouterCredentialStoreError.unexpectedStatus(addStatus)
      }
    default:
      throw TaskBoardOpenRouterCredentialStoreError.unexpectedStatus(updateStatus)
    }
  }

  public func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw TaskBoardOpenRouterCredentialStoreError.unexpectedStatus(status)
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
