import Foundation
import HarnessMonitorCore

extension MobileCommandRecord {
  func remoteRequiredPayload(_ key: String) throws -> String {
    guard let value = remoteOptionalPayload(key) else {
      throw MobileRemoteDaemonSyncError.invalidCommand("\(key) is required")
    }
    return value
  }

  func remoteOptionalPayload(_ key: String) -> String? {
    payload[key]?.remoteTrimmed
  }

  func remoteRequiredSessionID() throws -> String {
    try remoteRequiredTarget(target.sessionID, name: "sessionID")
  }

  func remoteRequiredAgentID() throws -> String {
    try remoteRequiredTarget(target.agentID, name: "agentID")
  }

  func remoteRequiredTaskID() throws -> String {
    try remoteRequiredTarget(target.taskID, name: "taskID")
  }

  func remoteBoolPayload(_ key: String) throws -> Bool? {
    guard let value = remoteOptionalPayload(key)?.lowercased() else {
      return nil
    }
    switch value {
    case "1", "true", "yes": return true
    case "0", "false", "no": return false
    default: throw MobileRemoteDaemonSyncError.invalidCommand("\(key) must be a boolean")
    }
  }

  func remotePositiveIntPayload(_ key: String) throws -> Int? {
    guard let value = remoteOptionalPayload(key) else { return nil }
    guard let result = Int(value), result > 0 else {
      throw MobileRemoteDaemonSyncError.invalidCommand("\(key) must be a positive integer")
    }
    return result
  }

  func remoteCSVPayload(_ key: String) -> [String] {
    remoteOptionalPayload(key)?
      .split(separator: ",")
      .compactMap { String($0).remoteTrimmed } ?? []
  }

  private func remoteRequiredTarget(_ value: String?, name: String) throws -> String {
    guard let value = value?.remoteTrimmed else {
      throw MobileRemoteDaemonSyncError.invalidCommand("\(name) is required")
    }
    return value
  }
}

extension String {
  var remoteTrimmed: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  func remotePathComponent() throws -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard let encoded = addingPercentEncoding(withAllowedCharacters: allowed) else {
      throw MobileRemoteDaemonSyncError.invalidCommand("invalid path component")
    }
    return encoded
  }
}

extension Dictionary where Key == String, Value == Any {
  mutating func add(_ key: String, _ value: Any?) {
    if let value {
      self[key] = value
    }
  }
}
