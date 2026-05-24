import Foundation

enum DashboardReviewsStorageCodec {
  private static let lock = NSLock()
  private static let encoder = JSONEncoder()
  private static let decoder = JSONDecoder()

  static func encodeToString<Value: Encodable>(_ value: Value) -> String {
    lock.lock()
    defer { lock.unlock() }

    guard let data = try? encoder.encode(value),
      let string = String(data: data, encoding: .utf8)
    else {
      return ""
    }
    return string
  }

  static func decode<Value: Decodable>(_ type: Value.Type, from string: String) -> Value? {
    lock.lock()
    defer { lock.unlock() }

    guard
      let data = string.data(using: .utf8),
      let decoded = try? decoder.decode(type, from: data)
    else {
      return nil
    }
    return decoded
  }
}
