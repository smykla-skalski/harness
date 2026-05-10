import HarnessMonitorKit
import SwiftUI

struct SessionTimelinePlaceholderScrollView: View {
  let presentation: SessionTimelineSectionPresentation
  let actionHandler: any DecisionActionHandler
  let contentIdentity: SessionTimelineContentIdentity
  let horizontalContentInset: CGFloat

  init(
    presentation: SessionTimelineSectionPresentation,
    actionHandler: any DecisionActionHandler,
    contentIdentity: SessionTimelineContentIdentity,
    horizontalContentInset: CGFloat = 0
  ) {
    self.presentation = presentation
    self.actionHandler = actionHandler
    self.contentIdentity = contentIdentity
    self.horizontalContentInset = horizontalContentInset
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        SessionTimelineCards(
          rows: [],
          placeholderCount: presentation.placeholderCount,
          shimmerPhase: SessionTimelinePlaceholderShimmer.restingPhase,
          showsShimmer: presentation.shouldAnimatePlaceholders,
          actionHandler: actionHandler,
          onSignalTap: nil
        )
      }
      .id(contentIdentity)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentMargins(.horizontal, horizontalContentInset, for: .scrollContent)
    .scrollIndicators(.visible)
    .scrollBounceBehavior(.always, axes: .vertical)
    .scrollClipDisabled(false)
  }
}
