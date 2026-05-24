import Foundation
import Testing

@Suite("AppOpenAnything source contracts")
struct AppOpenAnythingSourceContractTests {
  @Test("Command-K command exists and Command-F session search remains")
  func commandKExistsWithoutReplacingCommandF() throws {
    let menuSource = try harnessSourceFile(named: "Commands/OpenAnythingMenuCommands.swift")
    let commandsSource = try harnessSourceFile(named: "App/HarnessMonitorAppCommands.swift")

    #expect(menuSource.contains("Button(menuTitle, action: presentOpenAnything)"))
    #expect(menuSource.contains(".keyboardShortcut(\"k\", modifiers: .command)"))
    #expect(
      menuSource.contains(
        "Button(\"Open Anything (Sessions)\", action: presentOpenAnythingSessions)"
      )
    )
    #expect(menuSource.contains(".keyboardShortcut(\"k\", modifiers: [.command, .shift])"))
    // Audit #11: Open Anything anchors to the File menu (after `.newItem`).
    #expect(menuSource.contains("CommandGroup(after: .newItem)"))
    // Edit-menu Cmd-F session search is still owned by HarnessMonitorAppCommands.
    #expect(commandsSource.contains("Button(searchCommandTitle)"))
    #expect(commandsSource.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
  }

  @Test("Palette is presented in a floating NSPanel above all windows")
  func palettePresentsInFloatingPanel() throws {
    let panelSource = try harnessSourceFile(named: "App/OpenAnythingPaletteWindow.swift")
    let appSource = try harnessSourceFile(named: "App/HarnessMonitorApp.swift")
    let hostSource = try harnessSourceFile(named: "App/HarnessMonitorApp+OpenAnything.swift")
    let sessionSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let settingsSource = try previewableSourceFile(
      named: "Views/Settings/SettingsGeneralSection.swift"
    )
    let reviewsSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardReviewsRouteView.swift"
    )

    // The floating panel + controller is the single mount point for the
    // palette - it owns key focus, click-outside dismissal, and the global
    // (cross-window) presentation behavior.
    #expect(panelSource.contains("final class OpenAnythingFloatingPanel: NSPanel"))
    #expect(panelSource.contains("final class OpenAnythingPaletteWindowController"))
    #expect(panelSource.contains("isFloatingPanel = true"))
    // Canonical Spotlight-style level - keeps the palette above full-screen
    // and notification surfaces. Reverting to `.floating` would let other
    // floating windows occlude it.
    #expect(panelSource.contains("level = .statusBar"))
    #expect(panelSource.contains("NSHostingView"))
    // macOS 26 (Tahoe) animates window-open regardless of
    // `animationBehavior = .none`. The palette MUST hide via
    // `alphaValue = 0` (keeping the panel ordered front) and show by
    // restoring alpha + `makeKey` so the second-and-subsequent show skips
    // the system show animation entirely.
    #expect(panelSource.contains("panel?.alphaValue = 0"))
    #expect(panelSource.contains("panel.alphaValue = 1"))
    // Hosting view must skip the `[.minSize, .intrinsicContentSize, .maxSize]`
    // probe pass on every view update - the panel size is fixed by
    // `contentRect`, the probe is pure overhead.
    #expect(panelSource.contains("hosting.sizingOptions = []"))
    #expect(appSource.contains("OpenAnythingPaletteWindowController"))
    #expect(hostSource.contains("appOpenAnythingPaletteController.toggle("))
    #expect(hostSource.contains("struct HarnessMonitorOpenAnythingExecutorBinder: ViewModifier"))
    // No other view tree mounts the palette directly.
    #expect(!sessionSource.contains("OpenAnythingPaletteView("))
    #expect(!settingsSource.contains("OpenAnythingPaletteView("))
    #expect(!reviewsSource.contains("OpenAnythingPaletteView("))
  }

  @Test("Session AppSearchHost remains native toolbar search")
  func sessionAppSearchHostRemainsNativeToolbarSearch() throws {
    let hostSource = try previewableSourceFile(named: "Views/Search/AppSearchHost.swift")
    let sessionHostSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+SearchHost.swift"
    )

    #expect(hostSource.contains(".searchable("))
    #expect(hostSource.contains(".searchSuggestions"))
    #expect(sessionHostSource.contains("AppSearchHost("))
    #expect(!hostSource.contains("OpenAnythingPaletteView("))
  }

  @Test("Empty palette surfaces suggested commands")
  func emptyPaletteSurfacesSuggestedCommands() throws {
    let modelSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingPaletteModel.swift"
    )
    let paletteSource = try previewableSourceFile(named: "Views/App/OpenAnythingPaletteView.swift")
    let corpusSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingCorpusBuilder.swift"
    )
    let metadataSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingActionMetadata.swift"
    )

    #expect(modelSource.contains("public private(set) var suggestedResults"))
    // Audit #78: assignment must reach the actor's `suggestedResults`
    // factory. Ranking + scope filtering layer on top; both currently route
    // through `applyRanking` so the contract just requires the suggested
    // pipeline to be in place rather than pinning to a single literal.
    #expect(modelSource.contains("await index.suggestedResults("))
    #expect(modelSource.contains("suggestedResults = applyRanking"))
    #expect(modelSource.contains("? suggestedResults"))
    #expect(paletteSource.contains("model.suggestedResults"))
    #expect(corpusSource.contains("isSuggested: suggestedActions.contains(action)"))
    #expect(metadataSource.contains("static let suggestedActions"))
    #expect(metadataSource.contains(".openDiagnostics"))
    #expect(metadataSource.contains(".openReviews"))
  }

  @Test("Command palette routes diagnostics and settings actions")
  func commandPaletteRoutesDiagnosticsAndSettingsActions() throws {
    let executorSource = try harnessSourceFile(named: "App/OpenAnythingRouteExecutor.swift")
    let hostSource = try harnessSourceFile(named: "App/HarnessMonitorApp+OpenAnything.swift")

    // Executor was refactored from a dictionary to an exhaustive switch in
    // `e5c495664`; assertions check the case + return pair instead of
    // dictionary-literal syntax.
    #expect(executorSource.contains("case .openDiagnostics:"))
    #expect(executorSource.contains("return [.openDashboard(.diagnostics)]"))
    #expect(executorSource.contains("case .refreshDiagnostics:"))
    #expect(
      executorSource.contains(
        "return [.openDashboard(.diagnostics), .refreshDiagnostics]"
      )
    )
    #expect(executorSource.contains("case .reconnectDaemon:"))
    #expect(executorSource.contains("return [.reconnectDaemon]"))
    #expect(executorSource.contains("case .copyDiagnostics:"))
    #expect(executorSource.contains("return [.copyDiagnostics]"))
    #expect(executorSource.contains("case .openMCPSettings:"))
    #expect(executorSource.contains("return [.openSettings(rawValue: \"mcp\")]"))
    #expect(executorSource.contains("case .openDatabaseSettings:"))
    #expect(executorSource.contains("return [.openSettings(rawValue: \"database\")]"))

    #expect(hostSource.contains("case .refreshDiagnostics:"))
    #expect(hostSource.contains("Task { await store.refreshDiagnostics() }"))
    #expect(hostSource.contains("case .reconnectDaemon:"))
    #expect(hostSource.contains("Task { await store.reconnect() }"))
    #expect(hostSource.contains("case .copyDiagnostics:"))
    #expect(hostSource.contains("copyMonitorDiagnostics()"))
  }

  private func harnessSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: harnessSourceURL(named: relativePath), encoding: .utf8)
  }

  private func harnessKitSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: harnessKitSourceURL(named: relativePath), encoding: .utf8)
  }

  private func previewableSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: previewableSourceURL(named: relativePath), encoding: .utf8)
  }

  private func harnessSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitor")
      .appendingPathComponent(relativePath)
  }

  private func harnessKitSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorKit")
      .appendingPathComponent(relativePath)
  }

  private func previewableSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
  }

  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
