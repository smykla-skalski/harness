import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("OpenAnything context ranking")
@MainActor
struct OpenAnythingContextRankingTests {
  @Test("Context domain floats its section above the natural order")
  func contextFloatsSection() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.crossDomainRecords)

    // Natural order puts Task Board (displayOrder index 4) above Reviews (6).
    model.present(targetWindowID: nil)
    #expect(model.suggestedResults.sections.first?.domain == .taskBoard)

    // Opening from the Reviews view should float Reviews to the top.
    model.present(targetWindowID: nil, contextDomain: .reviews)
    #expect(model.suggestedResults.sections.first?.domain == .reviews)
  }

  @Test("Context domain keeps every other section visible")
  func contextKeepsOthersVisible() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.crossDomainRecords)

    model.present(targetWindowID: nil, contextDomain: .reviews)

    let domains = model.suggestedResults.sections.map(\.domain)
    #expect(domains.first == .reviews)
    #expect(domains.contains(.taskBoard))
  }

  @Test("Pinned section stays above the context section")
  func pinnedStaysAboveContext() async {
    let model = Self.makeModel()
    model.togglePin("review.alpha")
    await model.replaceCorpus(Self.crossDomainRecords)

    model.present(targetWindowID: nil, contextDomain: .taskBoard)

    #expect(model.suggestedResults.sections.first?.id == "pinned")
    #expect(model.suggestedResults.sections.dropFirst().first?.domain == .taskBoard)
  }

  @Test("Disabling the context preference leaves the natural order")
  func disabledContextLeavesOrder() async {
    let model = Self.makeModel()
    model.prioritizesContextDomain = false
    await model.replaceCorpus(Self.crossDomainRecords)

    model.present(targetWindowID: nil, contextDomain: .reviews)

    #expect(model.suggestedResults.sections.first?.domain == .taskBoard)
  }

  @Test("No context domain leaves the natural order")
  func nilContextLeavesOrder() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.crossDomainRecords)

    model.present(targetWindowID: nil)

    #expect(model.suggestedResults.sections.first?.domain == .taskBoard)
  }

  private static func makeModel() -> OpenAnythingPaletteModel {
    let suiteName = "OpenAnythingContextRankingTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      preconditionFailure("Failed to create OpenAnythingPaletteModel test defaults")
    }
    return OpenAnythingPaletteModel(
      recency: OpenAnythingRecencyStore(defaults: defaults, key: "recency"),
      pins: OpenAnythingPinStore(defaults: defaults, key: "pins")
    )
  }

  private static let crossDomainRecords: [OpenAnythingRecord] = [
    OpenAnythingRecord(
      id: "task.alpha",
      domain: .taskBoard,
      target: .taskBoardItem(id: "t1", sessionID: nil, workItemID: nil),
      title: "MeshTimeout Task",
      isSuggested: true
    ),
    OpenAnythingRecord(
      id: "review.alpha",
      domain: .reviews,
      target: .review(pullRequestID: "pr1"),
      title: "MeshTimeout PR",
      isSuggested: true
    ),
  ]
}
