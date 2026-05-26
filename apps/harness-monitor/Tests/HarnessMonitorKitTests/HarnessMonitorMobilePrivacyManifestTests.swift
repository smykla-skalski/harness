import Foundation
import XCTest

final class HarnessMonitorMobilePrivacyManifestTests: XCTestCase {
  func testMobileAndWatchTargetsBundlePrivacyManifest() throws {
    let projectURL = monitorAppRoot()
      .appendingPathComponent("Project.swift", isDirectory: false)
    let projectSource = try String(contentsOf: projectURL, encoding: .utf8)

    for targetName in [
      "watchWidgetsTarget",
      "watchAppTarget",
      "mobileAppTarget",
      "mobileWidgetsTarget",
    ] {
      let targetSource = try projectTargetSource(named: targetName, in: projectSource)
      XCTAssertTrue(
        targetSource.contains("\"Resources/PrivacyInfo.xcprivacy\""),
        "\(targetName) must bundle Resources/PrivacyInfo.xcprivacy"
      )
    }
  }

  func testPrivacyManifestDeclaresMirroredCloudKitDataWithoutTracking() throws {
    let manifest = try privacyManifest()
    XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
    XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty, true)

    let collectedDataTypes = try XCTUnwrap(
      manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
    )
    let entriesByType = Dictionary(
      uniqueKeysWithValues: try collectedDataTypes.map { entry in
        (try XCTUnwrap(entry["NSPrivacyCollectedDataType"] as? String), entry)
      }
    )
    let expectedLinkedValues = [
      "NSPrivacyCollectedDataTypeAudioData": false,
      "NSPrivacyCollectedDataTypeOtherUserContent": true,
      "NSPrivacyCollectedDataTypeUserID": true,
      "NSPrivacyCollectedDataTypeDeviceID": true,
      "NSPrivacyCollectedDataTypeProductInteraction": true,
    ]

