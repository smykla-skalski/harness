import HarnessMonitorKit
import OSLog
import SwiftUI

/// Quiet window between the last keystroke and the actor hop. Mirrors the
/// 150 ms budget set in the perf contract.
private let appSearchDebounceNanoseconds: UInt64 = 150_000_000

/// OSSignposter contract: every search query begins/ends an
/// `app_search_query` interval so trace-driven verification can measure
/// the median dispatch latency.
private let appSearchSignposter = OSSignposter(
  subsystem: "io.harnessmonitor",
  category: "perf"
)

/// Re-runs the search whenever the live query or active primary domain changes.
private struct AppSearchTrigger: Equatable {
  let query: String
  let primary: AppSearchDomain?
}

/// Toolbar-placed `.searchable` field that drives the cross-domain
/// `AppSearchModel` after a 150 ms debounce.
///
/// The modifier owns one `@State` for the live query (the only main-actor
/// write per keystroke). The primary domain is injected by the session
/// window so route changes do not flow through `FocusedValues` into the
/// native search field.
/// Ranking work happens off-MainActor inside `AppSearchIndex`.
///
/// Cmd-F focus is published through the shared focused-command dispatcher
/// instead of a hidden view-local Button. That keeps keyboard ownership in
/// app commands and avoids leaving an always-present opacity renderer in
/// the session window graph.
///
/// Suggestions stay on SwiftUI's native `.searchSuggestions` path, fed by a
/// compact value snapshot. The search field avoids an `isPresented` binding;
/// Instruments showed that binding fans toolbar search presentation through
/// the expensive AppKit text-field path.
public struct AppSearchHost: View {
  let model: AppSearchModel
  let prompt: LocalizedStringKey
  let primaryDomainProvider: @MainActor () -> AppSearchDomain?
  let fallbackPrimaryDomain: AppSearchDomain
  let isEnabled: Bool
  let automation: AppSearchAutomationState?
  let routeAction: (AppSearchHit) -> Void

  @State private var query: String = ""
  @State private var suggestionSnapshot = AppSearchSuggestionSnapshot.empty
  @State private var searchFocusDispatcher = HarnessSidebarSearchFocusDispatcher()
  @FocusState private var isSearchFocused: Bool

  public init(
    model: AppSearchModel,
    prompt: LocalizedStringKey = "Search session",
    primaryDomainProvider: @escaping @MainActor () -> AppSearchDomain? = { nil },
    fallbackPrimaryDomain: AppSearchDomain = .timeline,
    isEnabled: Bool = true,
    automation: AppSearchAutomationState? = nil,
    routeAction: @escaping (AppSearchHit) -> Void = { _ in }
  ) {
    self.model = model
    self.prompt = prompt
    self.primaryDomainProvider = primaryDomainProvider
    self.fallbackPrimaryDomain = fallbackPrimaryDomain
    self.isEnabled = isEnabled
    self.automation = automation
    self.routeAction = routeAction
  }

  public var body: some View {
    ZStack(alignment: .topTrailing) {
      AppSearchFieldSurface(
        query: $query,
        prompt: prompt,
        suggestionRows: suggestionSnapshot.rows,
        isFocused: $isSearchFocused,
        isEnabled: isEnabled,
        onSubmit: submitSearch
      )
      .equatable()

      AppSearchTaskAnchor(
        trigger: searchTrigger,
        shouldKeepSearchIndexActive: shouldKeepSearchIndexActive,
        runSearch: runDebouncedSearch,
        setPresented: model.setPresented
      )
      .frame(width: 0, height: 0)
      .allowsHitTesting(false)
    }
    .fixedSize()
    .task {
      automation?.handler = { command in
        Task { @MainActor in
          await applyAutomationCommand(command)
        }
      }
    }
    .onDisappear {
      automation?.handler = nil
    }
    .onChange(of: query) { oldValue, newValue in
      routeNativeSuggestionCompletion(from: oldValue, to: newValue)
    }
    .harnessFocusedSceneValue(\.harnessSidebarSearchFocusAction, searchFocusAction)
    .task {
      searchFocusDispatcher.handler = {
        focusSearchField()
      }
    }
  }

