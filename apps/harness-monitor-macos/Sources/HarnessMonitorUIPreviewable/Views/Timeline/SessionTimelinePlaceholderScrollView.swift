import HarnessMonitorKit
import SwiftUI

struct SessionTimelinePlaceholderScrollView: View {
  let presentation: SessionTimelineSectionPresentation
  let actionHandler: any DecisionActionHandler
  let contentIdentity: SessionTimelineContentIdentity
  let horizontalContentInset: CGFloat
  let showsScrollEdgeEffects: Bool

  init(
    presentation: SessionTimelineSectionPresentation,
    actionHandler: any DecisionActionHandler,
    contentIdentity: SessionTimelineContentIdentity,
    horizontalContentInset: CGFloat = 0,
    showsScrollEdgeEffects: Bool = false
  ) {
    self.presentation = presentation
    self.actionHandler = actionHandler
    self.contentIdentity = contentIdentity
    self.horizontalContentInset = horizontalContentInset
    self.showsScrollEdgeEffects = showsScrollEdgeEffects
  }

  var body: some View {
    let scrollView = ScrollView {
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

    if showsScrollEdgeEffects {
      scrollView
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    } else {
      scrollView
    }
  }
}
