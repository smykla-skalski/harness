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

  @Test("External daemon release opt-in stays scoped to Instruments audit builds")
  func externalDaemonReleaseOptInStaysAuditScoped() throws {
    let source = try sourceFile(named: "Support/HarnessMonitorDaemonOwnership.swift")

    #expect(source.contains("#if DEBUG || HARNESS_MONITOR_AUDIT_EXTERNAL_DAEMON"))
    #expect(source.contains("#else\n      _ = environment\n      self = .managed"))
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
