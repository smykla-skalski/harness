import Foundation
import Security

public enum RemoteDaemonKeychainTokenStoreError: LocalizedError, Equatable {
  case invalidToken
  case invalidPayload
  case unexpectedStatus(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .invalidToken:
      "The remote daemon token is empty"
    case .invalidPayload:
      "The remote daemon token in Keychain is unreadable"
    case .unexpectedStatus(let status):
      "Remote daemon Keychain access failed with status \(status)"
    }
  }
}

public struct RemoteDaemonKeychainTokenStore: RemoteDaemonTokenPersisting, Sendable {
  public static let defaultService = "io.harnessmonitor.remote-daemon.token"

  private let service: String

  public init(service: String = Self.defaultService) {
    self.service = service
  }

  public func loadToken(profileID: UUID) throws -> String? {
    var query = baseQuery(profileID: profileID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard
        let data = result as? Data,
        let token = String(data: data, encoding: .utf8),
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw RemoteDaemonKeychainTokenStoreError.invalidPayload
      }
      return token
    case errSecItemNotFound:
      return nil
    default:
      throw RemoteDaemonKeychainTokenStoreError.unexpectedStatus(status)
    }
  }

  public func saveToken(_ token: String, profileID: UUID) throws {
    guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RemoteDaemonKeychainTokenStoreError.invalidToken
    }
    let data = Data(token.utf8)
    let updateStatus = SecItemUpdate(
      baseQuery(profileID: profileID) as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var query = baseQuery(profileID: profileID)
      query[kSecValueData as String] = data
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw RemoteDaemonKeychainTokenStoreError.unexpectedStatus(addStatus)
      }
    default:
      throw RemoteDaemonKeychainTokenStoreError.unexpectedStatus(updateStatus)
    }
  }

  public func deleteToken(profileID: UUID) throws {
    let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw RemoteDaemonKeychainTokenStoreError.unexpectedStatus(status)
    }
  }

  private func baseQuery(profileID: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: profileID.uuidString.lowercased(),
    ]
  }
}
