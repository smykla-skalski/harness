import HarnessMonitorKit
import SwiftUI

struct SessionWindowSearchMirrorTrigger: Equatable {
  let shouldMirrorDecisionQuery: Bool
  let query: String
}

enum SessionWindowSearchMirrorPolicy {
  static func trigger(
    renderedRoute: SessionWindowRoute,
    appSearchQuery: String
  ) -> SessionWindowSearchMirrorTrigger {
    let shouldMirrorDecisionQuery = renderedRoute == .decisions
    return SessionWindowSearchMirrorTrigger(
      shouldMirrorDecisionQuery: shouldMirrorDecisionQuery,
      query: shouldMirrorDecisionQuery ? appSearchQuery : ""
    )
  }

  static func decisionQueryUpdate(
    from oldTrigger: SessionWindowSearchMirrorTrigger,
    to newTrigger: SessionWindowSearchMirrorTrigger
  ) -> String? {
    if newTrigger.shouldMirrorDecisionQuery {
      guard !newTrigger.query.isEmpty || oldTrigger.shouldMirrorDecisionQuery else {
        return nil
      }
      return newTrigger.query
    }
    guard oldTrigger.shouldMirrorDecisionQuery, !oldTrigger.query.isEmpty else {
      return nil
    }
    return ""
  }
}

/// Mirrors the unified ``AppSearchModel/query`` (post-debounce) into the
/// session decisions filter only while the rendered route consumes decision
/// filtering. Agent/task route searches use the app-search model directly and
/// must not invalidate the decisions cache on every query change.
struct SessionWindowSearchMirror: ViewModifier {
  let stateCache: SessionWindowStateCache
  let renderedRoute: SessionWindowRoute

  private var trigger: SessionWindowSearchMirrorTrigger {
    let appSearchQuery = renderedRoute == .decisions ? stateCache.appSearchModel.query : ""
    return SessionWindowSearchMirrorPolicy.trigger(
      renderedRoute: renderedRoute,
      appSearchQuery: appSearchQuery
    )
  }

  func body(content: Content) -> some View {
    content.onChange(of: trigger) { oldTrigger, newTrigger in
      guard
        let decisionQuery = SessionWindowSearchMirrorPolicy.decisionQueryUpdate(
          from: oldTrigger,
          to: newTrigger
        )
      else {
        return
      }
      guard stateCache.decisionFilters.query != decisionQuery else { return }
      stateCache.decisionFilters.query = decisionQuery
    }
  }
}
