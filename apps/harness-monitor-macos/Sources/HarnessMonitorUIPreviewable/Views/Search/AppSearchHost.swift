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

/// Re-runs the search whenever the live query or the focused-route's
/// resolved primary domain changes.
private struct AppSearchTrigger: Equatable {
  let query: String
  let primary: AppSearchDomain?
}

/// Toolbar-placed `.searchable` field that drives the cross-domain
/// `AppSearchModel` after a 150 ms debounce.
///
/// The modifier owns one `@State` for the live query (the only main-actor
/// write per keystroke). The primary domain at search time is resolved
/// from the focused route, falling back to `fallbackPrimaryDomain`.
/// Ranking work happens off-MainActor inside `AppSearchIndex`.
///
/// Cmd-F focus is published through the shared focused-command dispatcher
/// instead of a hidden view-local Button. That keeps keyboard ownership in
/// app commands and avoids leaving an always-present opacity renderer in
/// the session window graph.
///
/// Suggestion-popover persistence: `.searchSuggestions` on macOS is
/// backed by `NSSearchField`'s suggestion menu, which dismisses when
/// the window resigns key/active state and does NOT auto-reopen when
/// the window regains it. There is no SwiftUI-only API to force
/// re-presentation of the menu (confirmed by Apple Developer Forums
/// thread #704767, which has no SwiftUI workaround). The fix uses
/// `AppSearchFieldRebinder` -
/// an `NSViewRepresentable` that finds the underlying
/// `NSSearchField` in the window hierarchy and calls
/// `beginSearchInteraction()` (the same AppKit API
/// `NSSearchToolbarItem` uses internally) on
/// `NSWindow.didBecomeKeyNotification` while the user still has a
/// query.
public struct AppSearchHostModifier: ViewModifier {
  let model: AppSearchModel
  let prompt: LocalizedStringKey
  let fallbackPrimaryDomain: AppSearchDomain
  let automation: AppSearchAutomationState?
  let routeAction: (AppSearchHit) -> Void

  @FocusedValue(\.harnessSessionRouteFocus)
  private var routeFocus: HarnessSessionRouteFocus?

  @State private var query: String = ""
  @State private var isSearchPresented: Bool = false
  @State private var searchFocusRequestID: UInt64 = 0
  @State private var searchFocusDispatcher = HarnessSidebarSearchFocusDispatcher()

  public init(
    model: AppSearchModel,
    prompt: LocalizedStringKey = "Search session",
    fallbackPrimaryDomain: AppSearchDomain = .timeline,
    automation: AppSearchAutomationState? = nil,
    routeAction: @escaping (AppSearchHit) -> Void = { _ in }
  ) {
    self.model = model
    self.prompt = prompt
    self.fallbackPrimaryDomain = fallbackPrimaryDomain
    self.automation = automation
    self.routeAction = routeAction
  }

  public func body(content: Content) -> some View {
    content
      .searchable(
        text: $query,
        placement: .toolbar,
        prompt: prompt
      )
      .harnessMinimizableSearchToolbar()
      .searchSuggestions {
        AppSearchSuggestionsHost(model: model, onPick: handleHit)
      }
      .task(
        id: AppSearchTrigger(
          query: query,
          primary: resolvedPrimaryDomain
        )
      ) {
        await runDebouncedSearch(for: query)
      }
      .background {
        AppSearchFieldRebinder(
          shouldRebind: !query.isEmpty && isSearchPresented,
          focusRequestID: searchFocusRequestID
        )
      }
      .task(id: isSearchPresented) {
        model.setPresented(isSearchPresented)
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
      .environment(\.appSearchModel, model)
  }

  private var searchFocusAction: HarnessSidebarSearchFocus {
    HarnessSidebarSearchFocus(
      isAvailable: true,
      menuLabel: .findInSession,
      dispatcher: searchFocusDispatcher
    )
  }

  private func focusSearchField() {
    if !isSearchPresented {
      isSearchPresented = true
    }
    searchFocusRequestID &+= 1
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
    if isSearchPresented {
      isSearchPresented = false
    }
  }

  private var resolvedPrimaryDomain: AppSearchDomain {
    routeFocus?.domain ?? fallbackPrimaryDomain
  }

  private func applyAutomationCommand(_ command: AppSearchAutomationCommand) async {
    if query != command.query {
      query = command.query
      await Task.yield()
    }
    guard !Task.isCancelled else { return }
    if command.isPresented {
      if isSearchPresented != command.isPresented {
        isSearchPresented = command.isPresented
        searchFocusRequestID &+= 1
      }
      return
    }
    if isSearchPresented != command.isPresented {
      isSearchPresented = command.isPresented
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
    await model.runSearch(query: liveQuery, primary: primary)
    appSearchSignposter.endInterval("app_search_query", state)
  }

}

private struct AppSearchSuggestionsHost: View {
  let model: AppSearchModel
  let onPick: (AppSearchHit) -> Void

  @Environment(\.accessibilityVoiceOverEnabled)
  private var voiceOverEnabled
  @State private var lastAnnouncedHitCount = -1

  var body: some View {
    if voiceOverEnabled {
      suggestions
        .onChange(of: model.results.totalHitCount) { _, newValue in
          announceResults(totalHitCount: newValue)
        }
    } else {
      suggestions
    }
  }

  private var suggestions: some View {
    AppSearchSuggestionsView(
      results: model.results,
      onPick: onPick
    )
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
    automation: AppSearchAutomationState? = nil,
    routeAction: @escaping (AppSearchHit) -> Void = { _ in }
  ) -> some View {
    modifier(
      AppSearchHostModifier(
        model: model,
        prompt: prompt,
        fallbackPrimaryDomain: fallbackPrimaryDomain,
        automation: automation,
        routeAction: routeAction
      )
    )
  }
}
