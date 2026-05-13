import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Agent detail draft persistence")
@MainActor
struct AgentDetailSectionPersistenceTests {
  @Test("Persist skips unchanged draft values")
  func persistDraftSkipsUnchangedValues() throws {
    let defaults = try makeDefaults()
    let key = "agent-detail-draft"
    defaults.set("same", forKey: key)

    let wrote = AgentDetailSection.persistDraftIfNeeded(
      value: "same",
      key: key,
      defaults: defaults
    )

    #expect(wrote == false)
    #expect(defaults.string(forKey: key) == "same")
  }

  @Test("Persist stores changed draft values")
  func persistDraftStoresChangedValues() throws {
    let defaults = try makeDefaults()
    let key = "agent-detail-draft"
    defaults.set("old", forKey: key)

    let wrote = AgentDetailSection.persistDraftIfNeeded(
      value: "new",
      key: key,
      defaults: defaults
    )

    #expect(wrote == true)
    #expect(defaults.string(forKey: key) == "new")
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "io.harnessmonitor.tests.agent-detail.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      throw PersistenceTestError.failedToCreateDefaults
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}

private enum PersistenceTestError: Error {
  case failedToCreateDefaults
}
