import CryptoKit
import Foundation
import Security

public enum TaskBoardKeyMaterialStoreError: LocalizedError, Equatable {
  case unexpectedStatus(OSStatus)
  case invalidPayload

  public var errorDescription: String? {
    switch self {
    case .unexpectedStatus(let status):
      "Key-material store failed with Keychain status \(status)."
    case .invalidPayload:
      "Stored key material is unreadable."
    }
  }
}

public struct TaskBoardKeyMaterialSnapshot: Codable, Equatable, Sendable {
  public var privateKey: String?
  public var passphrase: String?
  public var keyPath: String?
  public var keyId: String?

  public init(
    privateKey: String? = nil,
    passphrase: String? = nil,
    keyPath: String? = nil,
    keyId: String? = nil
  ) {
    self.privateKey = privateKey
    self.passphrase = passphrase
    self.keyPath = keyPath
    self.keyId = keyId
  }

  public var isEmpty: Bool {
    privateKey == nil && passphrase == nil && keyPath == nil && keyId == nil
  }

  enum CodingKeys: String, CodingKey {
    case privateKey = "private_key"
    case passphrase
    case keyPath = "key_path"
    case keyId = "key_id"
  }
}

public struct TaskBoardKeyMaterialStore: Sendable {
  public enum Kind: String, Sendable {
    case ssh = "io.harnessmonitor.task-board.ssh-key"
    case signingSsh = "io.harnessmonitor.task-board.signing-ssh-key"
    case gpg = "io.harnessmonitor.task-board.gpg-key"
  }

  public enum Scope: Hashable, Sendable {
    case global
    case repository(String)

    public var account: String {
      switch self {
      case .global:
        "global"
      case .repository(let slug):
        "repo." + Self.hashRepository(slug)
      }
    }

    private static func hashRepository(_ slug: String) -> String {
      let normalized = slug.lowercased()
      let digest = Insecure.SHA1.hash(data: Data(normalized.utf8))
      return digest.map { String(format: "%02x", $0) }.joined()
    }
  }

  private let kind: Kind

  public init(kind: Kind) {
    self.kind = kind
  }

  public func load(scope: Scope = .global) throws -> TaskBoardKeyMaterialSnapshot {
    var query = baseQuery(scope: scope)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      break
    case errSecItemNotFound:
      return TaskBoardKeyMaterialSnapshot()
    default:
      throw TaskBoardKeyMaterialStoreError.unexpectedStatus(status)
    }

    guard let data = item as? Data else {
      throw TaskBoardKeyMaterialStoreError.invalidPayload
    }
    do {
      return try JSONDecoder().decode(TaskBoardKeyMaterialSnapshot.self, from: data)
    } catch {
      throw TaskBoardKeyMaterialStoreError.invalidPayload
    }
  }

  public func save(_ snapshot: TaskBoardKeyMaterialSnapshot, scope: Scope = .global) throws {
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
        throw TaskBoardKeyMaterialStoreError.unexpectedStatus(addStatus)
      }
    default:
      throw TaskBoardKeyMaterialStoreError.unexpectedStatus(updateStatus)
    }
  }

  public func delete(scope: Scope = .global) throws {
    let status = SecItemDelete(baseQuery(scope: scope) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw TaskBoardKeyMaterialStoreError.unexpectedStatus(status)
    }
  }

  private func baseQuery(scope: Scope) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: kind.rawValue,
      kSecAttrAccount as String: scope.account,
    ]
  }
}
