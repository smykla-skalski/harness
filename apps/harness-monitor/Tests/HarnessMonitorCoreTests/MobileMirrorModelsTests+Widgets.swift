import Foundation
import HarnessMonitorCore
import XCTest

extension MobileMirrorModelsTests {
  func testActiveMobileQueueCommandIgnoresDraftTerminalAndExpiredCommands() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var draft = mobileLiveActivityCommand(
      id: "draft",
      stationID: "station-a",
      status: .draft,
      updatedAt: now
    )
    draft.expiresAt = now.addingTimeInterval(60)
    let queued = mobileLiveActivityCommand(
      id: "queued",
      stationID: "station-a",
      status: .queued,
      updatedAt: now,
      expiresAt: now.addingTimeInterval(60)
    )
    let expired = mobileLiveActivityCommand(
      id: "expired",
      stationID: "station-a",
      status: .queued,
      updatedAt: now,
      expiresAt: now.addingTimeInterval(-1)
    )
    let succeeded = mobileLiveActivityCommand(
      id: "succeeded",
      stationID: "station-a",
      status: .succeeded,
      updatedAt: now,
      expiresAt: now.addingTimeInterval(60)
    )

    XCTAssertFalse(draft.isActiveMobileQueueCommand(now: now))
    XCTAssertTrue(queued.isActiveMobileQueueCommand(now: now))
    XCTAssertFalse(expired.isActiveMobileQueueCommand(now: now))
    XCTAssertFalse(succeeded.isActiveMobileQueueCommand(now: now))
  }

  func testMobileWidgetsCoverCommandAndCriticalDecisionSurfaces() throws {
    let root = monitorAppRoot()
    let coordinatorSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobile/MobileCommandLiveActivityCoordinator.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(
      coordinatorSource.contains("MobileCommandLiveActivityPresentation.primaryActivity")
    )

    let liveActivitySource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobileWidgets/MobileCommandLiveActivity.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(liveActivitySource.contains("context.attributes.systemImageName"))

    let needsYouWidgetSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobileWidgets/MobileNeedsYouWidget.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(needsYouWidgetSource.contains(".systemMedium"))

    let stationHealthWidgetSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobileWidgets/MobileStationHealthWidget.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(stationHealthWidgetSource.contains(".systemMedium"))

    let commandQueueWidgetSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobileWidgets/MobileCommandQueueWidget.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(commandQueueWidgetSource.contains(".systemMedium"))
    XCTAssertTrue(commandQueueWidgetSource.contains("isActiveMobileQueueCommand"))

    let watchWidgetSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorWatchWidgets/WatchMirrorWidgets.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(watchWidgetSource.contains("\"harness://commands\""))
  }

  func testMobileRuntimeDefersCloudKitPrivacyConstructionUntilUserAction() throws {
    let root = monitorAppRoot()
    let storeSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobile/MobileMonitorStore.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(storeSource.contains("privacyServiceProvider"))
    XCTAssertFalse(storeSource.contains("privacyService: any MobileCloudMirrorPrivacyManaging ="))

    let appSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobile/HarnessMonitorMobileApp.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(appSource.contains("#if targetEnvironment(simulator)"))
    XCTAssertTrue(appSource.contains("shouldRegisterCloudKitSubscriptions"))
    XCTAssertTrue(appSource.contains("demoModeEnabled: Self.defaultDemoModeEnabled"))

    let watchAppSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorWatch/HarnessMonitorWatchApp.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(watchAppSource.contains("demoModeEnabled: Self.defaultDemoModeEnabled"))
    XCTAssertTrue(watchAppSource.contains("shouldRegisterCloudKitSubscriptions"))
  }

  private func monitorAppRoot(filePath: StaticString = #filePath) -> URL {
    var url = URL(fileURLWithPath: "\(filePath)", isDirectory: false)
    for _ in 0..<3 {
      url.deleteLastPathComponent()
    }
    return url
  }
}
