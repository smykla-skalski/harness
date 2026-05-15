import Foundation
import Security

public enum TaskBoardTodoistCredentialStoreError: LocalizedError, Equatable {
  case unexpectedStatus(OSStatus)
  case invalidPayload

  public var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      "Todoist credential store failed with Keychain status \(status)."
    case .invalidPayload:
      "Stored Todoist credentials are unreadable."
    }
  }
}

public struct TaskBoardTodoistCredentialStore: Sendable {
  private let service = "io.harnessmonitor.task-board.todoist-credentials"
  private let account = "default"

  public init() {}

  public func load() throws -> TaskBoardTodoistCredentialSnapshot {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      break
    case errSecItemNotFound:
      return TaskBoardTodoistCredentialSnapshot()
    default:
      throw TaskBoardTodoistCredentialStoreError.unexpectedStatus(status)
    }

    guard let data = item as? Data else {
      throw TaskBoardTodoistCredentialStoreError.invalidPayload
    }
    do {
      return try JSONDecoder().decode(TaskBoardTodoistCredentialSnapshot.self, from: data)
    } catch {
      throw TaskBoardTodoistCredentialStoreError.invalidPayload
    }
  }

  public func save(_ snapshot: TaskBoardTodoistCredentialSnapshot) throws {
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
        throw TaskBoardTodoistCredentialStoreError.unexpectedStatus(addStatus)
      }
    default:
      throw TaskBoardTodoistCredentialStoreError.unexpectedStatus(updateStatus)
    }
  }

  public func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw TaskBoardTodoistCredentialStoreError.unexpectedStatus(status)
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
