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

/// Re-runs the search whenever the live query or resolved primary domain
/// changes.
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
/// Suggestions are rendered from a compact value snapshot in an app-owned
/// overlay. The search field itself stays native `.searchable` without an
/// `isPresented` binding; Instruments showed that binding fans toolbar
/// search presentation through the expensive AppKit text-field path.
public struct AppSearchHost: View {
  let model: AppSearchModel
  let prompt: LocalizedStringKey
  let primaryDomain: AppSearchDomain?
  let fallbackPrimaryDomain: AppSearchDomain
  let automation: AppSearchAutomationState?
  let routeAction: (AppSearchHit) -> Void

  @State private var query: String = ""
  @State private var suggestionSnapshot = AppSearchSuggestionSnapshot.empty
  @State private var searchFocusDispatcher = HarnessSidebarSearchFocusDispatcher()
  @FocusState private var isSearchFocused: Bool

  public init(
    model: AppSearchModel,
    prompt: LocalizedStringKey = "Search session",
    primaryDomain: AppSearchDomain? = nil,
    fallbackPrimaryDomain: AppSearchDomain = .timeline,
    automation: AppSearchAutomationState? = nil,
    routeAction: @escaping (AppSearchHit) -> Void = { _ in }
  ) {
    self.model = model
    self.prompt = prompt
    self.primaryDomain = primaryDomain
    self.fallbackPrimaryDomain = fallbackPrimaryDomain
    self.automation = automation
    self.routeAction = routeAction
  }

  public var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .overlay(alignment: .topTrailing) {
        suggestionOverlay
      }
      .searchable(
        text: $query,
        placement: .toolbar,
        prompt: prompt
      )
      .searchFocused($isSearchFocused)
      .harnessMinimizableSearchToolbar()
      .onSubmit(of: .search) {
        submitSearch()
      }
      .task(
        id: AppSearchTrigger(
          query: query,
          primary: resolvedPrimaryDomain
        )
      ) {
        await runDebouncedSearch(for: query)
      }
      .task(id: shouldKeepSearchIndexActive) {
        model.setPresented(shouldKeepSearchIndexActive)
      }
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
      .harnessFocusedSceneValue(\.harnessSidebarSearchFocusAction, searchFocusAction)
      .task {
        searchFocusDispatcher.handler = {
          focusSearchField()
        }
      }
  }

  private var searchFocusAction: HarnessSidebarSearchFocus {
    HarnessSidebarSearchFocus(
      isAvailable: true,
      menuLabel: .findInSession,
      dispatcher: searchFocusDispatcher
    )
  }

  private func focusSearchField() {
    guard !isSearchFocused else { return }
    isSearchFocused = true
  }

  @ViewBuilder private var suggestionOverlay: some View {
    if shouldShowSuggestionOverlay {
      AppSearchSuggestionsView(snapshot: suggestionSnapshot, onPick: handleHit)
        .padding(.top, 8)
        .padding(.trailing, 16)
        .zIndex(10)
        .allowsHitTesting(true)
    }
  }

  private var shouldShowSuggestionOverlay: Bool {
    shouldKeepSearchIndexActive
      && !suggestionSnapshot.rows.isEmpty
  }

  private var shouldKeepSearchIndexActive: Bool {
    isSearchFocused || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func submitSearch() {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let hit =
      suggestionSnapshot.hit(matchingCompletion: trimmed)
      ?? suggestionSnapshot.firstHit
      ?? model.results.sections.first?.hits.first
    guard let hit else { return }
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

  private var resolvedPrimaryDomain: AppSearchDomain {
    primaryDomain ?? fallbackPrimaryDomain
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

  private func runDebouncedSearch(for liveQuery: String) async {
    do {
      try await Task.sleep(nanoseconds: appSearchDebounceNanoseconds)
    } catch {
      return
    }
    guard !Task.isCancelled else {
      return
    }
    let primary = resolvedPrimaryDomain
    let signpostID = appSearchSignposter.makeSignpostID()
    let state = appSearchSignposter.beginInterval(
      "app_search_query",
      id: signpostID,
      "primary=\(primary.rawValue)"
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

public struct AppSearchHostModifier: ViewModifier {
  let model: AppSearchModel
  let prompt: LocalizedStringKey
  let primaryDomain: AppSearchDomain?
  let fallbackPrimaryDomain: AppSearchDomain
  let automation: AppSearchAutomationState?
  let routeAction: (AppSearchHit) -> Void

  public func body(content: Content) -> some View {
    content.overlay(alignment: .topTrailing) {
      AppSearchHost(
        model: model,
        prompt: prompt,
        primaryDomain: primaryDomain,
        fallbackPrimaryDomain: fallbackPrimaryDomain,
        automation: automation,
        routeAction: routeAction
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
  }
}

extension View {
  /// Attach the unified session-window search to a view's body.
  public func appSearchHost(
    model: AppSearchModel,
    prompt: LocalizedStringKey = "Search session",
    primaryDomain: AppSearchDomain? = nil,
    fallbackPrimaryDomain: AppSearchDomain = .timeline,
    automation: AppSearchAutomationState? = nil,
    routeAction: @escaping (AppSearchHit) -> Void = { _ in }
  ) -> some View {
    modifier(
      AppSearchHostModifier(
        model: model,
        prompt: prompt,
        primaryDomain: primaryDomain,
        fallbackPrimaryDomain: fallbackPrimaryDomain,
        automation: automation,
        routeAction: routeAction
      )
    )
  }
}
