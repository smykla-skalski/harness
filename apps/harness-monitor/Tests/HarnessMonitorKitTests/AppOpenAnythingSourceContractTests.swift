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
    // Open Anything anchors to the File menu after `.newItem`.
    #expect(menuSource.contains("CommandGroup(after: .newItem)"))
    // Edit-menu Cmd-F session search is still owned by HarnessMonitorAppCommands.
    #expect(commandsSource.contains("Button(searchCommandTitle)"))
    #expect(commandsSource.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
  }

  @Test("Palette is presented in a floating NSPanel above all windows")
  func palettePresentsInFloatingPanel() throws {
    let panelSource = try harnessSourceFile(named: "App/OpenAnythingPaletteWindow.swift")
    let positioningSource = try harnessSourceFile(
      named: "App/OpenAnythingPaletteWindow+Positioning.swift"
    )
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
    #expect(panelSource.contains("hide(reason: .windowResignedKey)"))
    #expect(panelSource.contains("model.dismiss(reason: reason)"))
    // Presentation signpost must wrap the visible AppKit path, not only the
    // model state mutation, otherwise Instruments misses window positioning
    // and makeKey latency.
    #expect(panelSource.contains("OpenAnythingSignposter.Interval.present"))
    // Hosting view must skip the `[.minSize, .intrinsicContentSize, .maxSize]`
    // probe pass on every view update - the panel size is fixed by
    // `contentRect`, the probe is pure overhead.
    #expect(panelSource.contains("hosting.sizingOptions = []"))
    // The palette opens centered on the active screen by default and restores
    // the user's remembered origin (clamped back onscreen) once they drag it.
    #expect(positioningSource.contains("OpenAnythingPanelPlacement.resolvedOrigin("))
    #expect(positioningSource.contains("NSScreen.screens.map"))
    #expect(positioningSource.contains("windowDidMove("))
    #expect(
      positioningSource.contains("OpenAnythingPreferencesDefaults.windowFrameOriginKey")
    )
    // Only a genuine drag persists - programmatic placement is guarded so the
    // remembered origin never drifts from prewarm or resize-to-content.
    #expect(panelSource.contains("positionPanel("))
    #expect(panelSource.contains("withProgrammaticFrameAdjustment"))
    #expect(panelSource.contains("panel.delegate = self"))
    #expect(appSource.contains("OpenAnythingPaletteWindowController"))
    #expect(hostSource.contains("let controller = appOpenAnythingPaletteController"))
    #expect(hostSource.contains("controller.toggle("))
    #expect(hostSource.contains("struct HarnessMonitorOpenAnythingExecutorBinder: ViewModifier"))
    // No other view tree mounts the palette directly.
    #expect(!sessionSource.contains("OpenAnythingPaletteView("))
    #expect(!settingsSource.contains("OpenAnythingPaletteView("))
    #expect(!reviewsSource.contains("OpenAnythingPaletteView("))
  }

  @Test("Open Anything palette text honors the app font scale")
  func openAnythingPaletteRespectsFontScale() throws {
    let panelSource = try harnessSourceFile(named: "App/OpenAnythingPaletteWindow.swift")
    let paletteSource = try previewableSourceFile(named: "Views/App/OpenAnythingPaletteView.swift")
    let rowSource = try previewableSourceFile(named: "Views/App/OpenAnythingPaletteRow.swift")
    let footerSource = try previewableSourceFile(named: "Views/App/OpenAnythingPaletteFooter.swift")

    // The detached NSHostingView root injects the app text-size scale because
    // it does not inherit the scene environment the rest of the app receives.
    #expect(panelSource.contains("HarnessMonitorTextSize.storageKey"))
    #expect(panelSource.contains(".sessionFontScale(textSizeIndex:"))
    // Palette text uses the scaled-font modifier rather than fixed sizes.
    #expect(paletteSource.contains(".scaledFont(.title3)"))
    #expect(rowSource.contains(".scaledFont("))
    #expect(footerSource.contains(".scaledFont("))
    #expect(!paletteSource.contains(".font(.title3)"))
  }

  @Test("App services install without status item label background hosts")
  func appServicesInstallWithoutStatusItemLabelBackgroundHosts() throws {
    let scenesSource = try harnessSourceFile(named: "App/HarnessMonitorApp+Scenes.swift")
    let openAnythingSource = try harnessSourceFile(
      named: "App/HarnessMonitorApp+OpenAnything.swift"
    )
    let clipboardSource = try previewableSourceFile(
      named: "Support/ClipboardAutomationMonitor.swift"
    )
    let labelRange = try #require(
      scenesSource.range(of: "private var menuBarExtraLabel: some View")
    )
    let labelSource = String(scenesSource[labelRange.lowerBound...])

    #expect(scenesSource.contains("installAppSceneServicesIfNeeded()"))
    #expect(scenesSource.contains("syncOpenAnythingGlobalHotKey()"))
    #expect(scenesSource.contains("restartOpenAnythingCorpusDriver("))
    #expect(openAnythingSource.contains("func installAppSceneServicesIfNeeded()"))
    #expect(openAnythingSource.contains("appOpenAnythingCorpusDriver.start("))
    #expect(
      openAnythingSource.contains(
        "appClipboardAutomationPolicyService.start(openWindow: openWindow)"
      )
    )
    #expect(clipboardSource.contains("final class ClipboardAutomationPolicyService"))
    #expect(
      !labelSource.contains(".background"),
      "MenuBarExtra labels are mirrored through Control Center NSStatusItemView scenes; "
        + "side-effect hosts must not mount inside that label."
    )
  }

  @Test("Open Anything transparency toggle gates the palette glass")
  func openAnythingTransparencyToggleGatesGlass() throws {
    let panelSource = try harnessSourceFile(named: "App/OpenAnythingPaletteWindow.swift")
    let prefsSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingPreferencesDefaults.swift"
    )
    let glassSource = try previewableSourceFile(named: "Theme/HarnessMonitorGlass.swift")
    let settingsSource = try previewableSourceFile(
      named: "Views/Settings/SettingsOpenAnythingSection.swift"
    )
    let accessibilitySource = try previewableSourceFile(
      named: "Support/HarnessMonitorAccessibility+OpenAnything.swift"
    )

    // Transparency is on by default, so existing installs and every other glass
    // surface stay unchanged.
    #expect(prefsSource.contains("transparencyEnabledKey"))
    #expect(prefsSource.contains("transparencyEnabledDefault = true"))
    // The floating-glass modifier consults the env flag and takes its opaque
    // fallback when transparency is off.
    #expect(glassSource.contains("harnessFloatingGlassTransparencyEnabled"))
    #expect(glassSource.contains("|| !transparencyEnabled"))
    // The palette injects the flag from the stored preference, scoping the
    // toggle to the Open Anything window only.
    #expect(panelSource.contains(".environment(\\.harnessFloatingGlassTransparencyEnabled"))
    #expect(panelSource.contains("OpenAnythingPreferencesDefaults.transparencyEnabledKey"))
    // Settings exposes the toggle with an accessibility identifier.
    #expect(settingsSource.contains("OpenAnythingPreferencesDefaults.transparencyEnabledKey"))
    #expect(settingsSource.contains("openAnythingTransparencyToggle"))
    #expect(accessibilitySource.contains("openAnythingTransparencyToggle"))
  }

  @Test("Open Anything Settings toggles feed production behavior")
  func openAnythingSettingsTogglesFeedModel() throws {
    let scopeSource = try harnessSourceFile(named: "App/HarnessMonitorApp+OpenAnythingScope.swift")
    let modelSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingPaletteModel.swift"
    )
    let paletteSource = try previewableSourceFile(named: "Views/App/OpenAnythingPaletteView.swift")
    let rowSource = try previewableSourceFile(named: "Views/App/OpenAnythingPaletteRow.swift")
    let settingsSource = try previewableSourceFile(
      named: "Views/Settings/SettingsOpenAnythingSection.swift"
    )

    #expect(scopeSource.contains("OpenAnythingPreferencesDefaults.showPinnedKey"))
    #expect(scopeSource.contains("OpenAnythingPreferencesDefaults.showRecentKey"))
    #expect(scopeSource.contains("OpenAnythingPreferencesDefaults.cmdClickBackgroundKey"))
    #expect(modelSource.contains("public var showsPinned"))
    #expect(modelSource.contains("public var showsRecent"))
    #expect(modelSource.contains("public var keepsPaletteOpenOnCommandClick"))
    #expect(paletteSource.contains("model.keepsPaletteOpenOnCommandClick"))
    #expect(paletteSource.contains("recordExecution(of: hit.id, refreshResults: keepsOpen)"))
    #expect(paletteSource.contains("beginKeepingPanelOpenActivation()"))
    #expect(paletteSource.contains("endKeepingPanelOpenActivation()"))
    #expect(rowSource.contains("NSEvent.modifierFlags"))
    let panelSource = try harnessSourceFile(named: "App/OpenAnythingPaletteWindow.swift")
    #expect(panelSource.contains("suppressesResignMainDismissal"))
    #expect(panelSource.contains("restorePanelAfterKeepingOpenActivation()"))
    #expect(settingsSource.contains("Cmd+Click keeps palette open"))
    #expect(settingsSource.contains("recently used palette entries rank higher"))
  }

  @Test("Open Anything current-window scope uses the keyed session snapshot")
  func currentWindowScopeUsesKeyedSessionSnapshot() throws {
    let scopeSource = try harnessSourceFile(named: "App/HarnessMonitorApp+OpenAnythingScope.swift")
    let sceneSource = try harnessSourceFile(named: "App/HarnessMonitorApp+SceneContent.swift")
    let hostSource = try harnessSourceFile(named: "App/HarnessMonitorApp+OpenAnything.swift")

    #expect(scopeSource.contains("openAnythingSessionID(forWindowID:"))
    #expect(scopeSource.contains("HarnessMonitorWindowID.sessionWindow(session.sessionId)"))
    #expect(scopeSource.contains("appStore.sessionWindowSnapshot(sessionID: sessionID)"))
    #expect(scopeSource.contains("appOpenAnythingLoadedSessionOverride"))
    #expect(sceneSource.contains("loadedSessionOverride: appOpenAnythingLoadedSessionOverride"))
    #expect(hostSource.contains("if let loadedSessionOverride"))
  }

  @Test("Open Anything timeline hits route and focus the selected entry")
  func timelineHitsRouteAndFocusEntry() throws {
    let executorSource = try harnessSourceFile(named: "App/OpenAnythingRouteExecutor.swift")
    let observerSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Observers.swift"
    )
    let listSource = try previewableSourceFile(named: "Views/Timeline/SessionTimelineList.swift")

    #expect(executorSource.contains(".requestSessionRoute(.timeline("))
    #expect(observerSource.contains("stateCache.sectionState.timelineEntryID = entryID"))
    #expect(observerSource.contains("stateCache.selectRoute(.timeline)"))
    #expect(listSource.contains("proxy.scrollTo(rowID, anchor: .center)"))
    #expect(listSource.contains("isFocused: key.rowID == row.id"))
  }

  @Test("Open Anything section header exposes collapse and show-all separately")
  func openAnythingSectionHeaderKeepsNestedControlsAccessible() throws {
    let headerSource = try previewableSourceFile(
      named: "Views/App/OpenAnythingPaletteSectionHeader.swift"
    )

    #expect(headerSource.contains("private var collapseButton"))
    #expect(headerSource.contains("Button(action: onToggleCollapse)"))
    #expect(headerSource.contains("Button(action: onToggleExpand)"))
    #expect(!headerSource.contains(".accessibilityElement(children: .ignore)"))
  }

  @Test("Global hot key registration failure clears enabled preference")
  func globalHotKeyFailureClearsEnabledPreference() throws {
    let hotKeySource = try harnessSourceFile(named: "App/GlobalHotKeyController.swift")

    #expect(hotKeySource.contains("OpenAnythingHotKeyDefaults.enabledKey"))
    #expect(hotKeySource.contains("guard installEventHandlerIfNeeded() else"))
    #expect(hotKeySource.contains("private func installEventHandlerIfNeeded() -> Bool"))
    #expect(hotKeySource.contains("UserDefaults.standard.set(false"))
    #expect(hotKeySource.contains("Failed to register Open Anything hot key"))
    #expect(hotKeySource.contains("Failed to install Open Anything hot key handler"))
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
    // Assignment must rebuild from the cached suggested lane, not through an
    // actor hop or full corpus scan, so opening the palette reflects changed
    // Settings before the user types.
    #expect(modelSource.contains("Self.suggestedResults("))
    #expect(modelSource.contains("from: corpusCache.suggestedRecords"))
    #expect(modelSource.contains("OpenAnythingPaletteCorpusCache"))
    #expect(modelSource.contains("suggestedResults = applyRanking"))
    #expect(modelSource.contains("? suggestedResults"))
    #expect(paletteSource.contains("model.suggestedResults"))
    #expect(paletteSource.contains("let expandsDomain = section.id == section.domain.rawValue"))
    #expect(paletteSource.contains("isExpanded: expandsDomain && model.isExpanded(section.domain)"))
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
    #expect(executorSource.contains("case .openDebugging:"))
    #expect(executorSource.contains("return [.openDashboard(.debugging)]"))
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