    XCTAssertEqual(Set(entriesByType.keys), Set(expectedLinkedValues.keys))
    for (dataType, linked) in expectedLinkedValues {
      let entry = try XCTUnwrap(entriesByType[dataType], "\(dataType) missing")
      XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
      XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, linked)
      XCTAssertEqual(
        entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
        ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
        "\(dataType) should be collected only for app functionality"
      )
    }
  }

  func testAppStorePrivacyPackageIsPresentAndSpecific() throws {
    let docsRoot = monitorAppRoot()
      .appendingPathComponent("docs/app-store", isDirectory: true)
    let requiredDocuments = [
      "privacy-policy.md",
      "privacy-labels.md",
      "review-notes.md",
    ]
    for document in requiredDocuments {
      let url = docsRoot.appendingPathComponent(document, isDirectory: false)
      let contents = try String(contentsOf: url, encoding: .utf8)
      XCTAssertFalse(contents.localizedCaseInsensitiveContains("TODO"), document)
      XCTAssertFalse(contents.localizedCaseInsensitiveContains("TBD"), document)
      XCTAssertFalse(contents.localizedCaseInsensitiveContains("placeholder"), document)
    }

    let privacyPolicy = try String(
      contentsOf: docsRoot.appendingPathComponent("privacy-policy.md"),
      encoding: .utf8
    )
    XCTAssertTrue(privacyPolicy.contains("Export mirrored CloudKit records"))
    XCTAssertTrue(privacyPolicy.contains("Delete mirrored CloudKit records"))
    XCTAssertTrue(privacyPolicy.contains("does not track users"))
    XCTAssertTrue(privacyPolicy.contains("seven days"))
    XCTAssertTrue(privacyPolicy.contains("clear metadata"))
    XCTAssertTrue(privacyPolicy.contains("encrypted-envelope"))

    let privacyLabels = try String(
      contentsOf: docsRoot.appendingPathComponent("privacy-labels.md"),
      encoding: .utf8
    )
    for expectedDataType in [
      "Other User Content",
      "User ID",
      "Device ID",
      "Product Interaction",
      "Audio Data",
    ] {
      XCTAssertTrue(privacyLabels.contains(expectedDataType), expectedDataType)
    }

    let reviewNotes = try String(
      contentsOf: docsRoot.appendingPathComponent("review-notes.md"),
      encoding: .utf8
    )
    XCTAssertTrue(reviewNotes.contains("harness://pair"))
    XCTAssertTrue(reviewNotes.contains("raw shell"))
    XCTAssertTrue(reviewNotes.contains("Demo mode"))
    XCTAssertTrue(reviewNotes.contains("record-type counts"))
    XCTAssertTrue(reviewNotes.contains("encrypted-envelope keys"))
  }

  func testMobilePrivacyControlsExposeInventoryAndFreshExports() throws {
    let root = monitorAppRoot()
    let storeSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMirrorStore/MirrorStore.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(storeSource.contains("var lastPrivacyInventory"))
    let privacySource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMirrorStore/MirrorStore+Privacy.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(privacySource.contains("lastPrivacyInventory = archive.inventory"))
    XCTAssertTrue(privacySource.contains("lastPrivacyInventory = deletionReport.inventory"))
    XCTAssertTrue(privacySource.contains("notificationDeliveryHistory.reset()"))
    XCTAssertTrue(privacySource.contains("harness-monitor-mirror-\\(timestamp)"))
    XCTAssertTrue(privacySource.contains("try data.write(to: fileURL, options: [.atomic])"))

    let settingsSource = try String(
      contentsOf: root.appendingPathComponent(
        "Sources/HarnessMonitorMobile/MobileRootView+SettingsView.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(settingsSource.contains("Last report"))
    XCTAssertTrue(settingsSource.contains("Encrypted bytes"))
  }

  func testMobileNotificationsUseTimeSensitiveInterruptionWithoutDeprecatedAuthorization()
    throws
  {
    let notificationsSource = try String(
      contentsOf: monitorAppRoot().appendingPathComponent(
        "Sources/HarnessMonitorMobile/MobileMonitorNotifications.swift"
      ),
      encoding: .utf8
    )

    XCTAssertTrue(
      notificationsSource.contains("authorizationOptions: UNAuthorizationOptions")
    )
    XCTAssertTrue(
      notificationsSource.contains("requestAuthorization(options: Self.authorizationOptions)")
    )
    XCTAssertFalse(
      notificationsSource.contains(
        "authorizationOptions: UNAuthorizationOptions = [\n"
          + "    .alert,\n"
          + "    .badge,\n"
          + "    .sound,\n"
          + "    .timeSensitive"
      )
    )
    XCTAssertTrue(notificationsSource.contains("case .timeSensitive: .timeSensitive"))
    XCTAssertTrue(
      notificationsSource.contains(
        "content.interruptionLevel = request.interruption.unNotificationInterruptionLevel"
      )
    )
  }

  private func monitorAppRoot(filePath: StaticString = #filePath) -> URL {
    var url = URL(fileURLWithPath: "\(filePath)", isDirectory: false)
    for _ in 0..<3 {
      url.deleteLastPathComponent()
    }
    return url
  }

  private func projectTargetSource(named targetName: String, in projectSource: String) throws
    -> Substring
  {
    let marker = "private let \(targetName): Target"
    let start = try XCTUnwrap(projectSource.range(of: marker))
    let targetSource = projectSource[start.lowerBound...]
    if let nextTarget = targetSource.dropFirst().range(of: "\nprivate let ") {
      return projectSource[start.lowerBound..<nextTarget.lowerBound]
    }
    return targetSource
  }

  private func privacyManifest() throws -> [String: Any] {
    let manifestURL = monitorAppRoot()
      .appendingPathComponent("Resources/PrivacyInfo.xcprivacy", isDirectory: false)
    let data = try Data(contentsOf: manifestURL)
    let manifest = try PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    )
    return try XCTUnwrap(manifest as? [String: Any])
  }
}
