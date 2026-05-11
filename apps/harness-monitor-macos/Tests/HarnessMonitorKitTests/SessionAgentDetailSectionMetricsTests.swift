import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Session agent detail metrics")
struct SessionAgentDetailSectionMetricsTests {
  @Test("Metrics scale TUI and composer chrome")
  func metricsScaleTUIAndComposerChrome() {
    let regular = SessionAgentDetailSectionMetrics(fontScale: 1.0)
    let large = SessionAgentDetailSectionMetrics(fontScale: 1.8)

    #expect(large.sectionSpacing > regular.sectionSpacing)
    #expect(large.sectionPadding > regular.sectionPadding)
    #expect(large.terminalPadding > regular.terminalPadding)
    #expect(large.composerSpacing > regular.composerSpacing)
    #expect(large.keyButtonWidth > regular.keyButtonWidth)
    #expect(large.composerMinHeight > regular.composerMinHeight)
    #expect(large.controlButtonMinSize == 44)
  }

  @Test("Metrics clamp extreme font scales")
  func metricsClampExtremeFontScales() {
    #expect(
      SessionAgentDetailSectionMetrics(fontScale: 0.1)
        == SessionAgentDetailSectionMetrics(fontScale: 0.85)
    )
    #expect(
      SessionAgentDetailSectionMetrics(fontScale: 9.0)
        == SessionAgentDetailSectionMetrics(fontScale: 1.8)
    )
  }

  @Test("Composer key layout covers every TUI key once")
  func composerKeyLayoutCoversEveryTUIKeyOnce() {
    #expect(Set(SessionAgentComposerKeyLayout.flattened) == Set(AgentTuiKey.allCases))
    #expect(SessionAgentComposerKeyLayout.flattened.count == AgentTuiKey.allCases.count)
  }

  @Test("Output announcement gate suppresses empty and throttled updates")
  func outputAnnouncementGateSuppressesEmptyAndThrottledUpdates() {
    var gate = SessionAgentOutputAnnouncementGate()
    let start = Date(timeIntervalSinceReferenceDate: 100)

    let emptyAllowed = gate.shouldAnnounce(output: "   ", now: start)
    let firstAllowed = gate.shouldAnnounce(output: "Ready", now: start)
    let throttledAllowed = gate.shouldAnnounce(
      output: "Still ready",
      now: start.addingTimeInterval(SessionAgentOutputAnnouncementGate.minimumInterval - 0.001)
    )
    let nextAllowed = gate.shouldAnnounce(
      output: "Done",
      now: start.addingTimeInterval(SessionAgentOutputAnnouncementGate.minimumInterval + 0.001)
    )

    #expect(!emptyAllowed)
    #expect(firstAllowed)
    #expect(!throttledAllowed)
    #expect(nextAllowed)
  }

  @Test("Composer focus policy only promotes active keyboard requests")
  func composerFocusPolicyOnlyPromotesActiveKeyboardRequests() {
    #expect(
      !SessionAgentComposerFocusPolicy.shouldPromoteComposerFocus(
        requestID: 0,
        isTuiActive: true
      )
    )
    #expect(
      !SessionAgentComposerFocusPolicy.shouldPromoteComposerFocus(
        requestID: 1,
        isTuiActive: false
      )
    )
    #expect(
      SessionAgentComposerFocusPolicy.shouldPromoteComposerFocus(
        requestID: 1,
        isTuiActive: true
      )
    )
  }

  @Test("Agent detail is split into viewport and composer views")
  func agentDetailIsSplitIntoViewportAndComposerViews() throws {
    let detailSource = try sourceFile(named: "SessionAgentDetailSection.swift")
    let laneSource = try sourceFile(named: "SessionAgentLaneViews.swift")
    let composerSource = try sourceFile(named: "SessionAgentComposer.swift")

    #expect(detailSource.contains("AgentDetailSummaryBand("))
    #expect(detailSource.contains("AgentDetailActivityBand("))
    #expect(detailSource.contains("AgentDetailActionBand("))
    #expect(detailSource.contains("AgentDetailAwaitingDecisionRegion("))
    #expect(detailSource.contains("SessionAgentTuiViewport("))
    #expect(detailSource.contains("SessionAgentComposer("))
    #expect(detailSource.contains("@Environment(\\.accessibilityVoiceOverEnabled)"))
    #expect(detailSource.contains("await Task.yield()"))
    #expect(laneSource.contains("accessibilityLabel(Text(latestOutput))"))
    #expect(composerSource.contains("GeometryReader"))
    #expect(composerSource.contains("SessionAgentComposerKeyLayout.rows"))
  }

  @Test("Session transcript helper prefers ACP transcript when available")
  func sessionTranscriptHelperPrefersAcpTranscriptWhenAvailable() {
    let nativeAgent = makeAgent(
      agentID: "agent-native",
      supportsNativeTranscript: true
    )
    let ledgerAgent = makeAgent(
      agentID: "agent-ledger",
      supportsNativeTranscript: false
    )
    let timeline = [
      makeTimelineEntry(entryID: "timeline-native", agentID: "agent-native"),
      makeTimelineEntry(entryID: "timeline-ledger", agentID: "agent-ledger"),
    ]
    let nativeTimeline = [timeline[0]]
    let ledgerTimeline = [timeline[1]]
    let acpTranscript = [makeTimelineEntry(entryID: "acp-native", agentID: "agent-native")]

    #expect(
      SessionAgentDetailSection.transcriptEntries(
        agent: nativeAgent,
        agentTimeline: nativeTimeline,
        acpTranscript: acpTranscript
      ).map(\.entryId) == ["acp-native"]
    )
    #expect(
      SessionAgentDetailSection.transcriptEntries(
        agent: ledgerAgent,
        agentTimeline: ledgerTimeline,
        acpTranscript: acpTranscript
      ).map(\.entryId) == ["timeline-ledger"]
    )
  }

  @Test("Session transcript helper falls back to timeline until ACP transcript arrives")
  func sessionTranscriptHelperFallsBackToTimelineUntilAcpTranscriptArrives() {
    let nativeAgent = makeAgent(
      agentID: "agent-native",
      supportsNativeTranscript: true
    )
    let nativeTimeline = [makeTimelineEntry(entryID: "timeline-native", agentID: "agent-native")]

    #expect(
      SessionAgentDetailSection.transcriptEntries(
        agent: nativeAgent,
        agentTimeline: nativeTimeline,
        acpTranscript: []
      ).map(\.entryId) == ["timeline-native"]
    )
  }

  @Test("Session action actor helper stays within the session agent roster")
  func sessionActionActorHelperStaysWithinSessionRoster() {
    let leader = makeAgent(agentID: "leader-1")
    let worker = makeAgent(agentID: "worker-1")
    let idle = makeAgent(agentID: "idle-1", status: .idle)
    let agents = [leader, worker, idle]

    #expect(
      SessionAgentDetailSection.resolvedActionActorID(
        preferredActorID: "worker-1",
        agents: agents,
        leaderID: "leader-1"
      ) == "worker-1"
    )
    #expect(
      SessionAgentDetailSection.resolvedActionActorID(
        preferredActorID: "missing",
        agents: agents,
        leaderID: "leader-1"
      ) == "leader-1"
    )
    #expect(
      SessionAgentDetailSection.resolvedActionActorID(
        preferredActorID: nil,
        agents: [idle],
        leaderID: nil
      ) == nil
    )
    #expect(
      SessionAgentDetailSection.hasRealLeader(
        leaderID: "leader-1",
        agents: agents
      )
    )
    #expect(
      !SessionAgentDetailSection.hasRealLeader(
        leaderID: "missing",
        agents: agents
      )
    )
  }

  private func sourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Sessions"
      )
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func makeAgent(
    agentID: String,
    supportsNativeTranscript: Bool = true,
    status: AgentStatus = .active
  ) -> AgentRegistration {
    AgentRegistration(
      agentId: agentID,
      name: agentID,
      runtime: "codex",
      role: .worker,
      capabilities: [],
      joinedAt: "2026-05-10T09:00:00Z",
      updatedAt: "2026-05-10T09:00:00Z",
      status: status,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "codex",
        supportsNativeTranscript: supportsNativeTranscript,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 1,
        hookPoints: []
      ),
      persona: nil
    )
  }

  private func makeTimelineEntry(
    entryID: String,
    agentID: String
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: entryID,
      recordedAt: "2026-05-10T09:00:00Z",
      kind: "agent.message",
      sessionId: "sess-session-agent-detail",
      agentId: agentID,
      taskId: nil,
      summary: entryID,
      payload: .object([:])
    )
  }
}
