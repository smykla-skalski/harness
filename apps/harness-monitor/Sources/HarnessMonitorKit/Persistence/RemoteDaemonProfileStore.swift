import Foundation

public enum RemoteDaemonProfileError: LocalizedError, Equatable {
  case invalidEndpoint
  case invalidProfile
  case invalidStoredProfiles
  case profileNotFound
  case missingToken
  case revoked

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "The remote daemon endpoint must be an HTTPS origin"
    case .invalidProfile:
      "The remote daemon profile is invalid"
    case .invalidStoredProfiles:
      "Stored remote daemon profiles are unreadable"
    case .profileNotFound:
      "The active remote daemon profile was not found"
    case .missingToken:
      "The active remote daemon token is missing from Keychain"
    case .revoked:
      "The active remote daemon client has been revoked"
    }
  }
}

public protocol RemoteDaemonProfilePersisting: Sendable {
  func load() throws -> RemoteDaemonProfileState
  func save(_ state: RemoteDaemonProfileState) throws
}

public protocol RemoteDaemonTokenPersisting: Sendable {
  func loadToken(profileID: UUID) throws -> String?
  func saveToken(_ token: String, profileID: UUID) throws
  func deleteToken(profileID: UUID) throws
}

public struct UserDefaultsRemoteDaemonProfileStore: @unchecked Sendable,
  RemoteDaemonProfilePersisting
{
  public static let defaultStorageKey = "io.harnessmonitor.remote-daemon.profiles"

  private let defaults: UserDefaults
  private let storageKey: String

  public init(
    defaults: UserDefaults = .standard,
    storageKey: String = Self.defaultStorageKey
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
  }

  public func load() throws -> RemoteDaemonProfileState {
    guard let data = defaults.data(forKey: storageKey) else {
      return RemoteDaemonProfileState()
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(RemoteDaemonProfileState.self, from: data).validated()
    } catch {
      throw RemoteDaemonProfileError.invalidStoredProfiles
    }
  }

  public func save(_ state: RemoteDaemonProfileState) throws {
    let state = try state.validated()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    do {
      defaults.set(try encoder.encode(state), forKey: storageKey)
    } catch {
      throw RemoteDaemonProfileError.invalidStoredProfiles
    }
  }
}
