import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit

@MainActor
final class SessionWindowRemovalTests: XCTestCase {
  func testAppLaunchBindsSupervisorSurfacesWithoutWindowPresenceState() {
    let store = makeStore()
    let notifications = HarnessMonitorUserNotificationController.preview(environment: [:])
    let dockBadge = PendingDecisionsDockBadgeController()
    let menuBarStatus = HarnessMonitorMenuBarStatusController()

    HarnessMonitorApp.bindSupervisorSurfaces(
      to: store,
      notificationController: notifications,
      dockBadgeController: dockBadge,
      menuBarStatusController: menuBarStatus
    )

    XCTAssertTrue(store.supervisorBindings.notificationController === notifications)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsStatusSync)
  }

  func testProductionSceneGraphContainsNoSessionWindow() throws {
    let appSource = try harnessSourceFile(named: "App/HarnessMonitorApp.swift")
    let scenesSource = try harnessSourceFile(named: "App/HarnessMonitorApp+Scenes.swift")

    XCTAssertFalse(appSource.contains("sessionWindowScene"))
    XCTAssertFalse(scenesSource.contains("WindowGroup"))
    XCTAssertFalse(scenesSource.contains("sessionScene"))
    XCTAssertFalse(scenesSource.contains("SessionWindowToken"))
  }

  func testWindowOpeningSurfaceContainsNoSessionEntryPoint() throws {
    let source = try uiPreviewableSourceFile(named: "Support/DashboardWindowOpenAction.swift")
    let identifiers = try uiPreviewableSourceFile(named: "Support/HarnessMonitorWindowIDs.swift")

    XCTAssertFalse(source.contains("openHarnessSessionWindow"))
    XCTAssertFalse(source.contains("SessionWindowTabMergeCoordinator"))
    XCTAssertFalse(identifiers.contains("sessionScene"))
    XCTAssertFalse(identifiers.contains("sessionWindow("))
  }

  func testSettingsContainNoSessionWindowSectionsOrControls() throws {
    let sidebar = try uiPreviewableSourceFile(named: "Views/Settings/SettingsSidebar.swift")
    let details = try uiPreviewableSourceFile(named: "Views/Settings/SettingsView+SectionSwitch.swift")
    let general = try uiPreviewableSourceFile(named: "Views/Settings/SettingsGeneralSection.swift")
    let appearance = try uiPreviewableSourceFile(named: "Views/Settings/SettingsAppearanceSection.swift")

    XCTAssertFalse(sidebar.contains("case focusMode"))
    XCTAssertFalse(sidebar.contains("case banners"))
    XCTAssertFalse(details.contains("SettingsFocusModeSection"))
    XCTAssertFalse(details.contains("SettingsBannersSection"))
    XCTAssertFalse(general.contains("GeneralWindowsSection"))
    XCTAssertFalse(appearance.contains("Session shortcut overlays"))
    XCTAssertFalse(appearance.contains("Session title blur"))
    XCTAssertFalse(appearance.contains("Sidebar session rows"))
  }

  private func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: PreviewDaemonController(mode: .empty),
      voiceCapture: PreviewVoiceCaptureService(),
      daemonOwnership: .managed
    )
  }

  private func harnessSourceFile(named relativePath: String) throws -> String {
    try sourceFile(target: "HarnessMonitor", relativePath: relativePath)
  }

  private func uiPreviewableSourceFile(named relativePath: String) throws -> String {
    try sourceFile(target: "HarnessMonitorUIPreviewable", relativePath: relativePath)
  }

  private func sourceFile(target: String, relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot = testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL = repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources")
      .appendingPathComponent(target)
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
