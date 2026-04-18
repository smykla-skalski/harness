import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("SidebarFooterMetricKind")
struct SidebarFooterMetricKindTests {
  @Test("All cases have non-empty title")
  func allCasesHaveNonEmptyTitle() {
    for kind in SidebarFooterMetricKind.allCases {
      #expect(!kind.title.isEmpty, "Expected non-empty title for \(kind.rawValue)")
    }
  }
}
