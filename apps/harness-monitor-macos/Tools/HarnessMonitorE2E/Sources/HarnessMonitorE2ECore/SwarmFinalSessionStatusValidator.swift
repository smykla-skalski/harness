import Foundation

public enum SwarmFinalSessionStatusValidator {
  public struct ValidationFailure: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
  }

  public static func validate(_ data: Data) throws {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ValidationFailure(message: "swarm final status payload was not a JSON object")
    }
    guard let status = json["status"] as? String, status == "ended" else {
      throw ValidationFailure(message: "swarm final status was not ended")
    }
    let tasks = tasks(from: json)
    let hasArbitration = tasks.contains {
      let value = $0["arbitration"]
      return value != nil && !(value is NSNull)
    }
    let hasObserveTask = tasks.contains { ($0["source"] as? String) == "observe" }
    guard hasArbitration, hasObserveTask else {
      throw ValidationFailure(
        message: "swarm final status missing expected arbitration or observe tasks"
      )
    }
  }

  static func tasks(from json: [String: Any]) -> [[String: Any]] {
    if let array = json["tasks"] as? [[String: Any]] {
      return array
    }
    if let map = json["tasks"] as? [String: Any] {
      return map.values.compactMap { $0 as? [String: Any] }
    }
    return []
  }
}