  private var searchFocusAction: HarnessSidebarSearchFocus? {
    guard isEnabled else {
      return nil
    }
    return HarnessSidebarSearchFocus(
      isAvailable: true,
      menuLabel: .findInSession,
      dispatcher: searchFocusDispatcher
    )
  }

  private func focusSearchField() {
    guard isEnabled else { return }
    guard !isSearchFocused else { return }
    isSearchFocused = true
  }

  private var shouldKeepSearchIndexActive: Bool {
    guard isEnabled else { return false }
    return isSearchFocused || hasSearchQuery
  }

  private func submitSearch() {
    guard isEnabled else { return }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let hit =
      suggestionSnapshot.hit(matchingCompletion: trimmed)
      ?? suggestionSnapshot.firstHit
      ?? model.results.sections.first?.hits.first
    guard let hit else { return }
    handleHit(hit)
  }

  private func routeNativeSuggestionCompletion(from oldValue: String, to newValue: String) {
    let oldTrimmed = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != oldTrimmed else { return }
    guard let hit = suggestionSnapshot.hit(matchingDisplayTitle: trimmed) else { return }
    handleHit(hit)
  }

  /// Route to the hit, then clear the query and collapse the search
  /// field as one atomic step. Without the clear, the per-route list
  /// (which mirrors `appSearchModel.query`) keeps its filter applied
  /// after drilling into a specific agent / decision / task and hides
  /// the rest of the route.
  private func handleHit(_ hit: AppSearchHit) {
    routeAction(hit)
    if !query.isEmpty {
      query = ""
    }
    model.clear()
    updateSuggestionSnapshot(.empty)
    if isSearchFocused {
      isSearchFocused = false
    }
  }

  private var searchTrigger: AppSearchTrigger {
    guard isEnabled, hasSearchQuery else {
      return AppSearchTrigger(query: "", primary: nil)
    }
    return AppSearchTrigger(query: query, primary: resolvedPrimaryDomain)
  }

  private var hasSearchQuery: Bool {
    !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var resolvedPrimaryDomain: AppSearchDomain {
    primaryDomainProvider() ?? fallbackPrimaryDomain
  }

  private func applyAutomationCommand(_ command: AppSearchAutomationCommand) async {
    if query != command.query {
      query = command.query
      if command.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        updateSuggestionSnapshot(.empty)
      }
      await Task.yield()
    }
    guard !Task.isCancelled else { return }
    if isSearchFocused != command.isPresented {
      isSearchFocused = command.isPresented
    }
  }

  private func runDebouncedSearch(for trigger: AppSearchTrigger) async {
    do {
      try await Task.sleep(nanoseconds: appSearchDebounceNanoseconds)
    } catch {
      return
    }
    guard !Task.isCancelled else {
      return
    }
    let liveQuery = trigger.query
    let primary = trigger.primary
    let primaryLabel = primary?.rawValue ?? "none"
    let signpostID = appSearchSignposter.makeSignpostID()
    let state = appSearchSignposter.beginInterval(
      "app_search_query",
      id: signpostID,
      "primary=\(primaryLabel)"
    )
    let results = await model.runSearch(query: liveQuery, primary: primary)
    appSearchSignposter.endInterval("app_search_query", state)
    guard !Task.isCancelled else {
      return
    }
    updateSuggestionSnapshot(AppSearchSuggestionSnapshot(results: results))
  }

  private func updateSuggestionSnapshot(_ snapshot: AppSearchSuggestionSnapshot) {
    guard suggestionSnapshot != snapshot else { return }
    suggestionSnapshot = snapshot
  }

}

