import Foundation

/// Open-set enum support kept local because PolicyModels cannot depend on HarnessMonitorKit.
public protocol TaskBoardOpenEnum: Codable, Hashable, Sendable {
  init(rawValue: String)
  var rawValue: String { get }
}

extension TaskBoardOpenEnum {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
