import Foundation

/// Open-set enum for daemon-emitted string values. Conforming types decode any
/// unrecognized raw value into `.unknown(raw)` so a Monitor build can render
/// older daemons emitting a newly-added enum case without erroring.
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
