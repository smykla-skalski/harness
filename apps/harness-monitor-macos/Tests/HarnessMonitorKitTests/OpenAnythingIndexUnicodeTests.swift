import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("OpenAnything index unicode + highlights")
struct OpenAnythingIndexUnicodeTests {
  @Test("Diacritic-insensitive search matches")
  func diacriticInsensitiveSearch() async {
    let index = OpenAnythingIndex()
    await index.replace(records: [
      Self.record(id: "session.cafe", title: "Café Session")
    ])

    let results = await index.search(query: "cafe")

    #expect(!results.sections.isEmpty)
    #expect(results.sections.first?.hits.first?.id == "session.cafe")
  }

  @Test("Case-insensitive search matches uppercase query")
  func caseInsensitiveSearch() async {
    let index = OpenAnythingIndex()
    await index.replace(records: [
      Self.record(id: "dashboard", title: "Dashboard")
    ])

    let results = await index.search(query: "DASHBOARD")

    #expect(results.sections.first?.hits.first?.id == "dashboard")
  }

  @Test("Highlights are non-empty on a prefix match")
  func highlightsNonEmptyOnPrefixMatch() async {
    let index = OpenAnythingIndex()
    await index.replace(records: [
      Self.record(id: "session.alpha", title: "Alpha Session")
    ])

    let results = await index.search(query: "Alpha")
    let hit = results.sections.first?.hits.first

    #expect(hit?.id == "session.alpha")
    #expect(hit?.highlights.title.isEmpty == false)
  }

  private static func record(id: String, title: String) -> OpenAnythingRecord {
    OpenAnythingRecord(
      id: id,
      domain: .sessions,
      target: .session(sessionID: id),
      title: title
    )
  }
}
