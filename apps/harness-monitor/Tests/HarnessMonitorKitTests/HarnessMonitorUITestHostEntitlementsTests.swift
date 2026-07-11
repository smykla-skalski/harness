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

  @Test("Watch app claims remote daemon pairing links directly")
  func watchAppClaimsRemoteDaemonPairingLinksDirectly() throws {
    let root = monitorAppRoot()
    let infoPlist = try loadDictionaryPlist(
      at: root.appendingPathComponent("Resources/HarnessMonitorWatch-Info.plist")
    )
    let urlTypes = try #require(infoPlist["CFBundleURLTypes"] as? [[String: Any]])
    let schemes = Set(
      urlTypes
        .compactMap { $0["CFBundleURLSchemes"] as? [String] }
        .flatMap { $0 }
    )
    #expect(schemes.contains("harness"))

    let appSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorWatch/HarnessMonitorWatchApp.swift"
      ),
      encoding: .utf8
    )
    #expect(appSource.contains("LiveWatchRemoteDaemonCredentialPairer("))
    #expect(appSource.contains("pairer: remotePairer"))
    #expect(appSource.contains("let pairingMutationGate = MobilePairingMutationGate()"))
    #expect(appSource.contains("pairingMutationGate: pairingMutationGate"))
    #expect(
      appSource.components(separatedBy: "mutationGate: pairingMutationGate").count == 3
    )
    #expect(appSource.contains(".onOpenURL"))
    #expect(appSource.contains("url.host?.lowercased() == \"remote-pair\""))
    #expect(appSource.contains("pairingReceiver.start"))

    let rootViewSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorWatch/RootView.swift"
      ),
      encoding: .utf8
    )
    #expect(rootViewSource.contains("Remove Watch Pairing"))
    #expect(rootViewSource.contains("removeDirectWatchPairing"))
    #expect(rootViewSource.contains("credential.stationID == store.selectedStationID"))
    #expect(!rootViewSource.contains("?? directCredentials.first"))

    let pairingViewSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorWatch/WatchRemoteDaemonPairingView.swift"
      ),
      encoding: .utf8
    )
    #expect(rootViewSource.contains("Pair Remote Daemon"))
    #expect(rootViewSource.contains("WatchRemoteDaemonPairingView()"))
    #expect(pairingViewSource.contains("TextField(\"Pairing Link\""))
    #expect(pairingViewSource.contains(".privacySensitive()"))
    #expect(pairingViewSource.contains(".textInputAutocapitalization(.never)"))
    #expect(pairingViewSource.contains(".autocorrectionDisabled()"))
    #expect(pairingViewSource.contains(".lineLimit(1)"))
    #expect(pairingViewSource.contains(".frame(height: 44)"))
    #expect(pairingViewSource.contains("pairingLink = \"\""))
    #expect(pairingViewSource.contains("Task { @MainActor in"))
    #expect(pairingViewSource.contains("pairDirectWatchDaemon"))

    let directPairerSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorWatch/LiveWatchRemoteDaemonCredentialPairer.swift"
      ),
      encoding: .utf8
    )
    let transferReceiverSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorWatch/WatchPairingSessionReceiver.swift"
      ),
      encoding: .utf8
    )
    #expect(directPairerSource.contains("try await mutationGate.perform"))
    #expect(transferReceiverSource.contains("try await mutationGate.perform"))
  }

  @Test("Mobile widgets can refresh encrypted mirrors")
  func mobileWidgetsCanRefreshEncryptedMirrors() throws {
    let root = monitorAppRoot()
    let projectURL = root.appendingPathComponent("Project.swift", isDirectory: false)
    let projectSource = try String(contentsOf: projectURL, encoding: .utf8)
    let mobileWidgetsStart =
      try #require(projectSource.range(of: "private let mobileWidgetsTarget"))
    let uiPreviewableStart =
      try #require(projectSource.range(of: "private let uiPreviewableTarget"))
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

  @Test("Mobile app supports CloudKit notification wakeups")
  func mobileAppSupportsCloudKitNotificationWakeups() throws {
    let root = monitorAppRoot()
    let infoPlist = try loadDictionaryPlist(
      at: root.appendingPathComponent("Resources/HarnessMonitorMobile-Info.plist")
    )

    #expect((infoPlist["UIBackgroundModes"] as? [String])?.contains("remote-notification") == true)
    #expect(infoPlist["NSSupportsLiveActivities"] as? Bool == true)

    let urlTypes = try #require(infoPlist["CFBundleURLTypes"] as? [[String: Any]])
    let schemes = Set(
      urlTypes
        .compactMap { $0["CFBundleURLSchemes"] as? [String] }
        .flatMap { $0 }
    )
    #expect(schemes.contains("harness"))
    #expect(!schemes.contains("harness-monitor"))

    let appSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobile/HarnessMonitorMobileApp.swift"
      ),
      encoding: .utf8
    )
    #expect(appSource.contains("UNUserNotificationCenter.current().delegate = self"))
    #expect(appSource.contains(".mobileNotificationTabRequested"))
    #expect(appSource.contains("willPresent notification: UNNotification"))
    #expect(appSource.contains("didReceive response: UNNotificationResponse"))
  }

  @Test("Mobile app coalesces external tab routing updates")
  func mobileAppCoalescesExternalTabRoutingUpdates() throws {
    let root = monitorAppRoot()
    let appSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobile/HarnessMonitorMobileApp.swift"
      ),
      encoding: .utf8
    )
    let rootViewSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobile/MobileRootView.swift"
      ),
      encoding: .utf8
    )

    #expect(appSource.contains("guard selectedTab != tab else"))
    #expect(appSource.contains("@State private var tabSelectionRequestID: UInt64 = 0"))
    #expect(appSource.contains("@State private var didHandleInitialSceneActivation = false"))
    #expect(appSource.contains("handleScenePhaseChange(newPhase)"))
    #expect(appSource.contains("guard didHandleInitialSceneActivation else"))
    #expect(appSource.contains("tabSelectionRequestID &+= 1"))
    #expect(appSource.contains("guard tabSelectionRequestID == requestID else"))
    #expect(
      appSource.contains(
        "private static let navigationRequestFrameDelay: Duration = .milliseconds(20)"
      )
    )
    #expect(appSource.contains("try await Task.sleep(for: Self.navigationRequestFrameDelay)"))
    #expect(rootViewSource.contains("TabView(selection: selectedTabBinding)"))
    #expect(rootViewSource.contains("content(for: .today)"))
    #expect(rootViewSource.contains("content(for: .settings)"))
    #expect(rootViewSource.contains("if selectedTab == tab"))
    #expect(rootViewSource.contains("Color.clear"))
    #expect(rootViewSource.contains("guard selectedTab != newValue else"))
  }
}

@Suite("Mobile native list actions")
struct HarnessMonitorMobileNativeListActionTests {
  @Test("Needs You queue swipes keep full-swipe on a full-width row")
  func needsYouQueueSwipeUsesFullWidthNativeActionHost() throws {
    let root = monitorAppRoot()
    let todaySource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobile/MobileRootView+TodayView.swift"
      ),
      encoding: .utf8
    )
    let modifierStart = try #require(
      todaySource.range(of: "func mobileAttentionQueueSwipeActions(")
    )
    let modifierSource = todaySource[modifierStart.lowerBound...]

    #expect(modifierSource.contains("frame(maxWidth: .infinity, alignment: .leading)"))
    #expect(modifierSource.contains(".contentShape(Rectangle())"))
    #expect(modifierSource.contains("swipeActions(edge: .trailing, allowsFullSwipe: true)"))
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
