import HarnessMonitorKit
import SwiftUI

struct SessionTimelinePlaceholderScrollView: View {
  let presentation: SessionTimelineSectionPresentation
  let actionHandler: any DecisionActionHandler
  let contentIdentity: SessionTimelineContentIdentity

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        SessionTimelineCards(
          rows: [],
          placeholderCount: presentation.placeholderCount,
          shimmerPhase: SessionTimelinePlaceholderShimmer.restingPhase,
          showsShimmer: presentation.shouldAnimatePlaceholders,
          actionHandler: actionHandler
        )
      }
      .id(contentIdentity)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.visible)
    .scrollBounceBehavior(.always, axes: .vertical)
    .scrollClipDisabled(false)
  }
}
