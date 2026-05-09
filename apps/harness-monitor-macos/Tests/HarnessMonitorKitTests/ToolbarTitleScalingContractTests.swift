import Foundation
import Testing

struct ToolbarTitleScalingContractTests {
  @Test("Monitor windows use native navigation titles instead of a custom toolbar title item")
  func monitorWindowsUseNativeNavigationTitles() throws {
    let contentSource = try previewableSourceFile(named: "Views/App/ContentViewSupport.swift")
    let workspaceSource = try previewableSourceFile(named: "Views/Workspace/Window/WorkspaceWindowView.swift")
    let sessionSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let sessionRootSource = try appSourceFile(named: "SessionWindowRootView.swift")

    #expect(contentSource.contains(".navigationTitle(navigationTitleText)"))
    #expect(contentSource.contains(".navigationSubtitle(navigationSubtitleText ?? \"\")"))
    #expect(!contentSource.contains("HarnessMonitorToolbarTitleToolbarItem("))
    #expect(workspaceSource.contains(".navigationTitle(workspaceNavigationTitle(for: viewModel.selection))"))
    #expect(workspaceSource.contains(".navigationSubtitle(workspaceNavigationSubtitle(for: viewModel.selection))"))
    #expect(!workspaceSource.contains("HarnessMonitorToolbarTitleToolbarItem("))
    #expect(sessionSource.contains("var navigationTitleText: String"))
    #expect(sessionSource.contains(".navigationTitle(navigationTitleText)"))
    #expect(!sessionSource.contains(".navigationSubtitle("))
    #expect(!sessionSource.contains("HarnessMonitorToolbarTitleToolbarItem("))
    #expect(!sessionRootSource.contains(".navigationTitle(windowTitle)"))
  }

  @Test("Session toolbar uses a static centerpiece and leaves glass to the system toolbar")
  func sessionToolbarUsesStaticCenterpieceAndSystemToolbarGlass() throws {
    let sessionSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowToolbar.swift")

    #expect(sessionSource.contains("SessionToolbarCenterpiece("))
    #expect(sessionSource.contains("SessionToolbarCenterpieceStatusStripState("))
    #expect(
      sessionSource.contains(
        """
              SessionToolbarCenterpieceSourceIcon(source: source)
              ConnectionToolbarBadge(metrics: metrics)
        """
      )
    )
    #expect(!sessionSource.contains("HarnessMonitorGlassControlGroup"))
    #expect(!sessionSource.contains("harnessFloatingControlGlass"))
    #expect(!sessionSource.contains("Menu {"))
    #expect(!sessionSource.contains(".buttonStyle(.glass)"))
    #expect(!sessionSource.contains(".buttonStyle(.glassProminent)"))
  }

  @Test("Session focus mode toolbar button uses animated moon symbols")
  func sessionFocusModeToolbarButtonUsesAnimatedMoonSymbols() throws {
    let sessionSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowToolbar.swift")
    let columnsSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView+Columns.swift")
    let bannerSource = try previewableSourceFile(named: "Views/Sessions/SessionBannerStack.swift")

    #expect(!sessionSource.contains("Toggle(isOn: $focusMode)"))
    #expect(sessionSource.contains("Image(systemName: focusMode ? \"moon.fill\" : \"moon\")"))
    #expect(sessionSource.contains(".contentTransition("))
    #expect(sessionSource.contains(".replace.magic(fallback: .downUp.wholeSymbol)"))
    #expect(sessionSource.contains("options: .nonRepeating"))
    #expect(sessionSource.contains(".frame(width: 14, height: 14)"))
    #expect(sessionSource.contains(".help(focusMode ? \"Exit focus mode\" : \"Enter focus mode\")"))
    #expect(sessionSource.contains("toggleFocusMode()"))
    #expect(sessionSource.contains("SessionFocusModeMotionPolicy.animation(reduceMotion: reduceMotion)"))
    #expect(sessionSource.contains("withAnimation(animation)"))
    #expect(!sessionSource.contains(".animation(.default, value: focusMode)"))
    #expect(columnsSource.contains("NavigationSplitView(columnVisibility: columnVisibilityBinding)"))
    #expect(columnsSource.contains("if focusMode {\n      focusModeSurface"))
    #expect(!columnsSource.contains("SessionFocusModeMotionPolicy.focusedSurfaceTransition"))
    #expect(!columnsSource.contains("sidebarMinimumWidth"))
    #expect(!bannerSource.contains("SessionFocusModeMotionPolicy.bannerTransition"))
  }

  @Test("Workspace toolbar keeps refresh as an explicit primary action")
  func workspaceToolbarKeepsRefreshAsPrimaryAction() throws {
    let workspaceSource = try previewableSourceFile(named: "Views/Workspace/Window/WorkspaceWindowView.swift")

    #expect(
      workspaceSource.contains(
        "ToolbarItem(placement: .primaryAction) {\n          Button(action: refresh)"
      )
    )
    #expect(workspaceSource.contains(".help(\"Refresh workspace\")"))
  }

  @Test("Session window leaves toolbar chrome to tabbing and scene shell")
  func sessionWindowLeavesToolbarChromeToTabbingAndSceneShell() throws {
    let sessionSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let columnsSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView+Columns.swift")

    #expect(!sessionSource.contains(".suppressToolbarBaselineSeparator()"))
    #expect(!columnsSource.contains(".toolbarBackgroundVisibility(.automatic, for: .windowToolbar)"))
  }

  private func previewableSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)

    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func appSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitor/App")
      .appendingPathComponent(relativePath)

    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
