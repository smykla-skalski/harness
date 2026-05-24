import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("OpenAnything corpus builder")
struct OpenAnythingCorpusBuilderTests {
  @Test("Empty input still emits action and window records")
  func emptyInputEmitsStaticRecords() {
    let records = OpenAnythingCorpusBuilder.records(input: Self.input())

    let domains = Set(records.map(\.domain))
    #expect(domains.contains(.actions))
    #expect(domains.contains(.windows))
  }

  @Test("PolicyCanvas action and window stay hidden when the flag is off")
  func policyCanvasLabGateRespected() {
    let off = OpenAnythingCorpusBuilder.records(
      input: Self.input(showsPolicyCanvasLab: false)
    )
    let on = OpenAnythingCorpusBuilder.records(
      input: Self.input(showsPolicyCanvasLab: true)
    )

    let offTargets = off.map(\.target)
    let onTargets = on.map(\.target)

    #expect(!offTargets.contains(where: Self.isPolicyCanvasLabAction))
    #expect(!offTargets.contains(where: Self.isPolicyCanvasLabWindow))
    #expect(onTargets.contains(where: Self.isPolicyCanvasLabAction))
    #expect(onTargets.contains(where: Self.isPolicyCanvasLabWindow))
  }

  @Test("Suggested actions stay marked across rebuilds")
  func suggestedActionsRoundTrip() {
    let records = OpenAnythingCorpusBuilder.records(input: Self.input())
    let suggestedIDs = records.filter(\.isSuggested).map(\.id)

    #expect(suggestedIDs.contains("action.newSession"))
    #expect(suggestedIDs.contains("action.openTaskBoard"))
    #expect(suggestedIDs.contains("action.openReviews"))
    #expect(suggestedIDs.contains("action.openDiagnostics"))
    #expect(suggestedIDs.contains("action.refresh"))
  }

  @Test("Action records do not duplicate dashboard-route records")
  func actionRecordsNoLongerDuplicateRouteRecords() {
    let records = OpenAnythingCorpusBuilder.records(input: Self.input())

    let actionTargets = records.filter { $0.domain == .actions }.map(\.target)
    let windowTargets = records.filter { $0.domain == .windows }.map(\.target)

    let windowDashboardRoutes = windowTargets.compactMap { target -> OpenAnythingDashboardRoute? in
      if case .dashboardRoute(let route) = target { return route }
      return nil
    }
    let actionDashboardOpens = actionTargets.compactMap { target -> OpenAnythingAction? in
      if case .action(let action) = target { return action }
      return nil
    }

    // The duplicate-route bug surfaced rows like "Open Board" (action) and
    // "Board" (windows.dashboardRoute) that resolved to the same step. After
    // Unit 2 there are no dashboardRoute records at all - the actions branch
    // is the sole entry point for dashboard sub-routes.
    #expect(windowDashboardRoutes.isEmpty)
    #expect(actionDashboardOpens.contains(.openTaskBoard))
    #expect(actionDashboardOpens.contains(.openReviews))
  }

  private static func input(showsPolicyCanvasLab: Bool = true) -> OpenAnythingCorpusInput {
    OpenAnythingCorpusInput(
      settingsSections: [
        OpenAnythingSettingsSectionProjection(
          rawValue: "general",
          title: "General",
          systemImage: "gearshape"
        )
      ],
      sessions: [],
      taskBoardItems: [],
      decisions: [],
      reviews: [],
      loadedSession: nil,
      showsPolicyCanvasLab: showsPolicyCanvasLab
    )
  }

  private static func isPolicyCanvasLabAction(_ target: OpenAnythingTarget) -> Bool {
    if case .action(.policyCanvasLab) = target { return true }
    return false
  }

  private static func isPolicyCanvasLabWindow(_ target: OpenAnythingTarget) -> Bool {
    if case .window(.policyCanvasLab) = target { return true }
    return false
  }
}
