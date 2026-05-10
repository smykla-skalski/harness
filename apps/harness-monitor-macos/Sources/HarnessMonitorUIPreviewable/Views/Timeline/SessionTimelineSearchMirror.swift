import HarnessMonitorKit
import SwiftUI

/// Mirrors the unified ``AppSearchModel/query`` (post-debounce) into the
/// timeline filter's free-text query so the existing matching pipeline
/// keeps narrowing entries from a single source of truth. The legacy
/// timeline search field is removed in a later chunk; until then the
/// mirror coexists with it.
struct SessionTimelineSearchMirror: ViewModifier {
  @Binding var filterQuery: String

  @Environment(\.appSearchModel)
  private var appSearchModel: AppSearchModel?

  func body(content: Content) -> some View {
    content
      .task(id: appSearchModel?.query ?? "") {
        guard let model = appSearchModel else { return }
        guard filterQuery != model.query else { return }
        filterQuery = model.query
      }
  }
}
