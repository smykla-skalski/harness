import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionWindowFlowTests {
  @Test("Open Recent window does not show the close-after-pick checkbox")
  func openRecentDoesNotRenderCloseAfterPickCheckbox() throws {
    let source = try previewableSourceFile(named: "Views/Sessions/OpenRecentView.swift")

    #expect(
      !source.contains(
        "Toggle(\"Close Open Recent after picking a session\", isOn: $closeAfterPick)"))
    #expect(!source.contains(".onGeometryChange("))
    #expect(source.contains("OpenRecentStartPanelLayout("))
    #expect(!source.contains("SessionBackgroundExtensionSurface()"))
    #expect(!source.contains(".backgroundExtensionEffect()"))
  }

  @MainActor
  @Test("Open Recent motion policy disables animation for reduce motion")
  func openRecentCloseAfterPickMotionPolicyRespectsReduceMotion() {
    #expect(OpenRecentCloseAfterPickMotionPolicy.animation(reduceMotion: true) == nil)
    #expect(OpenRecentCloseAfterPickMotionPolicy.animation(reduceMotion: false) != nil)
    #expect(OpenRecentCloseAfterPickMotionPolicy.dismissDelay(reduceMotion: true) == .zero)
    #expect(
      OpenRecentCloseAfterPickMotionPolicy.dismissDelay(reduceMotion: false)
        == .milliseconds(160)
    )
  }

  @Test("Open Recent close-after-pick uses native SwiftUI scene routing")
  func openRecentCloseAfterPickUsesCurrentWindowDismiss() throws {
    let source = try previewableSourceFile(named: "Views/Sessions/OpenRecentView.swift")

    #expect(!source.contains("import AppKit"))
    #expect(source.contains("@Environment(\\.dismiss)"))
    #expect(source.contains("@Environment(\\.openWindow)"))
    #expect(source.contains("openWindow.openHarnessSessionWindow"))
    #expect(source.contains("await Task.yield()"))
    #expect(source.contains("dismiss()"))
    #expect(!source.contains("OpenRecentSessionLaunchHandoff"))
    #expect(!source.contains("OpenRecentSourceWindowResolver"))
    #expect(!source.contains("NSApplication"))
    #expect(!source.contains("NSWindow"))
    #expect(!source.contains("requestUserAttention"))
    #expect(!source.contains("makeKeyAndOrderFront"))
    #expect(!source.contains("sourceWindow.close()"))
    #expect(!source.contains("@Environment(\\.dismissWindow)"))
    #expect(!source.contains("dismissWindow(id: HarnessMonitorWindowID.openRecent)"))
    #expect(!source.contains("openWindow(id: HarnessMonitorWindowID.openRecent)"))
  }

  @Test("Session tabs route through SwiftUI commands plus the tabbing accessor")
  func sessionTabsUseSwiftUISceneCommands() throws {
    let appSource = try harnessSourceFile(named: "App/HarnessMonitorApp.swift")
    let rootSource = try harnessSourceFile(named: "App/SessionWindowRootView.swift")
    let commandsSource = try harnessSourceFile(named: "Commands/WindowMenuCommands.swift")
    let tabbingAccessorPath = harnessSourceURL(named: "App/SessionWindowTabbing.swift").path
    let tabbingSource = try harnessSourceFile(named: "App/SessionWindowTabbing.swift")
    let tabbingSupportSource = try previewableSourceFile(
      named: "Support/SessionWindowTabbingSupport.swift"
    )

    #expect(FileManager.default.fileExists(atPath: tabbingAccessorPath))
    #expect(appSource.contains("Window("))
    #expect(appSource.contains("WindowGroup("))
    #expect(appSource.contains("id: HarnessMonitorWindowID.openRecent"))
    #expect(appSource.contains("id: HarnessMonitorWindowID.sessionScene"))
    #expect(appSource.contains("for: SessionWindowToken.self"))
    #expect(appSource.contains(".restorationBehavior(.disabled)"))
    #expect(appSource.contains(".commandsRemoved()"))
    #expect(appSource.contains("SessionWindowTabbing(isSessionWindow: false)"))
    #expect(commandsSource.contains("@Environment(\\.openWindow)"))
    #expect(commandsSource.contains("openHarnessSessionWindow"))
    #expect(rootSource.contains("SessionWindowTabbing(isSessionWindow: true)"))
    #expect(rootSource.contains("private var hostsSharedShellPresentation"))
    #expect(rootSource.contains("HarnessMonitorConfirmationDialogModifier("))
    #expect(rootSource.contains("HarnessMonitorSheetModifier("))
    #expect(rootSource.contains("isEnabled: hostsSharedShellPresentation"))
    #expect(tabbingSource.contains("scheduleWindowTabbingApplication()"))
    #expect(tabbingSource.contains("await Task.yield()"))
    #expect(tabbingSource.contains("guard window.toolbar != nil else"))
    #expect(appSource.contains("waitForSessionWindowToolbars("))
    #expect(appSource.contains("let tabReadyWindows = windows.filter { $0.toolbar != nil }"))
    #expect(tabbingSupportSource.contains("tabbingIdentifier"))
    #expect(tabbingSupportSource.contains("shouldPreferTabbedOpen"))
    #expect(tabbingSupportSource.contains("visibleSessionTabTargetWindow"))
  }

  @Test("Decision routing reuses an already open session window")
  func decisionRoutingReusesAnAlreadyOpenSessionWindow() throws {
    let source = try previewableSourceFile(named: "Support/SessionWindowOpenAction.swift")

    #expect(source.contains("store.openSessionWindowIDsSnapshot.contains(sessionID)"))
    #expect(source.contains("NSApplication.shared.activate()"))
    #expect(source.contains("openHarnessSessionWindow(sessionID: sessionID)"))
  }

  @Test("Session inspector resize uses native SwiftUI split")
  func sessionInspectorResizeUsesNativeSwiftUISplit() throws {
    let viewSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift")

    #expect(!viewSource.contains("import AppKit"))
    #expect(columnsSource.contains("HSplitView"))
    #expect(columnsSource.contains(".sessionPaneLeadingSeparator()"))
    #expect(!columnsSource.contains("SessionInspectorDivider("))
    #expect(!columnsSource.contains("DragGesture("))
    #expect(!columnsSource.contains("NSCursor"))
  }

  @Test("Session window owns the content-detail split UX")
  func sessionWindowOwnsTheContentDetailSplitUX() throws {
    let viewSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let splitSource = try previewableSourceFile(
      named: "Views/Sessions/SessionContentDetailSplitView.swift"
    )

    #expect(viewSource.contains("@SceneStorage(\"session.content-detail.width\")"))
    #expect(viewSource.contains("sessionSurface"))
    #expect(
      columnsSource.contains(
        "SessionContentDetailSplitView(contentWidth: contentColumnWidth)"
      )
    )
    #expect(columnsSource.contains(".navigationSplitViewStyle(.prominentDetail)"))
    #expect(splitSource.contains("HSplitView"))
    #expect(!splitSource.contains("NSCursor"))
    #expect(!splitSource.contains("DragGesture("))
    #expect(!splitSource.contains("@State"))
    #expect(!splitSource.contains("Task.sleep"))
    #expect(splitSource.contains("layoutPriority(1)"))
    #expect(splitSource.contains("sessionPaneLeadingSeparator()"))
  }

  @Test("Sidebar density keeps strict default and maps legacy values")
  func sidebarDensityResolvesStrictDefaultAndLegacyValues() {
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.defaultMode == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: nil) == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "strict") == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "dense") == .dense)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "concise") == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "detailed") == .dense)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "unknown") == .strict)
  }
}
