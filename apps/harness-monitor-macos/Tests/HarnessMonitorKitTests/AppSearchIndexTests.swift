import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("AppSearchIndex contract")
struct AppSearchIndexTests {

  // MARK: Empty / trimming behaviour

  @Test("Empty query returns no sections")
  func emptyQueryReturnsNoSections() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [makeAgent(id: "a1", name: "Codex Lead")])
    let results = await index.search(query: "", primary: .agents)
    #expect(results.sections.isEmpty)
    #expect(results.query.isEmpty)
  }

  @Test("Whitespace-only query is trimmed to empty")
  func whitespaceOnlyQueryIsTrimmedToEmpty() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [makeAgent(id: "a1", name: "Codex Lead")])
    let results = await index.search(query: "   \n\t  ", primary: .agents)
    #expect(results.sections.isEmpty)
  }

  @Test("Trimmed query is reported back unchanged")
  func trimmedQueryIsReportedBack() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [makeAgent(id: "a1", name: "Codex Lead")])
    let results = await index.search(query: "  codex  ", primary: .agents)
    #expect(results.query == "codex")
  }

  // MARK: Match semantics

  @Test("Substring match is case-insensitive")
  func substringMatchIsCaseInsensitive() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [
      makeAgent(id: "a1", name: "CODEX Lead"),
      makeAgent(id: "a2", name: "Claude Worker"),
    ])
    let results = await index.search(query: "codex", primary: .agents)
    #expect(results.totalHitCount == 1)
    #expect(results.sections.first?.hits.first?.id == "a1")
  }

  @Test("Title match outranks corpus-only match")
  func titleMatchOutranksCorpusOnly() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [
      // Title does not contain "linux"; corpus does (via persona description).
      makeAgent(id: "corpus-only", name: "Worker", personaDescription: "linux operator"),
      // Title does contain "linux".
      makeAgent(id: "title-match", name: "Linux Lead"),
    ])
    let results = await index.search(query: "linux", primary: .agents)
    let hits = results.sections.first?.hits ?? []
    #expect(hits.count == 2)
    #expect(hits.first?.id == "title-match")
  }

  @Test("No match means no hit")
  func noMatchMeansNoHit() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [makeAgent(id: "a1", name: "Codex Lead")])
    let results = await index.search(query: "nothingmatchesthis", primary: .agents)
    #expect(results.sections.isEmpty)
  }

  // MARK: Section ordering

  @Test("Primary domain section appears first")
  func primaryDomainSectionFirst() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [makeAgent(id: "a1", name: "alpha agent")])
    await index.reindex(decisions: [makeDecisionProjection(id: "d1", summary: "alpha decision")])
    await index.reindex(tasks: [makeTask(id: "t1", title: "alpha task")])
    await index.reindex(events: [makeEvent(id: "e1", summary: "alpha event")])
    let results = await index.search(query: "alpha", primary: .decisions)
    #expect(results.sections.first?.domain == .decisions)
  }

  @Test("Empty sections are omitted")
  func emptySectionsOmitted() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [makeAgent(id: "a1", name: "alpha agent")])
    await index.reindex(decisions: [makeDecisionProjection(id: "d1", summary: "beta decision")])
    let results = await index.search(query: "alpha", primary: .decisions)
    // Only agents matched; decisions section must be absent.
    #expect(results.sections.count == 1)
    #expect(results.sections.first?.domain == .agents)
  }

  @Test("With nil primary, fallback domain order ranks tasks > agents > timeline > decisions")
  func nilPrimaryGivesFallbackOrder() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [makeAgent(id: "a1", name: "alpha agent")])
    await index.reindex(decisions: [makeDecisionProjection(id: "d1", summary: "alpha decision")])
    await index.reindex(tasks: [makeTask(id: "t1", title: "alpha task")])
    await index.reindex(events: [makeEvent(id: "e1", summary: "alpha event")])
    let results = await index.search(query: "alpha", primary: nil)
    let domains = results.sections.map(\.domain)
    #expect(domains == [.tasks, .agents, .timeline, .decisions])
  }

  @Test("Primary domain leads, remaining domains follow fallback order")
  func primaryLeadsThenFallbackOrder() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [makeAgent(id: "a1", name: "alpha agent")])
    await index.reindex(decisions: [makeDecisionProjection(id: "d1", summary: "alpha decision")])
    await index.reindex(tasks: [makeTask(id: "t1", title: "alpha task")])
    await index.reindex(events: [makeEvent(id: "e1", summary: "alpha event")])
    let timelinePrimary = await index.search(query: "alpha", primary: .timeline)
    #expect(
      timelinePrimary.sections.map(\.domain) == [.timeline, .tasks, .agents, .decisions]
    )
    let agentsPrimary = await index.search(query: "alpha", primary: .agents)
    #expect(
      agentsPrimary.sections.map(\.domain) == [.agents, .tasks, .timeline, .decisions]
    )
    let decisionsPrimary = await index.search(query: "alpha", primary: .decisions)
    #expect(
      decisionsPrimary.sections.map(\.domain) == [.decisions, .tasks, .agents, .timeline]
    )
  }

  // MARK: Top-K cap

  @Test("Primary domain uses larger cap and flags truncation")
  func primaryDomainUsesPrimaryCap() async {
    let index = AppSearchIndex()
    let many = (0..<25).map { makeAgent(id: "a\($0)", name: "alpha \($0)") }
    await index.reindex(agents: many)
    let results = await index.search(
      query: "alpha",
      primary: .agents,
      primaryK: 15,
      fallbackK: 5
    )
    let section = results.sections.first
    #expect(section?.hits.count == 15)
    #expect(section?.truncated == true)
  }

  @Test("Non-primary domain uses fallback cap")
  func nonPrimaryDomainUsesFallbackCap() async {
    let index = AppSearchIndex()
    let many = (0..<25).map { makeAgent(id: "a\($0)", name: "alpha \($0)") }
    await index.reindex(agents: many)
    let results = await index.search(
      query: "alpha",
      primary: .timeline,
      primaryK: 15,
      fallbackK: 5
    )
    let agentsSection = results.sections.first { $0.domain == .agents }
    #expect(agentsSection?.hits.count == 5)
    #expect(agentsSection?.truncated == true)
  }

  @Test("Below-cap results are not flagged as truncated")
  func belowCapNotTruncated() async {
    let index = AppSearchIndex()
    await index.reindex(agents: (0..<3).map { makeAgent(id: "a\($0)", name: "alpha \($0)") })
    let results = await index.search(query: "alpha", primary: .agents)
    #expect(results.sections.first?.truncated == false)
  }

  @Test("Default caps keep toolbar suggestions compact across domains")
  func defaultCapsKeepToolbarSuggestionsCompact() async {
    let index = AppSearchIndex()
    let agents = (0..<25).map {
      makeAgent(id: "a\($0)", name: "alpha agent \($0)")
    }
    let decisions = (0..<25).map {
      makeDecisionProjection(id: "d\($0)", summary: "alpha decision \($0)")
    }
    let tasks = (0..<25).map {
      makeTask(id: "t\($0)", title: "alpha task \($0)")
    }
    let events = (0..<25).map {
      makeEvent(id: "e\($0)", summary: "alpha event \($0)")
    }
    await index.reindex(agents: agents)
    await index.reindex(decisions: decisions)
    await index.reindex(tasks: tasks)
    await index.reindex(events: events)

    let results = await index.search(query: "alpha", primary: .agents)
    let agentHitCount = results.sections.first { $0.domain == .agents }?.hits.count
    let taskHitCount = results.sections.first { $0.domain == .tasks }?.hits.count
    let timelineHitCount = results.sections.first { $0.domain == .timeline }?.hits.count
    let decisionHitCount = results.sections.first { $0.domain == .decisions }?.hits.count
    let allTruncated = results.sections.allSatisfy(\.truncated)

    #expect(results.totalHitCount == 8)
    #expect(agentHitCount == 5)
    #expect(taskHitCount == 1)
    #expect(timelineHitCount == 1)
    #expect(decisionHitCount == 1)
    #expect(allTruncated)
  }

  // MARK: Reindex behaviour

  @Test("Reindex replaces the previous corpus")
  func reindexReplacesPreviousCorpus() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [makeAgent(id: "old", name: "alpha")])
    await index.reindex(agents: [makeAgent(id: "new", name: "alpha new")])
    let results = await index.search(query: "alpha", primary: .agents)
    let ids = results.sections.first?.hits.map(\.id) ?? []
    #expect(ids == ["new"])
  }

  @Test("Hit carries the domain's system image")
  func hitCarriesDomainSystemImage() async {
    let index = AppSearchIndex()
    await index.reindex(decisions: [makeDecisionProjection(id: "d1", summary: "alpha")])
    let results = await index.search(query: "alpha", primary: .decisions)
    let hit = results.sections.first?.hits.first
    #expect(hit?.systemImage == AppSearchDomain.decisions.systemImage)
  }

  // MARK: Cross-domain hit count totals

  @Test("Total hit count sums across sections")
  func totalHitCountSumsAcrossSections() async {
    let index = AppSearchIndex()
    await index.reindex(agents: [makeAgent(id: "a1", name: "alpha agent")])
    await index.reindex(decisions: [
      makeDecisionProjection(id: "d1", summary: "alpha decision one"),
      makeDecisionProjection(id: "d2", summary: "alpha decision two"),
    ])
    let results = await index.search(query: "alpha", primary: nil)
    #expect(results.totalHitCount == 3)
    #expect(results.isEmpty == false)
  }
}

