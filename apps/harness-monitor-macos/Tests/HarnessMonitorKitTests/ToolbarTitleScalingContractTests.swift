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

  @Test("Session toolbar leaves glass chrome to the system toolbar")
  func sessionToolbarLeavesGlassChromeToTheSystemToolbar() throws {
    let sessionSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowToolbar.swift")

    #expect(!sessionSource.contains("SessionToolbarButtonStyle"))
    #expect(!sessionSource.contains("harnessFloatingControlGlass"))
    #expect(!sessionSource.contains(".buttonStyle(.glass)"))
    #expect(!sessionSource.contains(".buttonStyle(.glassProminent)"))
  }

  @Test("Session focus mode toolbar button uses animated moon symbols")
  func sessionFocusModeToolbarButtonUsesAnimatedMoonSymbols() throws {
    let sessionSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowToolbar.swift")

    #expect(sessionSource.contains("Image(systemName: focusMode ? \"moon.fill\" : \"moon\")"))
    #expect(sessionSource.contains(".contentTransition("))
    #expect(sessionSource.contains(".replace.magic(fallback: .downUp.wholeSymbol)"))
    #expect(sessionSource.contains("options: .nonRepeating"))
    #expect(sessionSource.contains(".animation(.default, value: focusMode)"))
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
