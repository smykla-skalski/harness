import Foundation
import HarnessMonitorKit

/// Perf-only bus used by `HarnessMonitorPerfDriver` to ask the live dashboard window
/// to programmatically scroll. The dashboard view listens for these notifications
/// when it detects an active perf scenario via the `HARNESS_MONITOR_PERF_SCENARIO`
/// environment variable. The bus stays inert in non-perf builds because nothing
/// posts to it.
public enum HarnessMonitorPerfDashboardScrollBus {
  /// Posted when the perf driver wants the dashboard's main scroll surface to scroll
  /// to its bottom edge.
  public static let scrollToBottom = Notification.Name(
    "io.harnessmonitor.perf.dashboardScroll.bottom"
  )

  /// Posted when the perf driver wants the dashboard's main scroll surface to scroll
  /// back to its top edge.
  public static let scrollToTop = Notification.Name(
    "io.harnessmonitor.perf.dashboardScroll.top"
  )

  /// Environment variable inspected by the dashboard view to decide whether to wire
  /// the scroll-position binding. Outside of perf runs the binding stays nil so the
  /// shared `HarnessMonitorColumnScrollView` keeps its default behavior.
  public static let scenarioEnvironmentKey = "HARNESS_MONITOR_PERF_SCENARIO"

  /// Scenario identifier this hook listens for. Kept for callers that reference
  /// the canonical scroll scenario by name; `activeScenarioIDs` is the source of
  /// truth for `isActive`.
  public static let activeScenarioID = "dashboard-live-scroll"

  /// Every scenario that wants the geometry+offset probe wired. Live-interact
  /// shares the same surface so it benefits from the same hook.
  public static let activeScenarioIDs: Set<String> = [
    "dashboard-live-scroll",
    "dashboard-live-interact",
  ]

  private static let auditComponent = "perf.dashboard-live-scroll"

  public static func isActive(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    let raw =
      environment[scenarioEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return activeScenarioIDs.contains(raw)
  }

  /// The environment cannot change after launch, so per-init callers should read this instead of re-bridging it via `isActive()`.
  public static let isActiveAtLaunch: Bool = isActive()

  /// Route scroll-trigger events through the shared perf trace bus so the audit
  /// JSONL records them alongside the driver-side scroll.post events. Without
  /// this, the os_signpost trace still gets the data but the extractor's app-trace
  /// summary stays at 0 for view-side signals.
  public static func recordTrigger(edge: String) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: auditComponent,
      event: "scroll.trigger.\(edge)"
    )
  }

  /// Same routing for geometry-change offset samples. Coalesced to >=8pt deltas
  /// so a 60Hz scroll animation does not flood the os_signpost trace (we ship
  /// one event per ~half-frame at typical scroll speeds, enough to prove the
  /// surface moved without blowing the Instruments bundle past the 90s xctrace
  /// finalize budget).
  public static func recordOffset(_ y: CGFloat) {
    let rounded = Int(y.rounded())
    let lastY = lastRecordedOffsetY.swap(rounded)
    if let lastY, abs(rounded - lastY) < 8 {
      return
    }
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: auditComponent,
      event: "scroll.offset",
      details: ["y": String(rounded)]
    )
  }

  /// Record the scroll surface's content size vs container size. Captured once
  /// per geometry transition so the audit can prove whether content > viewport.
  /// If contentH <= containerH, scrollTo(edge:) is a no-op by definition.
  public static func recordGeometry(
    contentHeight: CGFloat,
    containerHeight: CGFloat
  ) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      component: auditComponent,
      event: "scroll.geometry",
      details: [
        "content_h": String(Int(contentHeight.rounded())),
        "container_h": String(Int(containerHeight.rounded())),
      ]
    )
    latestGeometryState.update(
      contentHeight: contentHeight,
      containerHeight: containerHeight
    )
  }

  /// Latest geometry observed by the probe. The perf driver polls this so it
  /// can wait until the live daemon has streamed enough content for the scroll
  /// surface to actually exceed the viewport before posting scroll events.
  public static var latestGeometry: LatestGeometry {
    latestGeometryState.snapshot()
  }

  public struct LatestGeometry: Equatable, Sendable {
    public let contentHeight: CGFloat
    public let containerHeight: CGFloat

    public var isScrollable: Bool {
      contentHeight > containerHeight && containerHeight > 0
    }
  }

  private static let latestGeometryState = LatestGeometryState()
  private static let lastRecordedOffsetY = OptionalIntSlot()

  private final class LatestGeometryState: @unchecked Sendable {
    private let lock = NSLock()
    private var contentHeight: CGFloat = 0
    private var containerHeight: CGFloat = 0

    func update(contentHeight: CGFloat, containerHeight: CGFloat) {
      lock.lock()
      defer { lock.unlock() }
      self.contentHeight = contentHeight
      self.containerHeight = containerHeight
    }

    func snapshot() -> LatestGeometry {
      lock.lock()
      defer { lock.unlock() }
      return LatestGeometry(
        contentHeight: contentHeight,
        containerHeight: containerHeight
      )
    }
  }

  fileprivate final class OptionalIntSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?

    func swap(_ value: Int) -> Int? {
      lock.lock()
      defer { lock.unlock() }
      let previous = stored
      stored = value
      return previous
    }
  }
}