private struct AppSearchFieldSurface: View, Equatable {
  @Binding var query: String
  let prompt: LocalizedStringKey
  let suggestionRows: [AppSearchSuggestionRow]
  let isFocused: FocusState<Bool>.Binding
  let isEnabled: Bool
  let onSubmit: () -> Void
  private let queryValue: String
  private let isFocusedValue: Bool
  private let isEnabledValue: Bool

  init(
    query: Binding<String>,
    prompt: LocalizedStringKey,
    suggestionRows: [AppSearchSuggestionRow],
    isFocused: FocusState<Bool>.Binding,
    isEnabled: Bool,
    onSubmit: @escaping () -> Void
  ) {
    _query = query
    self.prompt = prompt
    self.suggestionRows = suggestionRows
    self.isFocused = isFocused
    self.isEnabled = isEnabled
    self.onSubmit = onSubmit
    queryValue = query.wrappedValue
    isFocusedValue = isFocused.wrappedValue
    isEnabledValue = isEnabled
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.queryValue == rhs.queryValue
      && lhs.isFocusedValue == rhs.isFocusedValue
      && lhs.suggestionRows == rhs.suggestionRows
      && lhs.isEnabledValue == rhs.isEnabledValue
  }

  @ViewBuilder var body: some View {
    if isEnabled {
      Color.clear
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .searchable(
          text: $query,
          placement: .toolbar,
          prompt: prompt
        )
        .searchSuggestions {
          ForEach(suggestionRows) { row in
            Text(verbatim: row.displayTitle)
              .searchCompletion(row.displayTitle)
          }
          .searchSuggestions(.hidden, for: .content)
        }
        .searchFocused(isFocused)
        .harnessMinimizableSearchToolbar()
        .onSubmit(of: .search) {
          onSubmit()
        }
    } else {
      Color.clear
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
  }
}

private struct AppSearchTaskAnchor: View {
  let trigger: AppSearchTrigger
  let shouldKeepSearchIndexActive: Bool
  let runSearch: (AppSearchTrigger) async -> Void
  let setPresented: (Bool) -> Void

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .task(id: trigger) {
        await runSearch(trigger)
      }
      .task(id: shouldKeepSearchIndexActive) {
        setPresented(shouldKeepSearchIndexActive)
      }
  }
}

public struct AppSearchHostModifier: ViewModifier {
  let model: AppSearchModel
  let prompt: LocalizedStringKey
  let primaryDomainProvider: @MainActor () -> AppSearchDomain?
  let fallbackPrimaryDomain: AppSearchDomain
  let isEnabled: Bool
  let automation: AppSearchAutomationState?
  let routeAction: (AppSearchHit) -> Void

  public func body(content: Content) -> some View {
    content.overlay(alignment: .topTrailing) {
      AppSearchHost(
        model: model,
        prompt: prompt,
        primaryDomainProvider: primaryDomainProvider,
        fallbackPrimaryDomain: fallbackPrimaryDomain,
        isEnabled: isEnabled,
        automation: automation,
        routeAction: routeAction
      )
    }
  }
}

extension View {
  /// Attach the unified session-window search to a view's body.
  public func appSearchHost(
    model: AppSearchModel,
    prompt: LocalizedStringKey = "Search session",
    primaryDomainProvider: @escaping @MainActor () -> AppSearchDomain? = { nil },
    fallbackPrimaryDomain: AppSearchDomain = .timeline,
    isEnabled: Bool = true,
    automation: AppSearchAutomationState? = nil,
    routeAction: @escaping (AppSearchHit) -> Void = { _ in }
  ) -> some View {
    modifier(
      AppSearchHostModifier(
        model: model,
        prompt: prompt,
        primaryDomainProvider: primaryDomainProvider,
        fallbackPrimaryDomain: fallbackPrimaryDomain,
        isEnabled: isEnabled,
        automation: automation,
        routeAction: routeAction
      )
    )
  }
}
