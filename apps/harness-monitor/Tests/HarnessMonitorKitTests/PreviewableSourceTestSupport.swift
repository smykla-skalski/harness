import Foundation

/// Reading the previewable UI layer as text, shared by the source-contract
/// suites. One copy of the file-discovery rules, because two suites that
/// disagree about which files hold a type would each check a different half of
/// it and both look green.

/// A type's own file together with its `Type+Extension.swift` siblings. Naming
/// those siblings instead goes stale as soon as a member moves into a new one,
/// and a file the test stops reading is a contract it stops checking without
/// ever saying so.
func previewableTypeSource(domain: String, type: String) throws -> String {
  let directory = previewableDomainDirectory(domain: domain)
  let files = try FileManager.default
    .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    .filter { url in
      url.pathExtension == "swift"
        && (url.deletingPathExtension().lastPathComponent == type
          || url.lastPathComponent.hasPrefix("\(type)+"))
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

func previewableSourceFile(domain: String, named relativePath: String) throws -> String {
  let fileURL = previewableDomainDirectory(domain: domain)
    .appendingPathComponent(relativePath)
  return try String(contentsOf: fileURL, encoding: .utf8)
}

func previewableDomainDirectory(domain: String) -> URL {
  let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  let repoRoot =
    testsDirectory
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  return
    repoRoot
    .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
    .appendingPathComponent("Views")
    .appendingPathComponent(domain)
}
