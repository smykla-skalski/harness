import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionWindowFlowTests {
  @Test("Session decision filters use toggles and live region includes visible count")
  func sessionDecisionFiltersUseTogglesAndLiveRegionIncludesVisibleCount() throws {
    let sidebarSource = try previewableSourceFile(named: "Views/Sessions/SessionSidebar.swift")
    let filterSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebar+Filtering.swift")
    let announcerSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebarMultiSelectAnnouncer.swift"
    )

    #expect(filterSource.contains("Toggle(severity.rawValue.capitalized"))
    #expect(filterSource.contains("private func severityBinding"))
    #expect(sidebarSource.contains(".accessibilityValue(decisionSelectionAccessibilityValue)"))
    #expect(sidebarSource.contains(#""\(count) of \(visible) \(anchor.kind.pluralNoun) selected""#))
    #expect(sidebarSource.contains(#""\(displayedSelectionSet.count) items selected""#))
    #expect(announcerSource.contains(#""\(count) of \(visibleCount) \(kind.pluralNoun) selected""#))
  }

  @MainActor
  @Test("Session window decision visibility distinguishes visible hidden and missing states")
  func sessionWindowDecisionVisibilityDistinguishesStates() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")
    state.selectDecision("decision-visible")

    #expect(
      state.selectedDecisionVisibility(
        allDecisionIDs: ["decision-visible", "decision-hidden"],
        visibleDecisionIDs: ["decision-visible"]
      ) == .visible
    )
    #expect(
      state.selectedDecisionVisibility(
        allDecisionIDs: ["decision-visible", "decision-hidden"],
        visibleDecisionIDs: ["decision-hidden"]
      ) == .hidden
    )
    #expect(
      state.selectedDecisionVisibility(
        allDecisionIDs: ["decision-hidden"],
        visibleDecisionIDs: ["decision-hidden"]
      ) == .missing
    )

    state.selectRoute(.overview)
    #expect(
      state.selectedDecisionVisibility(
        allDecisionIDs: ["decision-visible"],
        visibleDecisionIDs: ["decision-visible"]
      ) == .none
    )
  }

  @Test("Session inspector auto-collapse preserves preferred visibility")
  func sessionInspectorAutoCollapsePreservesPreferredVisibility() {
    #expect(!SessionInspectorVisibilityPolicy.allowsInspector(width: 1099))
    #expect(SessionInspectorVisibilityPolicy.allowsInspector(width: 1100))
    #expect(
      !SessionInspectorVisibilityPolicy.resolvedVisible(
        preferredVisible: true,
        canPresent: false
      )
    )
    #expect(
      SessionInspectorVisibilityPolicy.resolvedVisible(
        preferredVisible: true,
        canPresent: true
      )
    )
    #expect(
      !SessionInspectorVisibilityPolicy.resolvedVisible(
        preferredVisible: false,
        canPresent: true
      )
    )
  }

  @Test("Session window stores inspector preference separately from actual visibility")
  func sessionWindowStoresInspectorPreferenceSeparatelyFromActualVisibility() throws {
    let viewSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let inspectorPolicySource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Inspector.swift"
    )
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift")
    let inspectorSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowInspector.swift")

    #expect(viewSource.contains("@SceneStorage(\"session.inspector.visible\")"))
    #expect(viewSource.contains("@SceneStorage(\"session.inspector.preferred\")"))
    #expect(inspectorPolicySource.contains("preferredVisible: preferredBinding.wrappedValue"))
    #expect(columnsSource.contains("preferredVisible: $inspectorPreferred"))
    #expect(inspectorSource.contains("@Binding var preferredVisible"))
  }
}
