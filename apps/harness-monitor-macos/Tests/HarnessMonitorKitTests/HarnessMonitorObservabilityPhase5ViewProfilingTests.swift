import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Harness Monitor observability Phase 5 view profiling")
struct Phase5ViewProfilingTests {

  @Test("View signposter measures view body")
  func viewSignposterMeasuresViewBody() {
    var bodyEvaluated = false
    _ = ViewBodySignposter.measure("TestView") {
      bodyEvaluated = true
      return 42
    }
    #expect(bodyEvaluated)
  }

  @Test("View signposter returns body result")
  func viewSignposterReturnsBodyResult() {
    let result = ViewBodySignposter.measure("TestView") {
      "hello"
    }
    #expect(result == "hello")
  }

  @Test("View signposter exports a view span with the measured view name")
  func viewSignposterExportsViewSpanWithMeasuredViewName() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    _ = ViewBodySignposter.measure("SessionCockpitView") {
      "profiled"
    }

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "SessionCockpitView"
      ) != nil
    }

    let attributes = try #require(
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "SessionCockpitView"
      )
    )
    #expect(attributes["perf.signpost.name"] == "view.body")
    #expect(attributes["harness.view.name"] == "SessionCockpitView")
  }

  @Test("View signposter exports additional view-state attributes")
  func viewSignposterExportsAdditionalViewStateAttributes() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    _ = ViewBodySignposter.measure(
      "ToolbarCenterpieceView",
      attributes: [
        "harness.view.display_mode": "standard",
        "harness.view.status_message_count": "1",
      ]
    ) {
      "profiled"
    }

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "ToolbarCenterpieceView"
      ) != nil
    }

    let attributes = try #require(
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "ToolbarCenterpieceView"
      )
    )
    #expect(attributes["harness.view.display_mode"] == "standard")
    #expect(attributes["harness.view.status_message_count"] == "1")
  }

  @Test("View signposter can target invalidation logging to selected views")
  func viewSignposterCanTargetInvalidationLoggingToSelectedViews() {
    let environment = ["HARNESS_MONITOR_LOG_VIEW_UPDATES": "ContentView, ToolbarCenterpieceView"]

    #expect(ViewBodySignposter.shouldLogChanges(for: "ContentView", environment: environment))
    #expect(
      ViewBodySignposter.shouldLogChanges(
        for: "ToolbarCenterpieceView",
        environment: environment
      )
    )
    #expect(!ViewBodySignposter.shouldLogChanges(for: "SidebarView", environment: environment))
  }

  @Test("View signposter can enable invalidation logging for all views")
  func viewSignposterCanEnableInvalidationLoggingForAllViews() {
    let environment = ["HARNESS_MONITOR_LOG_VIEW_UPDATES": " all "]

    #expect(ViewBodySignposter.shouldLogChanges(for: "ContentView", environment: environment))
    #expect(ViewBodySignposter.shouldLogChanges(for: "SidebarView", environment: environment))
  }

  @MainActor
  @Test("Launch dashboard surfaces emit profiled body spans when automatic profiling is enabled")
  func launchDashboardSurfacesEmitProfiledBodySpansWhenAutomaticProfilingIsEnabled() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let store = withViewBodyProfilingEnabled {
      renderLaunchDashboardProfiledViews()
    }

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      viewBodySpanAttributes(in: collector.traceCollector, viewName: "ContentView") != nil
        && viewBodySpanAttributes(in: collector.traceCollector, viewName: "SidebarView") != nil
        && viewBodySpanAttributes(
          in: collector.traceCollector,
          viewName: "SidebarSearchAccessoryBar"
        ) != nil
        && viewBodySpanAttributes(
          in: collector.traceCollector,
          viewName: "ToolbarCenterpieceView"
        ) != nil
        && viewBodySpanAttributes(
          in: collector.traceCollector,
          viewName: "ConnectionToolbarBadge"
        ) != nil
    }

    let contentAttributes = try #require(
      viewBodySpanAttributes(in: collector.traceCollector, viewName: "ContentView")
    )
    let sidebarAttributes = try #require(
      viewBodySpanAttributes(in: collector.traceCollector, viewName: "SidebarView")
    )
    let accessoryAttributes = try #require(
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "SidebarSearchAccessoryBar"
      )
    )
    let toolbarAttributes = try #require(
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "ToolbarCenterpieceView"
      )
    )
    let badgeAttributes = try #require(
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "ConnectionToolbarBadge"
      )
    )
    let hasActiveFilters =
      !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || store.sessionFilter != .all
      || store.sessionFocusFilter != .all
      || store.sessionSortOrder != .recentActivity

    #expect(contentAttributes["harness.view.surface"] == "dashboard")
    #expect(sidebarAttributes["harness.view.session_filter"] == "active")
    #expect(
      accessoryAttributes["harness.view.has_active_filters"]
        == (hasActiveFilters ? "true" : "false")
    )
    #expect(toolbarAttributes["harness.view.display_mode"] == "standard")
    #expect(badgeAttributes["harness.view.transport"] == "webSocket")
  }

  @MainActor
  @Test("Critical cockpit views emit profiled body spans when rendered")
  func criticalCockpitViewsEmitProfiledBodySpansWhenRendered() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let (temporaryHome, environment) = try makeTestEnvironment(collector: collector)
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)
    render(
      SessionCockpitView(
        store: store,
        detail: PreviewFixtures.detail,
        timeline: PreviewFixtures.timeline,
        timelineWindow: .fallbackMetadata(for: PreviewFixtures.timeline),
        isSessionStatusStale: false,
        isSessionReadOnly: false,
        isTimelineLoading: false,
        isExtensionsLoading: false
      ),
      width: 1_440,
      height: 1_024
    )
    render(
      SessionCockpitTimelineSection(
        sessionID: PreviewFixtures.summary.sessionId,
        timeline: PreviewFixtures.timeline,
        timelineWindow: .fallbackMetadata(for: PreviewFixtures.timeline),
        isTimelineLoading: false,
        loadPage: { _, _ in }
      ),
      width: 960,
      height: 720
    )

    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForTraceExport(timeout: .seconds(3)) {
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "SessionCockpitView"
      ) != nil
        && viewBodySpanAttributes(
          in: collector.traceCollector,
          viewName: "SessionCockpitTimelineSection"
        ) != nil
    }

    #expect(
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "SessionCockpitView"
      ) != nil
    )
    #expect(
      viewBodySpanAttributes(
        in: collector.traceCollector,
        viewName: "SessionCockpitTimelineSection"
      ) != nil
    )
  }
}
