import Foundation
import Testing

@testable import HarnessMonitorKit

struct SupervisorAuditFiltersTests {
  @Test("empty filter reports isEmpty true")
  func defaultsAreEmpty() {
    let filters = SupervisorAuditFilters()
    #expect(filters.isEmpty)
  }

  @Test("whitespace search text is treated as empty")
  func whitespaceSearchTextIsEmpty() {
    let filters = SupervisorAuditFilters(searchText: "   \n\t")
    #expect(filters.isEmpty)
  }

  @Test("non-empty rule set flips isEmpty to false")
  func ruleIDsMakeFilterNonEmpty() {
    let filters = SupervisorAuditFilters(ruleIDs: ["stuck_agent"])
    #expect(!filters.isEmpty)
  }

  @Test("non-empty kind set flips isEmpty to false")
  func kindsMakeFilterNonEmpty() {
    let filters = SupervisorAuditFilters(kinds: [.actionDispatched])
    #expect(!filters.isEmpty)
  }

  @Test("non-empty severity set flips isEmpty to false")
  func severitiesMakeFilterNonEmpty() {
    let filters = SupervisorAuditFilters(severities: [.warn])
    #expect(!filters.isEmpty)
  }

  @Test("date range flips isEmpty to false")
  func dateRangeMakesFilterNonEmpty() {
    let now = Date()
    let filters = SupervisorAuditFilters(dateRange: now...now)
    #expect(!filters.isEmpty)
  }

  @Test("search text with content flips isEmpty to false")
  func searchTextMakesFilterNonEmpty() {
    let filters = SupervisorAuditFilters(searchText: "token")
    #expect(!filters.isEmpty)
  }

  @Test("decision id flips isEmpty to false")
  func decisionIDMakesFilterNonEmpty() {
    let filters = SupervisorAuditFilters(decisionID: UUID())
    #expect(!filters.isEmpty)
  }

  @Test("cursor stores anchor fields unchanged")
  func cursorRoundTripsFields() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let id = UUID()
    let cursor = SupervisorAuditCursor(createdAt: date, id: id)
    #expect(cursor.createdAt == date)
    #expect(cursor.id == id)
  }
}
