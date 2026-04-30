import Foundation

@testable import HarnessMonitorKit

extension WebSocketProtocolParityTests {
  func daemonRPCMethodValues() throws -> Set<String> {
    let daemonCatalog = try daemonRPCMethodCatalogPath()
    let contents = try String(contentsOf: daemonCatalog, encoding: .utf8)
    let values = contents.split(separator: "\n").compactMap { line -> String? in
      guard line.contains("pub const"),
        let prefixRange = line.range(of: #"&str = ""#)
      else {
        return nil
      }
      let suffix = line[prefixRange.upperBound...]
      guard let end = suffix.firstIndex(of: "\"") else {
        return nil
      }
      return String(suffix[..<end])
    }
    return Set(values)
  }

  private func daemonRPCMethodCatalogPath() throws -> URL {
    let relativeCatalogPath = "src/daemon/protocol/api_contract/ws_methods.rs"
    let env = ProcessInfo.processInfo.environment
    let candidateRoots = [
      env["HARNESS_MONITOR_REPO_ROOT"].map(URL.init(fileURLWithPath:)),
      env["HARNESS_MONITOR_APP_ROOT"].map(URL.init(fileURLWithPath:)),
      gitRepoRoot(),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
    ].compactMap { $0 }
    if let existing = candidateRoots.compactMap({
      existingCatalogPath(relativePath: relativeCatalogPath, startingAt: $0)
    }).first {
      return existing
    }
    throw CocoaError(.fileNoSuchFile)
  }

  private func gitRepoRoot() -> URL? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "rev-parse", "--show-toplevel"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        return nil
      }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      guard
        let path = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        path.isEmpty == false
      else {
        return nil
      }
      return URL(fileURLWithPath: path)
    } catch {
      return nil
    }
  }

  private func existingCatalogPath(relativePath: String, startingAt seed: URL) -> URL? {
    var current = seed
    while true {
      let candidate = current.appendingPathComponent(relativePath)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
      let parent = current.deletingLastPathComponent()
      guard parent.path != current.path else {
        return nil
      }
      current = parent
    }
  }
}
