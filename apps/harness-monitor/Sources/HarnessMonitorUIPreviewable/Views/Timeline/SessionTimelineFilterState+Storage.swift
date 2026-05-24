import Foundation

enum SessionTimelineFilterDefaults {
  static let persistenceModeKey = "harness.session.timeline.filters.persistence-mode"
  static let appStateKey = "harness.session.timeline.filters.app-state"
  static let sceneRegistryKey = "harness.session.timeline.filters.scene-registry"

  static let defaultPersistenceMode = SessionTimelineFilterPersistenceMode.sessionWindow
  static let defaultAppStateRawValue = ""

  static func readPersistenceModeRawValue(userDefaults: UserDefaults = .standard) -> String {
    userDefaults.string(forKey: persistenceModeKey) ?? defaultPersistenceMode.rawValue
  }

  static func readAppStateRawValue(userDefaults: UserDefaults = .standard) -> String {
    userDefaults.string(forKey: appStateKey) ?? defaultAppStateRawValue
  }

  static func writeAppStateRawValue(
    _ rawValue: String,
    userDefaults: UserDefaults = .standard
  ) {
    if rawValue.isEmpty {
      userDefaults.removeObject(forKey: appStateKey)
    } else {
      userDefaults.set(rawValue, forKey: appStateKey)
    }
  }
}

struct SessionTimelineStoredFilterRegistry: Equatable, Sendable {
  var statesBySessionID: [String: SessionTimelineFilterState] = [:]

  func state(for sessionID: String) -> SessionTimelineFilterState? {
    statesBySessionID[sessionID]
  }

  mutating func set(_ state: SessionTimelineFilterState, for sessionID: String) {
    if state.isEmpty {
      statesBySessionID.removeValue(forKey: sessionID)
    } else {
      statesBySessionID[sessionID] = state
    }
  }

  func encodedString() -> String? {
    let storage = SessionTimelineStoredFilterRegistryStorage(
      statesBySessionID: statesBySessionID.mapValues(\.storage)
    )
    return try? SessionTimelineFilterState.encoder.encodeToString(storage)
  }

  static func decode(from rawValue: String) -> Self {
    guard
      !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let data = rawValue.data(using: .utf8),
      let storage = try? SessionTimelineFilterState.decoder.decode(
        SessionTimelineStoredFilterRegistryStorage.self,
        from: data
      )
    else {
      return .init()
    }
    let statesBySessionID = storage.statesBySessionID.mapValues(
      SessionTimelineFilterState.init(storage:)
    )
    return Self(
      statesBySessionID: statesBySessionID
    )
  }
}

struct SessionTimelineFilterStateStorage: Codable {
  let query: String
  let searchScope: String
  let tones: [String]
  let eventTypes: [String]
  let agents: [String]
  let tasks: [String]
  let decisionSeverities: [String]
  let semanticProperties: [String]
  let rawPayloadKeys: [String]
}

struct SessionTimelineStoredFilterRegistryStorage: Codable {
  let statesBySessionID: [String: SessionTimelineFilterStateStorage]
}

struct StableFilterStateEncoder {
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  func encodeToString<Value: Encodable>(_ value: Value) throws -> String {
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw EncodingError.invalidValue(
        value,
        .init(codingPath: [], debugDescription: "Failed to encode filter state as UTF-8")
      )
    }
    return string
  }
}
