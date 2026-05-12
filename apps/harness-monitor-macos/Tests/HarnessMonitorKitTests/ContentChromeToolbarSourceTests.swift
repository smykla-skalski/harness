import Foundation
import Testing

@Suite("Content chrome toolbar source contracts")
struct ContentChromeToolbarSourceTests {
  @Test("Refresh startup state stays on the static symbol path")
  func refreshStartupStateStaysOnStaticSymbolPath() throws {
    let source = try sourceFile(at: "Views/App/ContentChromeToolbarSupport.swift")

    #expect(source.contains("private var refreshButton: some View"))
    #expect(source.contains("Button {\n      Task { await store.manualRefresh() }"))
    #expect(!source.contains("TimelineView"))
    #expect(!source.contains("shouldSpin"))
    #expect(!source.contains(".symbolEffect(.rotate"))
    #expect(source.contains("!reduceMotion && (showsSuccessFeedback || showsSuccessTint)"))
    #expect(source.contains(".contentTransition("))
    #expect(!source.contains("paused:"))
  }

  @Test("Root navigation toolbar ignores primary refresh state")
  func rootNavigationToolbarIgnoresPrimaryRefreshState() throws {
    let contentViewSource = try sourceFile(at: "Views/App/ContentView.swift")
    let toolbarItemsSource = try sourceFile(at: "Views/App/ContentToolbarItems.swift")
    let rootToolbarModel = try sourceSlice(
      in: contentViewSource,
      from: "private var contentNavigationToolbarModel",
      to: "@ToolbarContentBuilder private var contentToolbarItems"
    )

    #expect(rootToolbarModel.contains("ContentWindowNavigationToolbarModel("))
    #expect(rootToolbarModel.contains("canNavigateBack: store.contentUI.toolbar.canNavigateBack"))
    #expect(rootToolbarModel.contains("canCreateTask: store.areSelectedSessionActionsAvailable"))
    #expect(!rootToolbarModel.contains("isRefreshing"))
    #expect(!rootToolbarModel.contains("sleepPreventionEnabled"))
    #expect(!rootToolbarModel.contains("manualRefreshSuccessToken"))
    #expect(toolbarItemsSource.contains("struct ContentWindowNavigationToolbarModel: Equatable"))
    #expect(toolbarItemsSource.contains("struct ContentPrimaryToolbarModel: Equatable"))
    #expect(toolbarItemsSource.contains("let model: ContentWindowNavigationToolbarModel"))
    #expect(toolbarItemsSource.contains("let model: ContentPrimaryToolbarModel"))
  }

  private func sourceFile(at relativePath: String) throws -> String {
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

  private func sourceSlice(in source: String, from start: String, to end: String) throws -> String {
    guard let startRange = source.range(of: start),
      let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
    else {
      throw SourceContractError.missingMarker
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
  }
}

private enum SourceContractError: Error {
  case missingMarker
}
