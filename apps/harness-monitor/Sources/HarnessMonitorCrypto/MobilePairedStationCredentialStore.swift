import Foundation
import Security

public enum MobilePairedStationCredentialStoreError: Error, Equatable, Sendable {
  case unexpectedKeychainStatus(Int32)
  case invalidKeychainPayload
}

public protocol MobilePairedStationCredentialStore: Sendable {
  func save(_ credential: MobilePairedStationCredential) async throws
  func load(stationID: String) async throws -> MobilePairedStationCredential?
  func loadAll() async throws -> [MobilePairedStationCredential]
  func delete(stationID: String) async throws
}

public actor InMemoryMobilePairedStationCredentialStore: MobilePairedStationCredentialStore {
  private var credentials: [String: MobilePairedStationCredential]

  public init(credentials: [MobilePairedStationCredential] = []) {
    self.credentials = Dictionary(uniqueKeysWithValues: credentials.map { ($0.stationID, $0) })
  }

  public func save(_ credential: MobilePairedStationCredential) async throws {
    credentials[credential.stationID] = credential
  }

  public func load(stationID: String) async throws -> MobilePairedStationCredential? {
    credentials[stationID]
  }

  public func loadAll() async throws -> [MobilePairedStationCredential] {
    credentials.values.sorted(by: credentialSort)
  }

  public func delete(stationID: String) async throws {
    credentials.removeValue(forKey: stationID)
  }
}

public struct KeychainMobilePairedStationCredentialStore: MobilePairedStationCredentialStore {
  private let service: String
  private let accessGroup: String?
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    service: String = "io.harnessmonitor.mobile.paired-stations",
    accessGroup: String? = nil
  ) {
    self.service = service
    self.accessGroup = accessGroup
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  public func save(_ credential: MobilePairedStationCredential) async throws {
    let data = try encoder.encode(credential)
    var addQuery = baseQuery(account: credential.stationID)
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecSuccess {
      return
    }
    if status == errSecDuplicateItem {
      var updateQuery = baseQuery(account: credential.stationID)
      updateQuery.removeValue(forKey: kSecReturnData as String)
      let attributes = [kSecValueData as String: data]
      let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
      guard updateStatus == errSecSuccess else {
        throw MobilePairedStationCredentialStoreError.unexpectedKeychainStatus(updateStatus)
      }
      return
    }
    throw MobilePairedStationCredentialStoreError.unexpectedKeychainStatus(status)
  }

  public func load(stationID: String) async throws -> MobilePairedStationCredential? {
    var query = baseQuery(account: stationID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw MobilePairedStationCredentialStoreError.unexpectedKeychainStatus(status)
    }
    guard let data = result as? Data else {
      throw MobilePairedStationCredentialStoreError.invalidKeychainPayload
    }
    return try decoder.decode(MobilePairedStationCredential.self, from: data)
  }

  public func loadAll() async throws -> [MobilePairedStationCredential] {
    var query = baseQuery(account: nil)
    query[kSecReturnData as String] = true
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return []
    }
    guard status == errSecSuccess else {
      throw MobilePairedStationCredentialStoreError.unexpectedKeychainStatus(status)
    }
    guard let rows = result as? [[String: Any]] else {
      throw MobilePairedStationCredentialStoreError.invalidKeychainPayload
    }
    return
      try rows
      .compactMap { row -> MobilePairedStationCredential? in
        guard let data = row[kSecValueData as String] as? Data else {
          throw MobilePairedStationCredentialStoreError.invalidKeychainPayload
        }
        return try decoder.decode(MobilePairedStationCredential.self, from: data)
      }
      .sorted(by: credentialSort)
  }

  public func delete(stationID: String) async throws {
    let status = SecItemDelete(baseQuery(account: stationID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MobilePairedStationCredentialStoreError.unexpectedKeychainStatus(status)
    }
  }

  private func baseQuery(account: String?) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ]
    if let account {
      query[kSecAttrAccount as String] = account
    }
    if let accessGroup {
      query[kSecAttrAccessGroup as String] = accessGroup
    }
    return query
  }
}

private func credentialSort(
  _ lhs: MobilePairedStationCredential,
  _ rhs: MobilePairedStationCredential
) -> Bool {
  if lhs.defaultStation != rhs.defaultStation {
    return lhs.defaultStation
  }
  return lhs.pairedAt > rhs.pairedAt
}
