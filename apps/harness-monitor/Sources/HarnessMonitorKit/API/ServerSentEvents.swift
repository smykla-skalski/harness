import Foundation

public struct ServerSentEventFrame: Equatable, Sendable {
  public let event: String?
  public let data: String
}

public struct ServerSentEventParser: Sendable {
  private var currentEvent: String?
  private var currentDataLines: [String] = []

  public init() {}

  public mutating func push(line: String) -> ServerSentEventFrame? {
    if line.isEmpty {
      return flush()
    }

    if line.hasPrefix(":") {
      return nil
    }

    if let eventName = fieldValue(for: "event", in: line) {
      currentEvent = eventName
      return nil
    }

    if let data = fieldValue(for: "data", in: line) {
      currentDataLines.append(data)
    }

    return nil
  }

  public mutating func finish() -> ServerSentEventFrame? {
    flush()
  }

  private mutating func flush() -> ServerSentEventFrame? {
    guard currentEvent != nil || !currentDataLines.isEmpty else {
      currentEvent = nil
      currentDataLines.removeAll(keepingCapacity: true)
      return nil
    }

    let frame = ServerSentEventFrame(
      event: currentEvent,
      data: currentDataLines.joined(separator: "\n")
    )
    currentEvent = nil
    currentDataLines.removeAll(keepingCapacity: true)
    return frame
  }

  private func fieldValue(for key: String, in line: String) -> String? {
    let prefix = "\(key):"
    guard line.hasPrefix(prefix) else {
      return nil
    }

    let rawValue = line.dropFirst(prefix.count)
    if rawValue.first == " " {
      return String(rawValue.dropFirst())
    }
    return String(rawValue)
  }
}
