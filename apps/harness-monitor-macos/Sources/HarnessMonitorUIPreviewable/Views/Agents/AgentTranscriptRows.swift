import HarnessMonitorKit
import SwiftUI

// Lightweight transcript view for the agent detail pane. Skips the cockpit's
// filter controls, window navigation, viewport tracking, scroll-boundary
// loader, and AppStorage/SceneStorage filter persistence; renders the inner
// row cluster directly. Used in place of MonitorTimelineSection when the
// surface only needs "stream the recent transcript for this agent" without
// the cockpit's load-profile defenses.
struct AgentTranscriptRows: View {
  static let maximumPresentedEntries = 24

  let agentID: String
  let timeline: [TimelineEntry]
  let store: HarnessMonitorStore

  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  // The detail pane only shows a short transcript excerpt; capping here avoids
  // rebuilding the full timeline graph on every agent switch.
  static func recentTimelineEntries(from timeline: [TimelineEntry]) -> [TimelineEntry] {
    Array(timeline.suffix(Self.maximumPresentedEntries))
  }

  private var recentTimeline: [TimelineEntry] {
    Self.recentTimelineEntries(from: timeline)
  }

  private var presentation: SessionTimelineSectionPresentation {
    SessionTimelineSectionPresentation(
      sessionID: "agent:\(agentID)",
      timeline: recentTimeline,
      timelineWindow: nil,
      decisions: [],
      signals: [],
      filters: SessionTimelineFilterState(),
      isTimelineLoading: false,
      reduceMotion: reduceMotion,
      textSizeIndex: textSizeIndex,
      dateTimeConfiguration: dateTimeConfiguration
    )
  }

  var body: some View {
    let presentation = self.presentation
    if presentation.showsEmptyState {
      AgentDetailEmptyState(
        title: "No transcript yet",
        systemImage: "text.line.first.and.arrowtriangle.forward",
        description: "Send an update below to start the conversation.",
        tint: HarnessMonitorTheme.secondaryInk
      )
    } else {
      SessionTimelineCards(
        rows: presentation.rows,
        placeholderCount: 0,
        shimmerPhase: 0,
        showsShimmer: false,
        actionHandler: store.supervisorDecisionActionHandler(),
        onSignalTap: nil
      )
      .padding(HarnessMonitorTheme.spacingSM)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
