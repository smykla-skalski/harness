import Foundation
import Security

public enum MobileDeviceIdentityStoreError: Error, Equatable, Sendable {
  case unexpectedKeychainStatus(Int32)
  case invalidKeychainPayload
}

public protocol MobileDeviceIdentityStore: Sendable {
  func save(_ identity: MobileDeviceIdentity) async throws
  func load(id: String) async throws -> MobileDeviceIdentity?
  func delete(id: String) async throws
}

public actor InMemoryMobileDeviceIdentityStore: MobileDeviceIdentityStore {
  private var identities: [String: MobileDeviceIdentity]

  public init(identities: [MobileDeviceIdentity] = []) {
    self.identities = Dictionary(uniqueKeysWithValues: identities.map { ($0.id, $0) })
  }

  public func save(_ identity: MobileDeviceIdentity) async throws {
    identities[identity.id] = identity
  }

  public func load(id: String) async throws -> MobileDeviceIdentity? {
    identities[id]
  }

  public func delete(id: String) async throws {
    identities.removeValue(forKey: id)
  }
}

public struct KeychainMobileDeviceIdentityStore: MobileDeviceIdentityStore {
  private let service: String
  private let accessGroup: String?
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    service: String = "io.harnessmonitor.mobile.identity",
    accessGroup: String? = nil
  ) {
    self.service = service
    self.accessGroup = accessGroup
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  public func save(_ identity: MobileDeviceIdentity) async throws {
    let data = try encoder.encode(identity)
    var addQuery = baseQuery(account: identity.id)
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecSuccess {
      return
    }
    if status == errSecDuplicateItem {
      var updateQuery = baseQuery(account: identity.id)
      updateQuery.removeValue(forKey: kSecReturnData as String)
      let attributes = [kSecValueData as String: data]
      let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
      guard updateStatus == errSecSuccess else {
        throw MobileDeviceIdentityStoreError.unexpectedKeychainStatus(updateStatus)
      }
      return
    }
    throw MobileDeviceIdentityStoreError.unexpectedKeychainStatus(status)
  }

  public func load(id: String) async throws -> MobileDeviceIdentity? {
    var query = baseQuery(account: id)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw MobileDeviceIdentityStoreError.unexpectedKeychainStatus(status)
    }
    guard let data = result as? Data else {
      throw MobileDeviceIdentityStoreError.invalidKeychainPayload
    }
    return try decoder.decode(MobileDeviceIdentity.self, from: data)
  }

  public func delete(id: String) async throws {
    let status = SecItemDelete(baseQuery(account: id) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MobileDeviceIdentityStoreError.unexpectedKeychainStatus(status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    return query
  }
}
