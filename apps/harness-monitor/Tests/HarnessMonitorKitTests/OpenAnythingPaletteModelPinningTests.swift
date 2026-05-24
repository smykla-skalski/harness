import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("OpenAnything palette model pinning")
@MainActor
struct OpenAnythingPaletteModelPinningTests {
  @Test("recordExecution promotes the record in recency")
  func executionPromotes() async {
    let model = Self.makeModel()
    model.recordExecution(of: "session.alpha")
    #expect(model.recency.entries.first?.recordID == "session.alpha")
    #expect(model.lastDismissReason == .hitExecuted(recordID: "session.alpha"))
  }

  @Test("togglePin flips state and reports the result")
  func togglePinFlips() async {
    let model = Self.makeModel()
    let onAfterFirst = model.togglePin("a")
    let onAfterSecond = model.togglePin("a")

    #expect(onAfterFirst == true)
    #expect(onAfterSecond == false)
    #expect(model.pins.recordIDs.isEmpty)
  }

  @Test("togglePin reports capacity refusals")
  func togglePinReportsCapacityRefusals() async {
    let model = Self.makeModel()
    for index in 0..<OpenAnythingPinStore.capacity {
      #expect(model.togglePin("id-\(index)"))
    }

    #expect(model.togglePin("over-the-limit") == false)
    #expect(model.pins.isPinned("over-the-limit") == false)
    #expect(model.pins.recordIDs.count == OpenAnythingPinStore.capacity)
  }

