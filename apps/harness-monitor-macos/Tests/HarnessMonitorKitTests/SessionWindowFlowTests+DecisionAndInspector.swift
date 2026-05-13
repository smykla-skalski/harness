import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionWindowFlowTests {
  @Test("Session sidebar live region includes visible count")
  func sessionSidebarLiveRegionIncludesVisibleCount() throws {
    let selectionSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebar+Selection.swift"
    )
    let announcerSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebarMultiSelectAnnouncer.swift"
    )

    #expect(selectionSource.contains("var decisionSelectionAccessibilityValue: Text"))
    #expect(
      selectionSource.contains(#""\(count) of \(visible) \(anchor.kind.pluralNoun) selected""#)
    )
    #expect(selectionSource.contains(#""\(displayedSelection.count) items selected""#))
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
    let selectionDispatcherSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebar+SelectionDispatcher.swift"
    )

    #expect(!sectionSource.contains("Dismiss Selected"))
    #expect(!sectionSource.contains("Dismiss All Visible"))
    #expect(!sectionSource.contains("SessionDecisionFilterControls"))
    #expect(!sectionSource.contains(".badge(Text(\"\\(decisions.count) pending\"))"))
    #expect(columnsSource.contains("decisions: allSessionDecisions"))
    #expect(selectionDispatcherSource.contains("case .decision: return"))
    #expect(selectionDispatcherSource.contains("case .decision: decisions"))
  }

  @Test("Session sidebar headers use inset bordered add buttons")
  func sessionSidebarHeadersUseInsetBorderedAddButtons() throws {
    let sectionsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebar+Sections.swift")
    let decisionsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebarDecisionSection.swift"
    )
    let sidebarSource = try previewableSourceFile(named: "Views/Sessions/SessionSidebar.swift")

    #expect(sectionsSource.contains("struct SessionSidebarHeaderCreateButton: View"))
    #expect(sectionsSource.contains("Button(\"+\")"))
    #expect(sectionsSource.contains("HStack(alignment: .sessionSidebarHeaderButtonCenter"))
    #expect(sectionsSource.contains(".harnessActionButtonStyle(variant: .bordered, tint: nil)"))
    #expect(sectionsSource.contains(".controlSize(.small)"))
    #expect(sectionsSource.contains("GeometryReader { proxy in"))
    #expect(sectionsSource.contains(".alignmentGuide(.sessionSidebarHeaderButtonCenter)"))
    #expect(sectionsSource.contains("private var displayedShortcut: KeyboardShortcutDescriptor"))
    #expect(sectionsSource.contains("displayedShortcut.hint"))
    #expect(sectionsSource.contains("revealPolicy: .revealOnRelevantModifierHold"))
    #expect(sectionsSource.contains(".padding(.trailing, HarnessMonitorTheme.spacingSM)"))
    #expect(sidebarSource.contains("currentModifiers: currentModifiers"))
    #expect(sectionsSource.contains("let shortcut = kind.createShortcut"))
    // swiftlint:disable line_length
    #expect(
      sectionsSource.contains(
        "SessionSidebarHeaderCreateButton(\n        state: state,\n        kind: .agent,\n        accessibilityLabel: \"New Agent\""
      ))
    #expect(
      sectionsSource.contains(
        "SessionSidebarHeaderCreateButton(\n        state: state,\n        kind: .task,\n        accessibilityLabel: \"New Task\""
      ))
    #expect(
      decisionsSource.contains(
        "SessionSidebarHeaderCreateButton(\n        state: state,\n        kind: .decision,\n        accessibilityLabel: \"New Decision\""
      ))
    // swiftlint:enable line_length
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

  @Test("Keyboard shortcut labels align tokens on a shared baseline and use warm highlight tint")
  func keyboardShortcutLabelsAlignTokensOnSharedBaseline() throws {
    let supportSource = try previewableSourceFile(
      named: "Views/Sessions/OpenRecentView+Support.swift")

    #expect(supportSource.contains("HStack(alignment: .firstTextBaseline, spacing: keySpacing)"))
    #expect(supportSource.contains("return HarnessMonitorTheme.warmAccent"))
    #expect(!supportSource.contains(".caption.monospaced()"))
    #expect(supportSource.contains("case .key:\n      .callout.monospaced()"))
  }

  @Test("Primary create kind tracks the selected route without claiming Command-N")
  func primaryCreateKindTracksSelectedRouteWithoutClaimingCommandN() {
    #expect(SessionSelection.route(.agents).primaryCreateKind == .agent)
    #expect(SessionSelection.route(.tasks).primaryCreateKind == .task)
    #expect(SessionSelection.route(.decisions).primaryCreateKind == .decision)
    #expect(SessionCreateKind.agent.createShortcut.hint == "⌥⌘A")
    #expect(SessionCreateKind.task.createShortcut.hint == "⌥⌘T")
    #expect(SessionCreateKind.decision.createShortcut.hint == "⌥⌘D")
  }

  @Test(
    "Agents route detail prefers the remembered visible agent and otherwise falls back to the first visible one"
  )
  func agentsRouteDetailPrefersRememberedVisibleAgent() {
    #expect(
      SessionAgentRouteSelectionPolicy.preferredRouteDetailAgentID(
        rememberedAgentID: "agent-b",
        visibleAgentIDs: ["agent-a", "agent-b"]
      ) == "agent-b"
    )
    #expect(
      SessionAgentRouteSelectionPolicy.preferredRouteDetailAgentID(
        rememberedAgentID: "missing-agent",
        visibleAgentIDs: ["agent-a", "agent-b"]
      ) == "agent-a"
    )
    #expect(
      SessionAgentRouteSelectionPolicy.preferredRouteDetailAgentID(
        rememberedAgentID: "agent-b",
        visibleAgentIDs: []
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
    #expect(columnsSource.contains("preferredVisible: inspectorPreferredBinding"))
    #expect(inspectorSource.contains("@Binding var preferredVisible"))
  }

  @Test("Session startup does not force inspector visibility before geometry exists")
  func sessionStartupLeavesInspectorVisibilityToReactiveLayoutPasses() throws {
    let presentationSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Presentation.swift"
    )

    #expect(
      presentationSource.contains(
        """
          func performInitialLoad() async {
            hydrateSelectionFromPersistedStorage()
            hydrateDecisionFiltersFromPersistedStorage()
            await applyPendingSessionRouteIfNeeded()
            await loadSnapshot()
            requestPrimaryContentAccessibilityFocus()
            enableStartupSearchParticipation()
          }
        """
      )
    )
  }

  @Test("Session focused values wait until startup hydration completes")
  func sessionFocusedValuesWaitForStartupParticipation() throws {
    let focusedValuesSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+FocusedValues.swift"
    )

    #expect(focusedValuesSource.contains("let navigation ="))
    #expect(
      focusedValuesSource.contains(
        "isStartupSearchParticipationEnabled ? navigationCommand : nil"
      )
    )
    #expect(focusedValuesSource.contains("let attention ="))
    #expect(
      focusedValuesSource.contains(
        "isStartupSearchParticipationEnabled ? attentionFocus : nil"
      )
    )
    #expect(
      focusedValuesSource.contains(
        "var focusedInspectorCommand: SessionInspectorCommand?"
      )
    )
    #expect(
      focusedValuesSource.contains(
        "guard isStartupSearchParticipationEnabled else { return nil }"
      )
    )
    #expect(focusedValuesSource.contains("guard canPresentInspector else { return nil }"))
    #expect(focusedValuesSource.contains("return inspectorCommand"))
    #expect(focusedValuesSource.contains("let inspector = focusedInspectorCommand"))
  }
}

@Suite("Session inspector visibility policy")
struct SessionInspectorVisibilityPolicyTests {
  @Test("Startup inspector reconciliation waits for a concrete layout width")
  func startupInspectorReconciliationWaitsForConcreteLayoutWidth() {
    #expect(
      SessionInspectorVisibilityPolicy.shouldDeferVisibilityReconciliation(
        preferredVisible: true,
        hasInspectorContext: true,
        detailColumnWidth: 0,
        focusMode: false
      )
    )
    #expect(
      !SessionInspectorVisibilityPolicy.shouldDeferVisibilityReconciliation(
        preferredVisible: true,
        hasInspectorContext: true,
        detailColumnWidth: 1100,
        focusMode: false
      )
    )
    #expect(
      !SessionInspectorVisibilityPolicy.shouldDeferVisibilityReconciliation(
        preferredVisible: true,
        hasInspectorContext: false,
        detailColumnWidth: 0,
        focusMode: false
      )
    )
    #expect(
      !SessionInspectorVisibilityPolicy.shouldDeferVisibilityReconciliation(
        preferredVisible: true,
        hasInspectorContext: true,
        detailColumnWidth: 0,
        focusMode: true
      )
    )
  }
}
