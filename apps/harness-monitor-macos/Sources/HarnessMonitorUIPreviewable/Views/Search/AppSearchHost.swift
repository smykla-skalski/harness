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

/// Joins live query + selected scope into a single `.task(id:)` key so a
/// scope flip without keystrokes still re-runs the search.
private struct AppSearchTrigger: Equatable {
  let query: String
  let scope: AppSearchScope
}

/// Toolbar-placed `.searchable` field that drives the cross-domain
/// ``AppSearchModel`` after a 150 ms debounce.
///
/// The modifier owns one `@State` for the live query (the only main-actor
/// write per keystroke) and one `@State` for the explicit scope. The
/// primary domain at search time is resolved as: explicit scope wins,
/// otherwise the focused-route domain, otherwise `fallbackPrimaryDomain`.
/// Ranking work happens off-MainActor inside ``AppSearchIndex``.
public struct AppSearchHostModifier: ViewModifier {
  let model: AppSearchModel
  let prompt: LocalizedStringKey
  let fallbackPrimaryDomain: AppSearchDomain
  let routeAction: (AppSearchHit) -> Void

  @FocusedValue(\.harnessSessionRouteFocus)
  private var routeFocus: HarnessSessionRouteFocus?

  @State private var query: String = ""
  @State private var scope: AppSearchScope = .current
  @State private var lastAnnouncedHitCount = -1
  @State private var isSearchPresented: Bool = false

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
    // `isPresented:` is the system-Find auto-wire: SwiftUI binds Cmd-F (the
    // standard `TextEditingCommands` Find item) to this binding, so the same
    // write that programmatic callers would make is what the keyboard
    // shortcut already triggers natively. No custom dispatcher needed.
    content
      .searchable(
        text: $query,
        isPresented: $isSearchPresented,
        placement: .toolbar,
        prompt: prompt
      )
      .searchPresentationToolbarBehavior(.avoidHidingContent)
      .harnessMinimizableSearchToolbar()
      .searchScopes($scope, activation: .onSearchPresentation) {
        ForEach(AppSearchScope.allCases) { value in
          Text(value.label).tag(value)
        }
      }
      .searchSuggestions {
        AppSearchSuggestionsView(
          results: model.results,
          routeAction: routeAction
        )
      }
      .task(id: AppSearchTrigger(query: query, scope: scope)) {
        await runDebouncedSearch(for: query, scope: scope)
      }
      .onChange(of: model.results.totalHitCount) { _, newValue in
        announceResults(totalHitCount: newValue)
      }
      .environment(\.appSearchModel, model)
  }

  private func runDebouncedSearch(
    for liveQuery: String,
    scope: AppSearchScope
  ) async {
    do {
      try await Task.sleep(nanoseconds: appSearchDebounceNanoseconds)
    } catch {
      return
    }
    guard !Task.isCancelled else {
      return
    }
    let primary = scope.explicitDomain ?? routeFocus?.domain ?? fallbackPrimaryDomain
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
