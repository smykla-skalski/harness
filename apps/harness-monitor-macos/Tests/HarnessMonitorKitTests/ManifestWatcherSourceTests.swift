import Foundation
import Testing

@Suite("Manifest watcher source contracts")
struct ManifestWatcherSourceTests {
  @Test("Dispatch source cancel handler owns its opened descriptor")
  func dispatchSourceCancelHandlerOwnsItsOpenedDescriptor() throws {
    let source = try sourceFile(named: "API/ManifestWatcher.swift")

    #expect(!source.contains("var fileDescriptor"))
    #expect(!source.contains("state.fileDescriptor"))
    #expect(!source.contains("closeDescriptor"))
    #expect(source.contains("source.setCancelHandler {\n      close(descriptor)\n    }"))
  }

  private func sourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorKit")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
