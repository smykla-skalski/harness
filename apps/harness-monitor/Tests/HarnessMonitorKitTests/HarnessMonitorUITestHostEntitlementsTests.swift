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
    let exportedTypeDeclarations = try #require(
      infoPlist["UTExportedTypeDeclarations"] as? [[String: Any]]
    )
    let exportedTypeIdentifiers = Set(
      exportedTypeDeclarations.compactMap { $0["UTTypeIdentifier"] as? String }
    )

    for identifier in [
      "io.harnessmonitor.task",
      "io.harnessmonitor.session-agent",
      "io.harnessmonitor.task-board-item",
      "io.harnessmonitor.task-board-inbox-item",
    ] {
      #expect(exportedTypeIdentifiers.contains(identifier))
    }
  }

  @Test("Watch app stays paired to the iPhone companion")
  func watchAppStaysPairedToIPhoneCompanion() throws {
    let root = monitorAppRoot()
    let infoPlistURL =
      root
      .appendingPathComponent("Resources/HarnessMonitorWatch-Info.plist", isDirectory: false)
    let infoPlist = try loadDictionaryPlist(at: infoPlistURL)

    #expect(infoPlist["WKCompanionAppBundleIdentifier"] as? String == "io.harnessmonitor.app.ios")
    #expect(infoPlist["WKWatchOnly"] == nil)

    let projectURL = root.appendingPathComponent("Project.swift", isDirectory: false)
    let projectSource = try String(contentsOf: projectURL, encoding: .utf8)
    let mobileTargetStart = try #require(projectSource.range(of: "private let mobileAppTarget"))
    let mobileWidgetsStart =
      try #require(projectSource.range(of: "private let mobileWidgetsTarget"))
    let mobileTargetSource =
      projectSource[mobileTargetStart.lowerBound..<mobileWidgetsStart.lowerBound]
    #expect(mobileTargetSource.contains(".target(name: \"HarnessMonitorWatch\"),"))
    #expect(projectSource.contains("bundleId: \"io.harnessmonitor.app.ios.watch\""))
    #expect(projectSource.contains("bundleId: \"io.harnessmonitor.app.ios.watch.widgets\""))
  }

  @Test("Mobile widgets can refresh encrypted mirrors")
  func mobileWidgetsCanRefreshEncryptedMirrors() throws {
    let root = monitorAppRoot()
    let projectURL = root.appendingPathComponent("Project.swift", isDirectory: false)
    let projectSource = try String(contentsOf: projectURL, encoding: .utf8)
    let mobileWidgetsStart =
      try #require(projectSource.range(of: "private let mobileWidgetsTarget"))
    let uiPreviewableStart = try #require(projectSource.range(of: "private let uiPreviewableTarget"))
    let mobileWidgetsTarget =
      projectSource[mobileWidgetsStart.lowerBound..<uiPreviewableStart.lowerBound]

    for dependency in [
      "HarnessMonitorCore",
      "HarnessMonitorCrypto",
      "HarnessMonitorCloudMirror",
      "HarnessMonitorCloudKit",
    ] {
      #expect(
        mobileWidgetsTarget.contains(".target(name: \"\(dependency)\")"),
        "HarnessMonitorMobileWidgets must depend on \(dependency)"
      )
    }

    let entitlements = try loadDictionaryPlist(
      at: root.appendingPathComponent("HarnessMonitorMobileWidgets.entitlements")
    )
    #expect(
      entitlements["com.apple.security.application-groups"] as? [String]
        == ["group.io.harnessmonitor"]
    )
    #expect(
      entitlements["keychain-access-groups"] as? [String]
        == ["$(AppIdentifierPrefix)io.harnessmonitor"]
    )

    let timeline = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobileWidgets/MobileMirrorTimeline.swift"
      ),
      encoding: .utf8
    )
    #expect(timeline.contains("import HarnessMonitorCloudMirror"))
    #expect(timeline.contains("KeychainMobilePairedStationCredentialStore()"))
    #expect(timeline.contains("MobileCloudMirrorBackgroundRefresher("))
    #expect(timeline.contains("fallbackEntry(cachedSnapshot: cachedSnapshot"))
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
