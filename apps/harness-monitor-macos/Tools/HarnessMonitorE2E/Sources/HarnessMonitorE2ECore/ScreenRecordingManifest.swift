import Foundation

public struct ScreenRecordingManifest: Codable {
  public var processID: Int32
  public var outputPath: String
  public var logPath: String

  public init(processID: Int32, outputPath: String, logPath: String) {
    self.processID = processID
    self.outputPath = outputPath
    self.logPath = logPath
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }

  public static func decode(from data: Data) throws -> Self {
    try JSONDecoder().decode(Self.self, from: data)
  }

  public func write(to url: URL) throws {
    try encoded().write(to: url, options: .atomic)
  }

  public static func load(from url: URL) throws -> Self {
    try decode(from: Data(contentsOf: url))
  }
}
