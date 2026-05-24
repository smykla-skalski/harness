import Foundation

extension [String: JSONValue] {
  func stringValue(for key: String) -> String? {
    guard case .string(let value)? = self[key] else {
      return nil
    }
    return value
  }

  func boolValue(for key: String) -> Bool? {
    guard case .bool(let value)? = self[key] else {
      return nil
    }
    return value
  }

  func arrayStringValues(for key: String) -> [String] {
    guard case .array(let values)? = self[key] else {
      return []
    }
    return values.compactMap {
      guard case .string(let value) = $0 else {
        return nil
      }
      return value
    }
  }

  func uint64Value(for key: String) -> UInt64? {
    guard case .number(let value)? = self[key], value >= 0 else {
      return nil
    }
    return UInt64(value)
  }
}
