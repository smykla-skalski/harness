import Foundation

enum HarnessMonitorRequestID {
  static func next() -> String {
    UUID().uuidString.lowercased()
  }
}
