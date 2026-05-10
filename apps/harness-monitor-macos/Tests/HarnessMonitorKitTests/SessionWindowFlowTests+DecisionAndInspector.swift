import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionWindowFlowTests {
  @Test("Session sidebar live region includes visible count")
  func sessionSidebarLiveRegionIncludesVisibleCount() throws {
    let sidebarSource = try previewableSourceFile(named: "Views/Sessions/SessionSidebar.swift")
    let announcerSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebarMultiSelectAnnouncer.swift"
    )

    #expect(sidebarSource.contains(".accessibilityValue(decisionSelectionAccessibilityValue)"))
    #expect(sidebarSource.contains(#""\(count) of \(visible) \(anchor.kind.pluralNoun) selected""#))
    #expect(sidebarSource.contains(#""\(displayedSelectionSet.count) items selected""#))
    #expect(announcerSource.contains(#""\(count) of \(visibleCount) \(kind.pluralNoun) selected""#))
  }

  @Test("Session sidebar decision section omits dismiss and filter controls")
  func sessionSidebarDecisionSectionOmitsDismissAndFilterControls() throws {
    let sectionSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebarDecisionSection.swift"
    )
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let sidebarSource = try previewableSourceFile(named: "Views/Sessions/SessionSidebar.swift")

    #expect(!sectionSource.contains("Dismiss Selected"))
    #expect(!sectionSource.contains("Dismiss All Visible"))
    #expect(!sectionSource.contains("SessionDecisionFilterControls"))
    #expect(!sectionSource.contains(".badge(Text(\"\\(decisions.count) pending\"))"))
    #expect(columnsSource.contains("decisions: allSessionDecisions"))
    #expect(sidebarSource.contains("case .decision:\n        return false"))
    #expect(sidebarSource.contains("case .decision: return"))
  }

  @Test("Session sidebar headers use inset bordered add buttons")
  func sessionSidebarHeadersUseInsetBorderedAddButtons() throws {
    let sectionsSource = try previewableSourceFile(named: "Views/Sessions/SessionSidebar+Sections.swift")
    let decisionsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebarDecisionSection.swift"
    )

    #expect(sectionsSource.contains("struct SessionSidebarHeaderCreateButton: View"))
    #expect(sectionsSource.contains("Button(\"+\")"))
    #expect(sectionsSource.contains("HStack(alignment: .sessionSidebarHeaderButtonCenter"))
    #expect(sectionsSource.contains(".buttonStyle(.bordered)"))
    #expect(sectionsSource.contains(".controlSize(.small)"))
    #expect(sectionsSource.contains("VStack(alignment: .trailing"))
    #expect(sectionsSource.contains(".alignmentGuide(.sessionSidebarHeaderButtonCenter)"))
    #expect(sectionsSource.contains("private var displayedShortcut: KeyboardShortcutDescriptor"))
    #expect(sectionsSource.contains("shortcut: displayedShortcut"))
    #expect(sectionsSource.contains("revealPolicy: .revealOnRelevantModifierHold"))
    #expect(sectionsSource.contains(".padding(.trailing, HarnessMonitorTheme.spacingSM)"))
    #expect(sectionsSource.contains("currentModifiers: shortcutRevealModifiers"))
    #expect(sectionsSource.contains("SessionSidebarHeaderCreateButton(\n        state: state,\n        kind: .agent,\n        primaryKind: primaryCreateKind,\n        accessibilityLabel: \"New Agent\",\n        currentModifiers: shortcutRevealModifiers"))
    #expect(sectionsSource.contains("SessionSidebarHeaderCreateButton(\n        state: state,\n        kind: .task,\n        primaryKind: primaryCreateKind,\n        accessibilityLabel: \"New Task\",\n        currentModifiers: shortcutRevealModifiers"))
    #expect(decisionsSource.contains("SessionSidebarHeaderCreateButton(\n        state: state,\n        kind: .decision,\n        primaryKind: primaryCreateKind,\n        accessibilityLabel: \"New Decision\",\n        currentModifiers: shortcutRevealModifiers"))
  }

  @Test("Keyboard shortcut descriptors support reveal across modifier families")
  func keyboardShortcutDescriptorsSupportRevealAcrossModifierFamilies() {
    let createShortcut = SessionCreateKind.agent.createShortcut
    let controlShiftShortcut = KeyboardShortcutDescriptor(
      modifiers: [.control, .shift],
      keyEquivalent: "k",
      keyLabel: "K"
    )

    #expect(createShortcut.hint == "⌥⌘A")
    #expect(createShortcut.requiredEventModifiers.contains(.option))
    #expect(createShortcut.requiredEventModifiers.contains(.command))
    #expect(!createShortcut.requiredEventModifiers.contains(.shift))
    #expect(!createShortcut.isRevealed(by: []))
    #expect(createShortcut.isRevealed(by: [.option]))
    #expect(createShortcut.isRevealed(by: [.command]))
    #expect(!createShortcut.isRevealed(by: [.shift]))

    #expect(controlShiftShortcut.hint == "⌃⇧K")
    #expect(controlShiftShortcut.requiredEventModifiers.contains(.control))
    #expect(controlShiftShortcut.requiredEventModifiers.contains(.shift))
    #expect(controlShiftShortcut.isRevealed(by: [.control]))
    #expect(controlShiftShortcut.isRevealed(by: [.shift]))
    #expect(!controlShiftShortcut.isRevealed(by: [.option]))
  }

  @Test("Displayed create shortcut follows the primary create kind")
  func displayedCreateShortcutFollowsPrimaryCreateKind() {
    #expect(SessionSelection.route(.agents).primaryCreateKind == .agent)
    #expect(SessionSelection.route(.tasks).primaryCreateKind == .task)
    #expect(SessionSelection.route(.decisions).primaryCreateKind == .decision)
    #expect(SessionCreateKind.agent.displayedCreateShortcut(primaryKind: .agent).hint == "⌘N")
    #expect(SessionCreateKind.task.displayedCreateShortcut(primaryKind: .agent).hint == "⌥⌘T")
    #expect(SessionCreateKind.decision.displayedCreateShortcut(primaryKind: .decision).hint == "⌘N")
  }

  @Test("Agents route auto-selects the first visible agent")
  func agentsRouteAutoSelectsTheFirstVisibleAgent() {
    #expect(
      SessionAgentAutoSelectionPolicy.preferredAgentID(
        selection: .route(.agents),
        visibleAgentIDs: ["agent-a", "agent-b"]
      ) == "agent-a"
    )
    #expect(
      SessionAgentAutoSelectionPolicy.preferredAgentID(
        selection: .route(.agents),
        visibleAgentIDs: []
      ) == nil
    )
    #expect(
      SessionAgentAutoSelectionPolicy.preferredAgentID(
        selection: .route(.tasks),
        visibleAgentIDs: ["agent-a"]
      ) == nil
    )
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
