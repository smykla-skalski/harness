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

/// Toolbar-placed `.searchable` field that drives the cross-domain
/// ``AppSearchModel`` after a 150 ms debounce.
///
/// The modifier owns one `@State` for the live query (the only main-actor
/// write per keystroke) and resolves the primary domain at search time
/// from `@FocusedValue(\.harnessSessionRouteFocus)`. All ranking work
/// happens off-MainActor inside ``AppSearchIndex``.
///
/// The fallback domain (`fallbackPrimaryDomain`) is used when no route is
/// focused — typically when the session window is on the Overview or
/// Terminal routes that have no dedicated search corpus.
public struct AppSearchHostModifier: ViewModifier {
  let model: AppSearchModel
  let prompt: LocalizedStringKey
  let fallbackPrimaryDomain: AppSearchDomain

  @FocusedValue(\.harnessSessionRouteFocus)
  private var routeFocus: HarnessSessionRouteFocus?

  @State private var query: String = ""

  public init(
    model: AppSearchModel,
    prompt: LocalizedStringKey = "Search session",
    fallbackPrimaryDomain: AppSearchDomain = .timeline
  ) {
    self.model = model
    self.prompt = prompt
    self.fallbackPrimaryDomain = fallbackPrimaryDomain
  }

  public func body(content: Content) -> some View {
    content
      .searchable(
        text: $query,
        placement: .toolbar,
        prompt: prompt
      )
      .task(id: query) {
        await runDebouncedSearch(for: query)
      }
      .environment(\.appSearchModel, model)
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
    let primary = routeFocus?.domain ?? fallbackPrimaryDomain
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

extension View {
  /// Attach the unified session-window search to a view's body.
  public func appSearchHost(
    model: AppSearchModel,
    prompt: LocalizedStringKey = "Search session",
    fallbackPrimaryDomain: AppSearchDomain = .timeline
  ) -> some View {
    modifier(
      AppSearchHostModifier(
        model: model,
        prompt: prompt,
        fallbackPrimaryDomain: fallbackPrimaryDomain
      )
    )
  }
}
