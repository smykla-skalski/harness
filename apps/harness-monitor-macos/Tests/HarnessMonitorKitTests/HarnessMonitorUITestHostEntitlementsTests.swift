import Foundation
import Testing

@Suite("UI test host entitlements")
struct HarnessMonitorUITestHostEntitlementsTests {
  @Test("UI test host requests the monitor app-group access it needs")
  func uiTestHostRequestsMonitorAppGroupAccess() throws {
    let entitlementsURL = monitorAppRoot()
      .appendingPathComponent("HarnessMonitorUITestHost.entitlements", isDirectory: false)
    let plist = try PropertyListSerialization.propertyList(
      from: try Data(contentsOf: entitlementsURL),
      format: nil
    )

    let entitlements = try #require(plist as? [String: Any])

    #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
    #expect(
      entitlements["com.apple.security.application-groups"] as? [String]
        == ["Q498EB36N4.io.harnessmonitor"]
    )
  }

  private func monitorAppRoot(filePath: StaticString = #filePath) -> URL {
    var url = URL(fileURLWithPath: "\(filePath)", isDirectory: false)
    for _ in 0..<3 {
      url.deleteLastPathComponent()
    }
    return url
  }
}
