import AppKit
import HarnessMonitorKit
import SwiftUI

public enum DashboardAuditNavigationPreviewRenderer {
  @MainActor
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }
    return render(
      name: "audit-timeline-navigation",
      scenario: .timeline,
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && render(
        name: "audit-timeline-navigation-largest-text",
        scenario: .timeline,
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
      && render(
        name: "audit-deep-event-navigation",
        scenario: .deepEvent,
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        directory: directory
      )
  }

  @MainActor
  private static func render(
    name: String,
    scenario: DashboardAuditNavigationPreviewScenario,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let size = NSSize(width: 1120, height: 720)
    let hosted = DashboardAuditNavigationPreviewSurface(scenario: scenario)
      .frame(width: size.width, height: size.height)
      .background(Color(nsColor: .windowBackgroundColor))
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(size)
    let window = NSWindow(
      contentRect: view.bounds,
      styleMask: .borderless,
      backing: .buffered,
      defer: false,
      screen: NSScreen.main
    )
    window.contentView = view
    for _ in 0..<3 {
      view.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    view.layoutSubtreeIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }
    do {
      try data.write(
        to: URL(fileURLWithPath: directory)
          .appendingPathComponent(name)
          .appendingPathExtension("png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }
}

private enum DashboardAuditNavigationPreviewScenario {
  case timeline
  case deepEvent
}

@MainActor
private struct DashboardAuditNavigationPreviewSurface: View {
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  let history: GlobalWindowNavigationHistory

  init(scenario: DashboardAuditNavigationPreviewScenario) {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)
    let dashboardUI = HarnessMonitorStore.ContentDashboardSlice()
    let history = GlobalWindowNavigationHistory(store: store)
    switch scenario {
    case .timeline:
      dashboardUI.auditEvents = Self.auditEvents
      history.requestDashboardAudit(.sessionTimeline(.init(Self.timelineTarget)))
    case .deepEvent:
      dashboardUI.auditEvents = Self.deepAuditEvents
      history.requestDashboardAudit(.auditEvent(eventID: Self.deepTargetID))
    }
    self.store = store
    self.dashboardUI = dashboardUI
    self.history = history
  }

  var body: some View {
    DashboardAuditRouteView(store: store, dashboardUI: dashboardUI, history: history)
  }

  private static let timelineTarget = OpenAnythingLoadedSessionTimelineTarget(
    entry: TimelineEntry(
      entryId: "timeline-entry-42",
      recordedAt: "2026-08-05T08:42:00Z",
      kind: "agent.progress",
      sessionId: "session-preview",
      agentId: "worker-review",
      taskId: "task-1341",
      summary: "Navigation cutover validation completed",
      payload: .object([
        "phase": .string("validation"),
        "progress": .number(1),
      ])
    )
  )

  private static let auditEvents: [HarnessMonitorAuditEvent] = [
    .init(
      id: "audit-sync",
      recordedAt: HarnessMonitorAuditEvent.parseDate("2026-08-05T08:40:00Z") ?? .distantPast,
      source: "taskBoard",
      category: "sync",
      kind: "task_board.sync.completed",
      severity: "info",
      outcome: "success",
      title: "Task Board sync",
      summary: "Repository scope refreshed"
    ),
    .init(
      id: "audit-policy",
      recordedAt: HarnessMonitorAuditEvent.parseDate("2026-08-05T08:38:00Z") ?? .distantPast,
      source: "policy",
      category: "automation",
      kind: "automation.policy.checked",
      severity: "info",
      outcome: "success",
      title: "Automation policy",
      summary: "Kill switch and repository scope verified"
    ),
  ]

  private static let deepTargetID = "audit-deep-72"

  private static let deepAuditEvents: [HarnessMonitorAuditEvent] = (0..<90).map { index in
    let recordedAt = Date(timeIntervalSince1970: 1_786_000_000 - Double(index * 60))
    return HarnessMonitorAuditEvent(
      id: "audit-deep-\(index)",
      recordedAt: recordedAt,
      source: "automation",
      category: "navigation",
      kind: "navigation.validation",
      severity: index == 72 ? "warning" : "info",
      outcome: index == 72 ? "attention" : "success",
      title: index == 72 ? "Exact deep event target" : "Audit event \(index)",
      summary: index == 72
        ? "The selected event began below the visible timeline"
        : "Background audit event \(index)",
      subject: "issue-1341"
    )
  }
}
