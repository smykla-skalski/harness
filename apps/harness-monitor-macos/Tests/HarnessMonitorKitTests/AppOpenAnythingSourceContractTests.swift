import Foundation
import Testing

@Suite("AppOpenAnything source contracts")
struct AppOpenAnythingSourceContractTests {
  @Test("Command-K command exists and Command-F session search remains")
  func commandKExistsWithoutReplacingCommandF() throws {
    let commandsSource = try harnessSourceFile(named: "App/HarnessMonitorAppCommands.swift")

    #expect(commandsSource.contains("Button(\"Open Anything\", action: presentOpenAnything)"))
    #expect(commandsSource.contains(".keyboardShortcut(\"k\", modifiers: .command)"))
    #expect(commandsSource.contains("Button(searchCommandTitle)"))
    #expect(commandsSource.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
  }

  @Test("Palette overlay is mounted through the shared scene modifier")
  func paletteOverlayUsesSharedSceneModifier() throws {
    let hostSource = try harnessSourceFile(named: "App/HarnessMonitorApp+OpenAnything.swift")
    let sceneSource = try harnessSourceFile(named: "App/HarnessMonitorApp+SceneContent.swift")
    let sessionSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let settingsSource = try previewableSourceFile(
      named: "Views/Settings/SettingsGeneralSection.swift"
    )
    let reviewsSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardReviewsRouteView.swift"
    )

    #expect(hostSource.contains("struct HarnessMonitorOpenAnythingHostModifier: ViewModifier"))
    #expect(hostSource.contains("OpenAnythingPaletteView(model: model, execute: execute)"))
    #expect(
      sceneSource.contains("openAnythingHostModifier(windowID: HarnessMonitorWindowID.dashboard)")
    )
    #expect(
      sceneSource.contains("openAnythingHostModifier(windowID: HarnessMonitorWindowID.settings)")
    )
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
    #expect(modelSource.contains("suggestedResults = await index.suggestedResults()"))
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

    #expect(executorSource.contains(".openDiagnostics: [.openDashboard(.diagnostics)]"))
    #expect(
      executorSource.contains(
        ".refreshDiagnostics: [.openDashboard(.diagnostics), .refreshDiagnostics]"
      )
    )
    #expect(executorSource.contains(".reconnectDaemon: [.reconnectDaemon]"))
    #expect(executorSource.contains(".copyDiagnostics: [.copyDiagnostics]"))
    #expect(executorSource.contains(".openMCPSettings: [.openSettings(rawValue: \"mcp\")]"))
    #expect(
      executorSource.contains(
        ".openDatabaseSettings: [.openSettings(rawValue: \"database\")]"
      )
    )

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
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitor")
      .appendingPathComponent(relativePath)
  }

  private func harnessKitSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorKit")
      .appendingPathComponent(relativePath)
  }

  private func previewableSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
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
