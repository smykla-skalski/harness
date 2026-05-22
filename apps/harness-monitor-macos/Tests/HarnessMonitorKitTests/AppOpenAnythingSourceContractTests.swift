import Foundation
import Testing

@Suite("AppOpenAnything source contracts")
struct AppOpenAnythingSourceContractTests {
  @Test("Command-K command exists and Command-F session search remains")
  func commandKExistsWithoutReplacingCommandF() throws {
    let commandsSource = try harnessSourceFile(named: "App/HarnessMonitorAppCommands.swift")

    #expect(commandsSource.contains("Button(\"Open Anything\")"))
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
    let dependenciesSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardDependenciesRouteView.swift"
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
    #expect(!dependenciesSource.contains("OpenAnythingPaletteView("))
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

  private func harnessSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: harnessSourceURL(named: relativePath), encoding: .utf8)
  }

  private func previewableSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: previewableSourceURL(named: relativePath), encoding: .utf8)
  }

  private func harnessSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitor")
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
