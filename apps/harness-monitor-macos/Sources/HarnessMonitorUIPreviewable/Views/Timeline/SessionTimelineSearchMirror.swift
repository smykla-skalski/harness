import HarnessMonitorKit
import SwiftUI

struct SessionTimelineSearchMirrorTrigger: Equatable {
  let isEnabled: Bool
  let query: String
}

enum SessionTimelineSearchMirrorPolicy {
  static func trigger(
    isEnabled: Bool,
    appSearchQuery: String
  ) -> SessionTimelineSearchMirrorTrigger {
    SessionTimelineSearchMirrorTrigger(
      isEnabled: isEnabled,
      query: isEnabled ? appSearchQuery : ""
    )
  }

  static func filterQueryUpdate(
    from oldTrigger: SessionTimelineSearchMirrorTrigger,
    to newTrigger: SessionTimelineSearchMirrorTrigger
  ) -> String? {
    if newTrigger.isEnabled {
      return newTrigger.query
    }
    guard oldTrigger.isEnabled, !oldTrigger.query.isEmpty else {
      return nil
    }
    return ""
  }
}

/// Mirrors the unified ``AppSearchModel/query`` (post-debounce) into the
/// timeline filter's free-text query so the existing matching pipeline
/// keeps narrowing entries from a single source of truth only while the
/// timeline route owns that filter. Cockpit timelines are summary surfaces;
/// mirroring agent/task/decision searches into them needlessly rebuilds the
/// timeline presentation during every global-search step.
struct SessionTimelineSearchMirror: ViewModifier {
  @Binding var filterQuery: String
  let isEnabled: Bool

  @Environment(\.appSearchModel)
  private var appSearchModel: AppSearchModel?

  private var trigger: SessionTimelineSearchMirrorTrigger {
    SessionTimelineSearchMirrorPolicy.trigger(
      isEnabled: isEnabled,
      appSearchQuery: appSearchModel?.query ?? ""
    )
  }

  func body(content: Content) -> some View {
    content
      .onChange(of: trigger, initial: true) { oldTrigger, newTrigger in
        guard
          let query = SessionTimelineSearchMirrorPolicy.filterQueryUpdate(
            from: oldTrigger,
            to: newTrigger
          )
        else {
          return
        }
        guard filterQuery != query else { return }
        filterQuery = query
      }
  }
}