  @Test("togglePin refreshes suggested results while presented")
  func togglePinRefreshesPresentedSuggestions() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.multiSectionSuggestedRecords)
    model.present(targetWindowID: nil)

    #expect(model.displayedResults.sections.first?.id == OpenAnythingDomain.actions.rawValue)
    #expect(model.togglePin("session.alpha"))
    #expect(model.displayedResults.sections.first?.id == "pinned")
    #expect(model.displayedResults.sections.first?.hits.map(\.id) == ["session.alpha"])

    #expect(model.togglePin("session.alpha") == false)
    #expect(model.displayedResults.sections.first?.id == OpenAnythingDomain.actions.rawValue)
  }

  @Test("Pinned IDs surface at the top of the empty-query lane")
  func pinnedIDsSurfaceFirst() async {
    let model = Self.makeModel()
    model.togglePin("session.alpha")

    await model.replaceCorpus(Self.sampleRecords)

    let topHit = model.suggestedResults.allHits.first
    #expect(topHit?.id == "session.alpha")
    #expect(model.suggestedResults.sections.first?.title == "Pinned")
    #expect(
      Set(model.suggestedResults.sections.map(\.id)).count
        == model.suggestedResults.sections.count
    )
  }

  @Test("Pinned section collapse state does not collapse Actions")
  func pinnedSectionCollapseDoesNotCollapseActions() async {
    let model = Self.makeModel()
    model.toggleExpanded(.actions)

    model.toggleCollapsed(sectionID: "pinned", domain: .actions)

    #expect(model.isCollapsed(sectionID: "pinned"))
    #expect(!model.isCollapsed(sectionID: OpenAnythingDomain.actions.rawValue))
    #expect(model.isExpanded(.actions))
  }

  @Test("Pinned setting can leave suggested ranking untouched")
  func showPinnedSettingDisablesPinnedLane() async {
    let model = Self.makeModel()
    model.showsPinned = false
    model.togglePin("session.alpha")

    await model.replaceCorpus(Self.sampleRecords)

    #expect(model.suggestedResults.allHits.first?.id == "action.refresh")
  }

  @Test("Present refreshes suggested results after preference changes")
  func presentRefreshesSuggestedResultsAfterPreferenceChanges() async {
    let model = Self.makeModel()
    model.limitPerDomain = 1
    await model.replaceCorpus(Self.suggestedActionRecords)

    #expect(model.suggestedResults.sections.first?.hits.map(\.id) == ["action.refresh"])

    model.limitPerDomain = 2
    model.present(targetWindowID: nil)

    #expect(
      model.displayedResults.sections.first?.hits.map(\.id) == [
        "action.refresh",
        "action.copyDiagnostics",
      ]
    )
  }

  @Test("Recent ranking promotes used records")
  func recentRankingPromotesUsedRecords() async {
    let model = Self.makeModel()
    model.recordExecution(of: "action.copyDiagnostics")

    await model.replaceCorpus(Self.suggestedActionRecords)

    #expect(model.suggestedResults.sections.first?.hits.first?.id == "action.copyDiagnostics")
  }

  @Test("recordExecution can refresh presented suggestions")
  func recordExecutionRefreshesPresentedSuggestions() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.suggestedActionRecords)
    model.present(targetWindowID: nil)

    #expect(model.displayedResults.sections.first?.hits.first?.id == "action.refresh")

    model.recordExecution(of: "action.copyDiagnostics", refreshResults: true)

    #expect(model.displayedResults.sections.first?.hits.first?.id == "action.copyDiagnostics")
  }

  @Test("Unrelated recency keeps suggested order unchanged")
  func unrelatedRecencyKeepsSuggestedOrder() async {
    let model = Self.makeModel()
    model.recordExecution(of: "action.unrelated")

    await model.replaceCorpus(Self.suggestedActionRecords)

    #expect(
      model.suggestedResults.sections.first?.hits.map(\.id) == [
        "action.refresh",
        "action.copyDiagnostics",
      ]
    )
  }

  @Test("Disabled recency leaves suggested order unchanged")
  func disabledRecencyLeavesSuggestedOrder() async {
    let model = Self.makeModel()
    model.showsRecent = false
    model.recordExecution(of: "action.copyDiagnostics")

    await model.replaceCorpus(Self.suggestedActionRecords)

    #expect(
      model.suggestedResults.sections.first?.hits.map(\.id) == [
        "action.refresh",
        "action.copyDiagnostics",
      ]
    )
  }

  private static func makeModel() -> OpenAnythingPaletteModel {
    let suiteName = "OpenAnythingPaletteModelPinningTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      preconditionFailure("Failed to create OpenAnythingPaletteModel test defaults")
    }
    return OpenAnythingPaletteModel(
      recency: OpenAnythingRecencyStore(defaults: defaults, key: "recency"),
      pins: OpenAnythingPinStore(defaults: defaults, key: "pins")
    )
  }

  private static func record(
    id: String,
    domain: OpenAnythingDomain,
    target: OpenAnythingTarget,
    title: String,
    isSuggested: Bool = false
  ) -> OpenAnythingRecord {
    OpenAnythingRecord(
      id: id,
      domain: domain,
      target: target,
      title: title,
      isSuggested: isSuggested
    )
  }

  private static let sampleRecords: [OpenAnythingRecord] = [
    record(
      id: "action.refresh",
      domain: .actions,
      target: .action(.refresh),
      title: "Refresh",
      isSuggested: true
    ),
    record(
      id: "session.alpha",
      domain: .sessions,
      target: .session(sessionID: "alpha"),
      title: "Alpha Session"
    ),
    record(
      id: "session.beta",
      domain: .sessions,
      target: .session(sessionID: "beta"),
      title: "Beta Session"
    ),
  ]

  private static let suggestedActionRecords: [OpenAnythingRecord] = [
    record(
      id: "action.refresh",
      domain: .actions,
      target: .action(.refresh),
      title: "Refresh",
      isSuggested: true
    ),
    record(
      id: "action.copyDiagnostics",
      domain: .actions,
      target: .action(.copyDiagnostics),
      title: "Copy Diagnostics",
      isSuggested: true
    ),
  ]

  private static let multiSectionSuggestedRecords: [OpenAnythingRecord] = [
    record(
      id: "action.refresh",
      domain: .actions,
      target: .action(.refresh),
      title: "Refresh",
      isSuggested: true
    ),
    record(
      id: "window.dashboard",
      domain: .windows,
      target: .window(.dashboard),
      title: "Dashboard",
      isSuggested: true
    ),
    record(
      id: "session.alpha",
      domain: .sessions,
      target: .session(sessionID: "alpha"),
      title: "Alpha Session",
      isSuggested: true
    ),
  ]
}
