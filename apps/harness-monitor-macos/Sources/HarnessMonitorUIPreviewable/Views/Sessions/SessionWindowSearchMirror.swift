import HarnessMonitorKit
import SwiftUI

/// Mirrors the unified ``AppSearchModel/query`` (post-debounce) into the
/// session decisions filter so the existing decisions-cache pipeline keeps
/// receiving its query from a single source of truth. The legacy decisions
/// sidebar search field is removed in a later chunk; until then both
/// surfaces can write the field, with the toolbar mirror taking precedence
/// once the user types into it.
struct SessionWindowSearchMirror: ViewModifier {
  let stateCache: SessionWindowStateCache

  func body(content: Content) -> some View {
    content.onChange(of: stateCache.appSearchModel.query) { _, newValue in
      guard stateCache.decisionFilters.query != newValue else { return }
      stateCache.decisionFilters.query = newValue
    }
  }
}
