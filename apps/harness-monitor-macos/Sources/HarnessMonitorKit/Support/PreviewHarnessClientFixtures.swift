import Foundation

extension PreviewHarnessClient {
  public struct Fixtures: Sendable {
    let health: HealthResponse
    let projects: [ProjectSummary]
    let sessions: [SessionSummary]
    let detail: SessionDetail?
    let timeline: [TimelineEntry]
    let readySessionID: String?
    let detailsBySessionID: [String: SessionDetail]
    let coreDetailsBySessionID: [String: SessionDetail]
    let timelinesBySessionID: [String: [TimelineEntry]]
    let agentTuisBySessionID: [String: [AgentTuiSnapshot]]
    let codexRunsBySessionID: [String: [CodexRunSnapshot]]

    public init(
      health: HealthResponse,
      projects: [ProjectSummary],
      sessions: [SessionSummary],
      detail: SessionDetail?,
      timeline: [TimelineEntry],
      readySessionID: String?,
      detailsBySessionID: [String: SessionDetail],
      coreDetailsBySessionID: [String: SessionDetail],
      timelinesBySessionID: [String: [TimelineEntry]],
      agentTuisBySessionID: [String: [AgentTuiSnapshot]] = [:],
      codexRunsBySessionID: [String: [CodexRunSnapshot]] = [:]
    ) {
      self.health = health
      self.projects = projects
      self.sessions = sessions
      self.detail = detail
      self.timeline = timeline
      self.readySessionID = readySessionID
      self.detailsBySessionID = detailsBySessionID
      self.coreDetailsBySessionID = coreDetailsBySessionID
      self.timelinesBySessionID = timelinesBySessionID
      self.agentTuisBySessionID = agentTuisBySessionID
      self.codexRunsBySessionID = codexRunsBySessionID
    }

    public static let populated = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.projects,
      sessions: [PreviewFixtures.summary],
      detail: PreviewFixtures.detail,
      timeline: PreviewFixtures.timeline,
      readySessionID: PreviewFixtures.summary.sessionId,
      detailsBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )

    public static let taskDrop = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.projects,
      sessions: [PreviewFixtures.taskDropSummary],
      detail: PreviewFixtures.taskDropDetail,
      timeline: PreviewFixtures.timeline,
      readySessionID: PreviewFixtures.summary.sessionId,
      detailsBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.taskDropDetail],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )

    public static let dashboardLanding = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.projects,
      sessions: [PreviewFixtures.summary],
      detail: PreviewFixtures.detail,
      timeline: PreviewFixtures.timeline,
      readySessionID: nil,
      detailsBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )

    public static let singleAgent = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.singleAgentProjects,
      sessions: PreviewFixtures.singleAgentSessions,
      detail: PreviewFixtures.singleAgentDetail,
      timeline: [],
      readySessionID: PreviewFixtures.singleAgentSummary.sessionId,
      detailsBySessionID: [
        PreviewFixtures.singleAgentSummary.sessionId: PreviewFixtures.singleAgentDetail
      ],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [:]
    )

    public static let empty = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 0,
        sessionCount: 0
      ),
      projects: [],
      sessions: [],
      detail: nil,
      timeline: [],
      readySessionID: nil,
      detailsBySessionID: [:],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [:]
    )

    func detail(for sessionID: String, scope: String?) -> SessionDetail? {
      if scope == "core", let coreDetail = coreDetailsBySessionID[sessionID] {
        return coreDetail
      }

      if let scopedDetail = detailsBySessionID[sessionID] {
        return scopedDetail
      }

      return detail
    }

    func timeline(for sessionID: String) -> [TimelineEntry] {
      timelinesBySessionID[sessionID] ?? timeline
    }
  }
}
