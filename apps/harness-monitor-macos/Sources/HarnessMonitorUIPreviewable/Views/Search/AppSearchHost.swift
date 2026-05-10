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

/// Re-runs the search whenever the live query, the focused-route's
/// resolved primary domain, or the user-selected filter set changes.
private struct AppSearchTrigger: Equatable {
  let query: String
  let primary: AppSearchDomain?
  let selectedDomains: Set<AppSearchDomain>
}

/// Toolbar-placed `.searchable` field that drives the cross-domain
/// ``AppSearchModel`` after a 150 ms debounce.
///
/// The modifier owns one `@State` for the live query (the only main-actor
/// write per keystroke). The primary domain at search time is resolved
/// from the focused route, falling back to ``fallbackPrimaryDomain``.
/// Domain filtering is multi-select and lives on the model's
/// ``AppSearchModel/selectedDomains``; the suggestions view filters
/// rendered sections to that set. Ranking work happens off-MainActor
/// inside ``AppSearchIndex``.
public struct AppSearchHostModifier: ViewModifier {
  let model: AppSearchModel
  let prompt: LocalizedStringKey
  let fallbackPrimaryDomain: AppSearchDomain
  let routeAction: (AppSearchHit) -> Void

  @FocusedValue(\.harnessSessionRouteFocus)
  private var routeFocus: HarnessSessionRouteFocus?

  @State private var query: String = ""
  @State private var lastAnnouncedHitCount = -1
  @State private var isSearchPresented: Bool = false
  @FocusState private var searchFieldFocused: Bool

  public init(
    model: AppSearchModel,
    prompt: LocalizedStringKey = "Search session",
    fallbackPrimaryDomain: AppSearchDomain = .timeline,
    routeAction: @escaping (AppSearchHit) -> Void = { _ in }
  ) {
    self.model = model
    self.prompt = prompt
    self.fallbackPrimaryDomain = fallbackPrimaryDomain
    self.routeAction = routeAction
  }

  public func body(content: Content) -> some View {
    // Cmd-F path: a hidden `Button` co-located with the `.searchable`
    // owns the shortcut and writes both `isSearchPresented` and
    // `searchFieldFocused` directly. macOS does not auto-bind Cmd-F to
    // `.searchable` (Apple Developer Forums thread #688679); the menu
    // command + cross-scene `@FocusedBinding` route is documented as
    // fragile (Apple Developer Forums thread #693580). Co-locating the
    // shortcut with its target state is the canonical pure-SwiftUI fix.
    @Bindable var model = model

    return
      content
      .searchable(
        text: $query,
        isPresented: $isSearchPresented,
        placement: .toolbar,
        prompt: prompt
      )
      .searchFocused($searchFieldFocused)
      .searchPresentationToolbarBehavior(.avoidHidingContent)
      .harnessMinimizableSearchToolbar()
      .searchSuggestions {
        AppSearchSuggestionsView(
          results: model.results,
          selectedDomains: $model.selectedDomains,
          routeAction: routeAction
        )
      }
      .searchSuggestions(.visible, for: .menu)
      .background {
        Button("Find in Session", action: focusSearchField)
          .keyboardShortcut("f", modifiers: .command)
          .opacity(0)
          .accessibilityHidden(true)
      }
      .task(
        id: AppSearchTrigger(
          query: query,
          primary: resolvedPrimaryDomain,
          selectedDomains: model.selectedDomains
        )
      ) {
        await runDebouncedSearch(for: query)
      }
      .onChange(of: isSearchPresented, initial: true) { _, newValue in
        model.isPresented = newValue
      }
      .onChange(of: model.results.totalHitCount) { _, newValue in
        announceResults(totalHitCount: newValue)
      }
      .environment(\.appSearchModel, model)
  }

  private func focusSearchField() {
    isSearchPresented = true
    searchFieldFocused = true
  }

  private var resolvedPrimaryDomain: AppSearchDomain {
    routeFocus?.domain ?? fallbackPrimaryDomain
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
    await model.runSearch(query: liveQuery, primary: primary)
    appSearchSignposter.endInterval("app_search_query", state)
  }

  private func announceResults(totalHitCount: Int) {
    guard totalHitCount > 0, totalHitCount != lastAnnouncedHitCount else {
      lastAnnouncedHitCount = totalHitCount
      return
    }
    lastAnnouncedHitCount = totalHitCount
    let sectionCount = model.results.sections.count
    let primaryLabel = model.results.sections.first?.domain.label.lowercased() ?? ""
    let message: String
    if sectionCount > 1, !primaryLabel.isEmpty {
      message = "\(totalHitCount) results across \(sectionCount) sections, \(primaryLabel) first."
    } else if !primaryLabel.isEmpty {
      message = "\(totalHitCount) \(primaryLabel) results."
    } else {
      message = "\(totalHitCount) results."
    }
    AccessibilityNotification.Announcement(message).post()
  }
}

extension View {
  /// Attach the unified session-window search to a view's body.
  public func appSearchHost(
    model: AppSearchModel,
    prompt: LocalizedStringKey = "Search session",
    fallbackPrimaryDomain: AppSearchDomain = .timeline,
    routeAction: @escaping (AppSearchHit) -> Void = { _ in }
  ) -> some View {
    modifier(
      AppSearchHostModifier(
        model: model,
        prompt: prompt,
        fallbackPrimaryDomain: fallbackPrimaryDomain,
        routeAction: routeAction
      )
    )
  }
}
