import Foundation
import Testing

@Suite("UI test host entitlements")
struct HarnessMonitorUITestHostEntitlementsTests {
  @Test("UI test host requests the monitor app-group access it needs")
  func uiTestHostRequestsMonitorAppGroupAccess() throws {
    let entitlementsURL = monitorAppRoot()
      .appendingPathComponent("HarnessMonitorUITestHost.entitlements", isDirectory: false)
    let entitlements = try loadDictionaryPlist(at: entitlementsURL)

    #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
    #expect(
      entitlements["com.apple.security.application-groups"] as? [String]
        == ["Q498EB36N4.io.harnessmonitor"]
    )
  }
}

@Suite("App bundle metadata")
struct HarnessMonitorAppBundleMetadataTests {
  @Test("Harness Monitor exports custom drag payload UTTypes")
  func harnessMonitorExportsCustomDragPayloadUTTypes() throws {
    let infoPlistURL = monitorAppRoot()
      .appendingPathComponent("Resources/HarnessMonitor-Info.plist", isDirectory: false)
    let infoPlist = try loadDictionaryPlist(at: infoPlistURL)
    let exportedTypeDeclarations = try #require(infoPlist["UTExportedTypeDeclarations"] as? [[String: Any]])
    let exportedTypeIdentifiers = Set(
      exportedTypeDeclarations.compactMap { $0["UTTypeIdentifier"] as? String }
    )

    for identifier in [
      "io.harnessmonitor.task",
      "io.harnessmonitor.session-agent",
      "io.harnessmonitor.task-board-item",
      "io.harnessmonitor.task-board-inbox-item"
    ] {
      #expect(exportedTypeIdentifiers.contains(identifier))
    }
  }
}

private func loadDictionaryPlist(at url: URL) throws -> [String: Any] {
  let plist = try PropertyListSerialization.propertyList(
    from: try Data(contentsOf: url),
    format: nil
  )
  return try #require(plist as? [String: Any])
}

private func monitorAppRoot(filePath: StaticString = #filePath) -> URL {
  var url = URL(fileURLWithPath: "\(filePath)", isDirectory: false)
  for _ in 0..<3 {
    url.deleteLastPathComponent()
  }
  return url
}
