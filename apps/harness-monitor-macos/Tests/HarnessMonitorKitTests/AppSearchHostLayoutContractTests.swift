import Testing

extension SessionWindowFlowTests {
  @Test("Session search keeps the field native and suggestions snapshot-backed")
  func sessionSearchKeepsFieldNativeAndSuggestionsSnapshotBacked() throws {
    let source = try previewableSourceFile(named: "Views/Search/AppSearchHost.swift")

    #expect(source.contains(".searchable("))
    #expect(source.contains(".searchSuggestions"))
    #expect(source.contains(".searchSuggestions(.hidden, for: .content)"))
    #expect(source.contains(".searchCompletion(row.displayTitle)"))
    #expect(source.contains("public struct AppSearchHost: View"))
    #expect(source.contains("public struct AppSearchHostModifier: ViewModifier"))
    #expect(source.contains("private struct AppSearchFieldSurface: View"))
    #expect(source.contains("private struct AppSearchTaskAnchor: View"))
    #expect(source.contains("primaryDomainProvider: @escaping @MainActor"))
    #expect(source.contains("guard isEnabled, hasSearchQuery else {"))
    #expect(source.contains("AppSearchTrigger(query: \"\", primary: nil)"))
    #expect(source.contains("private struct AppSearchFieldSurface: View, Equatable"))
    #expect(source.contains(".equatable()"))
    #expect(source.contains("lhs.queryValue == rhs.queryValue"))
    #expect(source.contains("lhs.isFocusedValue == rhs.isFocusedValue"))
    #expect(source.contains("lhs.suggestionRows == rhs.suggestionRows"))
    #expect(source.contains(".searchFocused(isFocused)"))
    #expect(!source.contains("isPresented: $isSearchPresented"))
    #expect(source.contains("ZStack(alignment: .topTrailing)"))
    #expect(source.contains("suggestionRows: visibleSuggestionRows"))
    #expect(source.contains("HarnessMonitorPerfIsolation.disablesSearchSuggestions"))
    #expect(source.contains("@State private var suggestionSnapshot"))
    #expect(
      source.contains("updateSuggestionSnapshot(AppSearchSuggestionSnapshot(results: results))")
    )
    #expect(source.contains(".onSubmit(of: .search)"))
    #expect(source.contains("submitSearch()"))
    #expect(source.contains("let automation: AppSearchAutomationState?"))
    #expect(source.contains("await applyAutomationCommand(command)"))
    #expect(source.contains("await Task.yield()"))
    #expect(source.contains("HarnessSidebarSearchFocusDispatcher()"))
    #expect(source.contains(".harnessFocusedSceneValue(\\.harnessSidebarSearchFocusAction"))
    #expect(!source.contains(".environment(\\.appSearchModel, model)"))
    #expect(source.contains(".task(id: shouldKeepSearchIndexActive)"))
    #expect(source.contains("setPresented: model.setPresented"))
    #expect(!source.contains(".onChange(of: isSearchPresented"))
    #expect(!source.contains("Button(\"Find in Session\""))
    #expect(!source.contains(".searchPresentationToolbarBehavior(.avoidHidingContent)"))
    #expect(!source.contains("@Environment(\\.accessibilityVoiceOverEnabled)"))
    #expect(!source.contains("results: model.results"))
    #expect(!source.contains(".onChange(of: model.results.totalHitCount)"))
    #expect(source.contains("routeNativeSuggestionCompletion(from: oldValue, to: newValue)"))
    #expect(source.contains("suggestionSnapshot.hit(matchingDisplayTitle: trimmed)"))
    #expect(!source.contains("AppSearchSuggestionsView"))
    #expect(!source.contains("AppSearchFieldRebinder"))
    #expect(!source.contains("NSSearchField"))
    #expect(source.contains("Text(verbatim: row.displayTitle)"))
    #expect(!source.contains("Section {"))
    #expect(!source.contains("@Bindable var model = model"))
  }

  @Test("App search toolbar anchor stays zero-sized")
  func appSearchToolbarAnchorStaysZeroSized() throws {
    let source = try previewableSourceFile(named: "Views/Search/AppSearchHost.swift")
    let sessionHostSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+SearchHost.swift"
    )

    #expect(source.contains(".searchable("))
    #expect(source.contains(".frame(width: 0, height: 0)"))
    #expect(source.contains(".searchSuggestions"))
    #expect(!source.contains("suggestionOverlay"))
    #expect(!source.contains("AppSearchSuggestionsView"))
    #expect(source.contains(".allowsHitTesting(false)"))
    #expect(!source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity"))
    #expect(!sessionHostSource.contains(".frame(maxWidth: .infinity, maxHeight: .infinity"))
  }

  @Test("Session search waits until startup load enables the toolbar field")
  func sessionSearchDefersToolbarFieldUntilStartupSettles() throws {
    let hostSource = try previewableSourceFile(named: "Views/Search/AppSearchHost.swift")
    let sessionWindowSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView.swift"
    )
    let sessionHostSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+SearchHost.swift"
    )
    let presentationSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Presentation.swift"
    )

    #expect(hostSource.contains("let isEnabled: Bool"))
    #expect(hostSource.contains("guard isEnabled else {\n      return nil\n    }"))
    #expect(hostSource.contains("guard isEnabled, hasSearchQuery else {"))
    #expect(hostSource.contains("if isEnabled {"))
    #expect(
      sessionWindowSource.contains(
        """
        @State private var startupSearchParticipationEnabledStorage =
            HarnessMonitorUITestEnvironment.isEnabled
        """
      )
    )
    #expect(sessionWindowSource.contains("var isStartupSearchParticipationEnabled: Bool {"))
    #expect(sessionHostSource.contains("isEnabled: isStartupSearchParticipationEnabled"))
    #expect(presentationSource.contains("enableStartupSearchParticipation()"))
  }
}