// MARK: - Fixtures

private func makeAgent(
  id: String,
  name: String,
  personaDescription: String? = nil
) -> AgentRegistration {
  let persona: AgentPersona? = personaDescription.map { description in
    AgentPersona(
      identifier: "\(id)-persona",
      name: "\(id)-persona-name",
      symbol: .sfSymbol(name: "person.fill"),
      description: description
    )
  }
  return AgentRegistration(
    agentId: id,
    name: name,
    runtime: "claude",
    role: .leader,
    capabilities: [],
    joinedAt: "2026-05-10T00:00:00Z",
    updatedAt: "2026-05-10T00:00:00Z",
    status: .active,
    agentSessionId: "\(id)-session",
    lastActivityAt: nil,
    currentTaskId: nil,
    runtimeCapabilities: makeCapabilities(),
    persona: persona
  )
}

private func makeCapabilities() -> RuntimeCapabilities {
  RuntimeCapabilities(
    runtime: "claude",
    supportsNativeTranscript: true,
    supportsSignalDelivery: true,
    supportsContextInjection: true,
    typicalSignalLatencySeconds: 5,
    hookPoints: []
  )
}

private func makeDecisionProjection(
  id: String,
  summary: String,
  ruleID: String = "rule.test"
) -> DecisionSearchProjection {
  DecisionSearchProjection(
    id: id,
    summary: summary,
    ruleID: ruleID,
    agentID: nil,
    taskID: nil
  )
}

private func makeTask(id: String, title: String) -> WorkItem {
  WorkItem(
    taskId: id,
    title: title,
    context: nil,
    severity: .medium,
    status: .open,
    assignedTo: nil,
    createdAt: "2026-05-10T00:00:00Z",
    updatedAt: "2026-05-10T00:00:00Z",
    createdBy: nil,
    notes: [],
    suggestedFix: nil,
    source: .manual,
    blockedReason: nil,
    completedAt: nil,
    checkpointSummary: nil
  )
}

private func makeEvent(id: String, summary: String) -> TimelineEntry {
  TimelineEntry(
    entryId: id,
    recordedAt: "2026-05-10T00:00:00Z",
    kind: "test_event",
    sessionId: "sess-1",
    agentId: nil,
    taskId: nil,
    summary: summary,
    payload: .object([:])
  )
}
