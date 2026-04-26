import Foundation

/// Sidecar file in the recorder's control directory that lets the UI-test host
/// hand the freshly-launched application's PID to the recorder. The recorder
/// uses this to filter shareable windows down to the single process the UI test
/// just spawned, even when the user has the shipping Harness Monitor.app open
/// or another orphaned UI-test host happens to share the bundle identifier.
public enum RecordingControlPidFile {
  public static let fileName = "start.pid"

  @discardableResult
  public static func write(pid: Int32, into controlDirectory: URL) throws -> URL {
    try FileManager.default.createDirectory(
      at: controlDirectory,
      withIntermediateDirectories: true
    )
    let target = controlDirectory.appendingPathComponent(fileName)
    try Data("\(pid)\n".utf8).write(to: target, options: .atomic)
    return target
  }

  public static func read(from controlDirectory: URL) -> Int32? {
    let target = controlDirectory.appendingPathComponent(fileName)
    guard let raw = try? String(contentsOf: target, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return Int32(trimmed)
  }
}
